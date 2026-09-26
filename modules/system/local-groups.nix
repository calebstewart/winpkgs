# Local group membership: `windows.localGroups.<group>.members` names the
# accounts a group has. It maps one-to-one onto Get-/Add-/Remove-LocalGroupMember,
# and it is what `users.users.<name>.extraGroups` and `users.groups.<name>.members`
# (users.nix) are translated to: this is the membership of any group, whoever
# made the group and the account, and it creates neither.
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
# group or an account; `users.groups` and `users.users` do.
#
# A member winpkgs added is removed again when it leaves the configuration
# (`winpkgs.prune.groupMembers`); one that was already a member is only
# managed. Membership reaches a user's logon token at their next sign-in.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.windows.localGroups;

  builtin = import ./builtin-groups.nix { inherit lib; };

  # A built-in name, in any case, becomes its SID; a SID or any other name
  # passes through for the machine to resolve.
  resolve = name: builtin.sidOf name;

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
      exist by the time the membership is applied: this option creates
      neither groups nor accounts, `users.groups` and `users.users` do.
      Membership takes effect at the user's next sign-in.
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
