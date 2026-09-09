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
                test "$(echo "$doc" | jq -c '.settings')" = '{"generations":{"deleteOlderThan":null,"keep":10},"prune":{"files":true,"winget":true},"substitutions":[{"from":"/home/example","to":"%USERPROFILE%"}]}'
                test "$(echo "$docOldName" | jq '.settings.prune.winget')" = false
                test "$(echo "$doc" | jq -r '.kind')" = home
                test "$(echo "$doc" | jq -r '.version')" = 2
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
                      pkgs.neovim # nixpkgs does not build it for Windows; only the id matters
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
                unmappedFails = lib.boolToString (failsWith (pkgs: [ pkgs.hello ]));
                unavailableFails = lib.boolToString (failsWith (pkgs: [ pkgs.tmux ]));
                missing = lib.concatStringsSep " " missing;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                ids() { jq -r '[.resources[] | select(.type == "winpkgs/winget") | .id] | sort | join(",")' <<<"$1"; }
                test "$(ids "$doc")" = "BurntSushi.ripgrep.MSVC,Git.Git,Microsoft.PowerToys,Neovim.Neovim"
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
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                v() {
                  jq -r --arg k "$2" --arg n "$3" \
                    '[.resources[] | select(.properties.key == $k and .properties.name == $n)]
                     | if length == 1 then (.[0].properties.value | tostring) else "MISSING" end' <<<"$1"
                }
                wp() { jq -r --arg f "$2" '.resources[] | select(.type == "winpkgs/wallpaper") | .properties[$f]' <<<"$1"; }

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
                  winpkgs.name = "r";
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
