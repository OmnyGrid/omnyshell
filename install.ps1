# OmnyShell installer for Windows (Windows PowerShell 5.1+ or PowerShell 7).
#
#   irm https://raw.githubusercontent.com/OmnyGrid/omnyshell/master/install.ps1 | iex
#   .\install.ps1 --no-tools
#
# Installs the Dart SDK when it is missing or too old (upgrading an existing one
# the way it was installed), runs `dart pub global activate omnyshell`, installs
# the tools OmnyShell uses (Git for Windows, OpenSSL) and puts everything on the
# user PATH. It never asks questions; Windows may show a UAC prompt when a
# package needs administrator rights. Run with --help for the options (the same
# ones install.sh takes), and see install.md for details. install.bat launches
# this script from cmd.exe.

# Everything runs inside this script block (closed at the end of the file), so
# `irm … | iex` leaves no preferences, strict mode or functions behind in the
# user's session.
& {

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is far slower with a progress bar
Set-StrictMode -Version 2

$MinDartVersion = [version]'3.10.9'
$DartArchive = 'https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk'
$RepoRaw = 'https://raw.githubusercontent.com/OmnyGrid/omnyshell/master'
# Written inside a Dart SDK this installer unpacked, so --uninstall and upgrades
# only ever delete a directory the installer created.
$ZipMarker = '.omnyshell-installer'

function Test-Truthy([string]$Value) {
  return @('1', 'true', 'yes', 'on') -contains "$Value".ToLowerInvariant()
}

$Opt = @{
  Version           = "$env:OMNYSHELL_VERSION"
  Source            = "$env:OMNYSHELL_SOURCE"
  Git               = "$env:OMNYSHELL_GIT"
  GitRef            = "$env:OMNYSHELL_GIT_REF"
  NoTools           = Test-Truthy $env:OMNYSHELL_NO_TOOLS
  NoModifyPath      = Test-Truthy $env:OMNYSHELL_NO_MODIFY_PATH
  NoSudo            = Test-Truthy $env:OMNYSHELL_NO_SUDO
  DartMethod        = $(if ($env:OMNYSHELL_DART_METHOD) { $env:OMNYSHELL_DART_METHOD } else { 'auto' })
  DartDir           = "$env:OMNYSHELL_DART_DIR"
  NoDartUpgrade     = Test-Truthy $env:OMNYSHELL_NO_DART_UPGRADE
  ReinstallServices = Test-Truthy $env:OMNYSHELL_REINSTALL_SERVICES
  DryRun            = Test-Truthy $env:OMNYSHELL_DRY_RUN
  Quiet             = Test-Truthy $env:OMNYSHELL_QUIET
  Verbose           = Test-Truthy $env:OMNYSHELL_VERBOSE
  Uninstall         = Test-Truthy $env:OMNYSHELL_UNINSTALL
  Help              = $false
}

$Usage = @'
Usage: install.ps1 [options]      (or install.bat [options] from cmd.exe)

Installs OmnyShell (the Dart SDK if needed, the omnyshell CLI, its tools, PATH).

Options (each also reads the OMNYSHELL_* variable shown):
  --version <v>           Install this omnyshell version (OMNYSHELL_VERSION)
  --source <path>         Install from a local checkout (OMNYSHELL_SOURCE)
  --git <url>             Install from a git repository (OMNYSHELL_GIT)
  --git-ref <ref>         Branch, tag or commit for --git (OMNYSHELL_GIT_REF)
  --no-tools              Don't install Git for Windows / OpenSSL (OMNYSHELL_NO_TOOLS=1)
  --no-modify-path        Don't change the user PATH (OMNYSHELL_NO_MODIFY_PATH=1)
  --no-sudo               Never ask for administrator rights (OMNYSHELL_NO_SUDO=1)
  --dart-method <m>       auto | system | zip (OMNYSHELL_DART_METHOD)
  --dart-dir <dir>        Where a downloaded Dart SDK goes (OMNYSHELL_DART_DIR)
  --no-dart-upgrade       Never upgrade an existing Dart (OMNYSHELL_NO_DART_UPGRADE=1)
  --reinstall-services    Reinstall installed Hub/Node services after upgrading
                          (OMNYSHELL_REINSTALL_SERVICES=1)
  --dry-run               Print what would be done, change nothing (OMNYSHELL_DRY_RUN=1)
  --uninstall             Remove omnyshell, its PATH entries and a downloaded Dart SDK
                          (OMNYSHELL_UNINSTALL=1)
  --quiet                 Only print errors and the summary (OMNYSHELL_QUIET=1)
  --verbose               Also print every command run (OMNYSHELL_VERBOSE=1)
  -h, --help              Show this help
'@

function Read-Arguments([string[]]$Argv) {
  $i = 0
  while ($i -lt $Argv.Count) {
    $arg = $Argv[$i]
    $name = $arg
    $value = $null
    if ($arg -match '^(--[a-z-]+)=(.*)$') { $name = $Matches[1]; $value = $Matches[2] }
    $valued = @{
      '--version' = 'Version'; '--source' = 'Source'; '--git' = 'Git'; '--git-ref' = 'GitRef'
      '--dart-method' = 'DartMethod'; '--dart-dir' = 'DartDir'
    }
    $switches = @{
      '--no-tools' = 'NoTools'; '--no-modify-path' = 'NoModifyPath'; '--no-sudo' = 'NoSudo'
      '--no-dart-upgrade' = 'NoDartUpgrade'; '--reinstall-services' = 'ReinstallServices'
      '--dry-run' = 'DryRun'; '--uninstall' = 'Uninstall'; '--quiet' = 'Quiet'
      '--verbose' = 'Verbose'; '-h' = 'Help'; '--help' = 'Help'
    }
    if ($valued.ContainsKey($name)) {
      if ($null -eq $value) {
        $i++
        if ($i -ge $Argv.Count -or -not $Argv[$i]) { throw "$name needs a value (see --help)" }
        $value = $Argv[$i]
      }
      $Opt[$valued[$name]] = $value
    } elseif ($switches.ContainsKey($name) -and $null -eq $value) {
      $Opt[$switches[$name]] = $true
    } else {
      Write-Host $Usage
      throw "unknown option: $arg"
    }
    $i++
  }
  if (@('auto', 'system', 'zip') -notcontains $Opt.DartMethod) {
    throw "--dart-method must be auto, system or zip (got '$($Opt.DartMethod)')"
  }
  if ($Opt.Source -and $Opt.Git) { throw '--source and --git cannot be combined' }
  if ($Opt.Version -and ($Opt.Source -or $Opt.Git)) {
    throw '--version cannot be combined with --source or --git'
  }
  if ($Opt.GitRef -and -not $Opt.Git) { throw '--git-ref needs --git' }
}

# --- output -----------------------------------------------------------------

function Say([string]$Text) { if (-not $Opt.Quiet) { [Console]::Error.WriteLine($Text) } }
function Step([string]$Text) { Say "==> $Text" }
function Info([string]$Text) { Say "    $Text" }
function Warn([string]$Text) { [Console]::Error.WriteLine("omnyshell-install: warning: $Text") }

# Runs a native command, echoing it with --verbose/--dry-run (--dry-run skips
# it). Returns $true when it exited with 0.
function Invoke-Native([string]$Exe, [string[]]$ArgList = @()) {
  if ($Opt.Verbose -or $Opt.DryRun) { [Console]::Error.WriteLine("    `$ $Exe $($ArgList -join ' ')") }
  if ($Opt.DryRun) { return $true }
  # Windows PowerShell turns a native command's stderr into terminating errors
  # under 'Stop'; the exit code is what decides success here.
  $ErrorActionPreference = 'Continue'
  $global:LASTEXITCODE = 0
  if ($Opt.Quiet) { & $Exe @ArgList 2>&1 | Out-Null } else { & $Exe @ArgList | ForEach-Object { Info "$_" } }
  return ($LASTEXITCODE -eq 0)
}

function Test-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# --- environment --------------------------------------------------------------

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-ArchTag {
  $arch = $env:PROCESSOR_ARCHITEW6432
  if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
  switch ($arch) {
    'AMD64' { return 'x64' }
    'ARM64' { return 'arm64' }
    default { throw "unsupported CPU architecture: $arch (the Dart SDK needs x64 or arm64)" }
  }
}

function Get-DartDir {
  if ($Opt.DartDir) { return $Opt.DartDir }
  return Join-Path $env:LOCALAPPDATA 'omnyshell\dart-sdk'
}

# Same rule as lib/src/shared/utils/pub_cache_bin.dart.
function Get-PubBin {
  if ($env:PUB_CACHE) { return Join-Path $env:PUB_CACHE 'bin' }
  return Join-Path $env:LOCALAPPDATA 'Pub\Cache\bin'
}

# Records the user-PATH entries this installer added, for --uninstall.
function Get-StateFile { return Join-Path $env:LOCALAPPDATA 'omnyshell\installer-path.txt' }

# Package managers update the registry PATH, not this process's; reload it.
function Update-ProcessPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $extra = @($env:Path -split ';' | Where-Object { $_ })
  $all = New-Object System.Collections.Generic.List[string]
  foreach ($p in (@($machine -split ';') + @($user -split ';') + $extra)) {
    if ($p -and -not ($all -contains $p)) { $all.Add($p) }
  }
  $env:Path = $all -join ';'
}

