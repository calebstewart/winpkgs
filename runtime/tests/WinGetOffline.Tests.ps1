# winpkgs/winget installing from installation media's carried files, without
# winget. The installers are stand-ins: scripts that record the command line
# they were given, can register themselves in a redirected Add/Remove Programs,
# and exit with a chosen code -- run the way a real installer is, through
# Invoke-WinPkgsCommandLine. Add/Remove Programs, WinGet's portable
# directories, PATH, the machine's MSIX packages and its optional features are
# all redirected; nothing here installs anything on the machine it runs on.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\WinPkgs') -Force

    $TestKey = 'HKCU\Software\winpkgs-tests\' + [guid]::NewGuid().ToString('N')
    $TestPath = 'Registry::HKEY_CURRENT_USER\' + $TestKey.Substring(5)
    $env:WINPKGS_UNINSTALL_ROOT = $TestKey
    $env:WINPKGS_PORTABLE_PATH_KEY = "$TestKey\TestPath"
    $env:WINPKGS_STATE_DIR = Join-Path $TestDrive 'state'
    $env:WINPKGS_TEST_LOG = Join-Path $TestDrive 'install.log'
    $env:WINPKGS_MSIEXEC = Join-Path $TestDrive 'msiexec.ps1'

    # One stand-in serves every installer: it is named after what it stands
    # for, and reads what to do from variables carrying that name.
    $Stub = @'
$name = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
Add-Content -LiteralPath $env:WINPKGS_TEST_LOG -Value (@($name) + $args -join ' ')
$register = [Environment]::GetEnvironmentVariable("WINPKGS_TEST_REGISTER_$name")
if ($register) {
    $key, $display, $version = $register -split '\|'
    $path = 'Registry::HKEY_CURRENT_USER\' + $env:WINPKGS_UNINSTALL_ROOT.Substring(5) + '\HKLM\' + $key
    New-Item -Path $path -Force | Out-Null
    Set-ItemProperty -LiteralPath $path -Name DisplayName -Value $display
    Set-ItemProperty -LiteralPath $path -Name DisplayVersion -Value $version
}
$code = [Environment]::GetEnvironmentVariable("WINPKGS_TEST_EXIT_$name")
if ($code) { exit ([int]$code) }
exit 0
'@
    Set-Content -LiteralPath $env:WINPKGS_MSIEXEC -Value $Stub

    $Media = Join-Path $TestDrive 'media'

    function Hash([string]$Path) {
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    # A record as offlinePlan writes one, with its file placed on the media.
    # $Source is copied in under $Name; without one, the stand-in is.
    function Carried([string]$Id, [string]$Type, [string]$Name, [hashtable]$Extra = @{}, [string]$Source, [string]$Kind = 'home') {
        $relative = "installers/$Kind/$Id/$Name"
        $file = Join-Path $Media ($relative -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        if ($Source) { Copy-Item -LiteralPath $Source -Destination $file -Force } else { Set-Content -LiteralPath $file -Value $Stub }
        $r = @{
            id = $Id; version = '1.0.0'; url = "https://example.com/$Name"; sha256 = (Hash $file); type = $Type
            nestedType = $null; nestedFiles = @(); commands = @(); archiveBinariesDependOnPath = $false
            switches = @{ silent = $null; silentWithProgress = $null; custom = $null; installLocation = $null }
            scope = $null; productCode = $null; packageFamilyName = $null; appsAndFeaturesEntries = @()
            dependencies = @{ packages = @(); windowsFeatures = @(); windowsLibraries = @(); external = @() }
            expectedReturnCodes = @(); successCodes = @(); elevationRequirement = $null
            file = $relative; requires = @(); dependency = $false
        }
        foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
        return $r
    }

    function Sidecar([object[]]$Records, [string]$Kind = 'home', [string[]]$Order) {
        $installers = @{}
        foreach ($r in $Records) { $installers[$r.id] = $r }
        if (-not $Order) { $Order = @($Records | ForEach-Object { $_.id }) }
        $doc = @{ version = 1; arch = 'x64'; system = @{ order = @(); installers = @{} }; home = @{ order = @(); installers = @{} } }
        $doc[$Kind] = @{ order = $Order; installers = $installers }
        $doc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Media 'installers.json') -Encoding utf8
        return Read-WinPkgsInstallers -Path $Media -Kind $Kind
    }

    function Context($Installers, [string]$Kind = 'home') {
        @{ Installers = $Installers; Kind = $Kind; State = @{ owned = @{ winget = @() }; arp = @{} } }
    }
    function Props([string]$Id, [string]$Scope = 'user', [hashtable]$Extra = @{}) {
        $p = @{ id = $Id; version = '1.0.0'; pinned = $false; upgrade = $false; source = 'winget'; scope = $Scope }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        return $p
    }
    function Get-Offline($P, $Ctx) { Invoke-WinPkgsResource -Type 'winpkgs/winget' -Operation Get -Properties $P -Context $Ctx }
    function Set-Offline($P, $Ctx) { Invoke-WinPkgsResource -Type 'winpkgs/winget' -Operation Set -Properties $P -Current @{ exists = $false } -Context $Ctx }
    function Log { if (Test-Path -LiteralPath $env:WINPKGS_TEST_LOG) { @(Get-Content -LiteralPath $env:WINPKGS_TEST_LOG) } else { @() } }
    function Arp([string]$Name, [string]$Root = 'HKLM') { "$TestPath\$Root\$Name" }
    function Register([string]$Name, [string]$Display, [string]$Version, [string]$Publisher, [string]$Root = 'HKLM') {
        $path = Arp $Name $Root
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -LiteralPath $path -Name DisplayName -Value $Display
        Set-ItemProperty -LiteralPath $path -Name DisplayVersion -Value $Version
        if ($Publisher) { Set-ItemProperty -LiteralPath $path -Name Publisher -Value $Publisher }
    }
    function Restarting { & (Get-Module WinPkgs) { Test-WinPkgsRestartRequired } }
}

