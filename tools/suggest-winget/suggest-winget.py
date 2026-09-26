"""suggest-winget: winget ids for nixpkgs attributes, for overlays/winget.nix.

Given nixpkgs attribute names, reads what nixpkgs says about each (its name,
main program, homepage, where its source comes from) and ranks the packages of
the pinned winget-pkgs tree by how much of that their manifests share: the
same repository, the same homepage, a command of the same name, a moniker.
For the best candidates it asks lib/winget.nix -- the reader the `packages`
flake check uses -- which scopes an installer exists at, and prints the table
entry to paste, scope included.

The tree is indexed once per pin (a walk of every manifest directory, about a
quarter of a minute) and the index cached under $XDG_CACHE_HOME/winpkgs.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlsplit

WINGET_PKGS = os.environ.get("WINPKGS_WINGET_PKGS")
NIXPKGS = os.environ.get("WINPKGS_NIXPKGS")
SRC = os.environ.get("WINPKGS_SRC")
NIX_INSTANTIATE = os.environ.get("WINPKGS_NIX_INSTANTIATE", "nix-instantiate")
HERE = os.path.dirname(os.path.abspath(__file__))

# Hosts where the path, not the host, names a project.
FORGES = {"github.com", "gitlab.com", "codeberg.org", "bitbucket.org", "git.sr.ht", "sr.ht"}
# Ids that are a variant of a package rather than the package.
VARIANT = re.compile(r"\.(Preview|Nightly|Beta|Alpha|Dev|Canary|Insiders?|RC|Unstable|Portable)(\.|$)", re.I)

WEIGHTS = {
    "repository": 10,
    "homepage": 8,
    "command": 6,
    "moniker": 5,
    "id": 3,
    "name": 3,
    "site": 2,
    "tag": 1,
}
# Below this, no URL agrees: the match is on names only.
WEAK = 8


# -- versions, ordered as builtins.compareVersions orders them -------------

def _components(v):
    return [c for c in re.findall(r"[0-9]+|[^0-9.\-]+", v)]


def _cmp_component(a, b):
    if a.isdigit() and b.isdigit():
        return (int(a) > int(b)) - (int(a) < int(b))
    if a == "" and b.isdigit():
        return -1
    if a == "pre" and b != "pre":
        return -1
    if b == "pre" and a != "pre":
        return 1
    if a.isdigit():
        return 1
    if b.isdigit():
        return -1
    return (a > b) - (a < b)


def compare_versions(a, b):
    ca, cb = _components(a), _components(b)
    for i in range(max(len(ca), len(cb))):
        x = ca[i] if i < len(ca) else ""
        y = cb[i] if i < len(cb) else ""
        c = _cmp_component(x, y)
        if c:
            return c
    return 0


# -- the index -------------------------------------------------------------

def _scalar(text, key):
    m = re.search(r"^%s:[ \t]*(.*?)[ \t]*$" % re.escape(key), text, re.M)
    if not m:
        return None
    v = m.group(1)
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]
    return v or None


def _list(text, key):
    """A block sequence under `key`, at any indentation: Commands can be
    given per installer as well as at the root."""
    out = []
    for m in re.finditer(r"^([ \t]*)%s:[ \t]*\n((?:\1[ \t]*-[ \t]*.*\n?)+)" % re.escape(key), text, re.M):
        for item in re.findall(r"-[ \t]*(.*?)[ \t]*$", m.group(2), re.M):
            if len(item) >= 2 and item[0] == item[-1] and item[0] in "'\"":
                item = item[1:-1]
            if item:
                out.append(item)
    return out


def _read(path):
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def build_index(root):
    """Every package id with its newest version's locale and installer
    fields. A version directory is one holding `<id>.installer.yaml`."""
    versions = {}
    for dirpath, _dirs, files in os.walk(os.path.join(root, "manifests")):
        for f in files:
            if f.endswith(".installer.yaml"):
                pid = f[: -len(".installer.yaml")]
                versions.setdefault(pid, []).append((os.path.basename(dirpath), dirpath))
    index = []
    for pid, vs in versions.items():
        best = vs[0]
        for v in vs[1:]:
            if compare_versions(v[0], best[0]) > 0:
                best = v
        version, d = best
        main = _read(os.path.join(d, pid + ".yaml"))
        locale = _scalar(main, "DefaultLocale") or "en-US"
        loc = _read(os.path.join(d, "%s.locale.%s.yaml" % (pid, locale)))
        if not loc:
            # A singleton manifest carries everything in <id>.yaml.
            loc = main
        inst = _read(os.path.join(d, pid + ".installer.yaml"))
        index.append({
            "id": pid,
            "version": version,
            "name": _scalar(loc, "PackageName"),
            "publisher": _scalar(loc, "Publisher"),
            "moniker": _scalar(loc, "Moniker"),
            "description": _scalar(loc, "ShortDescription"),
            "tags": _list(loc, "Tags"),
            "urls": [u for u in (_scalar(loc, k) for k in (
                "PackageUrl", "PublisherUrl", "PublisherSupportUrl", "ReleaseNotesUrl")) if u],
            "installerUrls": re.findall(r"InstallerUrl:[ \t]*(\S+)", inst),
            "commands": _list(inst, "Commands"),
        })
    return index


def load_index(root, cache=True):
    key = os.path.basename(os.path.normpath(root))
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    path = os.path.join(base, "winpkgs", "suggest-winget-%s.json" % key)
    if cache and root.startswith("/nix/store/") and os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    print("indexing %s ..." % root, file=sys.stderr)
    index = build_index(root)
    if cache and root.startswith("/nix/store/"):
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path + ".tmp", "w") as f:
                json.dump(index, f)
            os.replace(path + ".tmp", path)
        except OSError:
            pass
    return index


# -- matching --------------------------------------------------------------

def _norm(word):
    return re.sub(r"[^a-z0-9]", "", (word or "").lower())


def _command(c):
    c = c.lower()
    for ext in (".exe", ".cmd", ".bat", ".com"):
        if c.endswith(ext):
            return c[: -len(ext)]
    return c


def url_keys(url):
    """("repository", "github.com/owner/repo") for a forge URL, else
    ("homepage", "host/path") and ("site", "host")."""
    try:
        u = urlsplit(url.strip())
    except ValueError:
        return []
    host = (u.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    if not host:
        return []
    parts = [p for p in u.path.split("/") if p]
    if host in FORGES:
        if len(parts) >= 2:
            repo = parts[1].lower()
            if repo.endswith(".git"):
                repo = repo[:-4]
            return [("repository", "%s/%s/%s" % (host, parts[0].lower(), repo))]
        return []
    path = "/".join(parts).lower()
    keys = [("site", host)]
    keys.append(("homepage", host + ("/" + path if path else "")))
    return keys


class Matcher:
    def __init__(self, index):
        self.index = index
        self.by = {k: {} for k in WEIGHTS}
        for i, e in enumerate(index):
            for kind, key in self._keys(e):
                self.by[kind].setdefault(key, set()).add(i)

    @staticmethod
    def _keys(e):
        for u in e["urls"] + e["installerUrls"]:
            for kind, key in url_keys(u):
                # An installer URL names where the download is, not the
                # project's page: its repository counts, its path does not.
                if kind == "homepage" and u not in e["urls"]:
                    continue
                if kind == "site" and u not in e["urls"]:
                    continue
                yield kind, key
        for c in e["commands"]:
            yield "command", _command(c)
        if e["moniker"]:
            yield "moniker", _norm(e["moniker"])
        yield "id", _norm(e["id"].split(".")[-1])
        if len(e["id"].split(".")) > 2:
            # BurntSushi.ripgrep.MSVC: the name is the middle.
            yield "id", _norm(e["id"].split(".")[1])
        if e["name"]:
            yield "name", _norm(e["name"])
        for t in e["tags"]:
            yield "tag", _norm(t)

    def candidates(self, meta, limit):
        names = {_norm(n) for n in (meta["name"].split(".")[-1], meta.get("pname")) if n}
        commands = {_command(c) for c in (meta.get("mainProgram"), meta.get("pname"), meta["name"].split(".")[-1]) if c}
        wanted = []
        for u in meta.get("homepages", []):
            wanted += url_keys(u)
        for u in meta.get("urls", []):
            wanted += [k for k in url_keys(u) if k[0] == "repository"]
        wanted += [("command", c) for c in commands]
        for n in names:
            wanted += [("moniker", n), ("id", n), ("name", n), ("tag", n)]

        scores = {}
        for kind, key in set(wanted):
            for i in self.by[kind].get(key, ()):
                s = scores.setdefault(i, {})
                s[kind] = key
        ranked = []
        for i, why in scores.items():
            e = self.index[i]
            score = sum(WEIGHTS[k] for k in why)
            # A site match alone is noise: every package from a big vendor.
            if set(why) <= {"site", "tag"}:
                continue
            if VARIANT.search(e["id"]):
                score -= 3
            ranked.append((score, e, why))
        ranked.sort(key=lambda r: (-r[0], len(r[1]["id"]), r[1]["id"]))
        return ranked[:limit]


# -- nix -------------------------------------------------------------------

def nix_eval(expr_file, **args):
    cmd = [NIX_INSTANTIATE, "--eval", "--strict", "--json", os.path.join(HERE, expr_file)]
    for k, v in args.items():
        cmd += ["--argstr" if isinstance(v, str) else "--arg", k, v if isinstance(v, str) else nix_list(v)]
    out = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, text=True)
    return json.loads(out.stdout)


def nix_list(xs):
    return "[ %s ]" % " ".join(json.dumps(x) for x in xs)


# -- output ----------------------------------------------------------------

def entry(attr, cand):
    """The overlays/winget.nix line for this attribute and candidate."""
    name = attr if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_'-]*", attr) else json.dumps(attr)
    pid = json.dumps(cand["id"])
    scope = cand.get("scope")
    if scope is None:
        return "%s = %s;" % (name, pid)
    return "%s = {\n  id = %s;\n  scope = \"%s\";\n};" % (name, pid, scope)


def with_scope(c):
    """Which scope the table must name: none when both work."""
    if c.get("error"):
        return c
    m, u = c.get("machine"), c.get("user")
    if m and u:
        c["scope"] = None
    elif m:
        c["scope"] = "machine"
    elif u:
        c["scope"] = "user"
    else:
        c["error"] = "no installer at either scope"
    return c


def report(results, out):
    for r in results:
        m = r["meta"]
        head = r["attr"]
        bits = []
        if m.get("pname"):
            bits.append(("%s %s" % (m["pname"], m.get("version") or "")).strip())
        if m.get("homepages"):
            bits.append(m["homepages"][0])
        if m.get("mainProgram"):
            bits.append("runs %s" % m["mainProgram"])
        if bits:
            head += "  (" + ", ".join(bits) + ")"
        print(head, file=out)
        mapping = m.get("mapping")
        if mapping is not None:
            print("  already in the table: %s" % (mapping["id"] or "null (no Windows build)"), file=out)
        if not m.get("found"):
            print("  not a package in the pinned nixpkgs", file=out)
            print(file=out)
            continue
        if not r["candidates"]:
            print("  no candidates in winget-pkgs; if winget has it under another name,", file=out)
            print("  pkgs.winpkgs.fromWinget \"Publisher.Id\" names it directly", file=out)
            print(file=out)
            continue
        for n, c in enumerate(r["candidates"], 1):
            scope = ""
            if "scope" in c or c.get("error"):
                scope = c["error"] if c.get("error") else (c["scope"] or "either scope") + " "
            print("  %d. %-40s %-14s score %2d  %s%s" % (
                n, c["id"], c["version"], c["score"], ("[" + scope.strip() + "] ") if scope else "",
                ", ".join("%s %s" % (k, v) for k, v in sorted(c["why"].items(), key=lambda kv: -WEIGHTS[kv[0]]))),
                file=out)
        best = r["candidates"][0]
        if len(r["candidates"]) > 1 and r["candidates"][1]["score"] == best["score"]:
            print("  (the first two score the same: check which one you want)", file=out)
        elif best["score"] < WEAK:
            print("  (a weak match, on %s alone: check it is the same program)" % " and ".join(sorted(best["why"])),
                  file=out)
        if best.get("error"):
            print("  %s: %s" % (best["id"], best["error"]), file=out)
        else:
            print("  entry:", file=out)
            for line in entry(r["attr"], best).splitlines():
                print("    " + line, file=out)
        print(file=out)


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="suggest-winget",
        description="Suggest overlays/winget.nix entries for nixpkgs attributes from the pinned winget-pkgs.")
    p.add_argument("attrs", nargs="+", metavar="ATTR", help="nixpkgs attribute names, e.g. ripgrep fd")
    p.add_argument("-n", "--limit", type=int, default=5, help="candidates per attribute (default 5)")
    p.add_argument("--json", action="store_true", help="print JSON instead of text")
    p.add_argument("--no-scope", action="store_true",
                   help="skip reading installer manifests for scopes")
    p.add_argument("--meta", help=argparse.SUPPRESS)  # precomputed meta.nix output, for tests
    p.add_argument("--winget-pkgs", default=WINGET_PKGS, help=argparse.SUPPRESS)
    a = p.parse_args(argv)
    if not a.winget_pkgs:
        p.error("no winget-pkgs tree (WINPKGS_WINGET_PKGS)")

    if a.meta:
        with open(a.meta) as f:
            metas = json.load(f)
    else:
        metas = nix_eval("meta.nix", nixpkgs=NIXPKGS, src=SRC, attrs=a.attrs)
    matcher = Matcher(load_index(a.winget_pkgs))

    results = []
    for meta in metas:
        cands = [dict(e, score=s, why=why) for s, e, why in
                 (matcher.candidates(meta, a.limit) if meta.get("found") else [])]
        results.append({"attr": meta["name"], "meta": meta, "candidates": cands})

    if not a.no_scope:
        # The first three of each: enough to choose between close scores.
        ids = sorted({c["id"] for r in results for c in r["candidates"][:3]})
        if ids:
            scopes = {s["id"]: s for s in nix_eval(
                "scope.nix", nixpkgs=NIXPKGS, src=SRC, wingetPkgs=a.winget_pkgs, ids=ids)}
            for r in results:
                for c in r["candidates"][:3]:
                    s = scopes[c["id"]]
                    c.update({k: s.get(k) for k in ("machine", "user", "error")})
                    with_scope(c)

    if a.json:
        json.dump(results, sys.stdout, indent=2)
        print()
    else:
        report(results, sys.stdout)


if __name__ == "__main__":
    main()
