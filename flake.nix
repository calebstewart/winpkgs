{
  description = "winpkgs - declarative Windows configuration: Nix evaluates, PowerShell applies";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Makes the embedded WSL distro (winpkgs.wsl) a NixOS-WSL system.
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
    }:
    let
      inherit (nixpkgs) lib;
      # Systems that *evaluate* configurations (WSL, CI). The target is always Windows.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      winpkgsLib = import ./lib {
        inherit
          lib
          self
          nixpkgs
          nixos-wsl
          ;
      };
    in
    {
      lib = winpkgsLib;

      # The full module tree, for consumers who want to evalModules themselves.
      windowsModules.default = import ./modules;

      templates.default = {
        path = ./template;
        description = "A flake with one winpkgs Windows configuration";
      };

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          example = winpkgsLib.windowsSystem {
            inherit system;
            modules = [ ./example/configuration.nix ];
          };
          withWsl = winpkgsLib.windowsSystem {
            inherit system;
            modules = [
              ./example/configuration.nix
              {
                winpkgs.wsl.enable = true;
                winpkgs.wsl.modules = [ { system.stateVersion = "26.05"; } ];
              }
            ];
          };
          advanced = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'';
          personalize = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'';
          advertising = ''HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'';
          dataCollection = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'';
        in
        {
          example = example.config.system.build.toplevel;

          # The example lists Microsoft.PowerShell and winpkgs.powershell ensures
          # it too: they must merge into one resource that upgrades.
          merge =
            pkgs.runCommand "winpkgs-merge"
              {
                doc = builtins.toJSON example.config.system.build.document;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                n=$(echo "$doc" | jq '[.resources[] | select(.id == "Microsoft.PowerShell")] | length')
                up=$(echo "$doc" | jq '.resources[] | select(.id == "Microsoft.PowerShell") | .properties.upgrade')
                test "$n" = 1 && test "$up" = true
                echo ok > $out
              '';

          # The contract the sugar modules live by: the right value for the
          # right name, nothing at all for an option left unset, and second
          # place behind an entry written by hand.
          sugar =
            let
              doc =
                extra:
                builtins.toJSON
                  (winpkgsLib.windowsSystem {
                    inherit system;
                    modules = [
                      {
                        winpkgs.name = "sugar";
                        winpkgs.cli.enable = false;
                        winpkgs.explorer = {
                          showHiddenFiles = true;
                          showFileExtensions = true;
                        };
                        winpkgs.taskbar.combineButtons = "never";
                        winpkgs.theme.mode = "dark";
                        winpkgs.privacy = {
                          advertisingId = false;
                          telemetry = "required";
                        };
                      }
                    ]
                    ++ extra;
                  }).config.system.build.document;
            in
            pkgs.runCommand "winpkgs-sugar"
              {
                # Keys travel as env vars so that no backslash has to survive
                # Nix, the shell and jq in turn.
                inherit
                  advanced
                  personalize
                  advertising
                  dataCollection
                  ;
                doc = doc [ ];
                overridden = doc [ { winpkgs.registry.${advanced}.Hidden = 2; } ];
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                # <doc> <key> <name> [field, default .properties.value]
                v() {
                  jq -r --arg k "$2" --arg n "$3" --arg f "''${4-value}" \
                    '[.resources[] | select(.properties.key == $k and .properties.name == $n)]
                     | if length == 1
                       then (if $f == "scope" then .[0].scope else .[0].properties[$f] end | tostring)
                       else "MISSING" end' <<<"$1"
                }

                # The two mistakes this module exists to stop anyone making
                # twice: Hidden is 1/2, and HideFileExt runs backwards.
                test "$(v "$doc" "$advanced" Hidden)" = 1
                test "$(v "$doc" "$advanced" HideFileExt)" = 0

                # One option, both taskbar-grouping values.
                test "$(v "$doc" "$advanced" TaskbarGlomLevel)" = 2
                test "$(v "$doc" "$advanced" MMTaskbarGlomLevel)" = 2

                # A theme key holds no `\Explorer`, so this is `restartKeys`
                # working -- and without it the theme is written and nothing on
                # screen changes.
                test "$(v "$doc" "$personalize" AppsUseLightTheme)" = 0
                test "$(v "$doc" "$personalize" AppsUseLightTheme restartExplorer)" = true

                # Scope is derived from the hive, so one module can span both.
                test "$(v "$doc" "$advertising" Enabled scope)" = user
                test "$(v "$doc" "$dataCollection" AllowTelemetry scope)" = machine

                # Unset means unmanaged: no resource at all.
                test "$(v "$doc" "$advanced" LaunchTo)" = MISSING

                # A hand-written entry beats the sugar's mkDefault -- and "= 2"
                # rather than "MISSING" is also the proof that it replaced the
                # definition instead of adding a second, duplicate-id resource.
                test "$(v "$overridden" "$advanced" Hidden)" = 2

                echo ok > $out
              '';

          # Two hand-written definitions of one value that disagree have to fail
          # evaluation rather than silently pick one -- which is what `listOf`'s
          # concatenating merge used to do to MultiStrings.
          conflict =
            let
              throws =
                v1: v2:
                let
                  doc =
                    (winpkgsLib.windowsSystem {
                      inherit system;
                      modules = [
                        { winpkgs.name = "conflict"; }
                        { winpkgs.registry.${advanced}.X = v1; }
                        { winpkgs.registry.${advanced}.X = v2; }
                      ];
                    }).config.system.build.document;
                in
                if (builtins.tryEval (builtins.deepSeq doc doc)).success then "no" else "yes";
            in
            pkgs.runCommand "winpkgs-conflict"
              {
                dword = throws 1 2;
                multi = throws [ "a" ] [ "b" ];
                agreed = throws 1 1;
              }
              ''
                test "$dword" = yes
                test "$multi" = yes
                test "$agreed" = no
                echo ok > $out
              '';

          # Proves the embedded NixOS-WSL system evaluates, without building a
          # whole NixOS closure in CI: instantiate its toplevel and record the
          # .drv path only.
          wsl-eval =
            pkgs.runCommand "winpkgs-wsl-eval"
              {
                drv = builtins.unsafeDiscardStringContext withWsl.config.system.build.wsl.config.system.build.toplevel.drvPath;
                hostName = withWsl.config.system.build.wsl.config.networking.hostName;
              }
              ''
                test "$hostName" = example
                echo "$drv" > $out
              '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
