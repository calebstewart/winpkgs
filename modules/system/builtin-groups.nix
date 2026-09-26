# The built-in local groups a client Windows has, by their well-known SIDs:
# their names are localised, the SIDs are not. Shared by `windows.localGroups`,
# which carries a built-in group as its SID, and `users.groups`, which never
# creates one.
{ lib }:
rec {
  sids = {
    "Administrators" = "S-1-5-32-544";
    "Users" = "S-1-5-32-545";
    "Guests" = "S-1-5-32-546";
    "Power Users" = "S-1-5-32-547";
    "Backup Operators" = "S-1-5-32-551";
    "Replicator" = "S-1-5-32-552";
    "Remote Desktop Users" = "S-1-5-32-555";
    "Network Configuration Operators" = "S-1-5-32-556";
    "Performance Monitor Users" = "S-1-5-32-558";
    "Performance Log Users" = "S-1-5-32-559";
    "Distributed COM Users" = "S-1-5-32-562";
    "IIS_IUSRS" = "S-1-5-32-568";
    "Cryptographic Operators" = "S-1-5-32-569";
    "Event Log Readers" = "S-1-5-32-573";
    "Hyper-V Administrators" = "S-1-5-32-578";
    "Access Control Assistance Operators" = "S-1-5-32-579";
    "Remote Management Users" = "S-1-5-32-580";
    "System Managed Accounts Group" = "S-1-5-32-581";
    "Device Owners" = "S-1-5-32-583";
    "User Mode Hardware Operators" = "S-1-5-32-584";
    "OpenSSH Users" = "S-1-5-32-585";
  };

  administrators = sids."Administrators";

  # Windows compares group names without regard to case, and so does this.
  byLowerName = lib.mapAttrs' (n: v: lib.nameValuePair (lib.toLower n) v) sids;

  # A built-in group's name as Windows spells it in English; any other as given.
  canonicalName =
    name: lib.findFirst (n: lib.toLower n == lib.toLower name) name (lib.attrNames sids);

  # The SID of a built-in group named in any case, or the name itself -- a SID,
  # or a group the machine has to resolve.
  sidOf = name: byLowerName.${lib.toLower name} or name;

  isBuiltin = name: byLowerName ? ${lib.toLower name} || lib.elem name (lib.attrValues sids);
}
