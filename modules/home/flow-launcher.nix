# Flow Launcher, the keyboard launcher: installed for this user, started at
# sign-in, and its Settings.json owned when `settings` says anything.
#
# Its installer is Squirrel's (winget: user scope, no machine install), so it
# lives in %LOCALAPPDATA%\FlowLauncher, where a stub Flow.Launcher.exe runs
# whichever versioned app-x.y.z\ directory is current. The stub is what the
# start-up entry and `showCommand` run, because it survives Flow's own updates
# where the versioned path does not. Flow is single-instance: starting it
# again while it runs shows the query window, which is how a hotkey daemon
# summons it (`programs.whkd.keybindings."alt + d" = showCommand`) without
# fighting Flow for a global hotkey registration.
#
# Settings.json is Flow's to rewrite: it saves the whole document, every
# setting included, when one changes and when it exits. A managed file is
# therefore rewritten back at the next apply -- what home-manager does with any
# program that edits its own configuration -- and Flow reads it at start, so a
# changed file wants a restart of Flow. Nothing is written when `settings` is
# empty, so a Flow left to its own devices causes no churn.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.programs.flow-launcher;
  json = pkgs.buildPackages.formats.json { };

  # "%LOCALAPPDATA%\..." as PowerShell says it, for a command whkd runs.
  vars = [
    "%LOCALAPPDATA%"
    "%APPDATA%"
    "%USERPROFILE%"
    "%PROGRAMFILES%"
  ];
  toPowerShell = lib.replaceStrings vars (
    map (v: "$Env:${lib.removeSuffix "%" (lib.removePrefix "%" v)}") vars
  );

  # A theme from a base16 palette. Flow themes are WPF resource dictionaries
  # that extend Base.xaml and override the styles that carry colour; this one
  # sets every colour the stock Dracula theme sets, with the palette's slots
  # in the roles the base16 convention gives them: base00 background, base02
  # selection and lines, base04 dim text, base05 text, base0D accent. Only
  # styles that Base.xaml has defined since Flow 2.1 are extended: a BasedOn
  # naming a style the installed Base.xaml lacks is a parse error, and Flow
  # then falls back to its default theme.
  strip = lib.removePrefix "#";
  color = slot: "#${strip cfg.base16.palette.${slot}}";
  themeXaml = ''
    <ResourceDictionary
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:system="clr-namespace:System;assembly=mscorlib">
        <ResourceDictionary.MergedDictionaries>
            <ResourceDictionary Source="pack://application:,,,/Themes/Base.xaml" />
        </ResourceDictionary.MergedDictionaries>
        <Thickness x:Key="ResultMargin">0 0 0 6</Thickness>
        <Style x:Key="ItemGlyph" BasedOn="{StaticResource BaseGlyphStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base05"}" />
        </Style>
        <Style x:Key="QueryBoxStyle" BasedOn="{StaticResource BaseQueryBoxStyle}" TargetType="{x:Type TextBox}">
            <Setter Property="SelectionBrush" Value="${color "base02"}" />
            <Setter Property="Foreground" Value="${color "base05"}" />
            <Setter Property="CaretBrush" Value="${color "base05"}" />
        </Style>
        <Style x:Key="QuerySuggestionBoxStyle" BasedOn="{StaticResource BaseQuerySuggestionBoxStyle}" TargetType="{x:Type TextBox}">
            <Setter Property="Foreground" Value="${color "base04"}" />
        </Style>
        <Style x:Key="WindowBorderStyle" BasedOn="{StaticResource BaseWindowBorderStyle}" TargetType="{x:Type Border}">
            <Setter Property="BorderBrush" Value="${color "base02"}" />
            <Setter Property="Background" Value="${color "base00"}" />
        </Style>
        <Style x:Key="WindowStyle" BasedOn="{StaticResource BaseWindowStyle}" TargetType="{x:Type Window}" />
        <Style x:Key="PendingLineStyle" BasedOn="{StaticResource BasePendingLineStyle}" TargetType="{x:Type Line}" />
        <Style x:Key="ItemTitleStyle" BasedOn="{StaticResource BaseItemTitleStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base05"}" />
        </Style>
        <Style x:Key="ItemSubTitleStyle" BasedOn="{StaticResource BaseItemSubTitleStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base04"}" />
        </Style>
        <Style x:Key="ItemNumberStyle" BasedOn="{StaticResource BaseItemNumberStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base04"}" />
        </Style>
        <Style x:Key="ItemTitleSelectedStyle" BasedOn="{StaticResource BaseItemTitleSelectedStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base0D"}" />
        </Style>
        <Style x:Key="ItemSubTitleSelectedStyle" BasedOn="{StaticResource BaseItemSubTitleSelectedStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base04"}" />
        </Style>
        <SolidColorBrush x:Key="ItemSelectedBackgroundColor">${color "base02"}</SolidColorBrush>
        <Style x:Key="ItemImageSelectedStyle" BasedOn="{StaticResource BaseItemImageSelectedStyle}" TargetType="{x:Type Image}" />
        <Style x:Key="HighlightStyle">
            <Setter Property="Inline.FontWeight" Value="SemiBold" />
            <Setter Property="Inline.Foreground" Value="${color "base0D"}" />
        </Style>
        <Style x:Key="ItemHotkeyStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Foreground" Value="${color "base04"}" />
        </Style>
        <Style x:Key="ItemHotkeySelectedStyle" BasedOn="{StaticResource BaseItemHotkeySelectedStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Foreground" Value="${color "base0D"}" />
        </Style>
        <Style x:Key="ThumbStyle" BasedOn="{StaticResource BaseThumbStyle}" TargetType="{x:Type Thumb}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border Background="${color "base02"}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="2" DockPanel.Dock="Right" />
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollBarStyle" BasedOn="{StaticResource BaseScrollBarStyle}" TargetType="{x:Type ScrollBar}" />
        <Style x:Key="SeparatorStyle" BasedOn="{StaticResource BaseSeparatorStyle}" TargetType="{x:Type Rectangle}">
            <Setter Property="Fill" Value="${color "base02"}" />
            <Setter Property="Height" Value="1" />
            <Setter Property="Margin" Value="12 0 12 6" />
        </Style>
        <Style x:Key="SearchIconStyle" BasedOn="{StaticResource BaseSearchIconStyle}" TargetType="{x:Type Path}">
            <Setter Property="Fill" Value="${color "base04"}" />
            <Setter Property="Width" Value="32" />
            <Setter Property="Height" Value="32" />
            <Setter Property="Opacity" Value="0.8" />
        </Style>
        <Style x:Key="ClockBox" BasedOn="{StaticResource BaseClockBox}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base04"}" />
        </Style>
        <Style x:Key="DateBox" BasedOn="{StaticResource BaseDateBox}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base04"}" />
        </Style>
        <Style x:Key="PreviewBorderStyle" BasedOn="{StaticResource BasePreviewBorderStyle}" TargetType="{x:Type Border}">
            <Setter Property="BorderBrush" Value="${color "base02"}" />
        </Style>
        <Style x:Key="PreviewItemTitleStyle" BasedOn="{StaticResource BasePreviewItemTitleStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base05"}" />
        </Style>
        <Style x:Key="PreviewItemSubTitleStyle" BasedOn="{StaticResource BasePreviewItemSubTitleStyle}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base04"}" />
        </Style>
        <Style x:Key="PreviewGlyph" BasedOn="{StaticResource BasePreviewGlyph}" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="${color "base05"}" />
        </Style>
    </ResourceDictionary>
  '';
  themed = cfg.base16 != null;

  # The theme is only worth writing if Flow is told to use it, so a base16
  # theme fills in `Theme` unless the settings chose another.
  settings =
    cfg.settings // lib.optionalAttrs (themed && !(cfg.settings ? Theme)) { Theme = cfg.base16.name; };
