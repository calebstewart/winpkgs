# Local accounts and groups, with NixOS's names: `users.users.<name>` and
# `users.groups.<name>`. What a user's *home* holds is a home configuration's
# business; this is the account itself -- that it exists, what it is called,
# which groups it is in -- which only the machine can say.
#
# Where NixOS and Windows mean the same thing the option is NixOS's:
# `description` is the full name, `extraGroups` and `members` are group
# membership, `initialPassword` is the password an account starts with, and
# `wheel` is Administrators. Where they do not, the option is left undeclared
# rather than faked: a SID is assigned, not chosen (`uid`, `gid`); a profile is
# made at the first sign-in, not beforehand (`home`, `createHome`); and a
# password Nix could keep would be one anybody can read out of the store
# (`hashedPassword`, `password`). Windows' own account settings are here under
# Windows' names (`passwordNeverExpires`, `userMayChangePassword`).
#
# An account that is not there is created with its initial password --
# `users.defaultInitialPassword` unless it names its own, blank if that is
# `null` -- and the password is expired, so the first sign-in has to replace
# it. It is not a secret and is not meant to be one. An account that is there
# already is managed: its declared settings are kept, its password never
# touched. So is a group; built-in groups are never created, only joined.
#
# Membership is `windows.localGroups`' (local-groups.nix), which this feeds:
# `extraGroups`, a group's `members`, and the built-in Users group for an
# `isNormalUser`. A group or account winpkgs created is owned: a group leaves
# with the configuration (`winpkgs.prune.groups`), an account only when asked
# (`winpkgs.prune.users`).
{
  lib,
  config,
  winpkgsSrc,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.users;
  builtin = import ./builtin-groups.nix { inherit lib; };
  installer = import ../../lib/installer.nix { inherit lib winpkgsSrc; };

  users = lib.attrValues cfg.users;
  groups = lib.attrValues cfg.groups;

  # NixOS's administrators' group is Windows' Administrators, and a built-in
  # group is spelled one way however it was written, so that `users` and
  # `Users` are one group in `windows.localGroups` as they are on the machine.
  canonicalGroup = g: if lib.toLower g == "wheel" then "Administrators" else builtin.canonicalName g;

  userOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          defaultText = lib.literalMD "the attribute name";
          description = ''
            The account name: what the account is signed in to with and what
            `C:\Users\` names its profile after. Up to 20 characters, none of
            `" / \ [ ] : ; | = , + * ? < >`, and not the computer's name.
          '';
        };

        description = mkOption {
          type = types.str;
          default = "";
          example = "Alice Q. User";
          description = ''
            The account's full name, as NixOS uses this option: the name the
            sign-in screen and the Start menu show. Empty leaves whatever the
            account has.
          '';
        };

        isNormalUser = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether the account is a member of the built-in Users group, which
            is what lets an account sign in to the machine and use it. Every
            account winpkgs creates is a normal local account; there is no
            Windows counterpart to NixOS's system users.
          '';
        };

        extraGroups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "wheel"
            "Hyper-V Administrators"
            "docker-users"
          ];
          description = ''
            Local groups the account is a member of, by name -- `wheel` is
            Administrators -- or by SID. The same as listing the account in each
            group's `members`; see `windows.localGroups` for how a group is
            found. A group that neither Windows nor `users.groups` makes has to
            exist by the time the membership is applied (an installer's, say).
          '';
        };

        initialPassword = mkOption {
          type = types.nullOr types.str;
          default = cfg.defaultInitialPassword;
          defaultText = lib.literalExpression "config.users.defaultInitialPassword";
          description = ''
            The password the account is created with, or `null` for a blank
            one. Only ever written when winpkgs creates the account, and expired
            as it is, so the first sign-in has to choose a new one -- unless
            `passwordNeverExpires` or `userMayChangePassword = false` means
            Windows cannot ask for that. Not a secret: it is in the configuration
            and the Nix store. A blank password cannot be used over the network,
            only at the console.
          '';
        };

        passwordNeverExpires = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            Whether the account's password is exempt from the machine's maximum
            password age. `true` also means an account winpkgs creates does not
            have to change its initial password. `null` leaves it as it is.
          '';
        };

        userMayChangePassword = mkOption {
          type = types.nullOr types.bool;
          default = null;
          description = ''
            Whether the account may change its own password. `false` also means
            an account winpkgs creates keeps its initial password, since it
            could not choose another. `null` leaves it as it is.
          '';
        };
      };
    };

  groupOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          defaultText = lib.literalMD "the attribute name";
          description = ''
            The group's name. A built-in group (`Administrators`, `Users`,
            `Hyper-V Administrators`, NixOS's `wheel`, ...) is matched whatever
            the case and whatever the machine's language calls it; any other is
            created when the machine has none by this name.
          '';
        };

        members = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "alice"
            "DOMAIN\\bob"
          ];
          description = ''
            Accounts in the group, besides those that name it in their
            `extraGroups`: local users by name, `DOMAIN\user`,
            `MicrosoftAccount\address`, or SIDs.
          '';
        };

        description = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            The group's description, for a group that is not built in. `null`
            leaves it as it is.
          '';
        };
      };
    };

  # `windows.localGroups` membership, by the name the group goes by there.
  memberships =
    lib.foldl'
      (acc: e: acc // { ${e.group} = (acc.${e.group} or [ ]) ++ [ e.member ]; })
      { }
      (
        lib.concatMap (u: map (g: { group = canonicalGroup g; member = u.name; }) u.extraGroups) users
        ++ map (u: { group = "Users"; member = u.name; }) (lib.filter (u: u.isNormalUser) users)
        ++ lib.concatMap (g: map (m: { group = canonicalGroup g.name; member = m; }) g.members) groups
      );

  # A group named by SID is one the machine already has.
  createdGroups = lib.filter (
    g: !builtin.isBuiltin (canonicalGroup g.name) && builtins.match "S-1-[0-9-]+" g.name == null
  ) groups;

  # Windows' rules for a local account name.
  badUserName =
    n:
    lib.stringLength n < 1
    || lib.stringLength n > 20
    || lib.any (c: lib.hasInfix c n) [
      "\""
      "/"
      "\\"
      "["
      "]"
      ":"
      ";"
      "|"
      "="
      ","
      "+"
      "*"
      "?"
      "<"
      ">"
    ]
    || builtins.match "[. ]*" n != null;

  lower = map lib.toLower;
  userNames = map (u: u.name) users;
  groupNames = map (g: g.name) groups;
  duplicates = xs: lib.filter (x: lib.count (y: y == x) xs > 1) (lib.unique xs);
  hostName = config.networking.hostName or null;
in
{
  options.users = {
    users = mkOption {
      type = types.attrsOf (types.submodule userOpts);
      default = { };
      example = lib.literalExpression ''
        {
          alice = {
            description = "Alice Q. User";
            extraGroups = [ "wheel" "Hyper-V Administrators" ];
          };
          kid = {
            initialPassword = null;
            extraGroups = [ "family" ];
          };
        }
      '';
      description = ''
        Local accounts, with NixOS's option names. One the machine does not
        have is created with its `initialPassword`, which it must change at its
        first sign-in; one it has is managed -- its declared settings kept, its
        password left alone. An account winpkgs created that leaves this set is
        deleted only under `winpkgs.prune.users`.

        With `winpkgs.installer`, one of these is the account Setup creates
        (`winpkgs.installer.user`).
      '';
    };

    groups = mkOption {
      type = types.attrsOf (types.submodule groupOpts);
      default = { };
      example = lib.literalExpression ''
        {
          family.members = [ "alice" "kid" ];
          wheel.members = [ "alice" ];
        }
      '';
      description = ''
        Local groups, with NixOS's option names. A group that is not built in
        and that the machine does not have is created, and deleted again when it
        leaves this set (`winpkgs.prune.groups`); built-in groups are only
        joined. Membership is carried by `windows.localGroups`.
      '';
    };

    defaultInitialPassword = mkOption {
      type = types.nullOr types.str;
      default = installer.defaultPassword;
      defaultText = lib.literalExpression ''"${installer.defaultPassword}"'';
      example = null;
      description = ''
        The password an account in `users.users` is created with unless it names
        its own `initialPassword`; `null` creates accounts with a blank one. It
        is expired as it is set, so each account chooses its real password at
        its first sign-in. Not a secret, and not meant to be: it is in the
        configuration, and so in the Nix store and on installation media.
      '';
    };
  };

  config = {
    windows.localGroups = lib.mapAttrs (_: members: { inherit members; }) memberships;

    winpkgs.resources =
      map (g: {
        type = "winpkgs/localGroup";
        id = "Group ${g.name}";
        scope = "machine";
        properties = {
          inherit (g) name description;
        };
      }) createdGroups
      ++ map (u: {
        type = "winpkgs/localUser";
        id = "User ${u.name}";
        scope = "machine";
        properties = {
          inherit (u)
            name
            initialPassword
            passwordNeverExpires
            userMayChangePassword
            ;
          fullName = if u.description == "" then null else u.description;
        };
      }) users;

    assertions = [
      {
        assertion = lib.all (u: !badUserName u.name) users;
        message = "users.users: a Windows account name is 1 to 20 characters, not only dots and spaces, and none of \" / \\ [ ] : ; | = , + * ? < >: ${
          lib.concatMapStringsSep ", " (n: "\"${n}\"") (lib.filter badUserName userNames)
        }";
      }
      {
        assertion = duplicates (lower userNames) == [ ];
        message = "users.users: Windows account names are not case-sensitive, so these are one account: ${lib.concatStringsSep ", " (duplicates (lower userNames))}";
      }
      {
        assertion = duplicates (lower groupNames) == [ ];
        message = "users.groups: Windows group names are not case-sensitive, so these are one group: ${lib.concatStringsSep ", " (duplicates (lower groupNames))}";
      }
      {
        assertion = lib.intersectLists (lower userNames) (lower (map (g: g.name) createdGroups)) == [ ];
        message = "users: Windows will not have a local account and a local group by the same name: ${
          lib.concatStringsSep ", " (lib.intersectLists (lower userNames) (lower (map (g: g.name) createdGroups)))
        }";
      }
      {
        assertion = hostName == null || !(lib.elem (lib.toLower hostName) (lower userNames));
        message = "users.users: Windows refuses a local account named after the computer ('${toString hostName}').";
      }
      {
        assertion = lib.all (g: g.description == null || !builtin.isBuiltin (canonicalGroup g.name)) groups;
        message = "users.groups: a built-in group's description is Windows' own; remove `description` from ${
          lib.concatMapStringsSep ", " (g: g.name) (
            lib.filter (g: g.description != null && builtin.isBuiltin (canonicalGroup g.name)) groups
          )
        }";
      }
    ];
  };
}
