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

    # The winget manifest repository, manifests only. It is to winget what
    # nixpkgs is to Nix: a commit of it says, for every id, which version is
    # latest, so a `winget.packages` entry without a version gets the one this
    # pin knows, updating packages is `nix flake update winget-pkgs`, and a
    # consumer moves the pin on their own schedule with
    # `inputs.winpkgs.inputs.winget-pkgs.follows`. Not a flake. Versions are
    # read from directory names; installer manifests by lib/winget.nix's own
    # YAML reader, which no configuration calls on yet.
    winget-pkgs = {
      url = "github:microsoft/winget-pkgs";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
      home-manager,
      winget-pkgs,
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
          winget-pkgs
          ;
      };

      # The documentation site, generated from this flake: the option trees,
      # the overlay's tables, the library's doc-comments and the outputs
      # (docs/default.nix). Reading an option tree never builds anything, so
      # it is built on whichever system evaluates.
      docs = forAllSystems (
        system:
        import ./docs {
          inherit lib self winpkgsLib;
          pkgs = nixpkgs.legacyPackages.${system};
        }
      );
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

      # `nix build .#docs` is the site; `nix run .#docs` builds and serves it.
      # `flakedoc` is the renderer the site is built with, on its own.
      packages = forAllSystems (system: {
        inherit (docs.${system}) docs flakedoc;
      });
      apps = forAllSystems (system: {
        docs = {
          type = "app";
          program = lib.getExe docs.${system}.serve;
          meta.description = "Build the documentation site and serve it";
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sys = modules: winpkgsLib.windowsSystem { inherit system modules; };
          home = modules: winpkgsLib.homeConfiguration { inherit system modules; };
          document = e: builtins.toJSON e.config.system.build.document;
          # Does evaluating this configuration's document fail?
          fails = e: !(builtins.tryEval (builtins.deepSeq (document e) true)).success;
          # Why it fails, when it is an assertion: the messages, so a check
          # can say which refusal it expects rather than that there was one.
          failed =
            e: lib.concatMapStringsSep "\n" (a: a.message) (lib.filter (a: !a.assertion) e.config.assertions);

          exampleHome = home [ ./example/home.nix ];
          # The home's machine-wide packages (Git) are the system's to install.
          exampleSystem = sys [
            ./example/configuration.nix
            { winpkgs.homes = [ exampleHome ]; }
          ];
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
                pinned=$(echo "$doc" | jq '.resources[] | select(.id == "Microsoft.PowerShell") | .properties.pinned')
                test "$n" = 1 && test "$up" = true && test "$pinned" = false
                test "$(echo "$doc" | jq -c '.settings')" = '{"generations":{"deleteOlderThan":null,"keep":10},"prune":{"features":true,"files":true,"groupMembers":true,"services":true,"winget":true},"substitutions":[{"from":"/home/example","to":"%USERPROFILE%"}]}'
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
                    winpkgs.activation.tell.command = "s.exe --reload";
                  }
                ]);
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                test "$(jq -r '.resources[-2].id' <<<"$doc")" = 'Service s'
                test "$(jq -r '.resources[-1].id' <<<"$doc")" = 'Activation tell'
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/file")] | length' <<<"$doc")" = 1
                echo ok > $out
              '';

          # An activation's revision follows its command and its triggers, and
          # nothing else; either kind of configuration has them.
          activation =
            let
              tell =
                command: triggers:
                document (home [
                  {
                    winpkgs.name = "a@a";
                    winpkgs.activation.tell = { inherit command triggers; };
                  }
                ]);
            in
            pkgs.runCommand "winpkgs-activation"
              {
                doc = tell "app --reload" [ "v1" ];
                again = tell "app --reload" [ "v1" ];
                newTriggers = tell "app --reload" [ "v2" ];
                newCommand = tell "app --reload --all" [ "v1" ];
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                p() { jq -r --arg f "$2" '.resources[] | select(.id == "Activation tell") | .[$f] // .properties[$f] | tostring' <<<"$1"; }
                test "$(p "$doc" type)" = winpkgs/activation
                test "$(p "$doc" scope)" = user
                test "$(p "$doc" name)" = tell
                test "$(p "$doc" command)" = 'app --reload'
                [[ "$(p "$doc" revision)" =~ ^[0-9a-f]{64}$ ]]
                test "$(p "$doc" revision)" = "$(p "$again" revision)"
                test "$(p "$doc" revision)" != "$(p "$newTriggers" revision)"
                test "$(p "$doc" revision)" != "$(p "$newCommand" revision)"
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
                  (lib.head (
                    lib.filter (r: r.id == "BurntSushi.ripgrep.MSVC")
                      (builtins.fromJSON (document exampleHome)).resources
                  )).properties.scope;
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
                machinePackages = lib.concatMapStringsSep "," (p: p.id) e.config.winpkgs.machinePackages;
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

                # Git's installer is machine-wide: programs.git hands it to the
                # system rather than installing it from the home.
                lacks Git.Git
                case ",$machinePackages," in *,Git.Git,*) ;; *) echo "Git.Git not exported: $machinePackages"; exit 1 ;; esac
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
          # in the mapping table exists in the pinned nixpkgs, every id in the
          # pinned winget-pkgs, and every id's installer manifest reads.
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
                      # machine-wide, like neovim below
                      pkgs.git
                      pkgs.ripgrep
                      # nixpkgs does not build it for Windows, so only the id
                      # matters; and its installer is machine-wide, so a home
                      # exports it rather than installing it itself.
                      pkgs.neovim
                      (pkgs.winpkgs.fromWinget "Microsoft.PowerToys")
                    ];
                    winget.packages = [ "BurntSushi.ripgrep.MSVC" ]; # merges with pkgs.ripgrep
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
              # Every id the table maps to exists in the pinned winget-pkgs:
              # the check the table's header used to ask of whoever added
              # the entry.
              mappedIds = lib.unique (
                lib.filter (id: id != null) (
                  map (entry: if builtins.isAttrs entry then entry.id else entry) (
                    lib.attrValues crossPkgs.winpkgs.wingetMappings
                  )
                )
              );
              missingFromWinget = lib.filter (id: !(winpkgsLib.winget.hasPackage winget-pkgs id)) mappedIds;
              # And every one's installer manifest, at its latest version in
              # the pin: it parses -- a manifest outside what lib.winget reads
              # fails this check by file and line -- and an installer is
              # picked at the scope the table gives the id, or at both scopes
              # where it gives none, with a URL and a hash to fetch it by.
              # This is what keeps the YAML reader, and the table's scopes,
              # honest as the pin moves: an unannotated id with an installer
              # at one scope only would fail at apply in the other kind of
              # configuration.
              scopeOf = lib.listToAttrs (
                map (entry: lib.nameValuePair entry.id (entry.scope or null)) (
                  lib.filter builtins.isAttrs (lib.attrValues crossPkgs.winpkgs.wingetMappings)
                )
              );
              installers = map (
                id:
                let
                  w = winpkgsLib.winget;
                  version = w.latestVersion winget-pkgs id;
                  manifest = w.installerManifest winget-pkgs id version;
                  at =
                    scope:
                    let
                      installer = w.selectInstaller { inherit manifest scope; };
                    in
                    if installer == null then null else w.installerRecord { inherit manifest installer; };
                in
                {
                  inherit id version;
                  scope = scopeOf.${id} or null;
                  machine = at "machine";
                  user = at "user";
                }
              ) (lib.filter (id: !(lib.elem id missingFromWinget)) mappedIds);
              unpicked = lib.filter (
                r: if r.scope != null then r.${r.scope} == null else r.machine == null || r.user == null
              ) installers;
              # What to do about each: annotate the scope winget has, or, for
              # an annotation winget does not bear out, change or drop it.
              unpickedAdvice =
                r:
                if r.scope != null then
                  "${r.id} has no ${r.scope} installer, yet the table says scope = \"${r.scope}\""
                else if r.machine == null && r.user == null then
                  "${r.id} has no installer at either scope"
                else
                  "${r.id} has no ${if r.machine == null then "machine" else "user"} installer: give it scope = \"${
                    if r.machine == null then "user" else "machine"
                  }\"";
              unfetchable =
                lib.filter
                  (
                    record:
                    !(lib.hasPrefix "https://" record.url) || builtins.match "[0-9a-f]{64}" record.sha256 == null
                  )
                  (
                    lib.concatMap (
                      r:
                      lib.filter (x: x != null) [
                        r.machine
                        r.user
                      ]
                    ) installers
                  );
              describePick =
                record:
                if record == null then
                  "-"
                else
                  lib.concatStringsSep "/" (
                    lib.filter (x: x != null) [
                      record.type
                      record.nestedType
                    ]
                  );
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
                missingFromWinget = lib.concatStringsSep " " missingFromWinget;
                wingetPkgs = winpkgsLib.winget.describe winget-pkgs;
                unpicked = lib.concatMapStringsSep "\n" unpickedAdvice unpicked;
                # The table's scopes reach configurations: a machine-only
                # package in a home is the system's to install, and a user-only
                # one in a system is refused by name.
                homeMachinePackages =
                  lib.concatMapStringsSep "," (p: p.id)
                    (home [
                      (
                        { pkgs, ... }:
                        {
                          winpkgs.name = "p@p";
                          winpkgs.cli.enable = false;
                          winpkgs.powershell.ensure = false;
                          home.packages = [
                            pkgs.firefox
                            pkgs.discord
                          ];
                        }
                      )
                    ]).config.winpkgs.machinePackages;
                systemUserOnlyRefusal = failed (sys [
                  (
                    { pkgs, ... }:
                    {
                      winpkgs.name = "p";
                      environment.systemPackages = [ pkgs.discord ];
                    }
                  )
                ]);
                unfetchable = lib.concatMapStringsSep " " (record: "${record.id}:${record.url}") unfetchable;
                installerCount = toString (lib.length installers);
                # Read by a person, in the build log: what each scope gets.
                installerTable = lib.concatMapStringsSep "\n" (
                  r: "${r.id} ${r.version}: machine ${describePick r.machine}, user ${describePick r.user}"
                ) installers;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                echo "installers in $wingetPkgs:"
                echo "$installerTable"
                test "$installerCount" -gt 0
                test -z "$unpicked" || { echo "overlays/winget.nix disagrees with $wingetPkgs:"; echo "$unpicked"; exit 1; }
                test "$homeMachinePackages" = Mozilla.Firefox
                case "$systemUserOnlyRefusal" in *"install per user only"*discord*) ;; *) echo "refusal: $systemUserOnlyRefusal"; exit 1 ;; esac
                test -z "$unfetchable" || { echo "installers without an https URL and a SHA-256: $unfetchable"; exit 1; }
                ids() { jq -r '[.resources[] | select(.type == "winpkgs/winget") | .id] | sort | join(",")' <<<"$1"; }
                prop() { jq -r --arg id "$2" --arg f "$3" '.resources[] | select(.id == $id) | .properties[$f]' <<<"$1"; }
                test "$(ids "$doc")" = "BurntSushi.ripgrep.MSVC,Microsoft.PowerToys"
                # git and neovim are machine-scope, so the home exports them for
                # the system to install rather than emitting resources of its own.
                test "$machinePackages" = Git.Git,Neovim.Neovim
                test "$gitId" = Git.Git
                test "$unmappedFails" = true
                test "$unavailableFails" = true
                test -z "$missing" || { echo "mapping names missing from nixpkgs: $missing"; exit 1; }
                test -z "$missingFromWinget" || { echo "mapped ids missing from $wingetPkgs: $missingFromWinget"; exit 1; }
                # environment.systemPackages, machine scope
                test "$(prop "$systemDoc" 7zip.7zip scope)" = machine
                # Against the real input: a default has some version and is
                # not pinned, and the example's wezterm pin is one. Which
                # version 7zip resolves to moves with the pin, so it is not
                # written down here.
                test "$(prop "$systemDoc" 7zip.7zip pinned)" = false
                test -n "$(prop "$systemDoc" 7zip.7zip version)"
                test "$(prop "$systemDoc" 7zip.7zip version)" != null
                test "$(prop "$systemDoc" wez.wezterm pinned)" = true
                test "$(prop "$systemDoc" wez.wezterm version)" = 20240203-110809-5046fc22
                echo ok > $out
              '';

          # lib.winget reads a winget-pkgs tree for directory names: which
          # versions a package has and which is latest. Against a fixture tree
          # laid out like the real one (example/winget-pkgs), so the strings
          # are exact where the real input's move: versions that need numeric
          # rather than lexical ordering, a sub-package directory beside a
          # package's versions, a dotted id, a digit-led id, a dated version.
          #
          # And what a configuration makes of it: an entry without a version
          # gets the tree's latest and is not pinned; one with a version is
          # pinned to it; a default and a pin of the same id merge into the
          # pin; `upgrade` keeps the resolved version but is not a pin; a
          # Store package has no version to resolve; an id the tree does not
          # have -- misspelt, wrong case, a publisher alone -- is refused by
          # name.
          winget-versions =
            let
              fixture = ./example/winget-pkgs;
              w = winpkgsLib.winget;
              versions = id: lib.concatStringsSep "," (lib.sort lib.versionOlder (w.versionsOf fixture id));
              latest = id: toString (w.latestVersion fixture id);

              over =
                modules:
                home (
                  [
                    {
                      winpkgs.name = "v@v";
                      winpkgs.cli.enable = false;
                      winpkgs.powershell.ensure = false;
                      winget.manifests = fixture;
                    }
                  ]
                  ++ modules
                );
              resolvedDoc = document (over [
                {
                  winget.packages = [
                    "Git.Git"
                    "Microsoft.PowerShell"
                    "Microsoft.PowerShell.Preview"
                    "Python.Python.3.13"
                    "7zip.7zip"
                    "wez.wezterm"
                    {
                      id = "BurntSushi.ripgrep.MSVC";
                      upgrade = true;
                    }
                    {
                      id = "9NBLGGH4NNS1";
                      source = "msstore";
                    }
                  ];
                }
              ]);
              pinnedDoc = document (over [
                {
                  winget.packages = [
                    {
                      id = "Git.Git";
                      version = "2.47.1";
                    }
                  ];
                }
                # A second module names the same id without a version: the
                # pin wins, and it is not a conflict.
                { winget.packages = [ "Git.Git" ]; }
              ]);
              refused = id: failed (over [ { winget.packages = [ id ]; } ]);
            in
            pkgs.runCommand "winpkgs-winget-versions"
              {
                inherit resolvedDoc pinnedDoc;
                typoRefused = refused "Git.Gitt";
                caseRefused = refused "git.git";
                publisherRefused = refused "Git";
                # A pin the tree does not list is a warning, not a refusal.
                stalePinWarns =
                  lib.concatStringsSep "\n"
                    (over [
                      {
                        winget.packages = [
                          {
                            id = "Git.Git";
                            version = "2.0.0";
                          }
                        ];
                      }
                    ]).config.warnings;
                nativeBuildInputs = [ pkgs.jq ];
                gitVersions = versions "Git.Git";
                gitLatest = latest "Git.Git";
                pwshVersions = versions "Microsoft.PowerShell";
                pwshLatest = latest "Microsoft.PowerShell";
                previewLatest = latest "Microsoft.PowerShell.Preview";
                pythonLatest = latest "Python.Python.3.13";
                sevenZipLatest = latest "7zip.7zip";
                weztermLatest = latest "wez.wezterm";
                ripgrepLatest = latest "BurntSushi.ripgrep.MSVC";
                # A publisher is a directory, not a package; an unknown id is
                # nothing at all.
                publisherHas = lib.boolToString (w.hasPackage fixture "Git");
                unknownHas = lib.boolToString (w.hasPackage fixture "Nope.Nope");
                unknownLatest = toString (w.latestVersion fixture "Nope.Nope");
                gitDir = lib.removePrefix (toString fixture) (w.manifestDir fixture "Git.Git");
                pythonDir = lib.removePrefix (toString fixture) (w.manifestDir fixture "Python.Python.3.13");
                described = w.describe fixture;
              }
              ''
                test "$gitVersions" = 2.47.1,2.47.9,2.47.10
                test "$gitLatest" = 2.47.10
                test "$pwshVersions" = 7.4.6.0,7.5.0.0
                test "$pwshLatest" = 7.5.0.0
                test "$previewLatest" = 7.6.0.0
                test "$pythonLatest" = 3.13.2
                test "$sevenZipLatest" = 24.09
                test "$weztermLatest" = 20240203-110809-5046fc22
                test "$ripgrepLatest" = 14.1.1
                test "$publisherHas" = false
                test "$unknownHas" = false
                test -z "$unknownLatest"
                test "$gitDir" = /manifests/g/Git/Git
                test "$pythonDir" = /manifests/p/Python/Python/3/13
                case "$described" in "the winget-pkgs tree at /"*) ;; *) echo "describe: $described"; exit 1 ;; esac

                prop() { jq -r --arg id "$2" --arg f "$3" '.resources[] | select(.id == $id) | .properties[$f]' <<<"$1"; }
                for id in Git.Git:2.47.10 Microsoft.PowerShell:7.5.0.0 Microsoft.PowerShell.Preview:7.6.0.0 \
                          Python.Python.3.13:3.13.2 7zip.7zip:24.09 wez.wezterm:20240203-110809-5046fc22 \
                          BurntSushi.ripgrep.MSVC:14.1.1; do
                  test "$(prop "$resolvedDoc" "''${id%%:*}" version)" = "''${id#*:}" || { echo "$id: got $(prop "$resolvedDoc" "''${id%%:*}" version)"; exit 1; }
                  test "$(prop "$resolvedDoc" "''${id%%:*}" pinned)" = false
                done
                test "$(prop "$resolvedDoc" BurntSushi.ripgrep.MSVC upgrade)" = true
                test "$(prop "$resolvedDoc" Git.Git upgrade)" = false
                test "$(prop "$resolvedDoc" 9NBLGGH4NNS1 version)" = null
                test "$(prop "$resolvedDoc" 9NBLGGH4NNS1 pinned)" = false
                test "$(jq '[.resources[] | select(.id == "Git.Git")] | length' <<<"$pinnedDoc")" = 1
                test "$(prop "$pinnedDoc" Git.Git version)" = 2.47.1
                test "$(prop "$pinnedDoc" Git.Git pinned)" = true
                for refusal in "$typoRefused" "$caseRefused" "$publisherRefused"; do
                  case "$refusal" in *"is not in the winget-pkgs tree at"*) ;; *) echo "refusal: $refusal"; exit 1 ;; esac
                done
                case "$typoRefused" in *Git.Gitt*) ;; *) echo "typo: $typoRefused"; exit 1 ;; esac
                case "$caseRefused" in *"winget search git.git"*) ;; *) echo "case: $caseRefused"; exit 1 ;; esac
                case "$stalePinWarns" in *"Git.Git is pinned to 2.0.0"*) ;; *) echo "stale pin: $stalePinWarns"; exit 1 ;; esac
                echo ok > $out
              '';

          # lib.winget reads installer manifests: the YAML subset, the root
          # folded into each installer, winget's selection in miniature, and
          # the record that leaves Nix. The fixture tree's installer
          # manifests each carry a shape that matters, said in their
          # comments; what no file here can hold (CRLF, a lone CR, a
          # byte-order mark -- .gitattributes makes every file LF) and what
          # the parser refuses are inline text. Each expectation is a pair,
          # what came out and what should have; the check prints the ones
          # that differ.
          winget-installers =
            let
              fixture = ./example/winget-pkgs;
              w = winpkgsLib.winget;
              parse = w.parseYAML "t.yaml";
              bom = builtins.fromJSON ("\"\\" + "uFEFF\"");

              reads = {
                crlf = [
                  "A: 1\r\nB:\r\n- x\r\n"
                  {
                    A = "1";
                    B = [ "x" ];
                  }
                ];
                lone-cr = [
                  "A: 1\r\rB: 2\r\n"
                  {
                    A = "1";
                    B = "2";
                  }
                ];
                bom = [
                  "${bom}# a comment first\nA: 1\n"
                  { A = "1"; }
                ];
                document-start = [
                  "---\nA: 1\n"
                  { A = "1"; }
                ];
                nothing = [
                  "# only a comment\n\n"
                  null
                ];
                comments = [
                  "A: x # trailing\nB: 'q # quoted' # trailing\nC: https://example.com/#fragment\n"
                  {
                    A = "x";
                    B = "q # quoted";
                    C = "https://example.com/#fragment";
                  }
                ];
                strings = [
                  ''
                    A: 'it'''s'
                    B: "a \"b\" \\ \u00e9"
                    C: "001"
                    D: 1.10
                    E: C:\x
                    F: a:b
                    G: -1978335189
                  ''
                  {
                    A = "it's";
                    B = ''a "b" \ é'';
                    C = "001";
                    D = "1.10";
                    E = ''C:\x'';
                    F = "a:b";
                    G = "-1978335189";
                  }
                ];
                empties = [
                  "A: []\nB: {}\nC:\nD:\n  E: x\n"
                  {
                    A = [ ];
                    B = { };
                    C = null;
                    D.E = "x";
                  }
                ];
                sequences = [
                  "A:\n- B: 1\n  C:\n  - x\n  - y\nD:\n  - 1\n  - -2\nE:\n- - x\n  - y\nF:\n- # a note\n  G: 1\n"
                  {
                    A = [
                      {
                        B = "1";
                        C = [
                          "x"
                          "y"
                        ];
                      }
                    ];
                    D = [
                      "1"
                      "-2"
                    ];
                    E = [
                      [
                        "x"
                        "y"
                      ]
                    ];
                    F = [ { G = "1"; } ];
                  }
                ];
              };
              misread = lib.filterAttrs (_: c: (parse (lib.head c)).value != lib.elemAt c 1) reads;

              # Text, the line it is refused at, and how the refusal starts.
              refusals = {
                flow = [
                  "A: 1\nB: [a, b]\n"
                  2
                  "a flow collection"
                ];
                block-scalar = [
                  "A: >-\n  x\n"
                  1
                  "a block scalar"
                ];
                anchor = [
                  "A:\n- &a\n  B: 1\n"
                  2
                  "an anchor, alias or tag"
                ];
                alias = [
                  "A: *a\n"
                  1
                  "an anchor, alias or tag"
                ];
                multi-line = [
                  "A:\n  x\n  y\n"
                  3
                  "a plain scalar that runs onto another line"
                ];
                value-and-block = [
                  "A: 1\n  B: 2\n"
                  2
                  "more under `A`"
                ];
                colon = [
                  "A: b: c\n"
                  1
                  "a `: ` inside a plain scalar"
                ];
                duplicate = [
                  "A: 1\nB: 2\nA: 3\n"
                  3
                  "`A` a second time"
                ];
                escape = [
                  "A: \"\\x41\"\n"
                  1
                  "a double-quoted string with an escape JSON does not have (\\x)"
                ];
                unclosed = [
                  "A: 'x\n"
                  1
                  "a single-quoted string that does not end"
                ];
                second-document = [
                  "A: 1\n---\nB: 2\n"
                  2
                  "a second document"
                ];
                tab = [
                  "A:\n\t- x\n"
                  2
                  "a tab"
                ];
                dedent = [
                  "A:\n    B: 1\n  C: 2\n"
                  3
                  "a line indented less"
                ];
                sequence-column = [
                  "A:\n  - x\n  B: 1\n"
                  3
                  "a key at the column of a sequence"
                ];
                scalar-for-key = [
                  "A: 1\nfoo\n"
                  2
                  "a scalar where a `key:` belongs"
                ];
              };
              unrefused = lib.mapAttrs (_: c: (parse (lib.head c)).error) (
                lib.filterAttrs (
                  _: c:
                  let
                    error = (parse (lib.head c)).error;
                  in
                  error == null
                  || !(lib.hasPrefix "t.yaml, line ${toString (lib.elemAt c 1)}: ${lib.elemAt c 2}" error)
                ) refusals
              );

              manifest = w.installerManifest fixture;
              pick =
                id: version: scope: arch:
                let
                  m = manifest id version;
                  i = w.selectInstaller {
                    manifest = m;
                    inherit scope arch;
                  };
                in
                if i == null then
                  null
                else
                  w.installerRecord {
                    manifest = m;
                    installer = i;
                  };
              everything = manifest "Example.Installers" "1.0.0";
              # The record of Example.Installers' machine entry of a type.
              entry =
                pred:
                w.installerRecord {
                  manifest = everything;
                  installer = lib.findFirst (
                    e: e.Architecture == "x64" && e.Scope == "machine" && pred e
                  ) null everything.Installers;
                };
              ofType = type: entry (e: e.InstallerType == type);

              # A pick and the fields of it that matter, or null for none.
              picks = {
                ripgrep-user = [
                  (pick "BurntSushi.ripgrep.MSVC" "14.1.1" "user" "x64")
                  {
                    id = "BurntSushi.ripgrep.MSVC";
                    version = "14.1.1";
                    type = "zip";
                    nestedType = "portable";
                    nestedFiles = [
                      {
                        relativeFilePath = "ripgrep-14.1.1-x86_64-pc-windows-msvc/rg.exe";
                        portableCommandAlias = "rg";
                      }
                    ];
                    url = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-pc-windows-msvc.zip";
                    sha256 = "d0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1";
                    scope = null;
                  }
                ];
                ripgrep-machine = [
                  (pick "BurntSushi.ripgrep.MSVC" "14.1.1" "machine" "x64")
                  {
                    url = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-pc-windows-msvc.zip";
                  }
                ];
                ripgrep-arm64 = [
                  (pick "BurntSushi.ripgrep.MSVC" "14.1.1" "user" "arm64")
                  {
                    url = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-aarch64-pc-windows-msvc.zip";
                  }
                ];
                # One URL, two scopes: the root's Silent and each entry's Custom.
                oh-my-posh-user = [
                  (pick "JanDeDobbeleer.OhMyPosh" "19.6.0" "user" "x64")
                  {
                    type = "inno";
                    scope = "user";
                    url = "https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v19.6.0/install-amd64.exe";
                    switches = {
                      silent = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-";
                      silentWithProgress = "/SILENT /SUPPRESSMSGBOXES /NORESTART /SP-";
                      custom = "/CURRENTUSER";
                      installLocation = null;
                    };
                  }
                ];
                oh-my-posh-machine = [
                  (pick "JanDeDobbeleer.OhMyPosh" "19.6.0" "machine" "x64")
                  {
                    scope = "machine";
                    url = "https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v19.6.0/install-amd64.exe";
                    switches = {
                      silent = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-";
                      silentWithProgress = "/SILENT /SUPPRESSMSGBOXES /NORESTART /SP-";
                      custom = "/ALLUSERS";
                      installLocation = null;
                    };
                  }
                ];
                # An MSIX declares no scope and installs for the user.
                oh-my-posh-msix = [
                  (pick "JanDeDobbeleer.OhMyPosh" "26.0.0" "user" "x64")
                  {
                    type = "msix";
                    packageFamilyName = "ohmyposh.cli_96v55e8n804z4";
                    productCode = null;
                    scope = null;
                  }
                ];
                # The one msi entry overrides the root's exe, and outranks it.
                seven-zip = [
                  (pick "7zip.7zip" "24.09" "machine" "x64")
                  {
                    version = "24.09";
                    type = "msi";
                    scope = "machine";
                    productCode = "{23170F69-40C1-2702-2409-000001000000}";
                    appsAndFeaturesEntries = [
                      {
                        displayName = "7-Zip 24.09 (x64 edition)";
                        publisher = "Igor Pavlov";
                        displayVersion = null;
                        productCode = "{23170F69-40C1-2702-2409-000001000000}";
                        upgradeCode = "{23170F69-40C1-2702-0000-000004000000}";
                        installerType = null;
                      }
                    ];
                    commands = [ "7z" ];
                    elevationRequirement = "elevatesSelf";
                  }
                ];
                # The root's product code is the exe's.
                seven-zip-x86 = [
                  (pick "7zip.7zip" "24.09" "machine" "x86")
                  {
                    type = "exe";
                    productCode = "7-Zip";
                    url = "https://www.7-zip.org/a/7z2409.exe";
                    switches = {
                      silent = "/S";
                      silentWithProgress = "/S";
                      custom = null;
                      installLocation = "/D=<INSTALLPATH>";
                    };
                  }
                ];
                seven-zip-user = [
                  (pick "7zip.7zip" "24.09" "user" "x64")
                  null
                ];
                alacritty = [
                  (pick "Alacritty.Alacritty" "0.13.2" "machine" "x64")
                  {
                    type = "wix";
                    productCode = "{EB4FE5BE-6897-441C-933D-4E592B392C63}";
                    dependencies = {
                      packages = [
                        {
                          id = "Microsoft.VCRedist.2015+.x64";
                          minimumVersion = "14.38.33130.0";
                        }
                      ];
                      windowsFeatures = [ ];
                      windowsLibraries = [ ];
                      external = [ ];
                    };
                  }
                ];
                discord = [
                  (pick "Discord.Discord" "1.0.9000" "user" "x64")
                  {
                    type = "exe";
                    productCode = null;
                    appsAndFeaturesEntries = [
                      {
                        displayName = "Discord";
                        publisher = "Discord Inc.";
                        displayVersion = null;
                        productCode = null;
                        upgradeCode = null;
                        installerType = null;
                      }
                    ];
                  }
                ];
                discord-machine = [
                  (pick "Discord.Discord" "1.0.9000" "machine" "x64")
                  null
                ];
                # No scope declared: the machine takes it, the user does not.
                wezterm-machine = [
                  (pick "wez.wezterm" "20240203-110809-5046fc22" "machine" "x64")
                  {
                    type = "inno";
                    scope = null;
                    productCode = "{BCF6F0DA-5B9A-408D-8562-F680AE6E1EAF}_is1";
                  }
                ];
                wezterm-user = [
                  (pick "wez.wezterm" "20240203-110809-5046fc22" "user" "x64")
                  null
                ];
                # x86 only, on x64.
                steam = [
                  (pick "Valve.Steam" "2.10.91.91" "machine" "x64")
                  {
                    type = "nullsoft";
                    url = "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe";
                  }
                ];
                jq = [
                  (pick "jqlang.jq" "1.7.1" "user" "x64")
                  {
                    type = "portable";
                    commands = [ "jq" ];
                    url = "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe";
                  }
                ];
                python-user = [
                  (pick "Python.Python.3.13" "3.13.2" "user" "x64")
                  {
                    type = "burn";
                    scope = "user";
                    productCode = "{bdda61aa-57d0-45c8-ae92-fa67d560e32f}";
                    switches = {
                      silent = null;
                      silentWithProgress = null;
                      custom = "InstallAllUsers=0 PrependPath=1";
                      installLocation = "DefaultJustForMeTargetDir=<INSTALLPATH>";
                    };
                    elevationRequirement = null;
                  }
                ];
                python-machine = [
                  (pick "Python.Python.3.13" "3.13.2" "machine" "x64")
                  {
                    scope = "machine";
                    switches = {
                      silent = null;
                      silentWithProgress = null;
                      custom = "InstallAllUsers=1 PrependPath=1";
                      installLocation = "DefaultAllUsersTargetDir=<INSTALLPATH>";
                    };
                    elevationRequirement = "elevatesSelf";
                  }
                ];
                example = [
                  (pick "Example.Installers" "1.0.0" "machine" "x64")
                  {
                    type = "msi";
                    url = "https://example.com/example.msi";
                    sha256 = "000000000000000000000000000000000000000000000000000000000000000f";
                    productCode = "{00000000-0000-0000-0000-00000000000F}";
                    packageFamilyName = null;
                    appsAndFeaturesEntries = [
                      {
                        displayName = "Example";
                        publisher = "Example Publisher";
                        displayVersion = null;
                        productCode = null;
                        upgradeCode = null;
                        installerType = null;
                      }
                    ];
                    expectedReturnCodes = [
                      {
                        code = -1978335189;
                        response = "alreadyInstalled";
                        responseUrl = null;
                      }
                      {
                        code = -2147219701;
                        response = "packageInUse";
                        responseUrl = "https://example.com/in-use";
                      }
                      {
                        code = 1618;
                        response = "installInProgress";
                        responseUrl = null;
                      }
                    ];
                    successCodes = [
                      3010
                      1641
                    ];
                    dependencies = {
                      packages = [
                        {
                          id = "Microsoft.VCRedist.2015+.x64";
                          minimumVersion = "14.0.0";
                        }
                        {
                          id = "Microsoft.DotNet.DesktopRuntime.8";
                          minimumVersion = null;
                        }
                      ];
                      windowsFeatures = [ "NetFx3" ];
                      windowsLibraries = [ "Microsoft.VCLibs.140.00" ];
                      external = [ "Java Runtime Environment 8" ];
                    };
                    elevationRequirement = "elevationRequired";
                  }
                ];
                example-user = [
                  (pick "Example.Installers" "1.0.0" "user" "x64")
                  { url = "https://example.com/example-user.msi"; }
                ];
                # arm64 runs neutral before x64.
                example-arm64 = [
                  (pick "Example.Installers" "1.0.0" "machine" "arm64")
                  { url = "https://example.com/example-neutral.msi"; }
                ];
                # What the root hands down depends on the type.
                example-msix = [
                  (ofType "msix")
                  {
                    productCode = null;
                    packageFamilyName = "Example.Installers_8wekyb3d8bbwe";
                    appsAndFeaturesEntries = [ ];
                  }
                ];
                example-zip = [
                  (entry (e: e.InstallerType == "zip" && e.NestedInstallerType == "portable"))
                  {
                    productCode = "Example";
                    packageFamilyName = null;
                    appsAndFeaturesEntries = [ ];
                    archiveBinariesDependOnPath = true;
                    nestedFiles = [
                      {
                        relativeFilePath = "example/bin/example.exe";
                        portableCommandAlias = null;
                      }
                      {
                        relativeFilePath = "example/bin/example-helper.exe";
                        portableCommandAlias = "exh";
                      }
                    ];
                  }
                ];
                example-inno = [
                  (ofType "inno")
                  {
                    productCode = "Example";
                    switches = {
                      silent = "/quiet";
                      silentWithProgress = null;
                      custom = "/inno";
                      installLocation = null;
                    };
                  }
                ];
              };
              mispicked = lib.filterAttrs (
                _: c:
                let
                  got = lib.head c;
                  want = lib.elemAt c 1;
                in
                if want == null then
                  got != null
                else
                  got == null || lib.any (k: (got.${k} or "(absent)") != want.${k}) (lib.attrNames want)
              ) picks;

              # Take Example.Installers' types away most preferred first: each
              # time the next is picked, and a zip of a zip and a font never.
              ladder = map (
                n:
                let
                  kept = lib.filter (
                    e:
                    let
                      r = lib.lists.findFirstIndex (t: t == e.InstallerType) null w.installerTypes;
                    in
                    r == null || r >= n
                  ) everything.Installers;
                  i = w.selectInstaller {
                    manifest = everything // {
                      Installers = kept;
                    };
                    scope = "machine";
                  };
                in
                if i == null then "none" else i.InstallerType
              ) (lib.range 0 (lib.length w.installerTypes));
              # And the msi's architectures: x64, neutral, x86.
              archLadder =
                map
                  (
                    gone:
                    let
                      i = w.selectInstaller {
                        manifest = everything // {
                          Installers = lib.filter (
                            e: e.InstallerType == "msi" && !(lib.elem e.Architecture gone)
                          ) everything.Installers;
                        };
                        scope = "machine";
                      };
                    in
                    if i == null then "none" else i.Architecture
                  )
                  [
                    [ ]
                    [ "x64" ]
                    [
                      "x64"
                      "neutral"
                    ]
                    [
                      "x64"
                      "neutral"
                      "x86"
                    ]
                  ];
              throws = v: !(builtins.tryEval (builtins.deepSeq v true)).success;
            in
            pkgs.runCommand "winpkgs-winget-installers"
              {
                misread = builtins.toJSON (lib.mapAttrs (_: c: (parse (lib.head c)).value) misread);
                unrefused = builtins.toJSON unrefused;
                mispicked = builtins.toJSON (
                  lib.mapAttrs (
                    _: c:
                    let
                      got = lib.head c;
                      want = lib.elemAt c 1;
                    in
                    {
                      inherit want;
                      got = if got == null || want == null then got else lib.filterAttrs (k: _: want ? ${k}) got;
                    }
                  ) mispicked
                );
                ladder = lib.concatStringsSep "," ladder;
                archLadder = lib.concatStringsSep "," archLadder;
                types = lib.concatStringsSep "," w.installerTypes;
                recordKeys = lib.concatStringsSep "," (
                  lib.attrNames (pick "BurntSushi.ripgrep.MSVC" "14.1.1" "user" "x64")
                );
                fromYAMLReads = (w.fromYAML "t.yaml" "A: 1\n").A;
                fromYAMLThrows = lib.boolToString (throws (w.fromYAML "t.yaml" "A: [1]\n"));
                # Git.Git's fixture versions have no installer manifest.
                missingThrows = lib.boolToString (throws (manifest "Git.Git" "2.47.1"));
                badScopeThrows = lib.boolToString (
                  throws (
                    w.selectInstaller {
                      manifest = everything;
                      scope = "system";
                    }
                  )
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                test "$misread" = '{}' || { echo "misread:"; jq . <<<"$misread"; exit 1; }
                test "$unrefused" = '{}' || { echo "not refused as expected:"; jq . <<<"$unrefused"; exit 1; }
                test "$mispicked" = '{}' || { echo "picked wrong:"; jq . <<<"$mispicked"; exit 1; }
                test "$ladder" = "$types,none" || { echo "ladder: $ladder"; exit 1; }
                test "$archLadder" = x64,neutral,x86,none || { echo "architectures: $archLadder"; exit 1; }
                test "$recordKeys" = appsAndFeaturesEntries,archiveBinariesDependOnPath,commands,dependencies,elevationRequirement,expectedReturnCodes,id,nestedFiles,nestedType,packageFamilyName,productCode,scope,sha256,successCodes,switches,type,url,version \
                  || { echo "record keys: $recordKeys"; exit 1; }
                test "$fromYAMLReads" = 1
                test "$fromYAMLThrows" = true
                test "$missingThrows" = true
                test "$badScopeThrows" = true
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
          # shape, restart triggers as a revision that changes with them, the
          # control a restart ends it with, and who may control it; a template
          # cannot have an account, a descriptor is a DACL alone, and a home
          # configuration has no services at all.
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
                      securityDescriptor = "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLORC;;;IU)(A;;CCLCSWLORC;;;SU)";
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
                saclInDescriptorFails = lib.boolToString (
                  fails (sys [
                    {
                      winpkgs.name = "s";
                      windows.services.t = {
                        command = "x";
                        securityDescriptor = "D:(A;;CCLCSWLORC;;;IU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)";
                      };
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
                test "$(p "$doc" 'Service steward' securityDescriptor)" = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLORC;;;IU)(A;;CCLCSWLORC;;;SU)'

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
                test "$(p "$doc" 'Service plain' securityDescriptor)" = null
                test "$(jq -r '[.resources[] | select(.id == "Service gone")] | length' <<<"$doc")" = 0

                test "$(jq -r '.settings.prune.services' <<<"$doc")" = true
                test "$accountOnTemplateFails" = true
                test "$servicesInHomeFails" = true
                test "$saclInDescriptorFails" = true
                echo ok > $out
              '';

          # Optional features: one winpkgs/optionalFeature per name, machine
          # scope, `false` carried as a disable rather than dropped; a home
          # configuration has none, features being the machine's.
          features =
            pkgs.runCommand "winpkgs-features"
              {
                doc = document (sys [
                  {
                    winpkgs.name = "f";
                    windows.features = {
                      Microsoft-Hyper-V-All = true;
                      Containers-DisposableClientVM = false;
                    };
                  }
                ]);
                featuresInHomeFails = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "f@f";
                      windows.features.Microsoft-Hyper-V-All = true;
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                f() { jq -r --arg id "$2" --arg p "$3" '.resources[] | select(.id == $id) | .properties[$p] | tostring' <<<"$1"; }
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/optionalFeature")] | length' <<<"$doc")" = 2
                test "$(jq -r '.resources[] | select(.id == "Feature Microsoft-Hyper-V-All") | .scope' <<<"$doc")" = machine
                test "$(f "$doc" 'Feature Microsoft-Hyper-V-All' name)" = Microsoft-Hyper-V-All
                test "$(f "$doc" 'Feature Microsoft-Hyper-V-All' enabled)" = true
                test "$(f "$doc" 'Feature Containers-DisposableClientVM' enabled)" = false
                test "$(jq -r '.settings.prune.features' <<<"$doc")" = true
                test "$featuresInHomeFails" = true
                echo ok > $out
              '';

          # Local groups: one winpkgs/groupMember per member, a built-in group
          # carried as its well-known SID and any other by name, members as
          # written, duplicates folded; ordered with services, after installs;
          # and none in a home configuration.
          local-groups =
            pkgs.runCommand "winpkgs-local-groups"
              {
                doc = document (sys [
                  {
                    winpkgs.name = "g";
                    windows.localGroups = {
                      "Hyper-V Administrators".members = [
                        "me"
                        "DOMAIN\\someone"
                        "me"
                      ];
                      docker-users.members = [ "S-1-5-21-1-2-3-1001" ];
                      "S-1-5-32-555".members = [ "me" ];
                    };
                    windows.files."C:/Program Files/d/d.exe".text = "d";
                  }
                ]);
                groupsInHomeFails = lib.boolToString (
                  fails (home [
                    {
                      winpkgs.name = "g@g";
                      windows.localGroups.docker-users.members = [ "me" ];
                    }
                  ])
                );
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                p() { jq -r --arg id "$2" --arg p "$3" '.resources[] | select(.id == $id) | .properties[$p]' <<<"$1"; }
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/groupMember")] | length' <<<"$doc")" = 4
                test "$(jq -r '.resources[] | select(.id == "Group Hyper-V Administrators: me") | .scope' <<<"$doc")" = machine
                test "$(p "$doc" 'Group Hyper-V Administrators: me' group)" = S-1-5-32-578
                test "$(p "$doc" 'Group Hyper-V Administrators: me' member)" = me
                test "$(p "$doc" 'Group Hyper-V Administrators: DOMAIN\someone' member)" = 'DOMAIN\someone'
                test "$(p "$doc" 'Group docker-users: S-1-5-21-1-2-3-1001' group)" = docker-users
                test "$(p "$doc" 'Group S-1-5-32-555: me' group)" = S-1-5-32-555
                # After the file: the group may be one an install creates.
                test "$(jq -r '.resources[0].type' <<<"$doc")" = winpkgs/file
                test "$(jq -r '.settings.prune.groupMembers' <<<"$doc")" = true
                test "$groupsInHomeFails" = true
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
          # merged with the profiles Terminal generates, with the base16 scheme
          # added and made the default unless the settings already chose one.
          # Only a single file can be merged.
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
                mergeIsOneFile = lib.boolToString (
                  fails (home [
                    base
                    {
                      windows.files."%APPDATA%/tree" = {
                        source = ./example/tree;
                        recursive = true;
                        merge = "windows-terminal";
                      };
                    }
                  ])
                );
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

                jq -e --arg id "$terminalPath" '.resources[] | select(.type == "winpkgs/file" and .id == $id) | .properties.merge == "windows-terminal"' <<<"$terminalDoc" >/dev/null
                test "$mergeIsOneFile" = true
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
              serviced = home [
                base
                {
                  programs.whkd = {
                    enable = true;
                    service.enable = true;
                    keybindings."alt + h" = "x";
                  };
                }
              ];
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
                # As a user service: a unit, and the Run entry removed.
                servicedDoc = document serviced;
                servicedUnit = builtins.toJSON serviced.config.systemd.user.services.whkd;
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

                absent() { jq -r --arg k "$run" --arg n "$2" '[.resources[] | select(.properties.key == $k and .properties.name == $n)] | .[0].properties.type' <<<"$1"; }
                test "$(absent "$servicedDoc" whkd)" = Absent
                test "$(jq -r '.Service.ExecStart[0]' <<<"$servicedUnit")" = '"C:\Program Files\whkd\bin\whkd.exe"'
                test "$(jq -r '.Service.KillMode' <<<"$servicedUnit")" = process
                test "$(jq -c '.Install.WantedBy' <<<"$servicedUnit")" = '["graphical-session.target"]'
                jq -e '.Unit["X-Restart-Triggers"][0] | contains(".shell pwsh")' <<<"$servicedUnit" >/dev/null

                for v in unknownKey twoDigits hashInCommand badProcessName appsOnly hookWithoutPause; do
                  test "''${!v}" = true || { echo "$v should have failed evaluation"; exit 1; }
                done
                echo ok > $out
              '';

          # komorebi: komorebi.json and komorebi.bar.json written whole, a base16
          # palette becoming the Custom theme of both unless they chose one, the
          # applications file placed and named, a Run entry through the
          # console-less komorebic, with --bar only when the bar is on, and
          # focus-stealing protection off unless asked for.
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
              # As user services: komorebi, and a bar per monitor or the one.
              serviced =
                bar:
                home [
                  base
                  {
                    programs.komorebi = {
                      enable = true;
                      service.enable = true;
                      inherit bar;
                    };
                  }
                ];
              servicedMulti = serviced {
                enable = true;
                monitors = {
                  "0" = { };
                  "1" = { };
                };
              };
              servicedOne = serviced { enable = true; };
              protection =
                value:
                home [
                  base
                  {
                    programs.komorebi = {
                      enable = true;
                      focusStealingProtection = value;
                    };
                  }
                ];
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
                servicedDoc = document servicedMulti;
                multiUnits = builtins.toJSON servicedMulti.config.systemd.user.services;
                oneUnits = builtins.toJSON servicedOne.config.systemd.user.services;
                protectedDoc = document (protection true);
                untouchedDoc = document (protection null);
                run = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Run'';
                desktop = ''HKCU\Control Panel\Desktop'';
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                startup() { jq -r --arg k "$run" '[.resources[] | select(.properties.key == $k and .properties.name == "komorebi")] | if length == 1 then .[0].properties.value else "MISSING" end' <<<"$1"; }
                v() {
                  jq -r --arg k "$2" --arg n "$3" \
                    '[.resources[] | select(.properties.key == $k and .properties.name == $n)]
                     | if length == 1 then "\(.[0].properties.type) \(.[0].properties.value)" else "MISSING" end' <<<"$1"
                }

                # Focus-stealing protection: off by default, as a Run entry and
                # as a service (komorebi cannot start under it), Windows' own
                # default when asked for, untouched when null.
                test "$(v "$fullDoc" "$desktop" ForegroundLockTimeout)" = 'DWord 0'
                test "$(v "$servicedDoc" "$desktop" ForegroundLockTimeout)" = 'DWord 0'
                test "$(v "$protectedDoc" "$desktop" ForegroundLockTimeout)" = 'DWord 200000'
                test "$(v "$untouchedDoc" "$desktop" ForegroundLockTimeout)" = MISSING

                # As user services: komorebi.exe itself, stopped through
                # komorebic; a bar per monitor file, part of komorebi's; the
                # Run entry removed.
                test "$(jq -r --arg k "$run" '[.resources[] | select(.properties.key == $k and .properties.name == "komorebi")] | .[0].properties.type' <<<"$servicedDoc")" = Absent
                test "$(jq -r '.komorebi.Service.ExecStart[0]' <<<"$multiUnits")" = '"C:\Program Files\komorebi\bin\komorebi.exe"'
                test "$(jq -r '.komorebi.Service.ExecStop' <<<"$multiUnits")" = '"C:\Program Files\komorebi\bin\komorebic-no-console.exe" stop'
                # Up once it answers: the bars, ordered after it, find it listening.
                test "$(jq -r '.komorebi.Service.ExecStartPost' <<<"$multiUnits")" = 'cmd.exe /d /s /c "(for /l %n in (1,1,5000) do @("C:\Program Files\komorebi\bin\komorebic.exe" state >nul 2>&1 && exit 0)) & exit 1"'
                test "$(jq -c '.komorebi.Install.WantedBy' <<<"$multiUnits")" = '["graphical-session.target"]'
                test "$(jq -r '.["komorebi-bar-1"].Service.ExecStart[0]' <<<"$multiUnits")" = '"C:\Program Files\komorebi\bin\komorebi-bar.exe" --config "/home/k/komorebi.bar.1.json"'
                test "$(jq -c '.["komorebi-bar-0"].Unit.PartOf' <<<"$multiUnits")" = '["komorebi.service"]'
                test "$(jq -c '.["komorebi-bar-0"].Install.WantedBy' <<<"$multiUnits")" = '["komorebi.service"]'
                test "$(jq -c 'keys' <<<"$oneUnits")" = '["komorebi","komorebi-bar"]'
                test "$(jq -r '.["komorebi-bar"].Service.ExecStart[0]' <<<"$oneUnits")" = '"C:\Program Files\komorebi\bin\komorebi-bar.exe" --config "/home/k/komorebi.bar.json"'

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
                servicedUnit =
                  builtins.toJSON
                    (home [
                      base
                      {
                        programs.masir = {
                          enable = true;
                          noRaise = true;
                          service.enable = true;
                        };
                      }
                    ]).config.systemd.user.services.masir;
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
                # As a user service: the flags, no console host, after komorebi.
                test "$(jq -r '.Service.ExecStart[0]' <<<"$servicedUnit")" = '"C:\Program Files\masir\bin\masir.exe" --no-raise'
                test "$(jq -c '.Unit.After' <<<"$servicedUnit")" = '["graphical-session.target","komorebi.service"]'
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

          # getExe: a package's main program as a Windows path, from the
          # table's programDir, a portable package's directory, or what
          # fromWinget was told; a package that says nothing fails by name. And
          # toPowerShell, for putting such a path in a command pwsh runs.
          executables =
            let
              crossPkgs =
                (home [
                  {
                    winpkgs.name = "x@x";
                    winpkgs.cli.enable = false;
                  }
                ])._module.args.pkgs;
              inherit (crossPkgs.winpkgs) getExe getExe' toPowerShell;
              flow = crossPkgs.winpkgs.fromWinget {
                id = "Flow-Launcher.Flow-Launcher";
                scope = "user";
                programDir = ''%LOCALAPPDATA%\FlowLauncher'';
                mainProgram = "Flow.Launcher";
              };
              refused = v: !(builtins.tryEval (builtins.deepSeq v true)).success;
              cases = [
                {
                  got = getExe crossPkgs.alacritty;
                  want = ''%ProgramFiles%\Alacritty\alacritty.exe'';
                }
                {
                  got = getExe crossPkgs.neovim;
                  want = ''%ProgramFiles%\Neovim\bin\nvim.exe'';
                }
                {
                  got = getExe crossPkgs.thide;
                  want = ''%LOCALAPPDATA%\Programs\thide\thide.exe'';
                }
                {
                  got = getExe flow;
                  want = ''%LOCALAPPDATA%\FlowLauncher\Flow.Launcher.exe'';
                }
                {
                  got = getExe' crossPkgs.thide "npm.cmd";
                  want = ''%LOCALAPPDATA%\Programs\thide\npm.cmd'';
                }
                # The annotation the installer paths read is unchanged by it.
                {
                  got = crossPkgs.alacritty.winget;
                  want = {
                    id = "Alacritty.Alacritty";
                    scope = "machine";
                  };
                }
                {
                  got = flow.winget;
                  want = {
                    id = "Flow-Launcher.Flow-Launcher";
                    scope = "user";
                  };
                }
                {
                  got = getExe crossPkgs.git;
                  want = ''%ProgramFiles%\Git\cmd\git.exe'';
                }
                # ripgrep installs at either scope, so where is not fixed.
                {
                  got = refused (getExe crossPkgs.ripgrep);
                  want = true;
                }
                {
                  got = refused (getExe (crossPkgs.winpkgs.fromWinget "Microsoft.PowerToys"));
                  want = true;
                }
                {
                  got = toPowerShell (getExe crossPkgs.alacritty);
                  want = ''$Env:ProgramFiles\Alacritty\alacritty.exe'';
                }
                {
                  got = toPowerShell ''%ProgramFiles(x86)%\x %APPDATA%\y'';
                  want = ''''${Env:ProgramFiles(x86)}\x $Env:APPDATA\y'';
                }
                {
                  got = toPowerShell "100% certain";
                  want = "100% certain";
                }
              ];
              failures = lib.filter (c: c.got != c.want) cases;
            in
            pkgs.runCommand "winpkgs-executables" { failures = builtins.toJSON failures; } ''
              test "$failures" = "[]" || { echo "$failures"; exit 1; }
              echo ok > $out
            '';

          # PowerShell: the profile assembled in initContent order (PSReadLine,
          # aliases as aliases or functions, the prompt hooks, the extra,
          # zoxide last), the per-user
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
                    initContent = "function global:prompt { 'custom> ' }";
                    windowsPowerShell = {
                      enable = true;
                      executionPolicy = "RemoteSigned";
                    };
                  };
                  programs.starship.enable = true;
                  programs.oh-my-posh.enable = true;
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
                # zoxide wraps whatever `prompt` exists when it starts, so it is
                # the last line: after starship's, oh-my-posh's and a prompt
                # of the configuration's own in initContent, and after the extra.
                has "oh-my-posh init pwsh | Invoke-Expression"
                has "function global:prompt { 'custom> ' }"
                test "$(grep -v '^$' <<<"$profile" | tail -n 1)" = "Invoke-Expression (& { (zoxide init powershell --cmd cd | Out-String) })" \
                  || { echo "zoxide's hook is not last:"; cat <<<"$profile"; exit 1; }

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
                      pkgs.ripgrep
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
                test "$(jq -r '[.resources[] | select(.type == "winpkgs/winget") | .id] | join(",")' <<<"$homeDoc")" = BurntSushi.ripgrep.MSVC
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
                      pkgs.ripgrep
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
                # A real id, since an invented one is refused for not being in
                # winget-pkgs before its scope is ever looked at; Flow
                # Launcher's installer is per-user only.
                userOnlyInSystemRefusal = failed (sys [
                  (
                    { pkgs, ... }:
                    {
                      winpkgs.name = "h";
                      environment.systemPackages = [
                        (pkgs.winpkgs.fromWinget {
                          id = "Flow-Launcher.Flow-Launcher";
                          scope = "user";
                        })
                      ];
                    }
                  )
                ]);
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
                test "$(ids "$homeDoc")" = "BurntSushi.ripgrep.MSVC"
                test "$machinePackages" = "Alacritty.Alacritty,LLVM.LLVM"
                test "$(ids "$systemDoc")" = "Alacritty.Alacritty,LLVM.LLVM"
                test "$(scope "$systemDoc" Alacritty.Alacritty)" = machine
                case "$userOnlyInSystemRefusal" in *"install per user only and belong in a home configuration"*Flow-Launcher*) ;; *) echo "refusal: $userOnlyInSystemRefusal"; exit 1 ;; esac
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
                # The distro implies the Virtual Machine Platform feature, at a
                # priority a host can override; without the distro, nothing.
                doc = document withWsl;
                overridden = document (sys [
                  ./example/configuration.nix
                  {
                    wsl.enable = true;
                    wsl.modules = [ { system.stateVersion = "26.05"; } ];
                    windows.features.VirtualMachinePlatform = false;
                  }
                ]);
                withoutWsl = document exampleSystem;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                test "$hostName" = example
                vmp() { jq -r '[.resources[] | select(.id == "Feature VirtualMachinePlatform")] | if length == 1 then .[0].properties.enabled else "MISSING" end' <<<"$1"; }
                test "$(vmp "$doc")" = true
                test "$(vmp "$overridden")" = false
                test "$(vmp "$withoutWsl")" = MISSING
                echo "$drv" > $out
              '';

          # Building the documentation is a check: it evaluates both option
          # trees and refuses to finish if an option has no description or no
          # type, which is more than "does it evaluate".
          docs = docs.${system}.docs;

          # The unattended installer, from the configurations to the media.
          #
          # The answer file is asserted for what a machine cannot tell you until
          # it is too late to fix: the features are enabled while the image is
          # still offline, the account and computer names come from the
          # configuration rather than from a second place, and oobeSystem
          # answers the region question that otherwise stops the install dead
          # with nobody there. The pairs a system refuses to build an installer
          # for are refused here, at evaluation. And `system.build.installer`
          # runs, against a stand-in for the Windows ISO -- the real one is
          # eight gigabytes and Microsoft's -- carrying the parts the script
          # actually reads: an image with a Foundation package and two editions
          # under UDF, and the two boot files.
          installer =
            let
              names = winpkgsLib.installer.splitHomeName "Caleb Stewart@gaming-windows";
              unattend = winpkgsLib.installer.mkUnattend {
                osVersion = "10.0.26100.1";
                computerName = names.host;
                userName = names.user;
                edition = "Windows 11 Pro";
                timeZone = "Eastern Standard Time";
                firstLogonCommand = ''powershell -File D:\winpkgs\setup.ps1'';
              };

              # The example home hides Widgets and declares Git (machine-wide);
              # it calls itself example@example, and a machine cannot have an
              # account named after itself.
              pairHome = home [
                ./example/home.nix
                { winpkgs.name = lib.mkForce "me@example"; }
              ];
              secondHome = home [
                ./example/home.nix
                { winpkgs.name = lib.mkForce "you@example"; }
              ];
              # Nothing fetched in a check: the two downloads are pinned
              # fetchurls and their absence changes nothing about the script.
              pairSystem =
                extra:
                sys (
                  [
                    ./example/configuration.nix
                    {
                      winpkgs.installer.wslMsi = null;
                      winpkgs.installer.wingetClient = null;
                    }
                  ]
                  ++ extra
                );
              installerOf = sysCfg: sysCfg.config.system.build.installer;
              refused =
                sysCfg: lib.boolToString (!(builtins.tryEval (builtins.seq (installerOf sysCfg) true)).success);

              accepted = pairSystem [ { winpkgs.homes = [ pairHome ]; } ];
              # The edition is checked against the image, not taken on trust.
              wrongEdition = pairSystem [
                {
                  winpkgs.homes = [ pairHome ];
                  winpkgs.installer.edition = "Windows 11 Enterprise";
                }
              ];
              twoHomes = pairSystem [
                {
                  winpkgs.homes = [
                    pairHome
                    secondHome
                  ];
                }
              ];
            in
            pkgs.runCommand "winpkgs-installer"
              {
                inherit unattend;
                nativeBuildInputs = [
                  pkgs.libxml2
                  pkgs.p7zip
                  pkgs.cdrtools
                  pkgs.wimlib
                ];
                user = names.user;
                host = names.host;
                buildIso = lib.getExe (installerOf accepted);
                buildIsoWrongEdition = lib.getExe (installerOf wrongEdition);
                payload = (installerOf accepted).payload;
                # The time zone travels from `time.timeZone` in Windows' words.
                timeZone = accepted.config.winpkgs.installer.timeZone;

                pairAccepted = refused accepted;
                # No home to install.
                withoutHomes = refused (pairSystem [ ]);
                # UCPD would refuse the Widgets write.
                pairWithUcpd = refused (pairSystem [
                  {
                    winpkgs.homes = [ pairHome ];
                    windows.userChoiceProtection.enable = lib.mkForce null;
                  }
                ]);
                # A home for some other machine.
                otherMachine = refused (pairSystem [
                  {
                    winpkgs.homes = [
                      (home [
                        ./example/home.nix
                        { winpkgs.name = lib.mkForce "me@elsewhere"; }
                      ])
                    ];
                  }
                ]);
                # Two homes: `installer` cannot choose, `installers.<user>` can.
                twoHomesUndecided = refused twoHomes;
                twoHomesByUser = lib.concatStringsSep " " (lib.attrNames twoHomes.config.system.build.installers);
              }
              ''
                printf '%s' "$unattend" > unattend.xml
                xmllint --noout unattend.xml

                # A name with a space in it is the ordinary case, not the edge
                # one: a Windows display name usually has one.
                test "$user" = "Caleb Stewart"
                test "$host" = gaming-windows

                q() { xmllint --xpath "$1" "''${2:-unattend.xml}"; }
                # Both features, enabled offline, against the image's own
                # Foundation package rather than a version written down here.
                test "$(q 'count(//*[local-name()="servicing"]/*[local-name()="package"]/*[local-name()="selection"])')" = 2
                q '//*[local-name()="selection"][@name="Microsoft-Windows-Subsystem-Linux"]/@state' | grep -q 'true'
                q '//*[local-name()="selection"][@name="VirtualMachinePlatform"]/@state' | grep -q 'true'
                q '//*[local-name()="assemblyIdentity"]/@version' | grep -q '10.0.26100.1'

                # The region screen: answered in oobeSystem, where windowsPE's
                # answer does not carry over.
                test "$(q 'count(//*[local-name()="settings"][@pass="oobeSystem"]/*[local-name()="component"][@name="Microsoft-Windows-International-Core"])')" = 1

                # Setup is told the account and the machine, once each.
                q '//*[local-name()="ComputerName"]/text()' | grep -qx 'gaming-windows'
                q '//*[local-name()="LocalAccount"]/*[local-name()="Name"]/text()' | grep -qx 'Caleb Stewart'
                q '//*[local-name()="AutoLogon"]/*[local-name()="Username"]/text()' | grep -qx 'Caleb Stewart'

                test "$pairAccepted" = false
                test "$withoutHomes" = true
                test "$pairWithUcpd" = true
                test "$otherMachine" = true
                test "$twoHomesUndecided" = true
                test "$twoHomesByUser" = "me you"
                test "$timeZone" = "Central Standard Time"

                # The payload: both closures, the script that drives them, and
                # what survives the reboot.
                test -e "$payload/setup.ps1"
                test -e "$payload/system/config.json"
                test -e "$payload/home/config.json"
                grep -q '"user":"me"' "$payload/setup.json"

                # A stand-in for the Windows ISO. Two editions, so the check that
                # the edition exists has something to choose between; the
                # Foundation package is an empty file with the right name, which
                # is all wimdir reports.
                mkdir -p src/Windows/servicing/Packages
                : > "src/Windows/servicing/Packages/Microsoft-Windows-Foundation-Package~31bf3856ad364e35~amd64~~10.0.26100.1.mum"
                wimcapture src install.wim "Windows 11 Home" > /dev/null
                wimappend src install.wim "Windows 11 Pro" > /dev/null
                mkdir -p tree/sources tree/boot tree/efi/microsoft/boot
                mv install.wim tree/sources/
                head -c 4096 /dev/zero > tree/boot/etfsboot.com
                head -c 4096 /dev/zero > tree/efi/microsoft/boot/efisys.bin
                mkisofs -quiet -iso-level 4 -udf -volid CCCOMA_X64FRE_EN-US_DV9 \
                  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -hide boot/etfsboot.com \
                  -eltorito-alt-boot -eltorito-platform efi \
                  -b efi/microsoft/boot/efisys.bin -no-emul-boot \
                  -o Win11.iso tree

                "$buildIso" --help | grep -q -- '--iso'

                # The remaster: the version read out of the image, the answer
                # file at the root, the payload beside it, the label set, both
                # boot images still declared.
                mkdir out
                "$buildIso" --iso Win11.iso --out out/winpkgs.iso
                test ! -e out/winpkgs.iso.part
                mkdir result
                7z x -y -oresult out/winpkgs.iso > /dev/null
                xmllint --noout result/autounattend.xml
                q '//*[local-name()="assemblyIdentity"]/@version' result/autounattend.xml | grep -q '"10.0.26100.1"'
                q '//*[local-name()="ComputerName"]/text()' result/autounattend.xml | grep -qx example
                q '//*[local-name()="LocalAccount"]/*[local-name()="Name"]/text()' result/autounattend.xml | grep -qx me
                q '//*[local-name()="TimeZone"]/text()' result/autounattend.xml | grep -qx 'Central Standard Time'
                q '//*[local-name()="CommandLine"]/text()' result/autounattend.xml | grep -q "FileSystemLabel -eq 'WINPKGS'"
                ! grep -q '@osVersion@' result/autounattend.xml
                cmp result/winpkgs/setup.ps1 "$payload/setup.ps1"
                test -e result/winpkgs/system/config.json
                test -e result/winpkgs/home/config.json
                test -e result/sources/install.wim
                isoinfo -d -i out/winpkgs.iso > iso.txt
                grep -q '^Volume id: WINPKGS$' iso.txt
                grep -q 'El Torito' iso.txt

                # The version handed in is the version written.
                "$buildIso" --iso Win11.iso --out out/pinned.iso --os-version 10.0.22621.1
                7z e -y -so out/pinned.iso autounattend.xml 2>/dev/null | grep -q 'version="10.0.22621.1"'

                # An edition the image does not have is refused, by name, with
                # the ones it does.
                if "$buildIsoWrongEdition" --iso Win11.iso --out out/wrong.iso 2> wrong.txt; then
                  echo "an edition the image lacks was accepted" >&2; exit 1
                fi
                grep -q "no edition named 'Windows 11 Enterprise'" wrong.txt
                grep -q 'Windows 11 Pro' wrong.txt
                test ! -e out/wrong.iso

                # Missing arguments and files fail before anything is unpacked.
                ! "$buildIso" --iso Win11.iso 2>/dev/null
                ! "$buildIso" --iso missing.iso --out out/x.iso 2>/dev/null
                ! "$buildIso" --iso Win11.iso --out out/x.iso --os-version 26100 2>/dev/null

                echo ok > $out
              '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
