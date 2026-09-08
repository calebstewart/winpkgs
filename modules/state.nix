# Policy for the state the runtime keeps on the machine: what it may remove
# when the configuration stops mentioning it, and how many generations to keep.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.winpkgs.prune = {
    winget = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Uninstall winget packages that winpkgs installed earlier but that are no
        longer declared. Only packages recorded in winpkgs' own ledger are ever
        removed; nothing pre-existing is touched.
      '';
    };

    files = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Delete files that winpkgs *created* and that are no longer declared
        (removed from the configuration, or `enable = false`). A file that
        already existed when winpkgs first wrote it is not owned and is left in
        place with winpkgs' content. Deletions are journaled, so `rollback`
        brings the file back.
      '';
    };
  };

  options.winpkgs.generations = {
    keep = mkOption {
      type = types.ints.unsigned;
      default = 10;
      description = ''
        How many of the most recent generations to keep, per scope, whatever
        their age. Older ones are deleted at the end of each apply, together
        with the backups that make their rollback possible.
      '';
    };

    deleteOlderThan = mkOption {
      type = types.nullOr (types.strMatching "[0-9]+[dhm]?");
      default = null;
      example = "30d";
      description = ''
        Only delete generations older than this (`30d`, `12h`, `90m`; a bare
        number is days), still keeping the newest `keep` regardless. `null`
        deletes purely by count.
      '';
    };
  };
}