# Runs [Exe] elevated (one UAC prompt) when this process is not an
# administrator. Returns $true on success.
function Invoke-Elevated([string]$Exe, [string[]]$ArgList) {
  if ($IsAdmin) { return Invoke-Native $Exe $ArgList }
  if ($Opt.NoSudo) { return $false }
  Info "Administrator rights are needed for: $Exe $($ArgList -join ' ') (Windows will ask)"
  if ($Opt.DryRun) { return $true }
  try {
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgList -Verb RunAs -Wait -PassThru
    return ($p.ExitCode -eq 0)
  } catch {
    Warn "elevation was refused or failed: $($_.Exception.Message)"
    return $false
  }
}

$WingetFlags = @('-e', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')

# --- Dart ---------------------------------------------------------------------

function Get-DartVersion([string]$Bin) {
  $ErrorActionPreference = 'Continue'
  $out =(& $Bin --version 2>&1 | Out-String)
  if ($out -match 'Dart SDK version: (\d+\.\d+\.\d+)') { return [version]$Matches[1] }
  return $null
}

function Find-Dart {
  $cmd = Get-Command dart -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    (Join-Path (Get-DartDir) 'bin\dart.exe'),
    (Join-Path $env:ProgramFiles 'Dart\dart-sdk\bin\dart.exe'),
    'C:\tools\dart-sdk\bin\dart.exe',
    (Join-Path $env:USERPROFILE 'scoop\apps\dart\current\bin\dart.exe'),
    (Join-Path $env:USERPROFILE 'flutter\bin\dart.bat'),
    'C:\src\flutter\bin\dart.bat'
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return $null
}

# How the Dart at [Bin] was installed: zip, flutter, fvm, scoop, choco, winget
# or unmanaged; with the flutter executable for Flutter installs.
function Get-DartKind([string]$Bin) {
  $full = [IO.Path]::GetFullPath($Bin)
  $dartDir = [IO.Path]::GetFullPath((Get-DartDir))
  if ($full.StartsWith($dartDir, [StringComparison]::OrdinalIgnoreCase)) { return @{ Kind = 'zip' } }
  if ($full -match '\\fvm\\') { return @{ Kind = 'fvm' } }
  $flutter = Join-Path (Split-Path $full) 'flutter.bat'
  if (-not (Test-Path $flutter) -and $full -match '^(.*)\\bin\\cache\\dart-sdk\\bin\\dart\.exe$') {
    $flutter = Join-Path $Matches[1] 'bin\flutter.bat'
  }
  if (Test-Path $flutter) { return @{ Kind = 'flutter'; Flutter = $flutter } }
  if ($full -match '\\scoop\\') { return @{ Kind = 'scoop' } }
  $chocoRoot = $env:ChocolateyInstall
  if ($full.StartsWith('C:\tools\dart-sdk', [StringComparison]::OrdinalIgnoreCase) -or
    ($chocoRoot -and $full.StartsWith($chocoRoot, [StringComparison]::OrdinalIgnoreCase))) {
    return @{ Kind = 'choco' }
  }
  if (Test-Command winget) {
    $ErrorActionPreference = 'Continue'
    $listed =(& winget list --id Google.DartSDK -e --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $listed -match 'Google\.DartSDK') { return @{ Kind = 'winget' } }
  }
  return @{ Kind = 'unmanaged' }
}

function Install-DartZip {
  $dartDir = Get-DartDir
  Step "Downloading the Dart SDK into $dartDir"
  if ((Test-Path $dartDir) -and -not (Test-Path (Join-Path $dartDir $ZipMarker)) -and
    (Get-ChildItem $dartDir -Force | Select-Object -First 1)) {
    throw "$dartDir exists and was not created by this installer; choose another --dart-dir"
  }
  $zip = "dartsdk-windows-$(Get-ArchTag)-release.zip"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("omnyshell-install-" + [guid]::NewGuid())
  if ($Opt.Verbose -or $Opt.DryRun) { Info "download $DartArchive/$zip" }
  if ($Opt.DryRun) { return (Join-Path $dartDir 'bin\dart.exe') }
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $zipPath = Join-Path $tmp $zip
    Invoke-WebRequest -UseBasicParsing -Uri "$DartArchive/$zip" -OutFile $zipPath
    $sum = (Invoke-WebRequest -UseBasicParsing -Uri "$DartArchive/$zip.sha256sum").Content
    # Windows PowerShell returns a non-text content type as bytes.
    if ($sum -is [byte[]]) { $sum = [Text.Encoding]::ASCII.GetString($sum) }
    $want = ("$sum".Trim() -split '\s+')[0]
    $got = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash
    if ($got -ne $want) { throw "checksum mismatch for $zip (expected $want, got $got)" }
    Expand-Archive -Path $zipPath -DestinationPath (Join-Path $tmp 'unzipped')
    if (Test-Path $dartDir) { Remove-Item -Recurse -Force $dartDir }
    New-Item -ItemType Directory -Force -Path (Split-Path $dartDir) | Out-Null
    Move-Item (Join-Path $tmp 'unzipped\dart-sdk') $dartDir
    New-Item -ItemType File -Path (Join-Path $dartDir $ZipMarker) | Out-Null
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
  return (Join-Path $dartDir 'bin\dart.exe')
}

# Installs Dart with the machine's package manager; returns its path or $null.
function Install-DartSystem {
  if (Test-Command winget) {
    Step 'Installing the Dart SDK with winget'
    if (Invoke-Native winget (@('install', '--id', 'Google.DartSDK') + $WingetFlags)) {
      Update-ProcessPath
      $found = Find-Dart
      if ($found) { return $found }
      if ($Opt.DryRun) { return 'dart' }  # nothing was installed to find
    }
    Info 'winget could not install Dart'
  }
  if (Test-Command choco) {
    Step 'Installing the Dart SDK with Chocolatey'
    if (Invoke-Elevated 'choco' @('install', 'dart-sdk', '-y', '--no-progress')) {
      Update-ProcessPath
      $found = Find-Dart
      if ($found) { return $found }
      if ($Opt.DryRun) { return 'dart' }  # nothing was installed to find
    }
  }
  if (Test-Command scoop) {
    Step 'Installing the Dart SDK with Scoop'
    if (Invoke-Native scoop @('install', 'dart')) {
      Update-ProcessPath
      $found = Find-Dart
      if ($found) { return $found }
      if ($Opt.DryRun) { return 'dart' }  # nothing was installed to find
    }
  }
  return $null
}

function Update-Dart([hashtable]$Kind) {
  Step "Upgrading the Dart SDK ($($Kind.Kind) install)"
  switch ($Kind.Kind) {
    'zip' { Install-DartZip | Out-Null; return $true }
    'flutter' { return (Invoke-Native $Kind.Flutter @('upgrade')) }
    'fvm' { return ((Invoke-Native fvm @('install', 'stable')) -and (Invoke-Native fvm @('global', 'stable'))) }
    'scoop' { return (Invoke-Native scoop @('update', 'dart')) }
    'choco' { return (Invoke-Elevated 'choco' @('upgrade', 'dart-sdk', '-y', '--no-progress')) }
    'winget' { return (Invoke-Native winget (@('upgrade', '--id', 'Google.DartSDK') + $WingetFlags)) }
    default { return $false }
  }
}

# Returns @{ Bin = <dart>; PreferPath = <put its bin first on PATH> }.
function Initialize-Dart {
  if ($Opt.DartMethod -eq 'zip') { return @{ Bin = (Install-DartZip); PreferPath = $true } }
  $bin = Find-Dart
  if (-not $bin) {
    $bin = Install-DartSystem
    if ($bin) { return @{ Bin = $bin; PreferPath = $false } }
    if ($Opt.DartMethod -eq 'system') {
      throw 'no package manager could install Dart here (try --dart-method zip)'
    }
    Info 'No usable package manager for Dart here; using the official SDK download'
    return @{ Bin = (Install-DartZip); PreferPath = $true }
  }

  $version = Get-DartVersion $bin
  $kind = Get-DartKind $bin
  if ($version -and $version -ge $MinDartVersion) {
    Step "Using Dart $version ($bin)"
    return @{ Bin = $bin; PreferPath = ($kind.Kind -eq 'zip') }
  }
  Info "Found Dart $(if ($version) { $version } else { 'of unknown version' }) at $bin ($($kind.Kind)); omnyshell needs >= $MinDartVersion"
  if ($Opt.NoDartUpgrade) {
    throw "Dart is too old and --no-dart-upgrade was given; upgrade it to $MinDartVersion or newer and re-run"
  }
  if ($kind.Kind -ne 'unmanaged' -and (Update-Dart $kind)) {
    if ($Opt.DryRun) { return @{ Bin = $bin; PreferPath = $false } }
    Update-ProcessPath
    $found = Find-Dart
    if ($found) { $bin = $found }
    $version = Get-DartVersion $bin
    if ($version -and $version -ge $MinDartVersion) {
      Step "Dart upgraded to $version"
      return @{ Bin = $bin; PreferPath = ($kind.Kind -eq 'zip') }
    }
    Warn "Dart is still $version after upgrading it with $($kind.Kind)"
  }
  if ($Opt.DartMethod -eq 'system') {
    throw "could not upgrade Dart at $bin; upgrade it to $MinDartVersion or newer and re-run"
  }
  Warn "installing a separate Dart SDK in $(Get-DartDir), placed ahead of $bin on PATH"
  return @{ Bin = (Install-DartZip); PreferPath = $true }
}

# --- tools ------------------------------------------------------------------

# Installs one tool with the first package manager that manages it.
function Install-Tool([string]$Name, [string]$WingetId, [string]$ChocoId, [string]$ScoopId) {
  if (Test-Command winget) {
    if (Invoke-Native winget (@('install', '--id', $WingetId) + $WingetFlags)) { return $true }
  }
  if ((Test-Command choco) -and (Invoke-Elevated 'choco' @('install', $ChocoId, '-y', '--no-progress'))) { return $true }
  if ((Test-Command scoop) -and (Invoke-Native scoop @('install', $ScoopId))) { return $true }
  return $false
}

# Tool directories a package installed but did not put on PATH.
$ExtraPathDirs = New-Object System.Collections.Generic.List[string]

function Initialize-Tools {
  $missing = @()
  if (-not (Test-Command git)) { $missing += 'git' }
  if (-not (Test-Command openssl)) { $missing += 'openssl' }
  if ($missing.Count -eq 0) { Step 'Tools: git and openssl are present'; return }
  if ($Opt.NoTools) {
    Warn "--no-tools: not installing $($missing -join ', ') (Git for Windows: Git Bash + winpty for full-screen programs on a Node, and drive git mounts; openssl: omnyshell cert gen)"
    return
  }
  Step "Installing tools: $($missing -join ', ')"
  if ($missing -contains 'git') {
    if (-not (Install-Tool 'Git for Windows' 'Git.Git' 'git' 'git')) {
      Warn 'could not install Git for Windows; get it from https://git-scm.com/download/win'
    }
  }
  if ($missing -contains 'openssl') {
    if (-not (Install-Tool 'OpenSSL' 'ShiningLight.OpenSSL.Light' 'openssl' 'openssl')) {
      Warn 'could not install OpenSSL; it is only needed for `omnyshell cert gen`'
    }
  }
  Update-ProcessPath
  if (-not $Opt.DryRun -and -not (Test-Command openssl)) {
    # The Shining Light installer does not always add itself to PATH.
    foreach ($dir in @((Join-Path $env:ProgramFiles 'OpenSSL-Win64\bin'), (Join-Path $env:ProgramFiles 'OpenSSL\bin'))) {
      if (Test-Path (Join-Path $dir 'openssl.exe')) { $ExtraPathDirs.Add($dir); break }
    }
  }
}

# --- PATH -------------------------------------------------------------------

function Set-UserPath([string[]]$Prepend, [string[]]$Append) {
  $current = @(([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') | Where-Object { $_ })
  $added = @()
  $rest = @($current | Where-Object { $p = $_; -not ($Prepend | Where-Object { $_ -ieq $p }) })
  foreach ($dir in $Prepend) { if (-not ($current | Where-Object { $_ -ieq $dir })) { $added += $dir } }
  $tail = @()
  foreach ($dir in $Append) {
    if (-not ($current | Where-Object { $_ -ieq $dir })) { $tail += $dir; $added += $dir }
  }
  $new = (@($Prepend) + $rest + $tail) -join ';'
  if ($Opt.DryRun) { return }
  # Unlike setx, this does not truncate at 1024 characters, and it notifies
  # running programs (new terminals pick the change up).
  [Environment]::SetEnvironmentVariable('Path', $new, 'User')
  if ($added.Count -gt 0) {
    $state = Get-StateFile
    New-Item -ItemType Directory -Force -Path (Split-Path $state) | Out-Null
    $previous = @()
    if (Test-Path $state) { $previous = @(Get-Content $state) }
    (@($previous) + $added | Select-Object -Unique) | Set-Content -Path $state
  }
}

function Set-OmnyPath([hashtable]$Dart) {
  $pubBin = Get-PubBin
  $dartBinDir = Split-Path $Dart.Bin
  $prepend = @()
  $append = @()
  if ($Dart.PreferPath) { $prepend += $dartBinDir } else { $append += $dartBinDir }
  $append += $ExtraPathDirs
  $append += $pubBin
  # This process needs them too, to verify the install.
  $env:Path = ((@($prepend) + @($env:Path) + @($append)) | Where-Object { $_ }) -join ';'
  if ($Opt.NoModifyPath) {
    Step 'Not changing PATH (--no-modify-path); add these to your user PATH:'
    foreach ($d in (@($prepend) + @($append))) { Info $d }
    return
  }
  Step 'Adding omnyshell to the user PATH'
  foreach ($d in (@($prepend) + @($append))) { Info $d }
  Set-UserPath $prepend $append
}

# --- omnyshell --------------------------------------------------------------

function Install-OmnyShellPackage([string]$Dart) {
  $argList = @('pub', 'global', 'activate')
  if ($Opt.Source) {
    Step "Installing omnyshell from $($Opt.Source)"
    $argList += @('--source', 'path', $Opt.Source)
  } elseif ($Opt.Git) {
    Step "Installing omnyshell from $($Opt.Git)"
    $argList += @('--source', 'git', $Opt.Git)
    if ($Opt.GitRef) { $argList += @('--git-ref', $Opt.GitRef) }
  } else {
    Step "Installing omnyshell$(if ($Opt.Version) { ' ' + $Opt.Version }) from pub.dev"
    $argList += 'omnyshell'
    if ($Opt.Version) { $argList += $Opt.Version }
  }
  if (-not (Invoke-Native $Dart $argList)) { throw 'dart pub global activate failed' }
}

function Update-Services([string]$Omny) {
  $ErrorActionPreference = 'Continue'
  foreach ($role in @('hub', 'node')) {
    $infoText = (& $Omny service info $role 2>$null | Out-String)
    if ($infoText -notmatch 'Service "') { continue }
    if ($Opt.ReinstallServices) {
      Step "Reinstalling the $role service on the new version"
      if (-not (Invoke-Native $Omny @('service', 'reinstall', $role))) {
        Warn "could not reinstall the $role service; run: omnyshell service reinstall $role"
      }
    } else {
      Info "A $role service is installed; it keeps running the previous version until you run: omnyshell service reinstall $role"
    }
  }
}

# --- uninstall ----------------------------------------------------------------

function Uninstall-OmnyShell {
  Step 'Uninstalling omnyshell'
  $dart = Find-Dart
  if ($dart) {
    if (-not (Invoke-Native $dart @('pub', 'global', 'deactivate', 'omnyshell'))) { Info 'omnyshell was not activated' }
  }
  $state = Get-StateFile
  if (Test-Path $state) {
    $ours = @(Get-Content $state)
    $current = @(([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') | Where-Object { $_ })
    $kept = @($current | Where-Object { $p = $_; -not ($ours | Where-Object { $_ -ieq $p }) })
    foreach ($d in $ours) { Info "Removing $d from the user PATH" }
    if (-not $Opt.DryRun) {
      [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
      Remove-Item $state
    }
  }
  $dartDir = Get-DartDir
  if (Test-Path (Join-Path $dartDir $ZipMarker)) {
    Info "Removing the Dart SDK this installer downloaded ($dartDir)"
    if (-not $Opt.DryRun) { Remove-Item -Recurse -Force $dartDir }
  }
  Say ''
  Say 'omnyshell is uninstalled. Kept: a Dart SDK installed by a package manager,'
  Say 'Git for Windows / OpenSSL, and %USERPROFILE%\.omnyshell (configuration and credentials).'
  Say 'Services, if any, are removed with: omnyshell service uninstall <hub|node>'
  Say '(run that before uninstalling, while the omnyshell command still exists).'
}

# --- main ---------------------------------------------------------------------

function Invoke-Main([string[]]$Argv) {
  Read-Arguments $Argv
  if ($Opt.Help) { Write-Host $Usage; return }
  # Older Windows PowerShell defaults to TLS 1.0, which the download hosts refuse.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  if ($Opt.Uninstall) { Uninstall-OmnyShell; return }
  if ($Opt.DryRun) { Step 'Dry run: nothing will be changed' }
  Step "Installing omnyshell on windows-$(Get-ArchTag)"

  $dart = Initialize-Dart
  Initialize-Tools
  Install-OmnyShellPackage $dart.Bin
  Set-OmnyPath $dart
  if ($Opt.DryRun) { Step 'Dry run finished'; return }

  $omny = Join-Path (Get-PubBin) 'omnyshell.bat'
  if (-not (Test-Path $omny)) { throw "omnyshell was not found at $omny after installing it" }
  # A source-activated wrapper prints pub's resolution output first.
  $ErrorActionPreference = 'Continue'
  $installed = (& $omny --version 2>$null | Select-Object -Last 1)
  $ErrorActionPreference = 'Stop'
  if ("$installed" -notmatch '^omnyshell ') { throw "$omny --version failed" }
  Update-Services $omny

  $Opt.Quiet = $false
  Say ''
  Say "Installed: $installed"
  Say "Dart:      $((& $dart.Bin --version 2>&1 | Select-Object -First 1))"
  if (-not $Opt.NoModifyPath) { Say 'Open a new terminal to use omnyshell.' }
  Say 'Get started: omnyshell --help   (docs: https://github.com/OmnyGrid/omnyshell)'
}

$exitCode = 0
try {
  Invoke-Main $args
} catch {
  [Console]::Error.WriteLine("omnyshell-install: error: $($_.Exception.Message)")
  $exitCode = 1
}
# Run as a file (install.bat, .\install.ps1): report the status. Piped into
# `iex`, `exit` would close the user's PowerShell window, so just return.
if ($PSCommandPath) { exit $exitCode }

} @args
