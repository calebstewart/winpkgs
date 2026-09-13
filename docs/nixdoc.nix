# Nix library function extraction.
#
# nixdoc reads RFC-145 doc-comments -- /** ... */ immediately above a binding --
# and emits structured entries. It ignores ordinary "#" comments entirely, so a
# function commented the old way is not documented badly, it is absent.
{ lib }:
{
  /**
    Run nixdoc over a flake's library files and collect the results.

    Each namespace becomes one page. `prefix` and `category` together decide the
    name a function is documented under: nixdoc renders `<prefix>.<category>.<fn>`,
    so a `lib.docs` namespace wants `prefix = "lib"` and `category = "docs"`.

    A namespace may name several files. nixdoc reads one file at a time, but a
    namespace assembled by re-exporting from its neighbours -- which is what a
    `lib/<name>/` directory usually is -- is one thing to its callers and should
    be one page to its readers.

    # Inputs

    `namespaces`
    : List of `{ name, files, category, prefix, description }` records, normally
      straight out of the configuration file.

    # Type

    ```
    mkLibDocs :: AttrSet -> Derivation
    ```
  */
  mkLibDocs =
    {
      pkgs,
      src,
      repoUrl,
      branch,
      namespaces,
    }:
    let
      jq = lib.getExe pkgs.jq;

      # nixdoc's output carries no provenance: it does not say which file it
      # read or what the namespace should be called. Each file's entries are
      # therefore tagged with their source here, before the namespace's files
      # are folded into one document.
      runFile = ns: file: ''
        ${lib.getExe pkgs.nixdoc} \
          --json-output \
          --prefix ${lib.escapeShellArg (ns.prefix or "lib")} \
          --category ${lib.escapeShellArg ns.category} \
          --description ${lib.escapeShellArg (ns.description or ns.name)} \
          --file ${lib.escapeShellArg "${src}/${file}"} \
          > entries.json

        ${jq} \
          --arg file ${lib.escapeShellArg file} \
          --arg url ${lib.escapeShellArg "${repoUrl}/blob/${branch}/${file}"} \
          '(.entries // []) | map(. + { file: $file, url: $url })' \
          entries.json >> entries.jsonl
      '';

      runNamespace = ns: ''
        : > entries.jsonl
        ${lib.concatMapStringsSep "\n" (runFile ns) (ns.files or [ ns.file ])}

        ${jq} -s \
          --arg name ${lib.escapeShellArg ns.name} \
          --arg description ${lib.escapeShellArg (ns.description or "")} \
          '{ name: $name, description: $description, entries: (add // []) }' \
          entries.jsonl >> namespaces.jsonl
      '';
    in
    pkgs.runCommand "flakedoc-lib.json" { } ''
      : > namespaces.jsonl
      ${lib.concatMapStringsSep "\n" runNamespace namespaces}
      ${jq} -s '.' namespaces.jsonl > $out
    '';
}
