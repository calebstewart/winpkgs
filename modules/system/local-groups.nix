# Local group membership: `windows.localGroups.<group>.members` names the
# accounts a group has. Group-shaped rather than `users.users.<name>.extraGroups`
# because a Windows system configuration has no honest `users.users`: it
# neither creates accounts nor describes them. Membership is the one part
# that translates, and it maps one-to-one onto Get-/Add-/Remove-LocalGroupMember.
#
# The concrete case is Hyper-V from an unelevated session: a member of the
# built-in Hyper-V Administrators group controls VMs without elevating, and
# UAC's filtered token keeps that group, so an administrator's ordinary shell
# -- and any per-user service started from their logon -- has it. Remote
# Desktop Users, Performance Log Users and docker-users are the same shape.
#
# Built-in groups are carried as their well-known SIDs: their names are
# localised, the SIDs are not. Any other group, and every member, is resolved
# on the machine, and everything is compared by SID. Nothing here creates a
# group or an account.
#
# A member winpkgs added is removed again when it leaves the configuration
# (`winpkgs.prune.groupMembers`); one that was already a member is only
# managed. Membership reaches a user's logon token at their next sign-in.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.windows.localGroups;

  # The built-in aliases a client Windows has, by their well-known SIDs.
  builtin = {
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

  # A built-in name becomes its SID; a SID or any other name passes through
  # for the machine to resolve.
  resolve = name: builtin.${name} or name;

  group = types.submodule {
    options.members = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "me"
        "DOMAIN\\someone"
        "S-1-5-21-1111111111-2222222222-3333333333-1001"
      ];
      description = ''
        Accounts that are members of the group, by name -- a local user, a
        `DOMAIN\user`, a `MicrosoftAccount\address` -- or by SID. Each is
        added if it is not already a member; one winpkgs added is removed
        again when it leaves this list. An account that does not exist is an
        error at apply time.
      '';
    };
  };
in
{
  options.windows.localGroups = mkOption {
    type = types.attrsOf group;
    default = { };
    example = lib.literalExpression ''
      {
        "Hyper-V Administrators".members = [ "me" ];
        docker-users.members = [ "me" ];
      }
    '';
    description = ''
      Local groups by name or SID, and who is in them. The built-in groups
      (`Administrators`, `Remote Desktop Users`, `Hyper-V Administrators`,
      ...) may be named in English whatever the machine's language: they are
      carried by their well-known SID. Any other group -- `docker-users`, one
      an installer created -- is looked up by name on the machine, and must
      already exist; winpkgs creates neither groups nor accounts. Membership
      takes effect at the user's next sign-in.
    '';
  };

  config.winpkgs.resources = lib.concatLists (
    lib.mapAttrsToList (
      name: g:
      map (member: {
        type = "winpkgs/groupMember";
        id = "Group ${name}: ${member}";
        scope = "machine";
        properties = {
          group = resolve name;
          inherit member;
        };
      }) (lib.unique g.members)
    ) cfg
  );
}