AfterAll {
    Remove-Item -LiteralPath $TestPath -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($v in 'UNINSTALL_ROOT', 'PORTABLE_PATH_KEY', 'PORTABLE_ROOT', 'PORTABLE_NO_LINKS', 'STATE_DIR', 'TEST_LOG', 'MSIEXEC', 'APPX_STATE', 'APPX_LOG', 'FEATURE_STATE') {
        Remove-Item -LiteralPath "Env:WINPKGS_$v" -ErrorAction SilentlyContinue
    }
    Get-ChildItem Env: | Where-Object { $_.Name -like 'WINPKGS_TEST_*' } | ForEach-Object { Remove-Item -LiteralPath "Env:$($_.Name)" }
}

Describe 'winpkgs/winget offline' {
    BeforeEach {
        Remove-Item -LiteralPath $env:WINPKGS_TEST_LOG -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $TestPath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Media -Recurse -Force -ErrorAction SilentlyContinue
        $env:WINPKGS_PORTABLE_ROOT = Join-Path $TestDrive ('winget-' + [guid]::NewGuid().ToString('N'))
        $env:WINPKGS_APPX_STATE = Join-Path $TestDrive 'appx.json'
        $env:WINPKGS_APPX_LOG = Join-Path $TestDrive 'appx.log'
        Remove-Item -LiteralPath $env:WINPKGS_APPX_STATE, $env:WINPKGS_APPX_LOG -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath Env:WINPKGS_PORTABLE_NO_LINKS -ErrorAction SilentlyContinue
        Get-ChildItem Env: | Where-Object { $_.Name -like 'WINPKGS_TEST_REGISTER_*' -or $_.Name -like 'WINPKGS_TEST_EXIT_*' } |
            ForEach-Object { Remove-Item -LiteralPath "Env:$($_.Name)" }
        & (Get-Module WinPkgs) { $script:RestartRequired = $false; $script:RestartReasons.Clear() }
    }

    Context 'each type, with winget''s switches' {
        It 'runs an msi through msiexec, quiet, with Custom after, and finds it by product code' {
            $r = Carried 'Example.Msi' 'msi' 'example.msi' @{
                productCode = '{11111111-2222-3333-4444-555555555555}'
                switches    = @{ silent = $null; silentWithProgress = $null; custom = 'ADD_PATH=1'; installLocation = $null }
            }
            $env:WINPKGS_TEST_REGISTER_msiexec = '{11111111-2222-3333-4444-555555555555}|Example MSI|1.0.0.0'
            $ctx = Context (Sidecar @($r))
            Set-Offline (Props 'Example.Msi') $ctx
            @(Log)[0] | Should -BeLike 'msiexec /i *installers\home\Example.Msi\example.msi /quiet /norestart ADD_PATH=1'
            $found = Get-Offline (Props 'Example.Msi') $ctx
            $found.exists | Should -BeTrue
            $found.version | Should -Be '1.0.0.0'
            $ctx.State.owned.winget | Should -Be @('Example.Msi')
        }

        It 'runs a wix installer through msiexec too' {
            $r = Carried 'Example.Wix' 'wix' 'example.msi'
            $ctx = Context (Sidecar @($r))
            Set-Offline (Props 'Example.Wix' 'machine') $ctx
            @(Log)[0] | Should -BeLike 'msiexec /i *example.msi /quiet /norestart'
        }

        It 'runs <type> with <expected> when the manifest names no silent switch' -TestCases @(
            @{ type = 'inno'; expected = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
            @{ type = 'nullsoft'; expected = '/S' }
            @{ type = 'burn'; expected = '/quiet /norestart' }
        ) {
            param($type, $expected)
            $r = Carried "Example.$type" $type "$type.ps1"
            $ctx = Context (Sidecar @($r))
            Set-Offline (Props "Example.$type") $ctx
            @(Log)[0] | Should -Be "$type $expected"
        }

        It 'puts the manifest''s Silent in place of the default, and Custom after it' {
            $r = Carried 'Example.Inno' 'inno' 'inno.ps1' @{
                switches = @{ silent = '/VERYSILENT'; silentWithProgress = $null; custom = '/CURRENTUSER'; installLocation = $null }
            }
            Set-Offline (Props 'Example.Inno') (Context (Sidecar @($r)))
            @(Log)[0] | Should -Be 'inno /VERYSILENT /CURRENTUSER'
        }

        It 'runs an exe with its manifest''s switch, SilentWithProgress when that is all there is' {
            $r = Carried 'Example.Exe' 'exe' 'setup.ps1' @{
                switches = @{ silent = $null; silentWithProgress = '--quiet-ish'; custom = $null; installLocation = $null }
            }
            Set-Offline (Props 'Example.Exe') (Context (Sidecar @($r)))
            @(Log)[0] | Should -Be 'setup --quiet-ish'
        }

        It 'will not run an exe with no silent switch, since nobody is there' {
            $r = Carried 'Example.Exe' 'exe' 'setup.ps1'
            { Set-Offline (Props 'Example.Exe') (Context (Sidecar @($r))) } | Should -Throw -ExpectedMessage '*no silent switch*'
            Log | Should -BeNullOrEmpty
        }

        It 'adds an MSIX for the user, and one for the machine provisioned' {
            $r = Carried 'Example.Msix' 'msix' 'example.msix' @{ packageFamilyName = 'Example.Msix_8wekyb3d8bbwe' }
            $ctx = Context (Sidecar @($r))
            (Get-Offline (Props 'Example.Msix') $ctx).exists | Should -BeFalse
            Set-Offline (Props 'Example.Msix') $ctx
            Get-Content -LiteralPath $env:WINPKGS_APPX_LOG | Should -BeLike 'add user *example.msix'
            (Get-Offline (Props 'Example.Msix') $ctx).version | Should -Be '1.0.0'

            Remove-Item -LiteralPath $env:WINPKGS_APPX_STATE, $env:WINPKGS_APPX_LOG
            Set-Offline (Props 'Example.Msix' 'machine') $ctx
            Get-Content -LiteralPath $env:WINPKGS_APPX_LOG | Should -BeLike 'add machine *example.msix'
        }

        It 'unpacks a zip and runs the installer inside it as its nested type' {
            $dir = Join-Path $TestDrive 'zip-nested\setup'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'inner.ps1') -Value $Stub
            $zip = Join-Path $TestDrive 'nested.zip'
            Compress-Archive -Path (Join-Path $TestDrive 'zip-nested\setup') -DestinationPath $zip -Force
            $r = Carried 'Example.Nested' 'zip' 'nested.zip' @{
                nestedType = 'exe'
                nestedFiles = @(@{ relativeFilePath = 'setup/inner.ps1'; portableCommandAlias = $null })
                switches = @{ silent = '/quiet'; silentWithProgress = $null; custom = $null; installLocation = $null }
            } -Source $zip
            Set-Offline (Props 'Example.Nested') (Context (Sidecar @($r)))
            @(Log)[0] | Should -Be 'inner /quiet'
        }
    }

    Context 'portables, laid out and registered as winget does' {
        BeforeAll {
            $content = Join-Path $TestDrive 'tool-src\tool-1.0'
            New-Item -ItemType Directory -Force -Path $content | Out-Null
            Set-Content -LiteralPath (Join-Path $content 'tool.exe') -Value 'not really a program'
            Set-Content -LiteralPath (Join-Path $TestDrive 'tool-src\README.md') -Value 'read me'
            $ToolZip = Join-Path $TestDrive 'tool.zip'
            Compress-Archive -Path (Join-Path $TestDrive 'tool-src\*') -DestinationPath $ToolZip -Force
            $Key = 'Example.Tool_Microsoft.Winget.Source_8wekyb3d8bbwe'
            function ToolRecord([hashtable]$Extra = @{}) {
                $e = @{
                    nestedType = 'portable'
                    nestedFiles = @(@{ relativeFilePath = 'tool-1.0/tool.exe'; portableCommandAlias = 'tl' })
                }
                foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
                Carried 'Example.Tool' 'zip' 'tool.zip' $e -Source $ToolZip
            }
            function Index([string]$Db) {
                & (Get-Module WinPkgs) { param($d) Initialize-WinPkgsSqlite; [WinPkgs.Native.Sqlite]::Query($d, 'select filepath, filetype, sha256, symlinktarget from portable order by filepath') } $Db
            }
            function Meta([string]$Db) {
                & (Get-Module WinPkgs) { param($d) Initialize-WinPkgsSqlite; [WinPkgs.Native.Sqlite]::Query($d, 'select name, value from metadata order by name') } $Db
            }
            function OnPath { @((Get-ItemProperty -LiteralPath "$TestPath\TestPath" -ErrorAction SilentlyContinue).Path -split ';' | Where-Object { $_ }) }

            # Whether this process may make a link at all: elevated, or with
            # Developer Mode on. Where it may not, the fallback is what runs,
            # and the tests that look for a link have nothing to look at.
            $probeTarget = Join-Path $TestDrive 'link-probe.txt'
            Set-Content -LiteralPath $probeTarget -Value 'probe'
            $CanLink = & (Get-Module WinPkgs) {
                param($t, $l) Initialize-WinPkgsKernel32; [WinPkgs.Native.Kernel32]::CreateSymbolicLinkW($l, $t, 0x2)
            } $probeTarget (Join-Path $TestDrive 'link-probe.lnk.txt')
            function NeedsLinks { if (-not $CanLink) { Set-ItResult -Skipped -Because 'this process cannot make links: not elevated, and Developer Mode is off' } }
        }

        It 'unpacks a zip into WinGet\Packages, links its command, and registers it where winget will find it' {
            NeedsLinks
            $ctx = Context (Sidecar @(ToolRecord))
            Set-Offline (Props 'Example.Tool') $ctx
            $root = Join-Path $env:WINPKGS_PORTABLE_ROOT 'user'
            $dir = Join-Path $root "Packages\$Key"
            Test-Path -LiteralPath (Join-Path $dir 'tool-1.0\tool.exe') | Should -BeTrue
            $link = Get-Item -LiteralPath (Join-Path $root 'Links\tl.exe') -Force
            $link.LinkType | Should -Be 'SymbolicLink'
            @($link.Target)[0] | Should -Be (Join-Path $dir 'tool-1.0\tool.exe')
            OnPath | Should -Contain (Join-Path $root 'Links')

            $arp = Get-ItemProperty -LiteralPath (Arp $Key 'HKCU')
            $arp.WinGetPackageIdentifier | Should -Be 'Example.Tool'
            $arp.WinGetSourceIdentifier | Should -Be 'Microsoft.Winget.Source_8wekyb3d8bbwe'
            $arp.WinGetInstallerType | Should -Be 'portable'
            $arp.UninstallString | Should -Be "winget uninstall --product-code $Key"
            $arp.DisplayVersion | Should -Be '1.0.0'
            $arp.InstallLocation | Should -Be $dir
            (Get-Item -LiteralPath (Arp $Key 'HKCU')).GetValueKind('InstallDirectoryCreated') | Should -Be 'DWord'

            # The index winget reads to uninstall it: the top-level entries
            # and the link, by winget's file types.
            $rows = @(Index (Join-Path $dir "$Key.db"))
            $rows.Count | Should -Be 3
            ($rows | Where-Object { $_[0] -eq (Join-Path $dir 'tool-1.0') })[1] | Should -Be '2'
            $readme = $rows | Where-Object { $_[0] -eq (Join-Path $dir 'README.md') }
            $readme[1] | Should -Be '1'
            $readme[2] | Should -Be (Hash (Join-Path $dir 'README.md'))
            $l = $rows | Where-Object { $_[1] -eq '3' }
            $l[0] | Should -Be (Join-Path $root 'Links\tl.exe')
            $l[3] | Should -Be "$dir\tool-1.0/tool.exe"
            (@(Meta (Join-Path $dir "$Key.db")) | ForEach-Object { "$($_[0])=$($_[1])" }) -match '^(majorVersion|minorVersion)=' | Should -Be @('majorVersion=1', 'minorVersion=0')

            $found = Get-Offline (Props 'Example.Tool') $ctx
            $found.exists | Should -BeTrue
            $found.version | Should -Be '1.0.0'
        }

        It 'puts the program''s directory on PATH instead where a link cannot be made' {
            $env:WINPKGS_PORTABLE_NO_LINKS = '1'
            Set-Offline (Props 'Example.Tool') (Context (Sidecar @(ToolRecord)))
            $root = Join-Path $env:WINPKGS_PORTABLE_ROOT 'user'
            $dir = Join-Path $root "Packages\$Key"
            Test-Path -LiteralPath (Join-Path $root 'Links\tl.exe') | Should -BeFalse
            OnPath | Should -Contain (Join-Path $dir 'tool-1.0')
            OnPath | Should -Not -Contain (Join-Path $root 'Links')
            (Get-ItemProperty -LiteralPath (Arp $Key 'HKCU')).InstallDirectoryAddedToPath | Should -Be 1
            @(Index (Join-Path $dir "$Key.db") | Where-Object { $_[1] -eq '3' }).Count | Should -Be 0
        }

        It 'links and puts the directory on PATH both, when the manifest says the programs depend on it' {
            NeedsLinks
            Set-Offline (Props 'Example.Tool') (Context (Sidecar @(ToolRecord @{ archiveBinariesDependOnPath = $true })))
            $root = Join-Path $env:WINPKGS_PORTABLE_ROOT 'user'
            Test-Path -LiteralPath (Join-Path $root 'Links\tl.exe') | Should -BeTrue
            OnPath | Should -Contain (Join-Path $root "Packages\$Key\tool-1.0")
        }

        It 'places a bare portable under its command''s name, for the machine' {
            NeedsLinks
            $exe = Join-Path $TestDrive 'jq-windows-amd64.exe'
            Set-Content -LiteralPath $exe -Value 'not really jq'
            $r = Carried 'Example.Jq' 'portable' 'jq-windows-amd64.exe' @{ commands = @('jq') } -Source $exe
            Set-Offline (Props 'Example.Jq' 'machine') (Context (Sidecar @($r)) 'system')
            $root = Join-Path $env:WINPKGS_PORTABLE_ROOT 'machine'
            $dir = Join-Path $root 'Packages\Example.Jq_Microsoft.Winget.Source_8wekyb3d8bbwe'
            Test-Path -LiteralPath (Join-Path $dir 'jq.exe') | Should -BeTrue
            (Get-Item -LiteralPath (Join-Path $root 'Links\jq.exe') -Force).LinkType | Should -Be 'SymbolicLink'
            (Get-ItemProperty -LiteralPath (Arp 'Example.Jq_Microsoft.Winget.Source_8wekyb3d8bbwe' 'HKLM')).InstallLocation | Should -Be $dir
        }
    }

    Context 'exit codes, read by the manifest' {
        It 'takes <code> as <what>' -TestCases @(
            @{ code = 3010; what = 'done, restart'; restart = $true; extra = @{} }
            @{ code = 1641; what = 'done, restart'; restart = $true; extra = @{} }
            @{ code = 42; what = 'a success code'; restart = $false; extra = @{ successCodes = @(42) } }
            @{ code = 7; what = 'already installed'; restart = $false; extra = @{ expectedReturnCodes = @(@{ code = 7; response = 'alreadyInstalled'; responseUrl = $null }) } }
            @{ code = 8; what = 'a restart the manifest asks for'; restart = $true; extra = @{ expectedReturnCodes = @(@{ code = 8; response = 'rebootRequiredToFinish'; responseUrl = $null }) } }
        ) {
            param($code, $what, $restart, $extra)
            $r = Carried 'Example.Codes' 'nullsoft' 'codes.ps1' $extra
            Set-Item -LiteralPath Env:WINPKGS_TEST_EXIT_codes -Value "$code"
            $ctx = Context (Sidecar @($r))
            { Set-Offline (Props 'Example.Codes') $ctx } | Should -Not -Throw
            Restarting | Should -Be $restart
            $ctx.State.owned.winget | Should -Be @('Example.Codes')
        }

        It 'fails with the manifest''s word for a code it knows' {
            $r = Carried 'Example.Codes' 'nullsoft' 'codes.ps1' @{
                expectedReturnCodes = @(@{ code = -2147219701; response = 'packageInUse'; responseUrl = 'https://example.com/in-use' })
            }
            Set-Item -LiteralPath Env:WINPKGS_TEST_EXIT_codes -Value '-2147219701'
            $ctx = Context (Sidecar @($r))
            { Set-Offline (Props 'Example.Codes') $ctx } | Should -Throw -ExpectedMessage '*exited -2147219701, which its manifest calls packageInUse (see https://example.com/in-use)*'
            $ctx.State.owned.winget | Should -BeNullOrEmpty
        }

        It 'fails on a code nothing accounts for' {
            $r = Carried 'Example.Codes' 'nullsoft' 'codes.ps1'
            Set-Item -LiteralPath Env:WINPKGS_TEST_EXIT_codes -Value '5'
            { Set-Offline (Props 'Example.Codes') (Context (Sidecar @($r))) } | Should -Throw -ExpectedMessage '*the installer exited 5'
        }
    }

    Context 'recognising what is installed' {
        It 'finds an install by its product code, in any of the roots' {
            $r = Carried 'Example.Code' 'inno' 'code.ps1' @{ productCode = '{ABCDEF01-2345-6789-ABCD-EF0123456789}_is1' }
            Register '{ABCDEF01-2345-6789-ABCD-EF0123456789}_is1' 'Example' '2.1.0' -Root 'HKLM32'
            $found = Get-Offline (Props 'Example.Code') (Context (Sidecar @($r)))
            $found.exists | Should -BeTrue
            $found.version | Should -Be '2.1.0'
        }

        It 'finds an install by display name and publisher' {
            $r = Carried 'Example.Named' 'exe' 'named.ps1' @{
                appsAndFeaturesEntries = @(@{ displayName = 'Example App'; publisher = 'Example Inc.'; displayVersion = $null; productCode = $null; upgradeCode = $null; installerType = $null })
            }
            Register 'Somebody.Else' 'Example App' '9.9' 'Someone Else' -Root 'HKCU'
            (Get-Offline (Props 'Example.Named') (Context (Sidecar @($r)))).exists | Should -BeFalse
            Register 'ExampleApp' 'Example App' '3.0' 'Example Inc.' -Root 'HKCU'
            (Get-Offline (Props 'Example.Named') (Context (Sidecar @($r)))).version | Should -Be '3.0'
        }

        It 'finds an MSI by its upgrade code, through the MSI registry''s packed GUIDs' {
            $product = '{C9C5BF1E-DA1F-4F14-B31B-8B4AC4EB3E0A}'
            $upgrade = '{F96F59BD-3E48-5E4E-B1A4-6CAFADEFEAE8}'
            $pack = { param($g) & (Get-Module WinPkgs) { param($x) ConvertTo-WinPkgsPackedGuid -Guid $x } $g }
            $packedProduct = & $pack $product
            # MSI's own example: {12345678-9ABC-DEF0-1234-56789ABCDEF0} packs to 87654321CBA90FED21436587A9CBED0F.
            & $pack '{12345678-9ABC-DEF0-1234-56789ABCDEF0}' | Should -Be '87654321CBA90FED21436587A9CBED0F'
            & (Get-Module WinPkgs) { param($x) ConvertFrom-WinPkgsPackedGuid -Packed $x } $packedProduct | Should -Be $product

            $table = "$TestPath\UpgradeCodes\HKLM\$(& $pack $upgrade)"
            New-Item -Path $table -Force | Out-Null
            Set-ItemProperty -LiteralPath $table -Name $packedProduct -Value ''
            Register $product 'Python 3.13.2 (64-bit)' '3.13.2150.0'
            $r = Carried 'Example.Upgrade' 'burn' 'python.ps1' @{
                appsAndFeaturesEntries = @(@{ displayName = $null; publisher = $null; displayVersion = '3.13.2150.0'; productCode = $null; upgradeCode = $upgrade; installerType = $null })
            }
            (Get-Offline (Props 'Example.Upgrade') (Context (Sidecar @($r)))).version | Should -Be '3.13.2150.0'
        }

        It 'finds an install its manifest gives nothing to find by, by what it added to Add/Remove Programs' {
            $r = Carried 'Example.Anon' 'exe' 'anon.ps1' @{
                switches = @{ silent = '-s'; silentWithProgress = $null; custom = $null; installLocation = $null }
            }
            $env:WINPKGS_TEST_REGISTER_anon = 'AnonApp|Anonymous|4.2'
            $ctx = Context (Sidecar @($r))
            Set-Offline (Props 'Example.Anon') $ctx
            $ctx.State.arp['Example.Anon'] | Should -Be @("$TestKey\HKLM\AnonApp")
            (Get-Offline (Props 'Example.Anon') $ctx).version | Should -Be '4.2'
        }
    }

    Context 'what comes first, and what is refused' {
        It 'installs what a package requires first, in the sidecar''s order, and only what is missing' {
            $c = Carried 'Example.C' 'nullsoft' 'c.ps1' @{ productCode = 'Example.C'; dependency = $true }
            $b = Carried 'Example.B' 'nullsoft' 'b.ps1' @{ productCode = 'Example.B'; dependency = $true; requires = @('Example.C') }
            $d = Carried 'Example.D' 'nullsoft' 'd.ps1' @{ productCode = 'Example.D'; dependency = $true }
            $a = Carried 'Example.A' 'nullsoft' 'a.ps1' @{
                requires = @('Example.D', 'Example.B')
                dependencies = @{ packages = @(@{ id = 'Example.B'; minimumVersion = $null }, @{ id = 'Example.D'; minimumVersion = '2.0' }); windowsFeatures = @(); windowsLibraries = @(); external = @() }
            }
            # D is there already, but older than A needs; B is not there at all.
            Register 'Example.D' 'D' '1.5'
            $ctx = Context (Sidecar @($a, $b, $c, $d) -Order @('Example.C', 'Example.B', 'Example.D', 'Example.A'))
            Set-Offline (Props 'Example.A') $ctx
            Log | Should -Be @('c /S', 'b /S', 'd /S', 'a /S')
            $ctx.State.owned.winget | Should -Be @('Example.A')
        }

        It 'installs nothing for a requirement already met' {
            $b = Carried 'Example.B' 'nullsoft' 'b.ps1' @{ productCode = 'Example.B'; dependency = $true }
            $a = Carried 'Example.A' 'nullsoft' 'a.ps1' @{ requires = @('Example.B') }
            Register 'Example.B' 'B' '1.0'
            Set-Offline (Props 'Example.A') (Context (Sidecar @($a, $b)))
            Log | Should -Be @('a /S')
        }

        It 'leaves a package alone that is already there, whatever the plan thought' {
            $r = Carried 'Example.There' 'nullsoft' 'there.ps1' @{ productCode = 'Example.There' }
            Register 'Example.There' 'There' '1.0.0'
            $ctx = Context (Sidecar @($r))
            Set-Offline (Props 'Example.There') $ctx
            Log | Should -BeNullOrEmpty
            $ctx.State.owned.winget | Should -Be @('Example.There')
        }

        It 'will not run a file that is not the one the media was built with' {
            $r = Carried 'Example.Tampered' 'nullsoft' 'tampered.ps1'
            $r.sha256 = '0' * 64
            { Set-Offline (Props 'Example.Tampered') (Context (Sidecar @($r))) } | Should -Throw -ExpectedMessage '*is not the file the media was built with*'
            Log | Should -BeNullOrEmpty
        }

        It 'refuses a package the media does not carry, naming it' {
            $ctx = Context (Sidecar @((Carried 'Example.Other' 'nullsoft' 'other.ps1')))
            { Get-Offline (Props 'Example.Missing') $ctx } | Should -Throw -ExpectedMessage '*Example.Missing is not among the installers the media carries*'
        }

        It 'leaves going down to a pinned version to winget' {
            $r = Carried 'Example.Pinned' 'nullsoft' 'pinned.ps1' @{ productCode = 'Example.Pinned' }
            Register 'Example.Pinned' 'Pinned' '2.0.0'
            { Set-Offline (Props 'Example.Pinned' 'user' @{ pinned = $true }) (Context (Sidecar @($r))) } | Should -Throw -ExpectedMessage '*uninstalling, which is winget''s*'
            Log | Should -BeNullOrEmpty
        }

        It 'enables the Windows features a package needs, and says which libraries are missing' {
            $env:WINPKGS_FEATURE_STATE = Join-Path $TestDrive 'features.txt'
            Set-Content -LiteralPath $env:WINPKGS_FEATURE_STATE -Value 'NetFx3=disabled'
            try {
                $r = Carried 'Example.Needs' 'nullsoft' 'needs.ps1' @{
                    dependencies = @{ packages = @(); windowsFeatures = @('NetFx3'); windowsLibraries = @('Microsoft.VCLibs.140.00'); external = @() }
                }
                Set-Offline (Props 'Example.Needs') (Context (Sidecar @($r))) 3>&1 | Out-String | Should -Match 'Microsoft.VCLibs.140.00'
                Get-Content -LiteralPath $env:WINPKGS_FEATURE_STATE | Should -Contain 'NetFx3=enabled'
            } finally {
                Remove-Item -LiteralPath Env:WINPKGS_FEATURE_STATE
            }
        }
    }

    Context 'plan and apply, handed the media' {
        It 'plans from the carried files, and never asks winget' {
            $r = Carried 'Example.Planned' 'nullsoft' 'planned.ps1' @{ productCode = 'Example.Planned' }
            $installers = Sidecar @($r)
            InModuleScope WinPkgs { Mock Import-WinPkgsWinGetClient { throw 'winget was asked' } }
            $doc = @{
                version = 2; kind = 'home'; root = $TestDrive; path = (Join-Path $TestDrive 'config.json')
                resources = @(@{ type = 'winpkgs/winget'; id = 'Example.Planned'; scope = 'user'; properties = (Props 'Example.Planned') })
            }
            $plan = @(Get-WinPkgsPlan -Document $doc -Installers $installers | Where-Object { $_.Type -eq 'winpkgs/winget' })
            $plan[0].Action | Should -Be 'create'
            $plan[0].Detail | Should -Be 'absent -> 1.0.0'
            Register 'Example.Planned' 'Planned' '1.0.0'
            @(Get-WinPkgsPlan -Document $doc -Installers $installers | Where-Object { $_.Type -eq 'winpkgs/winget' })[0].Action | Should -Be 'noop'
        }

        It 'reads a sidecar of another version as a refusal to guess' {
            New-Item -ItemType Directory -Force -Path $Media | Out-Null
            Set-Content -LiteralPath (Join-Path $Media 'installers.json') -Value '{"version":2}'
            { Read-WinPkgsInstallers -Path $Media -Kind home } | Should -Throw -ExpectedMessage '*reads version 1*'
        }

        It 'carries -Installers into the elevated apply' {
            $r = Carried 'Example.Sys' 'nullsoft' 'sys.ps1' @{ productCode = 'Example.Sys' } -Kind system
            Sidecar @($r) -Kind system | Out-Null
            Set-Content -LiteralPath (Join-Path $TestDrive 'system.json') -Value (@{
                    version = 2; kind = 'system'; settings = @{}
                    resources = @(@{ type = 'winpkgs/winget'; id = 'Example.Sys'; scope = 'machine'; properties = (Props 'Example.Sys' 'machine') })
                } | ConvertTo-Json -Depth 10)
            InModuleScope WinPkgs -Parameters @{ Media = $Media; Config = (Join-Path $TestDrive 'system.json') } {
                Mock Test-WinPkgsElevated { $false }
                Mock Invoke-WinPkgsElevated { }
                Invoke-WinPkgsApply -Document (Read-WinPkgsDocument -Path $Config) -Installers $Media
                Should -Invoke Invoke-WinPkgsElevated -Times 1 -ParameterFilter {
                    ($RuntimeArgs -join ' ') -like "apply -Config * -NoRestartExplorer -Installers $Media"
                }
            }
        }
    }
}