in
{
  options.programs.flow-launcher = {
    enable = mkEnableOption "Flow Launcher";

    package = mkOption {
      type = types.nullOr types.package;
      default = pkgs.winpkgs.fromWinget {
        id = "Flow-Launcher.Flow-Launcher";
        scope = "user";
      };
      defaultText = lib.literalExpression ''pkgs.winpkgs.fromWinget { id = "Flow-Launcher.Flow-Launcher"; scope = "user"; }'';
      description = "The package to install: winget's, a per-user install. `null` installs nothing.";
    };

    executable = mkOption {
      type = types.str;
      default = ''%LOCALAPPDATA%\FlowLauncher\Flow.Launcher.exe'';
      description = "Flow's stub executable, which runs the current version; the installer's location by default.";
    };

    autostart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start Flow at sign-in through `windows.startup`. Leave Flow's own
        "start on system startup" setting off: this entry replaces it, and
        points at the stub rather than the versioned path Flow would write.
      '';
    };

    settings = mkOption {
      type = json.type;
      default = { };
      example = lib.literalExpression ''
        {
          Hotkey = "Alt + Space";
          Theme = "Darker";
          ColorScheme = "Dark";
          StartFlowLauncherOnSystemStartup = false;
        }
      '';
      description = ''
        Flow's Settings.json (`%APPDATA%\FlowLauncher\Settings\Settings.json`),
        with Flow's own field names; a field left out keeps Flow's default.
        Written whole when set to anything, and Flow rewrites it with every
        field whenever it saves, so expect the next apply to put this back.
        Flow reads it at start. Empty, the default, leaves the file alone.
      '';
    };

    base16 = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            palette = mkOption {
              type = types.attrsOf types.str;
              example = lib.literalExpression "config.colorScheme.palette";
              description = "A base16 palette, `base00` .. `base0F`, with or without the leading `#`.";
            };
            name = mkOption {
              type = types.str;
              default = "base16";
              description = "The theme's name, which is its file name in Flow's theme list.";
            };
          };
        }
      );
      default = null;
      example = lib.literalExpression "{ palette = config.colorScheme.palette; name = \"Catppuccin Mocha\"; }";
      description = ''
        A Flow theme from a base16 palette, written to
        `%APPDATA%\FlowLauncher\Themes\<name>.xaml` and made `settings.Theme`
        unless that is set. It extends Flow's Base.xaml and colours what the
        stock Dracula theme colours: base00 window, base02 selection, lines
        and scrollbars, base05 text, base04 subtitles and hints, base0D the
        selected title and matched characters. Flow reads themes at start,
        so a changed palette wants a restart of Flow.
      '';
    };

    showCommand = mkOption {
      type = types.str;
      readOnly = true;
      default = ''Start-Process "${toPowerShell cfg.executable}"'';
      defaultText = lib.literalExpression ''"Start-Process \"$Env:LOCALAPPDATA\\FlowLauncher\\Flow.Launcher.exe\""'';
      description = ''
        A PowerShell command that shows the query window: Flow is
        single-instance, so starting it again brings up the running one. For
        a hotkey daemon binding, e.g. `programs.whkd.keybindings."alt + d"`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.optional (cfg.package != null) cfg.package;

    windows.files = {
      "%APPDATA%/FlowLauncher/Settings/Settings.json" = lib.mkIf (settings != { }) {
        source = json.generate "Settings.json" settings;
      };
      "%APPDATA%/FlowLauncher/Themes/${if themed then cfg.base16.name else "unused"}.xaml" =
        lib.mkIf themed
          {
            text = themeXaml;
          };
    };

    windows.startup."Flow.Launcher" = lib.mkIf cfg.autostart ''"${cfg.executable}"'';
  };
}
