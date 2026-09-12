{
  description = "winpkgs - declarative Windows configuration: Nix evaluates, PowerShell applies";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Makes the embedded WSL distro (`wsl.enable`) a NixOS-WSL system.
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # A home configuration evaluates home-manager's own modules; winpkgs
    # translates what they produce (files, variables, packages) to Windows.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
      home-manager,
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
          home-manager
          ;
      };
    in
    {
      lib = winpkgsLib;

      # The two module trees, for consumers who want to evalModules themselves.
      # The home tree expects home-manager's modules beside it (see
      # lib/default.nix); `homeConfiguration` is the assembled form.
      windowsModules = {
        system = import ./modules/system;
        home = import ./modules/home;
      };

      # nixpkgs attribute -> winget id annotations and pkgs.winpkgs.fromWinget.
      # The evaluators apply it already; exposed for consumers extending it.
      overlays.default = import ./overlays;

      templates.default = {
        path = ./template;
        description = "A flake with one winpkgs system configuration and one home configuration";
      };

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sys = modules: winpkgsLib.windowsSystem { inherit system modules; };
          home = modules: winpkgsLib.homeConfiguration { inherit system modules; };
          document = e: builtins.toJSON e.config.system.build.document;
          # Does evaluating this configuration's document fail?
          fails = e: !(builtins.tryEval (builtins.deepSeq (document e) true)).success;

          exampleSystem = sys [ ./example/configuration.nix ];
          exampleHome = home [ ./example/home.nix ];
          withWsl = sys [
            ./example/configuration.nix
            {
              wsl.enable = true;
              wsl.modules = [ { system.stateVersion = "26.05"; } ];
            }
          ];

          advanced = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'';
          personalize = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'';
          advertising = ''HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'';
          dataCollection = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'';
          keyboardLayout = ''HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout'';
          policiesSystem = ''HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'';
          explorerPolicy = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer'';
          search = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Search'';
          ucpd = ''HKLM\SYSTEM\CurrentControlSet\Services\UCPD'';
        in
        {
          example = exampleSystem.config.system.build.toplevel;
          example-home = exampleHome.config.system.build.toplevel;

          # The home example lists Microsoft.PowerShell and winpkgs.powershell
          # ensures it too: they must merge into one resource that upgrades.
          # State policy travels in settings, under the new and the old name.
          merge =
            pkgs.runCommand "winpkgs-merge"
              {
                doc = document exampleHome;
                docOldName = document (home [
                  ./example/home.nix
                  { winpkgs.packages.prune = false; }
                ]);
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                n=$(echo "$doc" | jq '[.resources[] | select(.id == "Microsoft.PowerShell")] | length')
                up=$(echo "$doc" | jq '.resources[] | select(.id == "Microsoft.PowerShell") | .properties.upgrade')
                test "$n" = 1 && test "$up" = true
                test "$(echo "$doc" | jq -c '.settings')" = '{"generations":{"deleteOlderThan":null,"keep":10},"prune":{"files":true,"services":true,"winget":true},"substitutions":[{"from":"/home/example","to":"%USERPROFILE%"}]}'
                test "$(echo "$docOldName" | jq '.settings.prune.winget')" = false
                test "$(echo "$doc" | jq -r '.kind')" = home
                test "$(echo "$doc" | jq -r '.version')" = 2
                echo ok > $out
              '';

          # Services are applied after everything else, whatever order their
          # modules merged in: a service restarted for a new binary must find
          # it already written.
          order =
            pkgs.runCommand "winpkgs-order"
              {
                doc = document (sys [
                  {
                    winpkgs.name = "o";
                    winpkgs.resources = [
                      {
                        type = "winpkgs/service";
                        id = "Service s";
                        scope = "machine";
                        properties = { };
                      }
                    ];
                    windows.files."C:/Program Files/s/s.exe".text = "s";
                  }
                ]);
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                test "$(jq -r '.resources[-1].id' <<<"$doc")" = 'Service s'
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/file")] | length' <<<"$doc")" = 1
                echo ok > $out
              '';

          # The contract the sugar modules live by: the right value for the
          # right name, nothing at all for an option left unset, second place
          # behind an entry written by hand -- and each kind of configuration
          # declares only its half of a module that spans both.
          sugar =
            pkgs.runCommand "winpkgs-sugar"
              {
                # Keys travel as env vars so that no backslash has to survive
                # Nix, the shell and jq in turn.
                inherit
                  advanced
                  personalize
                  advertising
                  dataCollection
                  keyboardLayout
                  policiesSystem
                  explorerPolicy
                  search
                  ucpd
                  ;
                homeDoc = document (home [
                  {
                    winpkgs.name = "sugar@sugar";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;
                    windows.explorer = {
                      showHiddenFiles = true;
                      showFileExtensions = true;
                    };
                    windows.taskbar.combineButtons = "never";
                    windows.theme.mode = "dark";
                    windows.privacy.advertisingId = false;
                    windows.privacy.webSearchInStart = false;
                  }
                ]);
                overridden = document (home [
                  {
                    winpkgs.name = "sugar@sugar";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;
                    windows.explorer.showHiddenFiles = true;
                    windows.registry.${advanced}.Hidden = 2;
                  }
                ]);
                systemDoc = document (sys [
                  {
                    winpkgs.name = "sugar";
                    windows.privacy.telemetry = "required";
                    windows.privacy.webSearchInStart = false;
                    windows.keyboard.lockShortcut = false;
                    windows.userChoiceProtection.enable = false;
                    windows.keyboard.remap = {
                      CapsLock = "LeftCtrl";
                      Insert = null;
                    };
                  }
                ]);
                # privacy.telemetry is HKLM: it must not exist in a home configuration.
                telemetryInHomeFails = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "x@x";
                      windows.privacy.telemetry = "required";
                    }
                  ])
                );
                # So is the lock policy: the user cannot write their own Policies key.
                lockInHomeFails = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "x@x";
                      windows.keyboard.lockShortcut = false;
                    }
                  ])
                );
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
                test "$(v "$homeDoc" "$advanced" Hidden)" = 1
                test "$(v "$homeDoc" "$advanced" HideFileExt)" = 0

                # One option, both taskbar-grouping values.
                test "$(v "$homeDoc" "$advanced" TaskbarGlomLevel)" = 2
                test "$(v "$homeDoc" "$advanced" MMTaskbarGlomLevel)" = 2

                # A theme key holds no `\Explorer`, so this is `restartKeys` working.
                test "$(v "$homeDoc" "$personalize" AppsUseLightTheme)" = 0
                test "$(v "$homeDoc" "$personalize" AppsUseLightTheme restartExplorer)" = true

                test "$(v "$homeDoc" "$advertising" Enabled scope)" = user

                # Unset means unmanaged: no resource at all.
                test "$(v "$homeDoc" "$advanced" LaunchTo)" = MISSING

                # A hand-written entry beats the sugar's mkDefault -- and "= 2"
                # rather than "MISSING" is also the proof that it replaced the
                # definition instead of adding a second, duplicate-id resource.
                test "$(v "$overridden" "$advanced" Hidden)" = 2

                # The system half.
                test "$(v "$systemDoc" "$dataCollection" AllowTelemetry)" = 1
                test "$(v "$systemDoc" "$dataCollection" AllowTelemetry scope)" = machine
                # Win+L off is the Remove Lock Computer policy, set to 1, machine-wide.
                test "$(v "$systemDoc" "$policiesSystem" DisableLockWorkstation)" = 1
                test "$(v "$systemDoc" "$policiesSystem" DisableLockWorkstation scope)" = machine
                test "$lockInHomeFails" = true

                # webSearchInStart is one option with a half in each kind: the
                # machine-wide policy current builds obey, and the per-user
                # value older ones read. The policy half was HKCU\Software\
                # Policies once, which a recent Windows makes ReadKey for the
                # user -- so it belongs to the system configuration, and each
                # kind must write its own half and not the other's.
                test "$(v "$systemDoc" "$explorerPolicy" DisableSearchBoxSuggestions)" = 1
                test "$(v "$systemDoc" "$explorerPolicy" DisableSearchBoxSuggestions scope)" = machine
                test "$(v "$systemDoc" "$search" BingSearchEnabled)" = MISSING
                test "$(v "$homeDoc" "$search" BingSearchEnabled)" = 0
                test "$(v "$homeDoc" "$search" BingSearchEnabled scope)" = user
                test "$(v "$homeDoc" "$explorerPolicy" DisableSearchBoxSuggestions)" = MISSING

                # UCPD refuses the Widgets value below the permission system, so the
                # way to make windows.taskbar.widgets converge is to stop the
                # driver loading: a machine-wide switch, and 4 is "disabled".
                test "$(v "$systemDoc" "$ucpd" Start)" = 4
                test "$(v "$systemDoc" "$ucpd" Start scope)" = machine
                # A driver's Start value is read at boot and nowhere else, so
                # the resource carries the flag that makes the apply say so and
                # leave with 3010 rather than reporting plain success.
                test "$(v "$systemDoc" "$ucpd" Start restartMachine)" = true
                # And an ordinary value does not, or every apply would ask for a
                # restart.
                test "$(v "$homeDoc" "$advanced" Hidden restartMachine)" = false
                # The same option turns off the task that would put the driver
                # back: UCPDMgr.exe runs at every logon, so the Start value on
                # its own is a setting Windows is free to reconsider.
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/scheduledTask")]
                               | if length == 1 then "\(.[0].properties.path)|\(.[0].properties.name)|\(.[0].properties.enabled)"
                                 else "MISSING" end' <<<"$systemDoc")" \
                     = '\Microsoft\Windows\AppxDeploymentClient\|UCPD velocity|false'
                # and a home configuration cannot declare one: the tasks worth
                # naming are Windows' own, and disabling them needs elevation.
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/scheduledTask")] | length' <<<"$homeDoc")" = 0
                # The scancode map, byte for byte: two zero dwords of header, a
                # count of 3 (two mappings plus the terminator), LeftCtrl over
                # CapsLock, nothing over Insert, terminator.
                test "$(jq -r --arg k "$keyboardLayout" \
                  '.resources[] | select(.properties.key == $k) | .properties.value | join(",")' \
                  <<<"$systemDoc")" = 0,0,0,0,0,0,0,0,3,0,0,0,29,0,58,0,0,0,82,224,0,0,0,0

                test "$telemetryInHomeFails" = true
                echo ok > $out
              '';

          # Two hand-written definitions of one value that disagree have to fail
          # evaluation rather than silently pick one.
          conflict =
            let
              throws =
                v1: v2:
                lib.boolToString (
                  fails (home [
                    { winpkgs.name = "c@c"; }
                    { windows.registry.${advanced}.X = v1; }
                    { windows.registry.${advanced}.X = v2; }
                  ])
                );
            in
            pkgs.runCommand "winpkgs-conflict"
              {
                dword = throws 1 2;
                multi = throws [ "a" ] [ "b" ];
                agreed = throws 1 1;
              }
              ''
                test "$dword" = true
                test "$multi" = true
                test "$agreed" = false
                echo ok > $out
              '';

          # A configuration holds resources of its own scope and nothing else;
          # anything else fails evaluation pointing at the other tree.
          kinds =
            let
              named = kind: name: { winpkgs.name = name; };
            in
            pkgs.runCommand "winpkgs-kinds"
              {
                systemKind = exampleSystem.config.winpkgs.kind;
                homeKind = exampleHome.config.winpkgs.kind;
                systemDocKind = (builtins.fromJSON (document exampleSystem)).kind;
                hklmInHome = lib.boolToString (
                  fails (home [
                    (named "home" "k@k")
                    { windows.registry."HKLM\\SOFTWARE\\x".v = 1; }
                  ])
                );
                hkcuInSystem = lib.boolToString (
                  fails (sys [
                    (named "system" "k")
                    { windows.registry."HKCU\\Software\\x".v = 1; }
                  ])
                );
                userPathInSystem = lib.boolToString (
                  fails (sys [
                    (named "system" "k")
                    { windows.files."%APPDATA%/x.txt".text = "x"; }
                  ])
                );
                machinePathInHome = lib.boolToString (
                  fails (home [
                    (named "home" "k@k")
                    { windows.files."%ProgramData%/x.txt".text = "x"; }
                  ])
                );
                machineWingetInHome = lib.boolToString (
                  fails (home [
                    (named "home" "k@k")
                    {
                      winget.packages = [
                        {
                          id = "7zip.7zip";
                          scope = "machine";
                        }
                      ];
                    }
                  ])
                );
                # and what each tree does not even declare
                wslInHome = lib.boolToString (
                  fails (home [
                    (named "home" "k@k")
                    { wsl.enable = true; }
                  ])
                );
                homeFileInSystem = lib.boolToString (
                  fails (sys [
                    (named "system" "k")
                    { home.file.".x".text = "x"; }
                  ])
                );
                # the defaults winget is told
                systemWingetScope =
                  (lib.head (
                    lib.filter (r: r.id == "7zip.7zip") (builtins.fromJSON (document exampleSystem)).resources
                  )).properties.scope;
                homeWingetScope =
                  (lib.head (lib.filter (r: r.id == "Git.Git") (builtins.fromJSON (document exampleHome)).resources))
                  .properties.scope;
              }
              ''
                test "$systemKind" = system && test "$homeKind" = home && test "$systemDocKind" = system
                for v in hklmInHome hkcuInSystem userPathInSystem machinePathInHome machineWingetInHome wslInHome homeFileInSystem; do
                  test "''${!v}" = true || { echo "$v should have failed evaluation"; exit 1; }
                done
                test "$systemWingetScope" = machine
                test "$homeWingetScope" = user
                echo ok > $out
              '';

          # The surface shared with home-manager, and platform detection the way
          # NixOS and nix-darwin modules do it: a module guarded on
          # pkgs.stdenv.hostPlatform lands its Windows branch and nothing else.
          shared =
            let
              e = home [
                (
                  { pkgs, lib, ... }:
                  {
                    winpkgs.name = "shared@shared";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;

                    home.file.".gitconfig".text = "[user]\n\tname = x\n";
                    home.file."tree" = {
                      source = ./example/tree;
                      recursive = true;
                    };
                    home.file."ignored" = {
                      text = "no";
                      enable = false;
                    };
                    xdg.configFile."wezterm/wezterm.lua".text = "return {}";
                    home.sessionVariables.EDITOR = ''%LOCALAPPDATA%\nvim\bin\nvim.exe'';

                    windows.files = lib.mkMerge [
                      (lib.mkIf pkgs.stdenv.hostPlatform.isWindows {
                        "%USERPROFILE%/platform".text = pkgs.stdenv.hostPlatform.system;
                      })
                      (lib.mkIf pkgs.stdenv.hostPlatform.isLinux { "%USERPROFILE%/wrong-linux".text = "wrong"; })
                      (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin { "%USERPROFILE%/wrong-darwin".text = "wrong"; })
                    ];
                  }
                )
              ];
            in
            pkgs.runCommand "winpkgs-shared"
              {
                doc = document e;
                hostSystem = e._module.args.pkgs.stdenv.hostPlatform.system;
                buildSystem = e._module.args.pkgs.buildPackages.stdenv.hostPlatform.system;
                # nixpkgs marks python3 broken for Windows; the set must still evaluate it.
                brokenEvaluates = lib.boolToString (
                  (builtins.tryEval (builtins.seq (toString e._module.args.pkgs.python3) true)).success
                );
                closure = e.config.system.build.toplevel;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                has() { jq -e --arg id "$1" '.resources[] | select(.id == $id)' <<<"$doc" >/dev/null; }
                lacks() { ! has "$1"; }

                test "$hostSystem" = x86_64-windows
                test "$buildSystem" = ${system}
                test "$brokenEvaluates" = true

                has '%USERPROFILE%/.gitconfig'
                has '%APPDATA%/wezterm/wezterm.lua'
                has '%USERPROFILE%/tree/a.txt'
                has '%USERPROFILE%/tree/sub/b.txt'
                lacks '%USERPROFILE%/tree'
                lacks '%USERPROFILE%/ignored'
                test "$(jq -r '.resources[] | select(.id == "Environment\\EDITOR") | .properties.value' <<<"$doc")" = '%LOCALAPPDATA%\nvim\bin\nvim.exe'
                test "$(jq -r '.resources[] | select(.id == "Environment\\EDITOR") | .properties.key' <<<"$doc")" = 'HKCU\Environment'

                has '%USERPROFILE%/platform'
                lacks '%USERPROFILE%/wrong-linux'
                lacks '%USERPROFILE%/wrong-darwin'

                test "$(cat "$closure"/files/*-a.txt)" = a
                test "$(cat "$closure"/files/*-b.txt)" = b
                echo ok > $out
              '';

          # home-manager's own modules evaluate in a home configuration, and
          # what they produce is translated: programs.* become winget installs
          # plus their generated files, the fictional home directory and $HOME
          # become %USERPROFILE%, sessionPath becomes the user PATH. What home-
          # manager adds for a Nix profile (man-db, the manual, .keep files, the
          # session-variables script) does not reach Windows.
          home-manager =
            let
              e = home [
                (
                  { config, ... }:
                  {
                    winpkgs.name = "hm@hm";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;

                    programs.git = {
                      enable = true;
                      settings.user.name = "HM";
                    };
                    programs.starship.enable = true;
                    xdg.enable = true;
                    home.sessionPath = [
                      "$HOME/.local/bin"
                      "${config.home.homeDirectory}/bin"
                    ];
                    home.file."hook" = {
                      text = "x";
                      onChange = "echo changed";
                    };
                  }
                )
              ];
              gitConfig =
                (lib.head (
                  lib.filter (f: f.target == "AppData/Roaming/git/config") (lib.attrValues e.config.home.file)
                )).source;
            in
            pkgs.runCommand "winpkgs-home-manager"
              {
                doc = document e;
                inherit gitConfig;
                warnings = lib.concatStringsSep "\n" e.config.warnings;
                username = e.config.home.username;
                homeDirectory = e.config.home.homeDirectory;
                # A host that prefers ~/.config overrides the mkDefault.
                dotConfig = document (home [
                  (
                    { config, ... }:
                    {
                      winpkgs.name = "hm@hm";
                      winpkgs.cli.enable = false;
                      winpkgs.powershell.ensure = false;
                      programs.git.enable = true;
                      xdg.configHome = "${config.home.homeDirectory}/.config";
                    }
                  )
                ]);
                outside = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "hm@hm";
                      home.file."/etc/elsewhere".text = "no";
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                has() { jq -e --arg id "$1" '.resources[] | select(.id == $id)' <<<"$doc" >/dev/null; }
                lacks() { ! has "$1"; }
                value() { jq -r --arg id "$1" '.resources[] | select(.id == $id) | .properties.value' <<<"$doc"; }

                test "$username" = hm
                test "$homeDirectory" = /home/hm

                has Git.Git
                has Starship.Starship
                lacks man-db
                has '%APPDATA%/git/config'
                jq -e '.resources[] | select(.id == "%USERPROFILE%/.config/git/config")' <<<"$dotConfig" >/dev/null
                test "$(jq -r '.resources[] | select(.id == "Environment\\XDG_CONFIG_HOME") | .properties.value' <<<"$dotConfig")" = '%USERPROFILE%\.config'
                grep -q 'name = "HM"' "$gitConfig"
                has '%USERPROFILE%/hook'
                lacks '%USERPROFILE%/.cache/.keep'
                lacks '%USERPROFILE%/.local/state/.keep'

                test "$(value 'Environment\STARSHIP_CONFIG')" = '%APPDATA%\starship.toml'
                test "$(value 'Environment\XDG_CONFIG_HOME')" = '%APPDATA%'
                test "$(value 'Environment\XDG_DATA_HOME')" = '%LOCALAPPDATA%'
                test "$(value 'Environment\XDG_STATE_HOME')" = '%LOCALAPPDATA%'
                test "$(value 'Environment\XDG_CACHE_HOME')" = '%LOCALAPPDATA%\Temp'
                lacks '%LOCALAPPDATA%/Temp/.keep'
                lacks '%LOCALAPPDATA%/.keep'
                has 'Path\%USERPROFILE%\.local\bin'
                has 'Path\%USERPROFILE%\bin'

                grep -q 'onChange is not run on Windows' <<<"$warnings"
                test "$outside" = true
                echo ok > $out
              '';

          # home.packages (home) and environment.systemPackages (system) become
          # winget installs through the overlay's annotations; nothing is built;
          # the unmapped and the Windows-less fail with their names; every name
          # in the mapping table exists in the pinned nixpkgs.
          packages =
            let
              e = home [
                (
                  { pkgs, ... }:
                  {
                    winpkgs.name = "p@p";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;
                    home.packages = [
                      pkgs.git
                      pkgs.ripgrep
                      # nixpkgs does not build it for Windows, so only the id
                      # matters; and its installer is machine-wide, so a home
                      # exports it rather than installing it itself.
                      pkgs.neovim
                      (pkgs.winpkgs.fromWinget "Microsoft.PowerToys")
                    ];
                    winget.packages = [ "Git.Git" ]; # merges with pkgs.git
                  }
                )
              ];
              crossPkgs = e._module.args.pkgs;
              failsWith =
                extra:
                fails (home [
                  (
                    { pkgs, ... }:
                    {
                      winpkgs.name = "p@p";
                      winpkgs.cli.enable = false;
                      home.packages = extra pkgs;
                    }
                  )
                ]);
              missing = lib.filter (n: !(crossPkgs ? ${n})) (lib.attrNames crossPkgs.winpkgs.wingetMappings);
            in
            pkgs.runCommand "winpkgs-packages"
              {
                doc = document e;
                systemDoc = document exampleSystem;
                gitId = crossPkgs.git.winget.id;
                machinePackages = lib.concatMapStringsSep "," (p: p.id) e.config.winpkgs.machinePackages;
                unmappedFails = lib.boolToString (failsWith (pkgs: [ pkgs.hello ]));
                unavailableFails = lib.boolToString (failsWith (pkgs: [ pkgs.tmux ]));
                missing = lib.concatStringsSep " " missing;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                ids() { jq -r '[.resources[] | select(.type == "winpkgs/winget") | .id] | sort | join(",")' <<<"$1"; }
                test "$(ids "$doc")" = "BurntSushi.ripgrep.MSVC,Git.Git,Microsoft.PowerToys"
                # neovim is machine-scope, so the home exports it for the system
                # to install rather than emitting a winget resource of its own.
                test "$machinePackages" = Neovim.Neovim
                test "$gitId" = Git.Git
                test "$unmappedFails" = true
                test "$unavailableFails" = true
                test -z "$missing" || { echo "mapping names missing from nixpkgs: $missing"; exit 1; }
                # environment.systemPackages, machine scope
                test "$(jq -r '.resources[] | select(.id == "7zip.7zip") | .properties.scope' <<<"$systemDoc")" = machine
                echo ok > $out
              '';

          # The theme module's two non-trivial settings: an accent colour fans
          # out into the dword layouts and the palette the shell reads, and a
          # wallpaper becomes a winpkgs/wallpaper resource, with the image
          # carried in the closure when it is a Nix path and left alone when
          # it is a Windows one.
          theme =
            let
              base = {
                winpkgs.name = "t@t";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
              accentKey = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'';
              dwmKey = ''HKCU\Software\Microsoft\Windows\DWM'';
            in
            pkgs.runCommand "winpkgs-theme"
              {
                inherit accentKey dwmKey;
                doc = document (home [
                  base
                  {
                    windows.theme = {
                      accentColor = "#d0000c";
                      accentColorInactive = "#313244";
                      wallpaper.image = ./example/tree/a.txt;
                      wallpaper.fit = "fit";
                      background = "#1e1e2e";
                    };
                  }
                ]);
                solid = document (home [
                  base
                  { windows.theme.background = "#000000"; }
                ]);
                onMachine = document (home [
                  base
                  { windows.theme.wallpaper.image = ''%USERPROFILE%\Pictures\w.jpg''; }
                ]);
                none = document (home [ base ]);
                # A fetched or built image is a derivation, named after itself
                # on the machine rather than after its store path.
                fetched = document (home [
                  base
                  (
                    { pkgs, ... }:
                    {
                      windows.theme.wallpaper.image = pkgs.buildPackages.writeText "w.jpg" "not a jpeg";
                    }
                  )
                ]);
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                v() {
                  jq -r --arg k "$2" --arg n "$3" \
                    '[.resources[] | select(.properties.key == $k and .properties.name == $n)]
                     | if length == 1 then (.[0].properties.value | tostring) else "MISSING" end' <<<"$1"
                }
                wp() { jq -r --arg f "$2" '.resources[] | select(.type == "winpkgs/wallpaper") | .properties[$f]' <<<"$1"; }

                # #313244 as ABGR
                test "$(v "$doc" "$dwmKey" AccentColorInactive)" = 4282659377

                test "$(wp "$fetched" image)" = '%LOCALAPPDATA%\winpkgs\wallpaper\w.jpg'
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%LOCALAPPDATA%/winpkgs/wallpaper/w.jpg")' <<<"$fetched" >/dev/null

                # #d0000c: 0xFF0C00D0 as ABGR, 0xC4D0000C as ARGB with the colorization alpha
                test "$(v "$doc" "$accentKey" AccentColorMenu)" = 4278976720
                test "$(v "$doc" "$dwmKey" AccentColor)" = 4278976720
                test "$(v "$doc" "$dwmKey" ColorizationColor)" = 3301965836
                # the palette: eight RGB0 entries, the colour fourth, Windows' constant last
                pal=$(jq -r --arg k "$accentKey" '.resources[] | select(.properties.key == $k and .properties.name == "AccentPalette") | .properties.value' <<<"$doc")
                test "$(jq -r 'length' <<<"$pal")" = 32
                test "$(jq -r '.[12:16] | join(",")' <<<"$pal")" = 208,0,12,0
                test "$(jq -r '.[28:32] | join(",")' <<<"$pal")" = 136,23,152,0
                test "$(jq -r '.[0] > 208' <<<"$pal")" = true   # lighter first
                test "$(jq -r '.[16] < 208' <<<"$pal")" = true  # darker after

                test "$(wp "$doc" image)" = '%LOCALAPPDATA%\winpkgs\wallpaper\a.txt'
                test "$(wp "$doc" fit)" = fit
                test "$(wp "$doc" background)" = '#1e1e2e'
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%LOCALAPPDATA%/winpkgs/wallpaper/a.txt")' <<<"$doc" >/dev/null

                test "$(wp "$solid" image)" = ""
                test "$(wp "$solid" background)" = '#000000'
                test "$(wp "$onMachine" image)" = '%USERPROFILE%\Pictures\w.jpg'
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/file" and (.id | contains("wallpaper")))] | length' <<<"$onMachine")" = 0
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/wallpaper")] | length' <<<"$none")" = 0
                echo ok > $out
              '';

          # The console colour table: ANSI names in, Windows' blue-green-red
          # table order and 0x00BBGGRR dwords out; a base16 palette (with or
          # without the '#') fills all eighteen, and a colour set by hand wins.
          console =
            let
              base = {
                winpkgs.name = "c@c";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
              mocha = {
                base00 = "1e1e2e";
                base03 = "585b70";
                base05 = "cdd6f4";
                base07 = "b4befe";
                base08 = "#f38ba8";
                base0A = "f9e2af";
                base0B = "a6e3a1";
                base0C = "94e2d5";
                base0D = "89b4fa";
                base0E = "cba6f7";
              };
            in
            pkgs.runCommand "winpkgs-console"
              {
                consoleKey = ''HKCU\Console'';
                doc = document (home [
                  base
                  { windows.console.base16 = mocha; }
                ]);
                overridden = document (home [
                  base
                  {
                    windows.console.base16 = mocha;
                    windows.console.colors.red = "#ff0000";
                  }
                ]);
                none = document (home [ base ]);
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                v() {
                  jq -r --arg k "$2" --arg n "$3" \
                    '[.resources[] | select(.properties.key == $k and .properties.name == $n)]
                     | if length == 1 then (.[0].properties.value | tostring) else "MISSING" end' <<<"$1"
                }
                test "$(v "$doc" "$consoleKey" ColorTable00)" = 3022366   # base00 1e1e2e -> 0x2e2e1e
                test "$(v "$doc" "$consoleKey" ColorTable04)" = 11045875  # red is Windows' fourth: f38ba8 -> 0xa88bf3
                test "$(v "$doc" "$consoleKey" ColorTable01)" = 16430217  # blue is Windows' first: 89b4fa -> 0xfab489
                test "$(v "$doc" "$consoleKey" ColorTable12)" = 11045875  # bright red = red
                test "$(v "$doc" "$consoleKey" ColorTable15)" = 16694964  # bright white base07 b4befe -> 0xfebeb4
                test "$(v "$doc" "$consoleKey" DefaultForeground)" = 16045773
                test "$(v "$doc" "$consoleKey" DefaultBackground)" = 3022366
                test "$(jq -r --arg k "$consoleKey" '[.resources[] | select(.properties.key == $k)] | length' <<<"$doc")" = 18
                test "$(v "$overridden" "$consoleKey" ColorTable04)" = 255
                test "$(jq -r --arg k "$consoleKey" '[.resources[] | select(.properties.key == $k)] | length' <<<"$none")" = 0
                echo ok > $out
              '';

          # Gaming spans both hives and each kind declares its half; a startup
          # entry writes the command and its StartupApproved record, null
          # deletes both, and the hive follows the kind.
          gaming-startup =
            let
              base = {
                winpkgs.name = "g@g";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
            in
            pkgs.runCommand "winpkgs-gaming-startup"
              {
                gameBar = ''HKCU\Software\Microsoft\GameBar'';
                gameDvr = ''HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'';
                gameConfig = ''HKCU\System\GameConfigStore'';
                gameDvrPolicy = ''HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR'';
                graphicsDrivers = ''HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'';
                userRun = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Run'';
                userApproved = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'';
                machineRun = ''HKLM\Software\Microsoft\Windows\CurrentVersion\Run'';
                homeDoc = document (home [
                  base
                  {
                    windows.gaming = {
                      gameMode = true;
                      captures = false;
                      fullscreenOptimizations = false;
                    };
                    windows.startup = {
                      Tray = ''"C:\Program Files\Tray\tray.exe" --minimized'';
                      Ember = ''"%LOCALAPPDATA%\Programs\ember\ember.exe"'';
                      OneDrive = null;
                    };
                  }
                ]);
                systemDoc = document (sys [
                  {
                    winpkgs.name = "g";
                    windows.gaming = {
                      allowCaptures = false;
                      hardwareAcceleratedScheduling = true;
                    };
                    windows.startup.Agent = ''C:\agent.exe'';
                  }
                ]);
                policyInHomeFails = lib.boolToString (
                  fails (home [
                    base
                    { windows.gaming.allowCaptures = false; }
                  ])
                );
                gameModeInSystemFails = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "g";
                      windows.gaming.gameMode = true;
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                v() {
                  jq -r --arg k "$2" --arg n "$3" --arg f "''${4-value}" \
                    '[.resources[] | select(.properties.key == $k and .properties.name == $n)]
                     | if length == 1 then (.[0].properties[$f] | tostring) else "MISSING" end' <<<"$1"
                }
                test "$(v "$homeDoc" "$gameBar" AutoGameModeEnabled)" = 1
                test "$(v "$homeDoc" "$gameDvr" AppCaptureEnabled)" = 0
                test "$(v "$homeDoc" "$gameConfig" GameDVR_Enabled)" = 0
                test "$(v "$homeDoc" "$gameConfig" GameDVR_FSEBehaviorMode)" = 2
                test "$(v "$homeDoc" "$gameConfig" GameDVR_HonorUserFSEBehaviorMode)" = 1
                test "$(v "$homeDoc" "$gameBar" UseNexusForGameBarEnabled)" = MISSING
                test "$(v "$homeDoc" "$userRun" Tray)" = '"C:\Program Files\Tray\tray.exe" --minimized'
                test "$(v "$homeDoc" "$userRun" Tray type)" = String
                test "$(v "$homeDoc" "$userApproved" Tray type)" = Binary
                # A %VAR% in the command is stored expandable.
                test "$(v "$homeDoc" "$userRun" Ember type)" = ExpandString
                test "$(v "$homeDoc" "$userRun" Ember)" = '"%LOCALAPPDATA%\Programs\ember\ember.exe"'
                test "$(v "$homeDoc" "$userApproved" Tray)" = '[2,0,0,0,0,0,0,0,0,0,0,0]'
                test "$(v "$homeDoc" "$userRun" OneDrive type)" = Absent
                test "$(v "$homeDoc" "$userApproved" OneDrive type)" = Absent

                test "$(v "$systemDoc" "$gameDvrPolicy" AllowGameDVR)" = 0
                test "$(v "$systemDoc" "$graphicsDrivers" HwSchMode)" = 2
                test "$(v "$systemDoc" "$machineRun" Agent)" = 'C:\agent.exe'
                test "$policyInHomeFails" = true
                test "$gameModeInSystemFails" = true
                echo ok > $out
              '';

          # Power: the plan by name or guid, timeouts in minutes (or never)
          # becoming seconds on both sides or each, button actions as codes,
          # hibernation as its own resource, fast startup as a registry value;
          # and networking.hostName is now the computer's name.
          power =
            let
              highPerf = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c";
              subSleep = "238c9fa8-0aad-41ed-83f4-97be242c8f20";
            in
            pkgs.runCommand "winpkgs-power"
              {
                inherit highPerf subSleep;
                hiberboot = ''HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power'';
                doc = document (sys [
                  {
                    networking.hostName = "desktop";
                    power = {
                      plan = "highPerformance";
                      sleep.computer = "never";
                      sleep.display = {
                        ac = 10;
                        battery = 5;
                      };
                      buttons.power = "shutdown";
                      hibernation = false;
                      fastStartup = false;
                    };
                  }
                ]);
                # No plan: settings go to whichever scheme is active.
                unplanned = document (sys [
                  {
                    winpkgs.name = "p";
                    power.sleep.computer = 30;
                  }
                ]);
                fastStartupNeedsHibernation = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "p";
                      power.hibernation = false;
                      power.fastStartup = true;
                    }
                  ])
                );
                lidCannotTurnOffDisplay = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "p";
                      power.buttons.lidClose = "turnOffDisplay";
                    }
                  ])
                );
                badNameFails = lib.boolToString (
                  fails (sys [ { networking.hostName = "this name is far too long"; } ])
                );
                powerInHomeFails = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "p@p";
                      power.plan = "balanced";
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                r() { jq -r --arg id "$2" --arg f "$3" '.resources[] | select(.id == $id) | .properties[$f] | tostring' <<<"$1"; }
                t() { jq -r --arg id "$2" '.resources[] | select(.id == $id) | .type' <<<"$1"; }

                test "$(t "$doc" 'Power\plan')" = winpkgs/powerPlan
                test "$(r "$doc" 'Power\plan' guid)" = "$highPerf"
                test "$(r "$doc" 'Power\sleep.computer' scheme)" = "$highPerf"
                test "$(r "$doc" 'Power\sleep.computer' subgroup)" = "$subSleep"
                test "$(r "$doc" 'Power\sleep.computer' ac)" = 0
                test "$(r "$doc" 'Power\sleep.computer' dc)" = 0
                test "$(r "$doc" 'Power\sleep.display' ac)" = 600
                test "$(r "$doc" 'Power\sleep.display' dc)" = 300
                test "$(r "$doc" 'Power\buttons.power' ac)" = 3
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/powerSetting")] | length' <<<"$doc")" = 3
                test "$(t "$doc" 'Power\hibernation')" = winpkgs/hibernation
                test "$(r "$doc" 'Power\hibernation' enabled)" = false
                test "$(jq -r --arg k "$hiberboot" '.resources[] | select(.properties.key == $k and .properties.name == "HiberbootEnabled") | .properties.value' <<<"$doc")" = 0
                test "$(t "$doc" ComputerName)" = winpkgs/computerName
                test "$(r "$doc" ComputerName name)" = desktop
                test "$(jq -r '.resources[] | select(.id == "ComputerName") | .scope' <<<"$doc")" = machine

                test "$(r "$unplanned" 'Power\sleep.computer' scheme)" = null
                test "$(r "$unplanned" 'Power\sleep.computer' ac)" = 1800
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/computerName")] | length' <<<"$unplanned")" = 0

                test "$fastStartupNeedsHibernation" = true
                test "$lidCannotTurnOffDisplay" = true
                test "$badNameFails" = true
                test "$powerInHomeFails" = true
                echo ok > $out
              '';

          # Time: an IANA name becomes the id Windows knows, the hardware
          # clock's interpretation is a plain registry value, and the whole of
          # the NTP client is one resource -- peers, interval and correction --
          # because w32time reads them together or not at all.
          time =
            pkgs.runCommand "winpkgs-time"
              {
                timeZoneInfo = ''HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'';
                tzauto = ''HKLM\SYSTEM\CurrentControlSet\Services\tzautoupdate'';
                doc = document (sys [
                  {
                    winpkgs.name = "t";
                    time.timeZone = "America/Chicago";
                    time.hardwareClockInLocalTime = false;
                    time.autoTimeZone = false;
                    time.ntp = {
                      enable = true;
                      servers = [
                        "time.cloudflare.com"
                        "time.nist.gov,0x8"
                      ];
                      pollInterval = 3600;
                      maxCorrection = "unlimited";
                    };
                  }
                ]);
                # A Windows id is passed through untranslated.
                windowsId = document (sys [
                  {
                    winpkgs.name = "t";
                    time.timeZone = "Central Standard Time";
                  }
                ]);
                unset = document (sys [ { winpkgs.name = "t"; } ]);
                badZoneFails = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "t";
                      time.timeZone = "America/Chicagoo";
                    }
                  ])
                );
                # The right id in the wrong case is an assertion, not a value
                # passed through to fail on the machine.
                wrongCaseFails = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "t";
                      time.timeZone = "central standard time";
                    }
                  ])
                );
                peersWithoutSyncFails = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "t";
                      time.ntp.enable = false;
                      time.ntp.servers = [ "time.nist.gov" ];
                    }
                  ])
                );
                timeInHomeFails = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "t@t";
                      time.timeZone = "America/Chicago";
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                r() { jq -r --arg id "$2" --arg f "$3" '.resources[] | select(.id == $id) | .properties[$f] | tostring' <<<"$1"; }
                v() {
                  jq -r --arg k "$2" --arg n "$3" \
                    '[.resources[] | select(.properties.key == $k and .properties.name == $n)]
                     | if length == 1 then (.[0].properties.value | tostring) else "MISSING" end' <<<"$1"
                }

                test "$(r "$doc" 'Time\zone' id)" = "Central Standard Time"
                test "$(r "$windowsId" 'Time\zone' id)" = "Central Standard Time"

                # UTC is RealTimeIsUniversal 1; the zone left to the network is
                # tzautoupdate 3, and switched off is 4.
                test "$(v "$doc" "$timeZoneInfo" RealTimeIsUniversal)" = 1
                test "$(v "$doc" "$tzauto" Start)" = 4

                # A peer keeps the flags it carries and inherits time.ntp.flags
                # otherwise, in the order it was written.
                test "$(r "$doc" 'Time\sync' servers)" = "time.cloudflare.com,0x9 time.nist.gov,0x8"
                test "$(r "$doc" 'Time\sync' enabled)" = true
                test "$(r "$doc" 'Time\sync' pollInterval)" = 3600
                test "$(r "$doc" 'Time\sync' maxCorrection)" = 4294967295

                # Unset means unmanaged: no resource, and no registry value either.
                test "$(jq -r '[.resources[] | select(.type | startswith("winpkgs/time"))] | length' <<<"$unset")" = 0
                test "$(v "$unset" "$timeZoneInfo" RealTimeIsUniversal)" = MISSING

                test "$badZoneFails" = true
                test "$wrongCaseFails" = true
                test "$peersWithoutSyncFails" = true
                test "$timeInHomeFails" = true
                echo ok > $out
              '';

          # Services: a declared service becomes one winpkgs/service resource
          # with its defaults spelled out, failure actions in the runtime's
          # shape, restart triggers as a revision that changes with them, and
          # the control a restart ends it with; a template cannot have an
          # account, and a home configuration has no services at all.
          services =
            let
              declare =
                triggers:
                sys [
                  {
                    winpkgs.name = "s";
                    windows.services.steward = {
                      command = ''"C:\Program Files\steward\steward.exe"'';
                      description = "A per-user service manager";
                      type = "userOwn";
                      failureActions = {
                        resetAfter = 60;
                        actions = [
                          {
                            action = "restart";
                            delay = 5000;
                          }
                          { action = "none"; }
                        ];
                      };
                      restartTriggers = triggers;
                      restartControl = 128;
                    };
                    windows.services.plain.command = ''C:\plain.exe --serve'';
                    windows.services.gone = {
                      command = ''C:\gone.exe'';
                      enable = false;
                    };
                  }
                ];
            in
            pkgs.runCommand "winpkgs-services"
              {
                doc = document (declare [ "v1" ]);
                again = document (declare [ "v1" ]);
                changed = document (declare [ "v2" ]);
                accountOnTemplateFails = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "s";
                      windows.services.t = {
                        command = "x";
                        type = "userOwn";
                        account = "NT AUTHORITY\\LocalService";
                      };
                    }
                  ])
                );
                servicesInHomeFails = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "s@s";
                      windows.services.t.command = "x";
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                p() { jq -r --arg id "$2" --arg f "$3" '.resources[] | select(.id == $id) | .properties | getpath($f | split(".") | map(if test("^[0-9]+$") then tonumber else . end)) | tostring' <<<"$1"; }

                test "$(jq -r '[.resources[] | select(.type == "winpkgs/service")] | length' <<<"$doc")" = 2
                test "$(jq -r '.resources[] | select(.id == "Service steward") | .scope' <<<"$doc")" = machine
                test "$(p "$doc" 'Service steward' name)" = steward
                test "$(p "$doc" 'Service steward' type)" = userOwn
                test "$(p "$doc" 'Service steward' command)" = '"C:\Program Files\steward\steward.exe"'
                test "$(p "$doc" 'Service steward' startType)" = automatic
                test "$(p "$doc" 'Service steward' failureActions.reset)" = 60
                test "$(p "$doc" 'Service steward' failureActions.actions.0.action)" = restart
                test "$(p "$doc" 'Service steward' failureActions.actions.0.delay)" = 5000
                test "$(p "$doc" 'Service steward' failureActions.actions.1.delay)" = 0
                [[ "$(p "$doc" 'Service steward' revision)" =~ ^[0-9a-f]{64}$ ]]
                test "$(p "$doc" 'Service steward' restartControl)" = 128

                # The same triggers give the same revision; new ones a new one.
                test "$(p "$doc" 'Service steward' revision)" = "$(p "$again" 'Service steward' revision)"
                test "$(p "$doc" 'Service steward' revision)" != "$(p "$changed" 'Service steward' revision)"

                # Defaults spelled out, and nothing claimed that was not declared.
                test "$(p "$doc" 'Service plain' type)" = own
                test "$(p "$doc" 'Service plain' displayName)" = plain
                test "$(p "$doc" 'Service plain' startType)" = automatic
                test "$(p "$doc" 'Service plain' account)" = null
                test "$(p "$doc" 'Service plain' description)" = null
                test "$(p "$doc" 'Service plain' failureActions)" = null
                test "$(p "$doc" 'Service plain' revision)" = null
                test "$(p "$doc" 'Service plain' restartControl)" = null
                test "$(jq -r '[.resources[] | select(.id == "Service gone")] | length' <<<"$doc")" = 0

                test "$(jq -r '.settings.prune.services' <<<"$doc")" = true
                test "$accountOnTemplateFails" = true
                test "$servicesInHomeFails" = true
                echo ok > $out
              '';

          # Sudo: two options over one DWORD -- `enable` alone takes Windows'
          # own default mode, naming a mode is a choice to enable, and `false`
          # is the fourth value of the same enum rather than an absent key.
          sudo =
            let
              key = ''HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo'';
            in
            pkgs.runCommand "winpkgs-sudo"
              {
                sudoKey = key;
                enabled = document (sys [
                  {
                    winpkgs.name = "s";
                    security.sudo.enable = true;
                  }
                ]);
                inline = document (sys [
                  {
                    winpkgs.name = "s";
                    security.sudo.mode = "normal";
                  }
                ]);
                disabled = document (sys [
                  {
                    winpkgs.name = "s";
                    security.sudo.enable = false;
                  }
                ]);
                unset = document (sys [ { winpkgs.name = "s"; } ]);
                # The escape hatch still wins: sugar writes at mkDefault.
                overridden = document (sys [
                  {
                    winpkgs.name = "s";
                    security.sudo.enable = true;
                    windows.registry.${key}.Enabled = 2;
                  }
                ]);
                modeWhileDisabledFails = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "s";
                      security.sudo.enable = false;
                      security.sudo.mode = "normal";
                    }
                  ])
                );
                sudoInHomeFails = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "s@s";
                      security.sudo.enable = true;
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                v() {
                  jq -r --arg k "$sudoKey" --arg f "''${2-value}" \
                    '[.resources[] | select(.properties.key == $k and .properties.name == "Enabled")]
                     | if length == 1 then (.[0].properties[$f] | tostring) else "MISSING" end' <<<"$1"
                }

                test "$(v "$enabled")" = 1
                test "$(v "$enabled" type)" = DWord
                test "$(v "$inline")" = 3
                test "$(v "$disabled")" = 0
                test "$(v "$overridden")" = 2

                # Unset means unmanaged: the key is not even created.
                test "$(v "$unset")" = MISSING

                test "$modeWhileDisabledFails" = true
                test "$sudoInHomeFails" = true
                echo ok > $out
              '';

          # The pointer becomes one resource carrying the set's name and the
          # accessibility values; Windows Terminal's settings.json is written
          # whole, with the base16 scheme added and made the default unless
          # the settings already chose one.
          pointer-terminal =
            let
              base = {
                winpkgs.name = "pt@pt";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
              mocha = {
                base00 = "1e1e2e";
                base02 = "313244";
                base03 = "585b70";
                base05 = "cdd6f4";
                base07 = "b4befe";
                base08 = "#f38ba8";
                base0A = "f9e2af";
                base0B = "a6e3a1";
                base0C = "94e2d5";
                base0D = "89b4fa";
                base0E = "cba6f7";
              };
              terminalPath = "%LOCALAPPDATA%/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json";
              terminal = home [
                base
                {
                  programs.windows-terminal = {
                    enable = true;
                    settings.copyOnSelect = true;
                    settings.profiles.defaults.font.face = "JetBrainsMono Nerd Font Mono";
                    schemes."Plain" = {
                      background = "#000000";
                      foreground = "#ffffff";
                    };
                    base16 = {
                      palette = mocha;
                      name = "Catppuccin Mocha";
                    };
                  };
                }
              ];
              chosen = home [
                base
                {
                  programs.windows-terminal = {
                    enable = true;
                    settings.profiles.defaults.colorScheme = "Campbell";
                    base16.palette = mocha;
                  };
                }
              ];
            in
            pkgs.runCommand "winpkgs-pointer-terminal"
              {
                pointerDoc = document (home [
                  base
                  {
                    windows.pointer = {
                      style = "black";
                      size = "large";
                    };
                  }
                ]);
                schemeDoc = document (home [
                  base
                  { windows.pointer.scheme = "Windows Black (large)"; }
                ]);
                # Settings renders a custom colour from SVGs; winpkgs does not offer one.
                customIsNotAStyle = lib.boolToString (
                  fails (home [
                    base
                    { windows.pointer.style = "custom"; }
                  ])
                );
                notBoth = lib.boolToString (
                  fails (home [
                    base
                    {
                      windows.pointer.style = "black";
                      windows.pointer.scheme = "Windows Black (large)";
                    }
                  ])
                );
                terminalDoc = document terminal;
                terminalFile = terminal.config.windows.files.${terminalPath}.source;
                chosenFile = chosen.config.windows.files.${terminalPath}.source;
                disabled = document (home [
                  base
                  { programs.windows-terminal.settings.copyOnSelect = true; }
                ]);
                inherit terminalPath;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                pp() { jq -r --arg f "$2" '.resources[] | select(.type == "winpkgs/pointer") | .properties[$f] | tostring' <<<"$1"; }
                test "$(pp "$pointerDoc" scheme)" = 'Windows Black (large)'
                test "$(pp "$pointerDoc" name)" = 'Windows Black (large)'
                test "$(pp "$pointerDoc" type)" = 4
                test "$(pp "$schemeDoc" scheme)" = 'Windows Black (large)'
                test "$(pp "$schemeDoc" type)" = null
                test "$customIsNotAStyle" = true
                test "$notBoth" = true

                jq -e --arg id "$terminalPath" '.resources[] | select(.type == "winpkgs/file" and .id == $id)' <<<"$terminalDoc" >/dev/null
                test "$(jq -r '.copyOnSelect' "$terminalFile")" = true
                test "$(jq -r '.profiles.defaults.font.face' "$terminalFile")" = 'JetBrainsMono Nerd Font Mono'
                test "$(jq -r '.profiles.defaults.colorScheme' "$terminalFile")" = 'Catppuccin Mocha'
                test "$(jq -r '[.schemes[].name] | join(",")' "$terminalFile")" = 'Plain,Catppuccin Mocha'
                test "$(jq -r '.schemes[] | select(.name == "Catppuccin Mocha") | .red' "$terminalFile")" = '#f38ba8'
                test "$(jq -r '.schemes[] | select(.name == "Catppuccin Mocha") | .purple' "$terminalFile")" = '#cba6f7'
                test "$(jq -r '.schemes[] | select(.name == "Catppuccin Mocha") | .selectionBackground' "$terminalFile")" = '#313244'
                test "$(jq -r '."$schema"' "$terminalFile")" = 'https://aka.ms/terminal-profiles-schema'
                test "$(jq -r '.profiles.defaults.colorScheme' "$chosenFile")" = Campbell
                test "$(jq -r '[.schemes[].name] | join(",")' "$chosenFile")" = base16
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/file")] | length' <<<"$disabled")" = 0
                echo ok > $out
              '';

          # whkd: the whkdrc comes out in the order its parser insists on, the
          # MSI package is handed to the system, and a Run entry starts the
          # daemon headless. What the parser would choke on fails evaluation.
          whkd =
            let
              base = {
                winpkgs.name = "w@w";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
              whkdPath = "%USERPROFILE%/.config/whkdrc";
              full = home [
                base
                {
                  programs.whkd = {
                    enable = true;
                    pause = "alt + shift + p";
                    pauseHook = ''echo "paused"'';
                    keybindings = {
                      "alt + h" = "komorebic focus left";
                      "alt + shift + oem_4" = "komorebic cycle-focus previous";
                      "alt + return" = "if ($wshell.AppActivate('Terminal') -eq $False) { start terminal }";
                      "alt + n" = {
                        Firefox = ''echo "hello firefox"'';
                        "Google Chrome" = "Ignore";
                        Default = "echo hi";
                      };
                      "alt + x" = null;
                    };
                    extraConfig = ''
                      alt + o : taskkill /f /im whkd.exe
                    '';
                  };
                }
              ];
              refused =
                whkd:
                lib.boolToString (
                  fails (home [
                    base
                    {
                      programs.whkd = {
                        enable = true;
                      }
                      // whkd;
                    }
                  ])
                );
            in
            pkgs.runCommand "winpkgs-whkd"
              {
                doc = document full;
                file = full.config.windows.files.${whkdPath}.source;
                expected = pkgs.writeText "whkdrc.expected" ''
                  # Written by winpkgs (programs.whkd); the next apply overwrites edits made here.

                  .shell pwsh
                  .pause alt + shift + p
                  .pause_hook echo "paused"

                  alt + n [
                      Default : echo hi
                      Firefox : echo "hello firefox"
                      Google Chrome : Ignore
                  ]

                  alt + h : komorebic focus left
                  alt + return : if ($wshell.AppActivate('Terminal') -eq $False) { start terminal }
                  alt + shift + oem_4 : komorebic cycle-focus previous

                  alt + o : taskkill /f /im whkd.exe
                '';
                machinePackages = lib.concatMapStringsSep "," (p: p.id) full.config.winpkgs.machinePackages;
                noAutostart = document (home [
                  base
                  {
                    programs.whkd = {
                      enable = true;
                      autostart = false;
                      keybindings."alt + h" = "x";
                    };
                  }
                ]);
                unknownKey = refused { keybindings."alt + bogus" = "x"; };
                twoDigits = refused { keybindings."alt + 10" = "x"; };
                hashInCommand = refused { keybindings."alt + c" = "echo #fff"; };
                badProcessName = refused { keybindings."alt + n"."notepad++" = "x"; };
                appsOnly = refused { keybindings."alt + n".Firefox = "x"; };
                hookWithoutPause = refused {
                  pauseHook = "echo";
                  keybindings."alt + h" = "x";
                };
                run = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Run'';
                inherit whkdPath;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                diff -u "$expected" "$file"

                jq -e --arg id "$whkdPath" '.resources[] | select(.type == "winpkgs/file" and .id == $id)' <<<"$doc" >/dev/null

                # Machine scope: exported for the system, not installed by the home.
                test "$machinePackages" = LGUG2Z.whkd
                test "$(jq '[.resources[] | select(.type == "winpkgs/winget" and .id == "LGUG2Z.whkd")] | length' <<<"$doc")" = 0

                startup() { jq -r --arg k "$run" '[.resources[] | select(.properties.key == $k and .properties.name == "whkd")] | if length == 1 then .[0].properties.value else "MISSING" end' <<<"$1"; }
                test "$(startup "$doc")" = 'conhost.exe --headless "C:\Program Files\whkd\bin\whkd.exe"'
                test "$(startup "$noAutostart")" = MISSING

                for v in unknownKey twoDigits hashInCommand badProcessName appsOnly hookWithoutPause; do
                  test "''${!v}" = true || { echo "$v should have failed evaluation"; exit 1; }
                done
                echo ok > $out
              '';

          # komorebi: komorebi.json and komorebi.bar.json written whole, a base16
          # palette becoming the Custom theme of both unless they chose one, the
          # applications file placed and named, and a Run entry through the
          # console-less komorebic, with --bar only when the bar is on.
          komorebi =
            let
              base = {
                winpkgs.name = "k@k";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
              mocha = {
                base00 = "1e1e2e";
                base01 = "181825";
                base02 = "313244";
                base03 = "45475a";
                base04 = "585b70";
                base05 = "cdd6f4";
                base06 = "f5e0dc";
                base07 = "b4befe";
                base08 = "#f38ba8";
                base09 = "fab387";
                base0A = "f9e2af";
                base0B = "a6e3a1";
                base0C = "94e2d5";
                base0D = "89b4fa";
                base0E = "cba6f7";
                base0F = "f2cdcd";
              };
              full = home [
                base
                {
                  programs.komorebi = {
                    enable = true;
                    settings = {
                      default_workspace_padding = 5;
                      monitors = [
                        {
                          workspaces = [
                            {
                              name = "1";
                              layout = "BSP";
                            }
                          ];
                        }
                      ];
                    };
                    applications = ./example/tree/a.txt;
                    base16.palette = mocha;
                    bar = {
                      enable = true;
                      settings.font_family = "JetBrains Mono";
                    };
                  };
                }
              ];
              chosen = home [
                base
                {
                  programs.komorebi = {
                    enable = true;
                    settings = {
                      theme = {
                        palette = "Base16";
                        name = "Ashes";
                      };
                      app_specific_configuration_path = "$Env:USERPROFILE/asc.json";
                    };
                    applications = ./example/tree/a.txt;
                    base16.palette = mocha;
                  };
                }
              ];
              multi = home [
                base
                {
                  programs.komorebi = {
                    enable = true;
                    bar = {
                      enable = true;
                      settings.font_family = "JetBrains Mono";
                      monitors = {
                        "0" = { };
                        "1" = {
                          font_family = "Iosevka";
                          monitor.work_area_offset.top = 40;
                        };
                      };
                    };
                  };
                }
              ];
              file = e: name: e.config.windows.files."%USERPROFILE%/${name}".source;
            in
            pkgs.runCommand "winpkgs-komorebi"
              {
                fullDoc = document full;
                chosenDoc = document chosen;
                multiDoc = document multi;
                fullJson = file full "komorebi.json";
                fullBar = file full "komorebi.bar.json";
                chosenJson = file chosen "komorebi.json";
                multiJson = file multi "komorebi.json";
                multiBar0 = file multi "komorebi.bar.0.json";
                multiBar1 = file multi "komorebi.bar.1.json";
                badMonitorFails = lib.boolToString (
                  fails (home [
                    base
                    {
                      programs.komorebi = {
                        enable = true;
                        bar.enable = true;
                        bar.monitors.left = { };
                      };
                    }
                  ])
                );
                machinePackages = lib.concatMapStringsSep "," (p: p.id) full.config.winpkgs.machinePackages;
                run = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Run'';
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                startup() { jq -r --arg k "$run" '[.resources[] | select(.properties.key == $k and .properties.name == "komorebi")] | if length == 1 then .[0].properties.value else "MISSING" end' <<<"$1"; }
                has() { jq -e --arg id "$2" '.resources[] | select(.type == "winpkgs/file" and .id == $id)' <<<"$1" >/dev/null; }
                lacks() { ! has "$1" "$2"; }

                test "$(jq -r '.default_workspace_padding' "$fullJson")" = 5
                test "$(jq -r '.monitors[0].workspaces[0].layout' "$fullJson")" = BSP
                test "$(jq -r '.theme.palette' "$fullJson")" = Custom
                test "$(jq -r '.theme.colours.base_00' "$fullJson")" = '#1e1e2e'
                test "$(jq -r '.theme.colours.base_08' "$fullJson")" = '#f38ba8'
                test "$(jq -r '.theme.colours.base_0f' "$fullJson")" = '#f2cdcd'
                test "$(jq -r '.theme.colours | length' "$fullJson")" = 16
                test "$(jq -r '.app_specific_configuration_path' "$fullJson")" = '$Env:USERPROFILE/applications.json'
                test "$(jq -r '.font_family' "$fullBar")" = 'JetBrains Mono'
                test "$(jq -r '.theme.colours.base_0d' "$fullBar")" = '#89b4fa'
                has "$fullDoc" '%USERPROFILE%/applications.json'
                has "$fullDoc" '%USERPROFILE%/komorebi.bar.json'
                test "$(startup "$fullDoc")" = '"C:\Program Files\komorebi\bin\komorebic-no-console.exe" start --bar'
                test "$machinePackages" = LGUG2Z.komorebi

                # A theme and a path the settings chose are left alone; no bar, no --bar.
                test "$(jq -r '.theme.name' "$chosenJson")" = Ashes
                test "$(jq -r '.app_specific_configuration_path' "$chosenJson")" = '$Env:USERPROFILE/asc.json'
                lacks "$chosenDoc" '%USERPROFILE%/komorebi.bar.json'
                test "$(startup "$chosenDoc")" = '"C:\Program Files\komorebi\bin\komorebic-no-console.exe" start'

                # A bar per monitor: one file each, listed in komorebi.json, the
                # shared settings underneath, no komorebi.bar.json.
                test "$(jq -c '.bar_configurations' "$multiJson")" = '["$Env:USERPROFILE/komorebi.bar.0.json","$Env:USERPROFILE/komorebi.bar.1.json"]'
                test "$(jq -r '.monitor' "$multiBar0")" = 0
                test "$(jq -r '.font_family' "$multiBar0")" = 'JetBrains Mono'
                test "$(jq -c '.monitor' "$multiBar1")" = '{"work_area_offset":{"top":40}}'
                test "$(jq -r '.font_family' "$multiBar1")" = Iosevka
                lacks "$multiDoc" '%USERPROFILE%/komorebi.bar.json'
                test "$(startup "$multiDoc")" = '"C:\Program Files\komorebi\bin\komorebic-no-console.exe" start --bar'
                test "$badMonitorFails" = true
                echo ok > $out
              '';

          # masir: the machine-scope package handed to the system and a headless
          # Run entry carrying its flags.
          masir =
            let
              base = {
                winpkgs.name = "m@m";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
              plain = home [
                base
                { programs.masir.enable = true; }
              ];
              flagged = home [
                base
                {
                  programs.masir = {
                    enable = true;
                    noRaise = true;
                    integrations = false;
                  };
                }
              ];
            in
            pkgs.runCommand "winpkgs-masir"
              {
                plainDoc = document plain;
                flaggedDoc = document flagged;
                noAutostart = document (home [
                  base
                  {
                    programs.masir = {
                      enable = true;
                      autostart = false;
                    };
                  }
                ]);
                machinePackages = lib.concatMapStringsSep "," (p: p.id) plain.config.winpkgs.machinePackages;
                run = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Run'';
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                startup() { jq -r --arg k "$run" '[.resources[] | select(.properties.key == $k and .properties.name == "masir")] | if length == 1 then .[0].properties.value else "MISSING" end' <<<"$1"; }
                test "$(startup "$plainDoc")" = 'conhost.exe --headless "C:\Program Files\masir\bin\masir.exe"'
                test "$(startup "$flaggedDoc")" = 'conhost.exe --headless "C:\Program Files\masir\bin\masir.exe" --no-raise --disable-integrations'
                test "$(startup "$noAutostart")" = MISSING
                test "$machinePackages" = LGUG2Z.masir
                echo ok > $out
              '';

          # Flow Launcher: a user-scope install, Settings.json only when asked,
          # an expandable Run entry to the stub, and a command that summons it.
          flow-launcher =
            let
              base = {
                winpkgs.name = "fl@fl";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
              settingsPath = "%APPDATA%/FlowLauncher/Settings/Settings.json";
              configured = home [
                base
                {
                  programs.flow-launcher = {
                    enable = true;
                    settings = {
                      Hotkey = "Alt + Space";
                      Theme = "Darker";
                    };
                  };
                }
              ];
              bare = home [
                base
                {
                  programs.flow-launcher = {
                    enable = true;
                    autostart = false;
                  };
                }
              ];
              themed = home [
                base
                {
                  programs.flow-launcher = {
                    enable = true;
                    base16 = {
                      palette = mocha;
                      name = "Catppuccin Mocha";
                    };
                  };
                }
              ];
              themedButChosen = home [
                base
                {
                  programs.flow-launcher = {
                    enable = true;
                    base16.palette = mocha;
                    settings.Theme = "Darker";
                  };
                }
              ];
              themePath = "%APPDATA%/FlowLauncher/Themes/Catppuccin Mocha.xaml";
              # The slots the theme uses.
              mocha = {
                base00 = "1e1e2e";
                base02 = "313244";
                base04 = "585b70";
                base05 = "cdd6f4";
                base0D = "#89b4fa";
              };
            in
            pkgs.runCommand "winpkgs-flow-launcher"
              {
                configuredDoc = document configured;
                bareDoc = document bare;
                themedDoc = document themed;
                themedSettings = themed.config.windows.files.${settingsPath}.source;
                themeText = themed.config.windows.files.${themePath}.text;
                chosenSettings = themedButChosen.config.windows.files.${settingsPath}.source;
                settingsFile = configured.config.windows.files.${settingsPath}.source;
                showCommand = configured.config.programs.flow-launcher.showCommand;
                machinePackages = lib.concatMapStringsSep "," (p: p.id) configured.config.winpkgs.machinePackages;
                run = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Run'';
                inherit settingsPath;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                entry() { jq -r --arg k "$run" --arg f "$2" '[.resources[] | select(.properties.key == $k and .properties.name == "Flow.Launcher")] | if length == 1 then (.[0].properties[$f] | tostring) else "MISSING" end' <<<"$1"; }

                test "$(jq -r '.Hotkey' "$settingsFile")" = 'Alt + Space'
                test "$(jq -r '.Theme' "$settingsFile")" = Darker
                jq -e --arg id "$settingsPath" '.resources[] | select(.type == "winpkgs/file" and .id == $id)' <<<"$configuredDoc" >/dev/null
                test "$(jq --arg id "$settingsPath" '[.resources[] | select(.type == "winpkgs/file" and .id == $id)] | length' <<<"$bareDoc")" = 0

                test "$(entry "$configuredDoc" value)" = '"%LOCALAPPDATA%\FlowLauncher\Flow.Launcher.exe"'
                test "$(entry "$configuredDoc" type)" = ExpandString
                test "$(entry "$bareDoc" value)" = MISSING

                test "$showCommand" = 'Start-Process "$Env:LOCALAPPDATA\FlowLauncher\Flow.Launcher.exe"'

                # A per-user installer: the home installs it itself, user scope.
                test "$(jq -r '.resources[] | select(.type == "winpkgs/winget" and .id == "Flow-Launcher.Flow-Launcher") | .properties.scope' <<<"$configuredDoc")" = user
                test -z "$machinePackages"

                # A base16 theme: the file, named as the settings' Theme unless they chose one.
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%APPDATA%/FlowLauncher/Themes/Catppuccin Mocha.xaml")' <<<"$themedDoc" >/dev/null
                test "$(jq -r '.Theme' "$themedSettings")" = 'Catppuccin Mocha'
                grep -q 'x:Key="WindowBorderStyle"' <<<"$themeText"
                grep -q 'Property="Background" Value="#1e1e2e"' <<<"$themeText"
                grep -q 'x:Key="ItemSelectedBackgroundColor">#313244<' <<<"$themeText"
                grep -q 'Property="Inline.Foreground" Value="#89b4fa"' <<<"$themeText"
                test "$(jq -r '.Theme' "$chosenSettings")" = Darker
                echo ok > $out
              '';

          # A portable program in home.packages is installed from its files:
          # the archive's contents under %LOCALAPPDATA%\Programs\<name>, that
          # directory on the user PATH, and no winget resource.
          portable =
            let
              e = home [
                (
                  { pkgs, ... }:
                  {
                    winpkgs.name = "p@p";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;
                    home.packages = [
                      pkgs.thide
                      pkgs.ripgrep
                    ];
                  }
                )
              ];
            in
            pkgs.runCommand "winpkgs-portable"
              {
                doc = document e;
                closure = e.config.system.build.toplevel;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                r() { jq -r --arg t "$1" --arg id "$2" --arg f "$3" '[.resources[] | select(.type == $t and .id == $id)] | if length == 1 then (.[0].properties[$f] | tostring) else "MISSING" end' <<<"$doc"; }
                test "$(r winpkgs/file '%LOCALAPPDATA%/Programs/thide' target)" = '%LOCALAPPDATA%/Programs/thide'
                test "$(r winpkgs/path 'Path\%LOCALAPPDATA%\Programs\thide' dir)" = '%LOCALAPPDATA%\Programs\thide'
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/winget") | .id] | join(",")' <<<"$doc")" = BurntSushi.ripgrep.MSVC
                test -f "$closure"/files/*-thide/thide.exe
                test -f "$closure"/files/*-thide/LICENSE.txt
                echo ok > $out
              '';

          # PowerShell: the profile assembled in order (PSReadLine, aliases as
          # aliases or functions, the tool hooks, the extra), the per-user
          # config with the execution policy, and the 5.1 host's copy and
          # registry policy only when asked.
          powershell =
            let
              base = {
                winpkgs.name = "ps@ps";
                winpkgs.cli.enable = false;
                winpkgs.powershell.ensure = false;
              };
              profilePath = "%USERPROFILE%/Documents/PowerShell/profile.ps1";
              full = home [
                base
                {
                  programs.powershell = {
                    enable = true;
                    executionPolicy = "RemoteSigned";
                    shellAliases = {
                      g = "git";
                      ll = "Get-ChildItem -Force";
                    };
                    psReadLine = {
                      options = {
                        EditMode = "Emacs";
                        PredictionSource = "History";
                        HistoryNoDuplicates = true;
                        MaximumHistoryCount = 5000;
                      };
                      keyHandlers."Ctrl+d" = "DeleteCharOrExit";
                    };
                    profileExtra = "Write-Host 'hi'";
                    windowsPowerShell = {
                      enable = true;
                      executionPolicy = "RemoteSigned";
                    };
                  };
                  programs.starship.enable = true;
                  programs.zoxide = {
                    enable = true;
                    options = [
                      "--cmd"
                      "cd"
                    ];
                  };
                  programs.direnv = {
                    enable = true;
                    enablePowerShellIntegration = false;
                  };
                }
              ];
              bare = home [
                base
                { programs.powershell.enable = true; }
              ];
              # home-manager's own oh-my-posh module, made to work on Windows:
              # settings written where XDG says, a theme by name, a store-path
              # configFile shipped beside the settings.
              omp =
                extra:
                home [
                  base
                  {
                    programs.powershell.enable = true;
                    programs.oh-my-posh = {
                      enable = true;
                    }
                    // extra;
                  }
                ];
              ompSettings = omp { settings.version = 3; };
              ompTheme = omp { useTheme = "catppuccin_mocha"; };
              ompFile = omp { configFile = ./example/tree/a.txt; };
              ompString = omp { configFile = ''C:\posh\mine.omp.yaml''; };
              # home-manager's own eza module: its aliases belong in the
              # profile, the one carrying the options names the executable so
              # it does not recurse, the rest go through it, and all five are
              # defaults a shellAliases entry of the same name displaces.
              ezaHome =
                extra:
                home [
                  base
                  {
                    programs.powershell.enable = true;
                    programs.eza = {
                      enable = true;
                    }
                    // extra;
                  }
                ];
              ezaFull = ezaHome {
                icons = "auto";
                git = true;
                extraOptions = [ "--group-directories-first" ];
                theme.filekinds.directory.foreground = "blue";
              };
              ezaPlain = ezaHome { };
              ezaOff = ezaHome { enablePowerShellIntegration = false; };
              ezaOverridden = home [
                base
                {
                  programs.powershell = {
                    enable = true;
                    shellAliases.ll = "Get-ChildItem -Force";
                  };
                  programs.eza.enable = true;
                }
              ];
              shellIds = ''HKCU\Software\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'';
            in
            pkgs.runCommand "winpkgs-powershell"
              {
                fullDoc = document full;
                bareDoc = document bare;
                ompSettingsDoc = document ompSettings;
                ompFileDoc = document ompFile;
                ompSettingsProfile = ompSettings.config.windows.files.${profilePath}.text;
                ompThemeProfile = ompTheme.config.windows.files.${profilePath}.text;
                ompFileProfile = ompFile.config.windows.files.${profilePath}.text;
                ompStringProfile = ompString.config.windows.files.${profilePath}.text;
                ezaDoc = document ezaFull;
                ezaProfile = ezaFull.config.windows.files.${profilePath}.text;
                ezaPlainProfile = ezaPlain.config.windows.files.${profilePath}.text;
                ezaOffProfile = ezaOff.config.windows.files.${profilePath}.text;
                ezaOverriddenProfile = ezaOverridden.config.windows.files.${profilePath}.text;
                profile = full.config.windows.files.${profilePath}.text;
                bareProfile = bare.config.windows.files.${profilePath}.text;
                configJson =
                  full.config.windows.files."%USERPROFILE%/Documents/PowerShell/powershell.config.json".source;
                inherit shellIds;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                has() { grep -qF -- "$1" <<<"$profile" || { echo "profile lacks: $1"; exit 1; }; }
                has "if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {"
                has "Set-PSReadLineOption -EditMode 'Emacs' -HistoryNoDuplicates:\$true -MaximumHistoryCount 5000 -PredictionSource 'History'"
                has "Set-PSReadLineKeyHandler -Chord 'Ctrl+d' -Function DeleteCharOrExit"
                has "Set-Alias -Name 'g' -Value 'git'"
                has "function ll { Get-ChildItem -Force @args }"
                has "Invoke-Expression (&starship init powershell)"
                has "zoxide init powershell --cmd cd"
                has "Write-Host 'hi'"
                if grep -q direnv <<<"$profile"; then echo "direnv hook present though its integration is off"; exit 1; fi
                # PSReadLine before aliases before hooks before the extra.
                test "$(grep -n -E 'Set-PSReadLineOption|Set-Alias|starship init|Write-Host' <<<"$profile" | cut -d: -f1 | tr '\n' ' ')" = "$(grep -n -E 'Set-PSReadLineOption|Set-Alias|starship init|Write-Host' <<<"$profile" | cut -d: -f1 | sort -n | tr '\n' ' ')"

                test "$(jq -r '."Microsoft.PowerShell:ExecutionPolicy"' "$configJson")" = RemoteSigned
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%USERPROFILE%/Documents/WindowsPowerShell/profile.ps1")' <<<"$fullDoc" >/dev/null
                test "$(jq -r --arg k "$shellIds" '.resources[] | select(.properties.key == $k and .properties.name == "ExecutionPolicy") | .properties.value' <<<"$fullDoc")" = RemoteSigned

                # oh-my-posh: the hook names the settings file where XDG puts it, a
                # theme by name, a shipped file, or a Windows path as given; the
                # package is winget's; a shipped file is a resource.
                grep -qF 'oh-my-posh init pwsh --config "$Env:APPDATA\oh-my-posh\config.json" | Invoke-Expression' <<<"$ompSettingsProfile"
                grep -qF "oh-my-posh init pwsh --config 'catppuccin_mocha' | Invoke-Expression" <<<"$ompThemeProfile"
                grep -qF 'oh-my-posh init pwsh --config "$Env:APPDATA\oh-my-posh\a.txt" | Invoke-Expression' <<<"$ompFileProfile"
                grep -qF 'oh-my-posh init pwsh --config "C:\posh\mine.omp.yaml" | Invoke-Expression' <<<"$ompStringProfile"
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%APPDATA%/oh-my-posh/config.json")' <<<"$ompSettingsDoc" >/dev/null
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%APPDATA%/oh-my-posh/a.txt")' <<<"$ompFileDoc" >/dev/null
                jq -e '.resources[] | select(.type == "winpkgs/winget" and .id == "JanDeDobbeleer.OhMyPosh")' <<<"$ompSettingsDoc" >/dev/null

                # eza: the alias carrying the options names the executable (a
                # PowerShell function calling its own name would recurse), the
                # others go through it, the theme is written where XDG puts it
                # and the package is winget's.
                grep -qF 'function eza { eza.exe --icons auto --git --group-directories-first @args }' <<<"$ezaProfile"
                grep -qF "Set-Alias -Name 'ls' -Value 'eza'" <<<"$ezaProfile"
                grep -qF 'function ll { eza -l @args }' <<<"$ezaProfile"
                grep -qF 'function lt { eza --tree @args }' <<<"$ezaProfile"
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%APPDATA%/eza/theme.yml")' <<<"$ezaDoc" >/dev/null
                jq -e '.resources[] | select(.type == "winpkgs/winget" and .id == "eza-community.eza")' <<<"$ezaDoc" >/dev/null
                # No options to carry: nothing to wrap, so ls names eza itself.
                if grep -q 'function eza' <<<"$ezaPlainProfile"; then echo "an eza options alias without options"; exit 1; fi
                grep -qF "Set-Alias -Name 'ls' -Value 'eza'" <<<"$ezaPlainProfile"
                # Integration off: no eza in the profile at all.
                if grep -q eza <<<"$ezaOffProfile"; then echo "eza aliases present though its integration is off"; exit 1; fi
                # The five are defaults; a shellAliases entry of the same name wins.
                grep -qF 'function ll { Get-ChildItem -Force @args }' <<<"$ezaOverriddenProfile"

                # Nothing asked for: a header-only profile, no config, no 5.1 files.
                test "$(grep -c -v -E '^(#|$)' <<<"$bareProfile")" = 0
                test "$(jq '[.resources[] | select(.type == "winpkgs/file" and (.id | test("powershell.config.json|WindowsPowerShell")))] | length' <<<"$bareDoc")" = 0
                test "$(jq --arg k "$shellIds" '[.resources[] | select(.properties.key == $k)] | length' <<<"$bareDoc")" = 0
                echo ok > $out
              '';

          # GitHub CLI: home-manager's programs.gh writes gh's own files where
          # XDG puts them, which is where gh looks; winpkgs replaces the one
          # thing that cannot cross -- a credential helper spelled as a Nix
          # store path -- with the command gh itself writes, and refuses
          # extensions by name.
          gh =
            let
              withGh =
                extra:
                home [
                  {
                    winpkgs.name = "gh@gh";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;
                    programs.git.enable = true;
                    programs.gh.enable = true;
                  }
                  extra
                ];
              gitConfigOf =
                e:
                (lib.head (
                  lib.filter (f: f.target == "AppData/Roaming/git/config") (lib.attrValues e.config.home.file)
                )).source;
            in
            pkgs.runCommand "winpkgs-gh"
              {
                doc = document (withGh {
                  programs.gh.hosts."github.com".user = "me";
                });
                gitConfig = gitConfigOf (withGh { });
                ownHosts = gitConfigOf (withGh {
                  programs.gh.gitCredentialHelper.hosts = [ "https://github.example.com" ];
                  programs.git.settings.credential."https://elsewhere".helper = "store";
                });
                noHelper = gitConfigOf (withGh {
                  programs.gh.gitCredentialHelper.enable = false;
                });
                dotConfig = document (
                  withGh (
                    { config, ... }:
                    {
                      xdg.enable = false;
                      xdg.configHome = "${config.home.homeDirectory}/.config";
                    }
                  )
                );
                extensions = lib.boolToString (
                  fails (withGh ({ pkgs, ... }: { programs.gh.extensions = [ pkgs.gh-dash ]; }))
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                value() { jq -r --arg id "$2" '.resources[] | select(.id == $id) | .properties.value' <<<"$1"; }

                # gh's files land where XDG puts them, and GH_CONFIG_DIR names
                # that directory so gh looks there whatever XDG_CONFIG_HOME
                # says -- including a home that turned the variables off.
                # winget has the package at either scope, so the home installs
                # it itself.
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%APPDATA%/gh/config.yml")' <<<"$doc" >/dev/null
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%APPDATA%/gh/hosts.yml")' <<<"$doc" >/dev/null
                test "$(value "$doc" 'Environment\GH_CONFIG_DIR')" = '%APPDATA%\gh'
                jq -e '.resources[] | select(.type == "winpkgs/file" and .id == "%USERPROFILE%/.config/gh/config.yml")' <<<"$dotConfig" >/dev/null
                test "$(value "$dotConfig" 'Environment\GH_CONFIG_DIR')" = '%USERPROFILE%\.config\gh'
                test "$(jq '[.resources[] | select(.id == "Environment\\XDG_CONFIG_HOME")] | length' <<<"$dotConfig")" = 0
                test "$(jq -r '.resources[] | select(.type == "winpkgs/winget" and .id == "GitHub.cli") | .properties.scope' <<<"$doc")" = user

                # The helper is a command found on the PATH, not a store path.
                ! grep -q /nix/store "$gitConfig"
                grep -qF '[credential "https://github.com"]' "$gitConfig"
                grep -qF '[credential "https://gist.github.com"]' "$gitConfig"
                test "$(grep -c -F 'helper = "!gh auth git-credential"' "$gitConfig")" = 2

                # A host list of its own, and a credential section the
                # configuration wrote for another host, left alone.
                grep -qF '[credential "https://github.example.com"]' "$ownHosts"
                ! grep -qF '[credential "https://github.com"]' "$ownHosts"
                grep -qF 'helper = "store"' "$ownHosts"

                # Switched off: no credential section at all.
                ! grep -q credential "$noHelper"

                test "$extensions" = true
                echo ok > $out
              '';

          # Fonts are packages installed from their files: a system's
          # fonts.packages machine-wide, a home's font-marked home.packages per
          # user; the closure carries the files, flattened per package. A font
          # in environment.systemPackages is refused, and every name in the
          # font table exists in the pinned nixpkgs.
          fonts =
            let
              theHome = home [
                (
                  { pkgs, ... }:
                  {
                    winpkgs.name = "f@f";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;
                    home.packages = [
                      pkgs.git
                      pkgs.nerd-fonts.jetbrains-mono
                      pkgs.nerd-fonts.jetbrains-mono # twice is once
                    ];
                  }
                )
              ];
              theSystem = sys [
                (
                  { pkgs, ... }:
                  {
                    winpkgs.name = "f";
                    fonts.packages = [ pkgs.dejavu_fonts ];
                  }
                )
              ];
              crossPkgs = theHome._module.args.pkgs;
              missing = lib.filter (n: !(crossPkgs ? ${n})) crossPkgs.winpkgs.fontPackages;
            in
            pkgs.runCommand "winpkgs-fonts"
              {
                homeDoc = document theHome;
                systemDoc = document theSystem;
                homeClosure = theHome.config.system.build.toplevel;
                # A package the table does not know, marked by hand.
                markedByHand = document (home [
                  (
                    { pkgs, ... }:
                    {
                      winpkgs.name = "f@f";
                      winpkgs.cli.enable = false;
                      winpkgs.powershell.ensure = false;
                      home.packages = [ (pkgs.winpkgs.font pkgs.hello) ];
                    }
                  )
                ]);
                fontInSystemPackagesFails = lib.boolToString (
                  fails (sys [
                    (
                      { pkgs, ... }:
                      {
                        winpkgs.name = "f";
                        environment.systemPackages = [ pkgs.inter ];
                      }
                    )
                  ])
                );
                missing = lib.concatStringsSep " " missing;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                fonts() { jq -r '[.resources[] | select(.type == "winpkgs/font") | .id] | sort | join(",")' <<<"$1"; }
                field() { jq -r --arg id "$2" --arg f "$3" '.resources[] | select(.id == $id) | if $f == "scope" then .scope else .properties[$f] end' <<<"$1"; }

                test "$(fonts "$homeDoc")" = nerd-fonts-jetbrains-mono
                test "$(field "$homeDoc" nerd-fonts-jetbrains-mono scope)" = user
                test "$(field "$homeDoc" nerd-fonts-jetbrains-mono source)" = fonts/nerd-fonts-jetbrains-mono
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/winget") | .id] | join(",")' <<<"$homeDoc")" = Git.Git
                ls "$homeClosure"/fonts/nerd-fonts-jetbrains-mono/*.ttf >/dev/null

                test "$(fonts "$systemDoc")" = dejavu-fonts
                test "$(field "$systemDoc" dejavu-fonts scope)" = machine

                test "$(fonts "$markedByHand")" = hello
                test "$fontInSystemPackagesFails" = true
                test -z "$missing" || { echo "font names missing from nixpkgs: $missing"; exit 1; }
                echo ok > $out
              '';

          # A home declares a machine-scope package; the system that lists the
          # home installs it. The home installs the rest itself. A user-only
          # package in environment.systemPackages is refused.
          homes =
            let
              theHome = home [
                (
                  { pkgs, ... }:
                  {
                    winpkgs.name = "h@h";
                    winpkgs.cli.enable = false;
                    winpkgs.powershell.ensure = false;
                    home.packages = [
                      pkgs.git
                      pkgs.alacritty
                      (pkgs.winpkgs.fromWinget {
                        id = "LLVM.LLVM";
                        scope = "machine";
                      })
                    ];
                  }
                )
              ];
              theSystem = sys [
                {
                  winpkgs.name = "h";
                  winpkgs.homes = [ theHome ];
                }
              ];
            in
            pkgs.runCommand "winpkgs-homes"
              {
                homeDoc = document theHome;
                systemDoc = document theSystem;
                machinePackages = lib.concatMapStringsSep "," (p: p.id) theHome.config.winpkgs.machinePackages;
                userOnlyInSystemFails = lib.boolToString (
                  fails (sys [
                    (
                      { pkgs, ... }:
                      {
                        winpkgs.name = "h";
                        environment.systemPackages = [
                          (pkgs.winpkgs.fromWinget {
                            id = "Some.UserOnly";
                            scope = "user";
                          })
                        ];
                      }
                    )
                  ])
                );
                notAHomeFails = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "h";
                      winpkgs.homes = [ exampleSystem ];
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                ids() { jq -r '[.resources[] | select(.type == "winpkgs/winget") | .id] | sort | join(",")' <<<"$1"; }
                scope() { jq -r --arg id "$2" '.resources[] | select(.id == $id) | .properties.scope' <<<"$1"; }
                test "$(ids "$homeDoc")" = "Git.Git"
                test "$machinePackages" = "Alacritty.Alacritty,LLVM.LLVM"
                test "$(ids "$systemDoc")" = "Alacritty.Alacritty,LLVM.LLVM"
                test "$(scope "$systemDoc" Alacritty.Alacritty)" = machine
                test "$userOnlyInSystemFails" = true
                test "$notAHomeFails" = true
                echo ok > $out
              '';

          # The pre-reorganisation names (everything under winpkgs.*) still
          # evaluate to the same document, with a rename warning each.
          renames =
            let
              modern = home [
                {
                  winpkgs.name = "r@r";
                  winpkgs.cli.enable = false;
                  winpkgs.powershell.ensure = false;
                  windows.explorer.showHiddenFiles = true;
                  windows.taskbar.alignment = "left";
                  windows.theme.mode = "dark";
                  windows.privacy.advertisingId = false;
                  windows.registry.${advanced}.DontPrettyPath = 1;
                  windows.files."%USERPROFILE%/r.txt".text = "r";
                  winget.packages = [ "Git.Git" ];
                }
              ];
              legacy = home [
                {
                  winpkgs.name = "r@r";
                  winpkgs.cli.enable = false;
                  winpkgs.powershell.ensure = false;
                  winpkgs.explorer.showHiddenFiles = true;
                  winpkgs.taskbar.alignment = "left";
                  winpkgs.theme.mode = "dark";
                  winpkgs.privacy.advertisingId = false;
                  winpkgs.registry.${advanced}.DontPrettyPath = 1;
                  winpkgs.files."%USERPROFILE%/r.txt".text = "r";
                  winpkgs.packages.winget = [ "Git.Git" ];
                }
              ];
              legacySystem = sys [
                {
                  networking.hostName = "r";
                  winpkgs.developer.longPaths = true;
                  winpkgs.wsl.enable = true;
                  winpkgs.wsl.modules = [ { system.stateVersion = "26.05"; } ];
                }
              ];
              modernSystem = sys [
                {
                  networking.hostName = "r";
                  windows.developer.longPaths = true;
                  wsl.enable = true;
                  wsl.modules = [ { system.stateVersion = "26.05"; } ];
                }
              ];
            in
            pkgs.runCommand "winpkgs-renames"
              {
                modern = document modern;
                legacy = document legacy;
                modernSystem = document modernSystem;
                legacySystem = document legacySystem;
                legacyWarnings = toString (lib.length legacy.config.warnings);
                modernWarnings = toString (lib.length modern.config.warnings);
                hostName = modernSystem.config.winpkgs.name;
                wslHostName = modernSystem.config.system.build.wsl.config.networking.hostName;
              }
              ''
                test "$modern" = "$legacy"
                test "$modernSystem" = "$legacySystem"
                test "$modernWarnings" = 0
                test "$legacyWarnings" = 7
                test "$hostName" = r
                test "$wslHostName" = r
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
