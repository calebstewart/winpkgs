# The local groups this home's user is to be in. Membership is machine state
# -- the SAM, `Add-LocalGroupMember`, an elevated write -- and a home
# configuration never elevates, so the home does not add itself to a group: it
# says which groups it wants, and the system configuration that lists it in
# `winpkgs.homes` adds the user, elevated (`modules/system/homes.nix`). The
# same shape as `winpkgs.machinePackages`, and for the same reason: the user
# declares where the want belongs, the system does what only it can do.
#
# Written by the home rather than computed, unlike `machinePackages`: there is
# nothing to derive a group from. It is not `users.users.<name>.extraGroups`
# -- a home configuration is one user and has no `users.users`, which is the
# same reason the system spells it `windows.localGroups.<group>.members`
# rather than borrowing NixOS's name -- and it is not `windows.localGroups`
# either, which is group-shaped, machine scope, and so lives in the system
# tree. `winpkgs.*` is where the options that travel between the two trees
# already are.
{ lib, ... }:
{
  options.winpkgs.groups = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [
      "Hyper-V Administrators"
      "docker-users"
    ];
    description = ''
      Local groups this home's user is to be a member of, by name or SID. The
      system configuration that lists this home in `winpkgs.homes` adds the
      user -- the part of `winpkgs.name` before its last `@` -- to each one,
      as `windows.localGroups.<group>.members`; a home no system configuration
      lists adds nobody to anything. The built-in groups (`Hyper-V
      Administrators`, `Remote Desktop Users`, ...) may be named in English
      whatever the machine's language: the system module carries them by their
      well-known SID. Neither the group nor the account is created. Membership
      reaches the user's logon token at their next sign-in.
    '';
  };
}
