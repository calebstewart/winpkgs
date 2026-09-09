# Keyboard and mouse. `remap` is the reason this module is worth having: the
# scancode map is a hand-computed binary blob everywhere else it is written
# down, and here it is an attrset.
#
# Nothing here restarts Explorer, because nothing here would be fixed by it: the
# scancode map is read by the keyboard driver at boot, and the `Control Panel`
# values are read at sign-in.
#
# Spans both scopes: `remap` is `HKLM` and exists in a system configuration,
# everything else is `HKCU` and exists in a home configuration.
{
  lib,
  config,
  winpkgsKind,
  ...
}:
let
  inherit (lib) types;
  sugar = import ./sugar.nix { inherit lib; };
  cfg = config.windows.keyboard;

  keyboardLayout = ''HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout'';
  mouse = ''HKCU\Control Panel\Mouse'';
  keyboardCp = ''HKCU\Control Panel\Keyboard'';
  accessibility = ''HKCU\Control Panel\Accessibility'';
  policiesSystem = ''HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System'';

  # 0xE000: the prefix that tells the right-hand modifiers and the navigation
  # cluster apart from the keys sharing their base scancode.
  ext = c: 57344 + c;

  scancodes = {
    Escape = 1;
    Backspace = 14;
    Tab = 15;
    Enter = 28;
    LeftCtrl = 29;
    Semicolon = 39;
    Apostrophe = 40;
    Grave = 41;
    LeftShift = 42;
    Backslash = 43;
    RightShift = 54;
    LeftAlt = 56;
    Space = 57;
    CapsLock = 58;
    F1 = 59;
    F2 = 60;
    F3 = 61;
    F4 = 62;
    F5 = 63;
    F6 = 64;
    F7 = 65;
    F8 = 66;
    F9 = 67;
    F10 = 68;
    NumLock = 69;
    ScrollLock = 70;
    F11 = 87;
    F12 = 88;

    PrintScreen = ext 55;
    Home = ext 71;
    Up = ext 72;
    PageUp = ext 73;
    Left = ext 75;
    Right = ext 77;
    End = ext 79;
    Down = ext 80;
    PageDown = ext 81;
    Insert = ext 82;
    Delete = ext 83;
    LeftWin = ext 91;
    RightWin = ext 92;
    Apps = ext 93;
    RightCtrl = ext 29;
    RightAlt = ext 56;
  };

  word = n: [
    (lib.mod n 256)
    ((n - lib.mod n 256) / 256)
  ];
  dword =
    n:
    word n
    ++ [
      0
      0
    ];

  # Two zero dwords of header, a count that includes its own null terminator,
  # then one word pair per mapping -- the replacement first, the key being
  # replaced second -- and the terminator.
  scancodeMap =
    m:
    let
      code = k: if k == null then 0 else scancodes.${k};
      pairs = lib.mapAttrsToList (source: target: word (code target) ++ word scancodes.${source}) m;
    in
    dword 0 ++ dword 0 ++ dword (lib.length pairs + 1) ++ lib.concatLists pairs ++ dword 0;

  remap = cfg.remap or null;
  named =
    if remap == null then [ ] else lib.attrNames remap ++ lib.remove null (lib.attrValues remap);
  unknown = lib.unique (lib.filter (n: !(scancodes ? ${n})) named);

  settings = sugar.forKind winpkgsKind allSettings;
  allSettings = {
    remap = {
      keys = [ keyboardLayout ];
      type = types.attrsOf (types.nullOr types.str);
      example = {
        CapsLock = "LeftCtrl";
        Insert = null;
      };
      # `{}` is not the same as unset: it deletes the value, restoring the
      # identity mapping. That is what makes the option declarative rather than
      # a one-way switch.
      writes = m: {
        ${keyboardLayout}."Scancode Map" =
          if m == { } then
            null
          else
            {
              type = "Binary";
              value = scancodeMap m;
            };
      };
      description = ''
        Keys to remap, from the key pressed to the key produced. `null` as a
        target disables the key. `{}` removes the mapping entirely.

        Machine scope, and the keyboard driver reads it at boot, so a remap
        takes effect after a restart rather than at the end of an apply.
      '';
    };

    mouseAcceleration = {
      keys = [ mouse ];
      type = types.bool;
      # Three values named after the curve rather than the feature, all strings.
      writes = v: {
        ${mouse} = {
          MouseSpeed = sugar.pair "1" "0" v;
          MouseThreshold1 = sugar.pair "6" "0" v;
          MouseThreshold2 = sugar.pair "10" "0" v;
        };
      };
      description = "Accelerate the pointer -- Windows calls it Enhance pointer precision.";
    };

    repeatDelay = {
      key = keyboardCp;
      name = "KeyboardDelay";
      type = types.ints.between 0 3;
      encode = toString;
      description = "How long a held key waits before repeating: 0 is shortest, 3 is longest.";
    };

    repeatRate = {
      key = keyboardCp;
      name = "KeyboardSpeed";
      type = types.ints.between 0 31;
      encode = toString;
      description = "How fast a held key repeats: 0 is slowest, 31 is fastest.";
    };

    # These are the shortcuts, not the features. Turning the feature off is a
    # sign-in-time decision; turning the shortcut off is what stops Windows
    # asking about it every time you hold shift too long.
    stickyKeysShortcut = {
      key = "${accessibility}\\StickyKeys";
      name = "Flags";
      type = types.bool;
      encode = sugar.pair "510" "506";
      description = "Offer Sticky Keys when Shift is pressed five times.";
    };
    filterKeysShortcut = {
      key = "${accessibility}\\Keyboard Response";
      name = "Flags";
      type = types.bool;
      encode = sugar.pair "126" "122";
      description = "Offer Filter Keys when right Shift is held for eight seconds.";
    };
    toggleKeysShortcut = {
      key = "${accessibility}\\ToggleKeys";
      name = "Flags";
      type = types.bool;
      encode = sugar.pair "62" "58";
      description = "Offer Toggle Keys when Num Lock is held for five seconds.";
    };

    # Win+L is not a shortcut a hotkey daemon can take: Windows handles it
    # before any hook sees it. The only switch is the policy that removes
    # locking from the shell altogether, which is what this writes.
    lockShortcut = {
      key = policiesSystem;
      name = "DisableLockWorkstation";
      type = types.bool;
      encode = sugar.off;
      description = ''
        Lock the machine with Win+L. `false` frees the combination for a hotkey
        daemon (`programs.whkd`) by way of the policy Remove Lock Computer, so
        it also takes Lock off the Ctrl+Alt+Del screen and the Start menu; the
        lock screen itself, and locking on sleep or timeout, are untouched.
        Takes effect without signing out.
      '';
    };
  };
in
{
  options.windows.keyboard = sugar.options settings;

  config = {
    windows.registry = sugar.writes settings cfg;

    assertions = [
      {
        assertion = unknown == [ ];
        message = ''
          windows.keyboard.remap names keys winpkgs does not have scancodes for:
          ${lib.concatStringsSep ", " unknown}

          Known keys: ${lib.concatStringsSep ", " (lib.attrNames scancodes)}
        '';
      }
    ];
  };
}
