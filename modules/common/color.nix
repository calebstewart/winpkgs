# Colours, for the settings that take one. A colour is written as "#rrggbb";
# Windows wants it as a dword in one of two byte orders, or as a palette of
# shades. Plain functions, imported like sugar.nix.
{ lib }:
let
  inherit (lib) types;

  digits = "0123456789abcdef";
  digit =
    c:
    let
      i = lib.lists.findFirstIndex (d: d == c) null (lib.stringToCharacters digits);
    in
    if i == null then throw "not a hex digit: ${c}" else i;

  clamp01 = x: lib.max 0.0 (lib.min 1.0 x);
  round = x: builtins.floor (x + 0.5);
  toByte = x: round (clamp01 x * 255);

  # RGB <-> HSV, each channel in [0, 1], hue in [0, 1).
  toHsv =
    {
      r,
      g,
      b,
    }:
    let
      mx = lib.max r (lib.max g b);
      mn = lib.min r (lib.min g b);
      d = mx - mn;
      h =
        if d == 0 then
          0
        else if mx == r then
          ((g - b) / d + (if g < b then 6 else 0)) / 6
        else if mx == g then
          ((b - r) / d + 2) / 6
        else
          ((r - g) / d + 4) / 6;
    in
    {
      inherit h;
      s = if mx == 0 then 0 else d / mx;
      v = mx;
    };

  fromHsv =
    {
      h,
      s,
      v,
    }:
    let
      i = builtins.floor (h * 6);
      f = h * 6 - i;
      p = v * (1 - s);
      q = v * (1 - f * s);
      t = v * (1 - (1 - f) * s);
      sector = lib.mod i 6;
    in
    if sector == 0 then
      {
        r = v;
        g = t;
        b = p;
      }
    else if sector == 1 then
      {
        r = q;
        g = v;
        b = p;
      }
    else if sector == 2 then
      {
        r = p;
        g = v;
        b = t;
      }
    else if sector == 3 then
      {
        r = p;
        g = q;
        b = v;
      }
    else if sector == 4 then
      {
        r = t;
        g = p;
        b = v;
      }
    else
      {
        r = v;
        g = p;
        b = q;
      };

  # The colour with its saturation and value scaled.
  scale =
    c: sf: vf:
    let
      hsv = toHsv {
        r = c.r / 255.0;
        g = c.g / 255.0;
        b = c.b / 255.0;
      };
      out = fromHsv {
        inherit (hsv) h;
        s = clamp01 (hsv.s * sf);
        v = clamp01 (hsv.v * vf);
      };
    in
    {
      r = toByte out.r;
      g = toByte out.g;
      b = toByte out.b;
    };
in
rec {
  # The option type: "#rrggbb", either case.
  hex = types.strMatching "#[0-9a-fA-F]{6}";

  # "#d0000c" -> { r = 208; g = 0; b = 12; }
  parse =
    s:
    let
      h = lib.toLower (lib.removePrefix "#" s);
      byte = i: 16 * digit (lib.substring i 1 h) + digit (lib.substring (i + 1) 1 h);
    in
    {
      r = byte 0;
      g = byte 2;
      b = byte 4;
    };

  # The two dword layouts Windows uses. `alpha` is 0-255.
  abgr = alpha: c: alpha * 16777216 + c.b * 65536 + c.g * 256 + c.r; # 0xAABBGGRR: DWM\AccentColor, Explorer\Accent
  argb = alpha: c: alpha * 16777216 + c.r * 65536 + c.g * 256 + c.b; # 0xAARRGGBB: DWM\ColorizationColor

  # "r g b" with decimal components: Control Panel\Colors.
  triplet = c: "${toString c.r} ${toString c.g} ${toString c.b}";

  # The shades Windows derives from an accent colour: three lighter (paler as
  # well as brighter) and three darker (a touch more saturated). The factors
  # were read off the palette Settings writes for a red; they are close, not
  # Windows' undocumented arithmetic.
  lighter = c: k: scale c (lib.elemAt [ 0.90 0.66 0.54 ] k) (lib.elemAt [ 1.02 1.08 1.11 ] k);
  darker = c: k: scale c (lib.elemAt [ 1.01 1.03 1.08 ] k) (lib.elemAt [ 0.86 0.68 0.47 ] k);

  # Explorer\Accent\AccentPalette: eight RGB0 entries -- lightest first, the
  # colour fourth, darkest seventh, and a fixed last entry Windows always
  # writes. The shell reads its tints from here, so the palette has to follow
  # the colour.
  palette =
    c:
    lib.concatMap
      (s: [
        s.r
        s.g
        s.b
        0
      ])
      [
        (lighter c 2)
        (lighter c 1)
        (lighter c 0)
        c
        (darker c 0)
        (darker c 1)
        (darker c 2)
      ]
    ++ [
      136
      23
      152
      0
    ];
}
