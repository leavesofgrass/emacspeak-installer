<#
.SYNOPSIS
Installs emacspeak with real speech on Windows 10 or 11.

.DESCRIPTION
Three speech engines are offered; -Speech or a menu picks them:
  omnivox   OmniVox (https://github.com/robertmeta/omnivox), an emacspeak
            speech server written in Rust, speaking with the Windows
            system voices through the WinRT SpeechSynthesizer. Its
            prebuilt release is checksum verified, or it is built from
            source with -OmnivoxSource.
  espeak    OmniVox again, with its built-in espeak-ng engine, chosen by
            OMNIVOX_ENGINE=espeak. Needs eSpeak NG's voice data, which
            comes with the eSpeak NG installer.
  sharpwin  sharpwin (https://github.com/robertmeta/sharpwin), a C#
            server using the Windows SAPI voices, built here with the
            .NET 8 SDK or newer.
The script clones emacspeak, generates its autoloads, byte-compiles it,
installs the chosen engines, and writes an Emacs init file and a launcher.

Run it as your normal user, in Windows PowerShell 5.1 or PowerShell 7:
  powershell -ExecutionPolicy Bypass -File scripts\install-emacspeak-windows.ps1
Run it again later to update emacspeak and the speech engines.

Without Emacs 29.1 or newer it installs GNU Emacs with winget, Git the
same way if git is missing, and the .NET 8 SDK for sharpwin. Otherwise
it changes nothing outside the prefix folder: no PATH, no HOME, no
shortcuts, unless you ask with -AddToPath, -SetHome or
-StartMenuShortcut. For Linux and macOS, use the other installers in
this folder.

.PARAMETER Speech
The speech engines to install, separated by commas, such as
omnivox,sharpwin. The first is the launcher's default. all means every
engine, and list describes them and exits. Without -Speech, a rerun
keeps the engines of the last run; a first run asks with a menu, or
takes omnivox when nobody can answer.

.PARAMETER Prefix
Where emacspeak is cloned and built. Default: .emacspeak in the folder
named by HOME, or in your profile folder when HOME is not set.

.PARAMETER Repo
The emacspeak git repository.

.PARAMETER Ref
The branch or tag to build. Default: master.

.PARAMETER OmnivoxVersion
The OmniVox release to install, such as 1.3.0. Default: the latest.

.PARAMETER OmnivoxSource
Build OmniVox from source with cargo instead of using the prebuilt
release. Needs Rust, CMake, LLVM (libclang) and the Visual Studio C++
build tools, which you install yourself.

.PARAMETER EmacsPath
The emacs.exe to use, Emacs 29.1 or newer. A folder holding
bin\emacs.exe, such as an unpacked GNU Emacs zip, works too.

.PARAMETER SkipDeps
Do not run winget. You installed Emacs and Git yourself, and the .NET 8
SDK or newer for sharpwin.

.PARAMETER NoCompile
Do not byte-compile emacspeak; it then runs from source and starts
more slowly.

.PARAMETER NoTest
Skip the self-tests at the end.

.PARAMETER NoSound
Skip only the self-tests that can make a sound: OmniVox's own check,
which plays a tone and speech, the default server speaking its version,
and sharpwin started as a server. The others run silently.

.PARAMETER StartMenuShortcut
Add an Emacspeak shortcut to your Start menu.

.PARAMETER SetHome
Set the HOME environment variable of your account to your profile
folder, as OmniVox's README recommends when you load emacspeak from
your own init file.

.PARAMETER AddToPath
Add the prefix folder to the PATH of your account, so the emacspeak
command works in any new Command Prompt or PowerShell window.

.PARAMETER Help
Show a short usage text.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\install-emacspeak-windows.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\install-emacspeak-windows.ps1 -SkipDeps -EmacsPath D:\emacs-30.2\bin\emacs.exe

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\install-emacspeak-windows.ps1 -Speech omnivox,sharpwin
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$Speech = @(),
    [string]$Prefix = '',
    [string]$Repo = 'https://github.com/tvraman/emacspeak.git',
    [string]$Ref = 'master',
    [string]$OmnivoxVersion = '',
    [switch]$OmnivoxSource,
    [string]$EmacsPath = '',
    [switch]$SkipDeps,
    [switch]$NoCompile,
    [switch]$NoTest,
    [switch]$NoSound,
    [switch]$StartMenuShortcut,
    [switch]$SetHome,
    [switch]$AddToPath,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Marker = 'Written by install-emacspeak-windows.ps1'
$OmnivoxRepo = 'robertmeta/omnivox'
# Used only when GitHub cannot be asked for the latest release and no
# OmniVox is installed yet: the release this script was written against.
$OmnivoxFallback = '1.3.0'
$EmacsWingetId = 'GNU.Emacs'
$GitWingetId = 'Git.Git'
$DotnetWingetId = 'Microsoft.DotNet.SDK.8'
$EspeakWingetId = 'eSpeak-NG.eSpeak-NG'
$EspeakReleases = 'https://github.com/espeak-ng/espeak-ng/releases'
# sharpwin has no release tags, so its main branch is built.
$SharpwinRepo = 'https://github.com/robertmeta/sharpwin.git'
$SharpwinBranch = 'main'
$MinEmacs = '29.1'
$LF = [string][char]10
$CRLF = [string][char]13 + [string][char]10
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
# git must never wait for a password prompt that nobody sees.
$GitEnv = @{ GIT_TERMINAL_PROMPT = '0' }
# dotnet sends usage data to Microsoft unless told not to, and makes a
# developer certificate on its first run; neither is needed here.
$DotnetEnv = @{ DOTNET_CLI_TELEMETRY_OPTOUT = '1'; DOTNET_NOLOGO = '1'
                DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'; DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false' }

# The speech engines, in menu order. omnivox and espeak are the same
# server: OmniVox speaks with the Windows voices, or with its built-in
# espeak-ng when OMNIVOX_ENGINE=espeak is in its environment.
$EngineNames = @('omnivox', 'espeak', 'sharpwin')
$DefaultEngine = 'omnivox'
$EngineInfo = @{
    omnivox  = @{ Display = 'OmniVox'; Server = 'omnivox'
                  Menu = 'the Windows system voices through OmniVox'
                  Needs = 'nothing more; OmniVox comes prebuilt from GitHub, checksum verified.' }
    espeak   = @{ Display = 'espeak'; Server = 'omnivox'
                  Menu = "eSpeak NG voices through OmniVox's built-in espeak-ng"
                  Needs = "eSpeak NG's voice data, from the eSpeak NG installer (winget id $EspeakWingetId)." }
    sharpwin = @{ Display = 'sharpwin'; Server = 'sharpwin'
                  Menu = 'the Windows SAPI voices through sharpwin, built here'
                  Needs = "the .NET 8 SDK or newer; winget installs $DotnetWingetId unless -SkipDeps." }
}

# --------------------------------------------------------------------------
# Output and the log. Every line on screen also goes to the log. Until the
# prefix holds the emacspeak clone the log is kept in memory, because git
# clones only into an empty folder; it is written out once the clone exists.
$script:LogPath = $null
$script:LogBuffer = New-Object System.Text.StringBuilder
# Set by each section: what to do about a failure there.
$script:Hint = ''

function Add-Log([string]$Text) {
    if ($null -ne $script:LogPath) {
        [IO.File]::AppendAllText($script:LogPath, $Text, $Utf8NoBom)
    } else {
        [void]$script:LogBuffer.Append($Text)
    }
}

function Open-Log([string]$Path) {
    [IO.File]::WriteAllText($Path, $script:LogBuffer.ToString(), $Utf8NoBom)
    $script:LogPath = $Path
    [void]$script:LogBuffer.Clear()
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text"
    Add-Log ($CRLF + '==> ' + $Text + $CRLF)
}

function Write-Info([string]$Text) {
    Write-Host $Text
    Add-Log ($Text + $CRLF)
}

function Write-Warn([string]$Text) {
    Write-Info "Warning: $Text"
}

function Get-LogRef {
    if ($null -ne $script:LogPath) { return "The full output is in $script:LogPath" }
    return ''
}

# Shows the end of the log, so the lines just above the error explain it.
function Show-LogTail {
    if ($null -ne $script:LogPath) {
        $text = [IO.File]::ReadAllText($script:LogPath)
    } else {
        $text = $script:LogBuffer.ToString()
    }
    $lines = @([regex]::Split($text.TrimEnd(), '\r?\n') | Select-Object -Last 20)
    Write-Host ''
    Write-Host 'Last lines of the log:'
    foreach ($line in $lines) { Write-Host $line }
}

function Fail([string]$Text) {
    Write-Host "ERROR: $Text"
    Add-Log ('ERROR: ' + $Text + $CRLF)
    exit 1
}

# Anything not caught below ends here, as one plain error line.
trap {
    $where = $_.InvocationInfo.ScriptLineNumber
    $text = $_.Exception.Message
    Write-Host "ERROR: unexpected failure at line $where of the script: $text"
    Add-Log ("ERROR: unexpected failure at line $where of the script: $text" + $CRLF)
    if ($null -ne $script:LogPath) { Write-Host "The full output is in $script:LogPath" }
    exit 1
}

function Show-Usage([string]$DefaultPrefix) {
    $lines = @(
        'Usage: powershell -ExecutionPolicy Bypass -File install-emacspeak-windows.ps1 [options]',
        '',
        'Installs emacspeak with real speech on Windows 10 or 11.',
        'Run it as your normal user. Run it again later to update',
        'emacspeak and its speech engines.',
        '',
        'Options:',
        '  -Speech LIST         speech engines, separated by commas:',
        '                       omnivox, espeak, sharpwin, or all. The',
        '                       first is the default. -Speech list',
        '                       describes them. Without -Speech, a rerun',
        '                       keeps the last choice; a first run asks.',
        '  -Prefix DIR          where emacspeak is cloned and built',
        "                       (default $DefaultPrefix)",
        '  -Repo URL            emacspeak git repository',
        '  -Ref REF             branch or tag to build (default master)',
        '  -OmnivoxVersion VER  OmniVox release to install, such as 1.3.0',
        '                       (default: the latest release)',
        '  -OmnivoxSource       build OmniVox from source with cargo',
        '  -EmacsPath FILE      the emacs.exe to use, 29.1 or newer',
        '  -SkipDeps            do not run winget; you installed Emacs',
        '                       and Git yourself, and .NET for sharpwin',
        '  -NoCompile           do not byte-compile; run from source',
        '  -NoTest              skip the self-tests at the end',
        '  -NoSound             skip only the self-tests that make sound',
        '  -StartMenuShortcut   add Emacspeak to your Start menu',
        '  -SetHome             set HOME to your profile folder',
        '  -AddToPath           add the prefix to your PATH',
        '  -Help                show this help',
        '',
        "Without Emacs $MinEmacs or newer, it installs $EmacsWingetId with winget,",
        "$GitWingetId if git is missing, and $DotnetWingetId for sharpwin",
        'if no .NET 8 SDK or newer is found. Nothing else outside the prefix',
        'changes unless you ask with the last three switches.',
        'Get-Help on this script shows more about each option.'
    )
    foreach ($line in $lines) { Write-Host $line }
}

# --------------------------------------------------------------------------
# Running programs. PowerShell 5.1 mangles quotes in native arguments and
# turns native error output into exceptions, so programs run through
# System.Diagnostics.Process, with their output appended to the log.

# Quotes one argument the way Windows programs split their command line.
function ConvertTo-Argument([string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq [char]92) {
            $slashes++
        } elseif ($c -eq [char]34) {
            [void]$sb.Append([char]92, 2 * $slashes + 1)
            [void]$sb.Append([char]34)
            $slashes = 0
        } else {
            if ($slashes -gt 0) { [void]$sb.Append([char]92, $slashes) }
            $slashes = 0
            [void]$sb.Append($c)
        }
    }
    if ($slashes -gt 0) { [void]$sb.Append([char]92, 2 * $slashes) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Runs a program with its input closed (or given INPUT), stops it after
# SECONDS, and returns its exit status and output. Never throws. In
# ENVIRONMENT, a name with the value $null is taken out of the program's
# environment.
function Invoke-Program {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$Seconds = 600,
        [string]$WorkingDirectory = '',
        [string]$InputText = '',
        [hashtable]$Environment = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $quoted = @()
    foreach ($a in $Arguments) { $quoted += ConvertTo-Argument $a }
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8NoBom
    $psi.StandardErrorEncoding = $Utf8NoBom
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($name in $Environment.Keys) {
        if ($null -eq $Environment[$name]) {
            [void]$psi.EnvironmentVariables.Remove($name)
        } else {
            $psi.EnvironmentVariables[$name] = [string]$Environment[$name]
        }
    }
    Add-Log ('> ' + $FilePath + ' ' + $psi.Arguments + $CRLF)
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Add-Log ('(could not start: ' + $_.Exception.Message + ')' + $CRLF)
        return [pscustomobject]@{ Started = $false; ExitCode = -1; TimedOut = $false
                                  Output = ''; ErrorOutput = $_.Exception.Message }
    }
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    try {
        if ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
    } catch {
        # The program exited before reading its input; its status tells.
    }
    $timedOut = -not $process.WaitForExit($Seconds * 1000)
    if ($timedOut) {
        try { $process.Kill() } catch { }
        [void]$process.WaitForExit(10000)
    } else {
        $process.WaitForExit()
    }
    $out = ''
    $err = ''
    if ($outTask.Wait(10000)) { $out = $outTask.Result }
    if ($errTask.Wait(10000)) { $err = $errTask.Result }
    $code = -1
    if (-not $timedOut) { $code = $process.ExitCode }
    foreach ($text in @($out, $err)) {
        if ($text) {
            # OmniVox colors its log lines; screen readers read the codes aloud.
            $plain = [regex]::Replace($text, ([string][char]27) + '\[[0-9;]*[A-Za-z]', '')
            Add-Log $plain
            if (-not $plain.EndsWith($LF)) { Add-Log $CRLF }
        }
    }
    if ($timedOut) { Add-Log ("(stopped after $Seconds seconds)" + $CRLF) }
    Add-Log ("(exit status $code)" + $CRLF)
    return [pscustomobject]@{ Started = $true; ExitCode = $code; TimedOut = $timedOut
                              Output = $out; ErrorOutput = $err }
}

# Like Invoke-Program, but a failure stops the script with WHAT and the hint.
function Invoke-Logged {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$Seconds = 1800,
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{}
    )
    $r = Invoke-Program -FilePath $FilePath -Arguments $Arguments -Seconds $Seconds `
        -WorkingDirectory $WorkingDirectory -Environment $Environment
    if (-not $r.Started) {
        Fail "$What failed: $FilePath did not start ($($r.ErrorOutput)). $script:Hint"
    }
    if ($r.TimedOut) {
        Show-LogTail
        Fail "$What did not finish within $Seconds seconds. $script:Hint $(Get-LogRef)"
    }
    if ($r.ExitCode -ne 0) {
        Show-LogTail
        Fail "$What failed (exit status $($r.ExitCode)). $script:Hint $(Get-LogRef)"
    }
    return $r
}

# --------------------------------------------------------------------------
# Finding Emacs and git.

function Get-EmacsVersion([string]$Exe) {
    $r = Invoke-Program -FilePath $Exe -Arguments @('-Q', '--batch', '--eval', '(princ emacs-version)') -Seconds 120
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) { return $null }
    $v = $r.Output.Trim()
    if ($v -match '^[0-9]+(\.[0-9]+)+$') { return $v }
    return $null
}

function Test-NewEnough([string]$Version) {
    return ([version]$Version) -ge ([version]$MinEmacs)
}

# Turns a file or folder given with -EmacsPath into the emacs.exe it means.
function Resolve-EmacsExe([string]$Path) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $full -PathType Container) {
        foreach ($c in @((Join-Path $full 'bin\emacs.exe'), (Join-Path $full 'emacs.exe'))) {
            if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
        }
        return $null
    }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        if ((Split-Path -Leaf $full) -ieq 'runemacs.exe') {
            $full = Join-Path (Split-Path -Parent $full) 'emacs.exe'
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
        }
        return $full
    }
    return $null
}

# Every emacs.exe on PATH or in the usual install folders: the GNU
# installer (and winget, which runs it), Scoop and Chocolatey.
function Get-EmacsCandidates {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(Get-Command -Name 'emacs.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $found.Add($c.Source)
    }
    $roots = @()
    foreach ($base in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        $roots += (Join-Path $base 'Emacs')
        $roots += (Join-Path $base 'Programs\Emacs')
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $found.Add((Join-Path $root 'bin\emacs.exe'))
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $found.Add((Join-Path $d.FullName 'bin\emacs.exe'))
        }
    }
    if ($env:LOCALAPPDATA) {
        $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (Test-Path -LiteralPath $packages -PathType Container) {
            foreach ($d in @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'GNU.Emacs*' -ErrorAction SilentlyContinue)) {
                foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Filter 'emacs.exe' -ErrorAction SilentlyContinue)) {
                    $found.Add($f.FullName)
                }
            }
        }
    }
    if ($env:USERPROFILE) { $found.Add((Join-Path $env:USERPROFILE 'scoop\apps\emacs\current\bin\emacs.exe')) }
    if ($env:ProgramData) { $found.Add((Join-Path $env:ProgramData 'chocolatey\lib\emacs\tools\emacs\bin\emacs.exe')) }
    $seen = @{}
    $result = @()
    foreach ($p in $found) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $key = $p.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $result += $p
    }
    return , $result
}

# Returns the newest Emacs 29.1 or newer as @{ Path; Version }, or $null.
# Older ones are reported, so a failure can name them.
function Find-Emacs {
    $best = $null
    foreach ($exe in (Get-EmacsCandidates)) {
        $v = Get-EmacsVersion $exe
        if ($null -eq $v) {
            Write-Info "Skipping $exe : it does not run in batch mode."
            continue
        }
        if (-not (Test-NewEnough $v)) {
            Write-Info "Skipping Emacs $v at $exe : emacspeak needs $MinEmacs or newer."
            continue
        }
        if ($null -eq $best -or ([version]$v) -gt ([version]$best.Version)) {
            $best = @{ Path = $exe; Version = $v }
        }
    }
    return $best
}

function Find-Git {
    $c = @(Get-Command -Name 'git.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($c.Count -gt 0) { return $c[0].Source }
    $places = @()
    if ($env:ProgramFiles) { $places += (Join-Path $env:ProgramFiles 'Git\cmd\git.exe') }
    if ($env:LOCALAPPDATA) { $places += (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe') }
    foreach ($p in $places) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

# SCOPE, when given, is winget's --scope: machine for a package whose
# manifest installs for all users.
function Install-WithWinget([string]$Id, [string]$Name, [string]$Scope = '') {
    $winget = @(Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($winget.Count -eq 0) {
        Fail ("winget is not available, so $Name cannot be installed for you. Install " +
              'App Installer from the Microsoft Store (it provides winget), or install ' +
              "$Name yourself, then rerun this script (with -SkipDeps if you like).")
    }
    Write-Info "Windows may ask for permission to install $Name (an elevation prompt). Answer Yes."
    Write-Info 'Progress goes to the log; this can take several minutes.'
    $arguments = @('install', '--exact', '--id', $Id)
    if ($Scope) { $arguments += @('--scope', $Scope) }
    $arguments += @('--accept-source-agreements', '--accept-package-agreements')
    $r = Invoke-Program -FilePath $winget[0].Source -Seconds 2400 -Arguments $arguments
    return $r
}

# The machine's own architecture, also from a 32-bit or emulated shell.
function Get-NativeArch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    try {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        $reg = (Get-ItemProperty -LiteralPath $key -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
        if ($reg) { $arch = $reg }
    } catch {
        # Keep the value from the environment.
    }
    return $arch
}

function ConvertTo-LispPath([string]$Path) {
    return $Path.Replace([string][char]92, '/')
}

# --------------------------------------------------------------------------
# Choosing the speech engines.

function Get-EngineDisplay([string[]]$Names) {
    return (@($Names | ForEach-Object { $EngineInfo[$_].Display }) -join ', ')
}

# One line per engine: what it speaks with, and what it needs.
function Show-SpeechList {
    foreach ($name in $EngineNames) {
        $e = $EngineInfo[$name]
        Write-Host "${name}: $($e.Menu). Needs $($e.Needs)"
    }
}

# Turns the words given with -Speech into engine names, in order and
# without repeats. all stands for every engine; an unknown name stops.
function ConvertTo-EngineList([string[]]$Words) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($word in $Words) {
        $w = $word.Trim().ToLowerInvariant()
        if (-not $w) { continue }
        $expanded = @($w)
        if ($w -eq 'all') { $expanded = $EngineNames }
        foreach ($name in $expanded) {
            if ($EngineNames -notcontains $name) {
                Show-SpeechList
                Fail ("-Speech: unknown speech engine $word. Use names from the list above, " +
                      'separated by commas, or all.')
            }
            if (-not $names.Contains($name)) { $names.Add($name) }
        }
    }
    if ($names.Count -eq 0) {
        Show-SpeechList
        Fail '-Speech needs engine names from the list above, separated by commas, or all.'
    }
    return , $names.ToArray()
}

# True when someone can answer a question: input and output are a
# console, Windows runs this in a user session, and PowerShell was not
# started with -NonInteractive.
function Test-Interactive {
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    } catch {
        return $false
    }
    if (-not [Environment]::UserInteractive) { return $false }
    foreach ($a in [Environment]::GetCommandLineArgs()) {
        if ($a -match '^[-/]{1,2}noni') { return $false }
    }
    return $true
}

# Asks which engines to install, until the answer makes sense.
function Read-SpeechMenu {
    Write-Info 'Which speech engines should emacspeak get?'
    for ($i = 0; $i -lt $EngineNames.Count; $i++) {
        $name = $EngineNames[$i]
        $line = "$($i + 1)) ${name}: $($EngineInfo[$name].Menu)"
        if ($name -eq $DefaultEngine) { $line += ' (default)' }
        Write-Info $line
    }
    $defaultNumber = [array]::IndexOf($EngineNames, $DefaultEngine) + 1
    $prompt = "Numbers separated by spaces, or Enter for the default [$defaultNumber]: "
    while ($true) {
        Write-Host $prompt -NoNewline
        $answer = [Console]::ReadLine()
        Add-Log ($prompt + $answer + $CRLF)
        # No answer at all (end of input) also means the default.
        if ($null -eq $answer -or -not $answer.Trim()) { return , @($DefaultEngine) }
        $picked = New-Object System.Collections.Generic.List[string]
        $ok = $true
        foreach ($word in ($answer.Trim() -split '[\s,]+')) {
            $n = 0
            if (-not [int]::TryParse($word, [ref]$n) -or $n -lt 1 -or $n -gt $EngineNames.Count) {
                $ok = $false
                break
            }
            if (-not $picked.Contains($EngineNames[$n - 1])) { $picked.Add($EngineNames[$n - 1]) }
        }
        if ($ok) { return , $picked.ToArray() }
        Write-Info "Please answer with numbers from 1 to $($EngineNames.Count), separated by spaces, such as: 1 3"
    }
}

# The engines recorded by the last successful run, or $null.
function Read-SpeechRecord {
    if (-not (Test-Path -LiteralPath $SpeechFile -PathType Leaf)) { return $null }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($SpeechFile)) {
        $name = $line.Trim().ToLowerInvariant()
        if (-not $name) { continue }
        if ($EngineNames -notcontains $name) {
            Write-Warn "$SpeechFile names an unknown speech engine, $name; ignored."
        } elseif (-not $names.Contains($name)) {
            $names.Add($name)
        }
    }
    if ($names.Count -eq 0) { return $null }
    return , $names.ToArray()
}

# --------------------------------------------------------------------------
# What the engines need.

# Where OmniVox's espeak-ng engine finds eSpeak NG's voice data, as
# @{ Path; How }, or $null. The places are checked in the order OmniVox
# and espeak-ng check them. OmniVox's Windows zip has no voice data: it
# comes from an eSpeak NG install, whose installer writes its folder to
# the registry, or from OmniVox's own source build.
function Find-EspeakData {
    $places = New-Object System.Collections.Generic.List[object]
    if ($env:ESPEAK_NG_DATA) {
        $places.Add(@((Join-Path $env:ESPEAK_NG_DATA 'espeak-ng-data'), 'the ESPEAK_NG_DATA variable'))
    }
    $buildRoot = Join-Path $OmnivoxDir 'src\target\release\build'
    if ($OmnivoxSource -and (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $buildRoot -Directory -Filter 'espeak-rs-sys-*' -ErrorAction SilentlyContinue)) {
            $places.Add(@((Join-Path $d.FullName 'out\share\espeak-ng-data'), "OmniVox's source build"))
        }
    }
    $places.Add(@((Join-Path $PrefixPath 'servers\espeak-ng-data'), 'the folder beside omnivox.exe'))
    if ($env:ESPEAK_DATA_PATH) {
        $places.Add(@((Join-Path $env:ESPEAK_DATA_PATH 'espeak-ng-data'), 'the ESPEAK_DATA_PATH variable'))
        $places.Add(@($env:ESPEAK_DATA_PATH, 'the ESPEAK_DATA_PATH variable'))
    }
    foreach ($key in @('HKLM:\SOFTWARE\eSpeak NG', 'HKLM:\SOFTWARE\WOW6432Node\eSpeak NG')) {
        try {
            $dir = [string](Get-ItemProperty -LiteralPath $key -Name 'Path' -ErrorAction Stop).Path
            if ($dir) { $places.Add(@((Join-Path $dir 'espeak-ng-data'), 'the eSpeak NG install')) }
        } catch {
            # No eSpeak NG install registered here.
        }
    }
    foreach ($place in $places) {
        if (Test-Path -LiteralPath (Join-Path $place[0] 'phontab') -PathType Leaf) {
            return @{ Path = $place[0].TrimEnd([char]92); How = $place[1] }
        }
    }
    return $null
}

# The dotnet.exe with a .NET 8 or newer SDK, as @{ Exe; Version }, where
# Version is the newest such SDK, or $null.
function Find-DotnetSdk {
    $candidates = @()
    foreach ($c in @(Get-Command -Name 'dotnet.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $candidates += $c.Source
    }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe') }
    $seen = @{}
    foreach ($exe in $candidates) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $key = $exe.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $r = Invoke-Program -FilePath $exe -Arguments @('--list-sdks') -Seconds 120 -Environment $DotnetEnv
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) { continue }
        $best = $null
        foreach ($m in [regex]::Matches($r.Output, '(?m)^(([0-9]+)\.[0-9]+\.[0-9]+)(\S*)\s+\[')) {
            $v = [version]$m.Groups[1].Value
            if ($v.Major -ge 8 -and ($null -eq $best -or $v -gt $best.Number)) {
                $best = @{ Exe = $exe; Number = $v; Version = $m.Groups[1].Value + $m.Groups[3].Value }
            }
        }
        if ($null -ne $best) { return $best }
    }
    return $null
}

# Whether Windows has a sound output device, asked without making a sound.
function Test-SoundOutput {
    try {
        if (-not ('EmacspeakInstaller.WinMM' -as [type])) {
            Add-Type -Namespace EmacspeakInstaller -Name WinMM -MemberDefinition @'
[DllImport("winmm.dll")]
public static extern uint waveOutGetNumDevs();
'@
        }
        return [EmacspeakInstaller.WinMM]::waveOutGetNumDevs() -gt 0
    } catch {
        return $false
    }
}

# The first line of TEXT that reports a failure, without Lisp quoting.
function Get-FirstErrorLine([string]$Text) {
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $plain = ($line -replace '^output: "', '').Trim()
        if ($plain -match '(?i)exception|error|fail|not found|cannot|could not|missing') { return $plain }
    }
    return ''
}

# --------------------------------------------------------------------------
# servers\.servers is part of emacspeak's git tree. M-x dtk-select-server
# offers the names listed there, and OmniVox's README asks for both names.
# The file keeps its own line endings, so git sees only the two new lines.

function Get-NewlineOf([string]$Text) {
    if ($Text.Contains($CRLF)) { return $CRLF }
    return $LF
}

function Get-ServersNames([string]$Text) {
    return @([regex]::Split($Text, '\r?\n') | ForEach-Object { $_.Trim() })
}

function Register-Omnivox {
    if (-not (Test-Path -LiteralPath $ServersList -PathType Leaf)) {
        Fail "$ServersList is missing; is $PrefixPath an emacspeak clone? Move it away or use -Prefix."
    }
    $text = [IO.File]::ReadAllText($ServersList)
    $nl = Get-NewlineOf $text
    $names = Get-ServersNames $text
    $add = ''
    if ($text.Length -gt 0 -and -not $text.EndsWith($LF)) { $add = $nl }
    foreach ($name in @('omnivox', 'log-omnivox')) {
        if ($names -notcontains $name) { $add += $name + $nl }
    }
    if ($add.Trim()) { [IO.File]::AppendAllText($ServersList, $add, $Utf8NoBom) }
}

# Keeps the files this script adds to the clone out of git status.
function Add-GitExcludes {
    $file = Join-Path $PrefixPath '.git\info\exclude'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    $text = ''
    if (Test-Path -LiteralPath $file -PathType Leaf) { $text = [IO.File]::ReadAllText($file) }
    $nl = Get-NewlineOf $text
    $listed = Get-ServersNames $text
    $add = ''
    if ($text.Length -gt 0 -and -not $text.EndsWith($LF)) { $add = $nl }
    foreach ($pattern in @('/speech-engines', '/emacspeak-init.el', '/omnivox-init.el',
                           '/emacspeak-selftest.el', '/emacspeak.cmd', '/install-emacspeak-windows.log',
                           '/omnivox/', '/sharpwin/', '/servers/omnivox.exe', '/servers/log-omnivox.exe',
                           '/servers/sharpwin.exe', '/servers/log-sharpwin.exe')) {
        if ($listed -notcontains $pattern) { $add += $pattern + $nl }
    }
    if ($add.Trim()) { [IO.File]::AppendAllText($file, $add, $Utf8NoBom) }
}

# Takes this script's two lines out again, so git sees the file unchanged.
function Unregister-Omnivox {
    if (-not (Test-Path -LiteralPath $ServersList -PathType Leaf)) { return }
    $text = [IO.File]::ReadAllText($ServersList)
    $nl = Get-NewlineOf $text
    $endsWithNewline = $text.EndsWith($LF)
    $lines = @([regex]::Split($text, '\r?\n'))
    if ($endsWithNewline) { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    $kept = @($lines | Where-Object { @('omnivox', 'log-omnivox') -notcontains $_.Trim() })
    if ($kept.Count -eq $lines.Count) { return }
    $new = $kept -join $nl
    if ($endsWithNewline -and $kept.Count -gt 0) { $new += $nl }
    [IO.File]::WriteAllText($ServersList, $new, $Utf8NoBom)
}

# --------------------------------------------------------------------------
# OmniVox.

function Test-ValidVersion([string]$Version) {
    return $Version -match '^[0-9]+\.[0-9]+[0-9A-Za-z.-]*$'
}

# Prints the latest OmniVox release, such as 1.3.0, from the GitHub API.
function Get-LatestOmnivoxVersion {
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$OmnivoxRepo/releases/latest" `
            -UseBasicParsing -TimeoutSec 30
        $tag = $release.PSObject.Properties['tag_name']
        if ($null -eq $tag) { return $null }
        $v = ([string]$tag.Value).TrimStart('v')
        if (Test-ValidVersion $v) { return $v }
    } catch {
        Add-Log ('GitHub API: ' + $_.Exception.Message + $CRLF)
    }
    return $null
}

# Downloads URL to PATH unless an earlier run already did. The download goes
# to a .part file first, so an interrupted one is never taken as complete.
function Save-Download([string]$Url, [string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Write-Info "Already downloaded: $(Split-Path -Leaf $Path)"
        return
    }
    $part = $Path + '.part'
    Add-Log ("Downloading $Url" + $CRLF)
    try {
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -TimeoutSec 600
    } catch {
        Add-Log ($_.Exception.Message + $CRLF)
        Fail "could not download $Url ($($_.Exception.Message)). $script:Hint"
    }
    Move-Item -LiteralPath $part -Destination $Path -Force
}

# Copies omnivox.exe and omnivox-voices.el into place, then records the version.
function Install-OmnivoxFiles([string]$Exe, [string]$El) {
    $elispDir = Join-Path $OmnivoxDir 'elisp'
    New-Item -ItemType Directory -Force -Path $elispDir | Out-Null
    try {
        Copy-Item -LiteralPath $El -Destination (Join-Path $elispDir 'omnivox-voices.el') -Force
        Copy-Item -LiteralPath $Exe -Destination $OmnivoxExe -Force
        # OmniVox's README registers the same binary under the name log-omnivox.
        # Windows links need administrator rights, so this is a copy.
        Copy-Item -LiteralPath $Exe -Destination $LogOmnivoxExe -Force
    } catch {
        Fail ("could not copy OmniVox into $PrefixPath\servers ($($_.Exception.Message)). " +
              'If emacspeak is running, quit Emacs, then rerun this script.')
    }
    $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--version') -Seconds 30
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Fail "$OmnivoxExe does not run on this computer. Rerun with -OmnivoxSource to build it here. $(Get-LogRef)"
    }
    [IO.File]::WriteAllText($InstalledFile, $script:Want + $CRLF, $Utf8NoBom)
    Write-Info "Installed $OmnivoxExe ($($r.Output.Trim())), and log-omnivox.exe beside it."
}

function Install-PrebuiltOmnivox([string]$Version) {
    $base = "https://github.com/$OmnivoxRepo/releases/download/v$Version"
    $zipName = "omnivox-$Version-windows-$Arch.zip"
    $downloads = Join-Path $OmnivoxDir 'downloads'
    $zip = Join-Path $downloads $zipName
    $sums = Join-Path $downloads "sha256sums-$Version.txt"
    $dir = Join-Path $OmnivoxDir "release-$Version-$Arch"
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    Write-Step "Downloading OmniVox $Version for $Arch ($zipName)"
    $script:Hint = ("Check the internet connection. If release $Version lacks this file, " +
                    'pick another with -OmnivoxVersion, or use -OmnivoxSource.')
    Save-Download "$base/$zipName" $zip
    Save-Download "$base/sha256sums.txt" $sums
    # PowerShell names ignore case, so these must not be called $want:
    # that would hide the script's $Want from Install-OmnivoxFiles.
    $expectedHash = $null
    foreach ($line in [IO.File]::ReadAllLines($sums)) {
        $parts = @($line.Trim() -split '\s+', 2)
        if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $zipName) {
            $expectedHash = $parts[0].ToLowerInvariant()
            break
        }
    }
    if ($null -eq $expectedHash) {
        Fail ("sha256sums.txt of OmniVox $Version has no line for $zipName, so it cannot " +
              'be checked. Pick a release with -OmnivoxVersion, or use -OmnivoxSource.')
    }
    $actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        # Set both files aside, so the next run downloads them afresh.
        foreach ($f in @($zip, $sums)) { Move-Item -LiteralPath $f -Destination ($f + '.bad') -Force }
        Fail ("checksum mismatch for ${zipName}: expected $expectedHash, got $actualHash. The " +
              "download is damaged or was changed; both files were set aside as .bad in " +
              "$downloads. Run the script again to download them afresh; if it fails again, " +
              'use -OmnivoxSource.')
    }
    Write-Info "Checksum verified: SHA-256 $actualHash"
    $script:Hint = 'Run the script again, or use -OmnivoxSource.'
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    } catch {
        Fail "could not unpack $zipName ($($_.Exception.Message)). $script:Hint"
    }
    $exe = Join-Path $dir 'omnivox.exe'
    $el = Join-Path $dir 'omnivox-voices.el'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $el -PathType Leaf)) {
        Fail ("$zipName does not hold omnivox.exe and omnivox-voices.el; the release layout " +
              'may have changed. Try -OmnivoxSource.')
    }
    Install-OmnivoxFiles $exe $el
}

# Rust's tools, CMake and libclang for OmniVox's source build, or a list of
# what is missing. Nothing is installed: on Windows these need the Visual
# Studio C++ build tools, which this script leaves to you.
function Find-SourceTools {
    $tools = @{ Cargo = $null; Rustc = $null; CMake = $null; LibClang = $null; Missing = @() }
    $cargo = @(Get-Command -Name 'cargo.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($cargo.Count -gt 0) {
        $tools.Cargo = $cargo[0].Source
    } elseif ($env:USERPROFILE -and (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))) {
        $tools.Cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    }
    if ($tools.Cargo) {
        $rustc = Join-Path (Split-Path -Parent $tools.Cargo) 'rustc.exe'
        if (Test-Path -LiteralPath $rustc -PathType Leaf) { $tools.Rustc = $rustc }
    }
    if (-not $tools.Rustc) { $tools.Missing += 'Rust (cargo and rustc), from https://rustup.rs' }
    $cmake = @(Get-Command -Name 'cmake.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmake.Count -gt 0) {
        $tools.CMake = $cmake[0].Source
    } elseif ($env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe'))) {
        $tools.CMake = Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe'
    } else {
        $tools.Missing += 'CMake, from https://cmake.org'
    }
    $clangDirs = @()
    if ($env:LIBCLANG_PATH) { $clangDirs += $env:LIBCLANG_PATH }
    if ($env:ProgramFiles) { $clangDirs += (Join-Path $env:ProgramFiles 'LLVM\bin') }
    foreach ($d in $clangDirs) {
        if (Test-Path -LiteralPath (Join-Path $d 'libclang.dll') -PathType Leaf) { $tools.LibClang = $d; break }
    }
    if (-not $tools.LibClang) {
        $tools.Missing += 'LLVM, for libclang.dll (https://github.com/llvm/llvm-project/releases), or set LIBCLANG_PATH'
    }
    return $tools
}

function Build-OmnivoxFromSource([string]$Version) {
    $tag = "v$Version"
    $src = Join-Path $OmnivoxDir 'src'
    $script:Hint = "Check the internet connection, and that OmniVox has a release $tag."
    if (Test-Path -LiteralPath (Join-Path $src '.git')) {
        Write-Step "Updating the OmniVox source in $src to $tag"
        Invoke-Logged -What "fetching OmniVox $tag" -FilePath $GitExe -Environment $GitEnv -Arguments @(
            '-C', $src, 'fetch', '-q', '--depth', '1', 'origin', "refs/tags/${tag}:refs/tags/$tag") | Out-Null
        Invoke-Logged -What "checking out OmniVox $tag" -FilePath $GitExe -Environment $GitEnv -Arguments @(
            '-C', $src, 'checkout', '-q', $tag) | Out-Null
    } else {
        Write-Step "Cloning OmniVox $tag into $src"
        Invoke-Logged -What 'cloning OmniVox' -FilePath $GitExe -Environment $GitEnv -Arguments @(
            'clone', '-q', '--depth', '1', '--branch', $tag, "https://github.com/$OmnivoxRepo.git", $src) | Out-Null
    }
    Write-Step "Building OmniVox $Version with cargo (several minutes; it compiles espeak-ng too)"
    $script:Hint = ('Update Rust (rustup update), make sure the Visual Studio C++ build tools ' +
                    'are installed, and rerun; or leave out -OmnivoxSource to use the prebuilt release.')
    $path = (Split-Path -Parent $SourceTools.Cargo) + ';' + (Split-Path -Parent $SourceTools.CMake) + ';' + $env:PATH
    $buildEnv = @{ PATH = $path; LIBCLANG_PATH = $SourceTools.LibClang }
    Invoke-Logged -What 'cargo build' -FilePath $SourceTools.Cargo -Seconds 5400 -Environment $buildEnv -Arguments @(
        'build', '--release', '--manifest-path', (Join-Path $src 'Cargo.toml')) | Out-Null
    Install-OmnivoxFiles (Join-Path $src 'target\release\omnivox.exe') (Join-Path $src 'elisp\omnivox-voices.el')
}

# --------------------------------------------------------------------------
# sharpwin. Its own Makefile runs dotnet build, a framework-dependent build
# that needs its DLLs beside it. Here dotnet publish makes the same
# framework-dependent program as one file, so servers\sharpwin.exe and its
# copy log-sharpwin.exe need nothing else beside them.

# MSBuild reads this after SharpWin.csproj. The project names System.Speech
# without a version, which current NuGet refuses (error NU1015); this
# gives it the version that matches the project's net8.0.
function Get-SharpwinTargetsText {
    $lines = @(
        '<Project>',
        "  <!-- $Marker, which rewrites it on every run. -->",
        '  <!-- SharpWin.csproj names System.Speech without a version, which current',
        '       NuGet refuses (NU1015). This gives it the version for net8.0. -->',
        '  <ItemGroup>',
        '    <PackageReference Update="System.Speech" Version="8.0.0" />',
        '  </ItemGroup>',
        '</Project>'
    )
    return ($lines -join $CRLF) + $CRLF
}

function Install-Sharpwin {
    $src = Join-Path $SharpwinDir 'src'
    $script:Hint = "Check the internet connection. To leave sharpwin out, rerun with -Speech without it."
    if (Test-Path -LiteralPath (Join-Path $src '.git')) {
        Write-Step "Updating the sharpwin source in $src ($SharpwinBranch branch)"
        Invoke-Logged -What 'updating the sharpwin source' -FilePath $GitExe -Environment $GitEnv -Arguments @(
            '-C', $src, 'pull', '-q', '--ff-only', 'origin', $SharpwinBranch) | Out-Null
    } else {
        Write-Step "Cloning sharpwin ($SharpwinBranch branch; it has no release tags) into $src"
        Invoke-Logged -What 'cloning sharpwin' -FilePath $GitExe -Environment $GitEnv -Arguments @(
            'clone', '-q', '--depth', '1', '--branch', $SharpwinBranch, $SharpwinRepo, $src) | Out-Null
    }
    $commit = (Invoke-Logged -What 'reading the sharpwin commit' -FilePath $GitExe -Environment $GitEnv `
        -Arguments @('-C', $src, 'rev-parse', 'HEAD')).Output.Trim()
    $commitText = (Invoke-Program -FilePath $GitExe -Arguments @(
        '-C', $src, 'log', '-1', '--format=commit %h of %cd', '--date=short')).Output.Trim()
    Write-Info "sharpwin source: $commitText"
    $want = "$commit $Rid"
    $installed = ''
    if (Test-Path -LiteralPath $SharpwinInstalledFile -PathType Leaf) {
        $installed = ([IO.File]::ReadAllText($SharpwinInstalledFile)).Trim()
    }
    $script:SharpwinText = "$commitText, framework-dependent for $Rid"
    if ($installed -eq $want -and (Test-Path -LiteralPath $SharpwinExe -PathType Leaf) -and
        (Test-Path -LiteralPath $LogSharpwinExe -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $SharpwinDir 'elisp\win-voices.el') -PathType Leaf)) {
        Write-Info 'This sharpwin is already built and installed; keeping it.'
        return
    }
    Write-Step "Building sharpwin for $Rid with the .NET SDK $($Dotnet.Version) (a minute or two)"
    $script:Hint = ('NuGet needs the internet to fetch NAudio, NVorbis and System.Speech. The ' +
                    "lines above name the problem; to leave sharpwin out, rerun with -Speech without it.")
    $targets = Join-Path $SharpwinDir 'sharpwin-build.targets'
    [IO.File]::WriteAllText($targets, (Get-SharpwinTargetsText), $Utf8NoBom)
    $publish = Join-Path $SharpwinDir 'publish'
    # NuGet's packages and dotnet's own files stay in the prefix, and no
    # build server outlives the build. RollForward=Major lets the program
    # run on .NET 9 or newer when .NET 8 itself is not installed.
    $buildEnv = $DotnetEnv.Clone()
    $buildEnv['NUGET_PACKAGES'] = Join-Path $SharpwinDir 'nuget-packages'
    $buildEnv['NUGET_HTTP_CACHE_PATH'] = Join-Path $SharpwinDir 'nuget-http-cache'
    $buildEnv['DOTNET_CLI_HOME'] = Join-Path $SharpwinDir 'dotnet-home'
    $buildEnv['MSBUILDDISABLENODEREUSE'] = '1'
    Invoke-Logged -What 'dotnet publish of sharpwin' -FilePath $Dotnet.Exe -Seconds 1800 -Environment $buildEnv -Arguments @(
        'publish', (Join-Path $src 'SharpWin.csproj'), '--nologo', '-c', 'Release', '-r', $Rid,
        '--self-contained', 'false', '-p:PublishSingleFile=true', '-p:RollForward=Major',
        "-p:CustomAfterMicrosoftCommonTargets=$targets", '--disable-build-servers', '-o', $publish) | Out-Null
    $built = Join-Path $publish 'SharpWin.exe'
    $el = Join-Path $src 'win-voices.el'
    if (-not (Test-Path -LiteralPath $built -PathType Leaf) -or -not (Test-Path -LiteralPath $el -PathType Leaf)) {
        Fail ("the sharpwin build finished, but $built or $el is missing; sharpwin's layout may " +
              "have changed. Rerun with -Speech without sharpwin. $(Get-LogRef)")
    }
    $elispDir = Join-Path $SharpwinDir 'elisp'
    New-Item -ItemType Directory -Force -Path $elispDir | Out-Null
    try {
        Copy-Item -LiteralPath $el -Destination (Join-Path $elispDir 'win-voices.el') -Force
        Copy-Item -LiteralPath $built -Destination $SharpwinExe -Force
        # emacspeak lists log-sharpwin too; the same program logs what it
        # reads when it runs under that name.
        Copy-Item -LiteralPath $built -Destination $LogSharpwinExe -Force
    } catch {
        Fail ("could not copy sharpwin into $PrefixPath\servers ($($_.Exception.Message)). " +
              'If emacspeak is running, quit Emacs, then rerun this script.')
    }
    [IO.File]::WriteAllText($SharpwinInstalledFile, $want + $CRLF, $Utf8NoBom)
    Write-Info "Installed $SharpwinExe, and log-sharpwin.exe beside it."
}

# --------------------------------------------------------------------------
# emacspeak's Lisp. make is usually missing on Windows, and make config
# stops at its chmod, so this does what lisp/Makefile does: generate the
# autoloads, then byte-compile each file in its own Emacs, in the order of
# the Makefile's OBJECTS list, with the Makefile's own Emacs options.

$EmacsBatch = @('-batch', '-q', '-no-site-file', '-f', 'package-initialize', '--eval',
                '(setq file-name-handler-alist nil gc-cons-threshold 64000000 load-source-file-function nil)')

# The .el files behind lisp/Makefile's OBJECTS, in order, or $null.
function Get-CompileList([string]$LispDir) {
    $makefile = Join-Path $LispDir 'Makefile'
    if (-not (Test-Path -LiteralPath $makefile -PathType Leaf)) { return $null }
    $text = [regex]::Replace([IO.File]::ReadAllText($makefile), '\\\r?\n', ' ')
    $vars = @{}
    foreach ($line in [regex]::Split($text, '\r?\n')) {
        $m = [regex]::Match($line, '^([A-Z_]+)\s*=\s*(.*)$')
        if ($m.Success) { $vars[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    if (-not $vars.ContainsKey('OBJECTS')) { return $null }
    $files = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($ref in [regex]::Matches($vars['OBJECTS'], '\$\(([A-Z_]+)\)')) {
        $group = $ref.Groups[1].Value
        if (-not $vars.ContainsKey($group)) { continue }
        foreach ($word in ($vars[$group] -split '\s+')) {
            if ($word -match '^[A-Za-z0-9_.+-]+\.elc$' -and -not $seen.ContainsKey($word)) {
                $seen[$word] = $true
                $files.Add($word.Substring(0, $word.Length - 1))
            }
        }
    }
    return , $files
}

function Invoke-ByteCompile([string]$LispDir) {
    $list = Get-CompileList $LispDir
    if ($null -eq $list -or $list.Count -lt 10) {
        Fail ("could not read the list of files to compile from $LispDir\Makefile; its " +
              'format may have changed. Rerun with -NoCompile to run emacspeak from source.')
    }
    $deps = @('-l', (Join-Path $LispDir 'emacspeak-preamble.el'), '-l', (Join-Path $LispDir 'emacspeak-loaddefs.el'))
    $compiled = 0
    $current = 0
    $optedOut = 0
    $missing = @()
    $failed = @()
    foreach ($el in $list) {
        $src = Join-Path $LispDir $el
        $elc = $src + 'c'
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $missing += $el; continue }
        # emacspeak-loaddefs.el, for one, asks not to be compiled; Emacs
        # would skip it and write no .elc.
        if (Select-String -LiteralPath $src -SimpleMatch -Pattern 'no-byte-compile: t' -Quiet) {
            $optedOut++
            continue
        }
        if ((Test-Path -LiteralPath $elc -PathType Leaf) -and
            (Get-Item -LiteralPath $elc).LastWriteTimeUtc -ge (Get-Item -LiteralPath $src).LastWriteTimeUtc) {
            $current++
            continue
        }
        $r = Invoke-Program -FilePath $EmacsExe -WorkingDirectory $LispDir -Seconds 600 `
            -Arguments ($EmacsBatch + $deps + @('-f', 'batch-byte-compile', $el))
        if ($r.Started -and -not $r.TimedOut -and $r.ExitCode -eq 0 -and (Test-Path -LiteralPath $elc)) {
            $compiled++
            if ($compiled % 50 -eq 0) { Write-Info "Compiled $compiled of up to $($list.Count) files so far." }
        } else {
            $failed += $el
        }
    }
    Write-Info "Compiled $compiled files; $current were up to date, and $optedOut ask to stay source."
    if ($missing.Count -gt 0) {
        Write-Warn "the Makefile lists files this clone lacks: $($missing -join ', ')"
    }
    if ($failed.Count -gt 0) {
        Write-Warn ("$($failed.Count) files did not compile and load from source instead: " +
                    "$($failed -join ', '). Their errors are in the log.")
    }
    $script:CompileText = "byte-compiled ($compiled now, $current up to date, $($failed.Count) failed)"
}

# --------------------------------------------------------------------------
# Files this script writes into the prefix.

# The init file has a part for each server installed in the prefix, now or
# by an earlier run, so DTK_PROGRAM can pick any of them.
function Get-InitText {
    $omnivoxThere = Test-Path -LiteralPath (Join-Path $OmnivoxDir 'elisp\omnivox-voices.el') -PathType Leaf
    $sharpwinThere = Test-Path -LiteralPath (Join-Path $SharpwinDir 'elisp\win-voices.el') -PathType Leaf
    $servers = @()
    $paths = @()
    $clauses = @()
    if ($omnivoxThere) {
        $servers += 'omnivox'
        $paths += '(add-to-list ''load-path "' + (ConvertTo-LispPath (Join-Path $OmnivoxDir 'elisp')) + '")'
        $clauses += ' ((string-match "omnivox" dtk-program) (require ''omnivox-voices))'
    }
    if ($sharpwinThere) {
        $servers += 'sharpwin'
        $paths += '(add-to-list ''load-path "' + (ConvertTo-LispPath (Join-Path $SharpwinDir 'elisp')) + '")'
        $clauses += ' ((string-match "sharpwin" dtk-program) (require ''win-voices))'
    }
    $template = @'
;;; emacspeak-init.el --- emacspeak with real speech on Windows  -*- lexical-binding: t; coding: utf-8 -*-
;; @MARKER@, which rewrites it on every run.
;; Load it from your own init file, or copy these settings there.
;; Keep your own settings in emacspeak-local.el beside this file: it is
;; loaded below if it exists, and the script never changes it. The same
;; goes for omnivox-local.el, its older name.

;; DTK_PROGRAM picks the speech server: @SERVERLIST@.
;; Without it, the server is @DEFAULTSERVER@, the first engine chosen.
@ENGINENOTE@
;; A newer .el wins over an older .elc, so a stale compiled file never loads.
(setq load-prefer-newer t)
;; Emacspeak's Lisp, and each server's own Lisp folder.
(add-to-list 'load-path "@LISP@")
@PATHS@
;; Emacspeak runs servers/<server>.exe by name; let Emacs find them.
(add-to-list 'exec-path "@SERVERS@")

(setq dtk-program (or (getenv "DTK_PROGRAM") "@DEFAULTSERVER@"))
@ESPEAKDEFAULT@;; A server's own Lisp loads only when dtk-program names that server,
;; and before emacspeak itself.
(cond
@CLAUSES@)
@LOCALPART@
(load "@OLDLOCAL@" t)
(load "@LOCAL@" t)

;; OmniVox and sharpwin play the auditory icons themselves.
(when (string-match "omnivox\\|sharpwin" dtk-program)
  (setq emacspeak-play-program nil))
;; Native compilation runs in the background; do not pop up its warnings.
(setq native-comp-async-report-warnings-errors 'silent)

(load-file "@SETUP@")
'@
    # Each optional part ends with a newline, or is empty.
    $engineNote = ''
    if ($omnivoxThere) {
        $engineNote = (';; For omnivox, OMNIVOX_ENGINE=espeak gives eSpeak NG voices, and' + $LF +
                       ';; native, or no OMNIVOX_ENGINE at all, the Windows voices.' + $LF)
    }
    $espeakDefault = ''
    if ($Engines[0] -eq 'espeak') {
        $espeakDefault = (';; The first engine chosen is OmniVox''s espeak-ng, so OmniVox speaks' + $LF +
                          ';; with eSpeak NG unless OMNIVOX_ENGINE says otherwise.' + $LF +
                          '(unless (getenv "OMNIVOX_ENGINE") (setenv "OMNIVOX_ENGINE" "espeak"))' + $LF + $LF)
    }
    $localPart = @()
    if ($omnivoxThere) {
        $localPart += @(
            '',
            ';; M-x omnivox switches to OmniVox from any server.',
            '(autoload ''omnivox "omnivox-voices" "Switch speech to OmniVox." t)')
    }
    $localPart += @('', ';; Optional, best kept in emacspeak-local.el:')
    if ($omnivoxThere) {
        $localPart += @(
            ';; M-x customize-group RET omnivox RET lists every OmniVox setting.',
            ';; (setq omnivox-speech-rate 50)   ; 50 is normal speed; higher is faster',
            ';; (setq omnivox-voice-id "...")   ; M-x omnivox-select-voice picks one')
    }
    if ($sharpwinThere) {
        $localPart += @(
            ';; sharpwin reads its volumes from the environment, such as:',
            ';; (setenv "SHARPWIN_VOICE_VOLUME" "100")   ; 0 to 100',
            ';; (setenv "SHARPWIN_SOUND_VOLUME" "1.0")   ; 0 to 1, also SHARPWIN_TONE_VOLUME')
    }
    $text = $template.Replace($CRLF, $LF)
    $text = $text.Replace('@MARKER@', $Marker)
    $text = $text.Replace('@SERVERLIST@', ($servers -join ' or '))
    $text = $text.Replace('@DEFAULTSERVER@', $EngineInfo[$Engines[0]].Server)
    $text = $text.Replace('@ENGINENOTE@', $engineNote)
    $text = $text.Replace('@LISP@', (ConvertTo-LispPath (Join-Path $PrefixPath 'lisp')))
    $text = $text.Replace('@PATHS@', ($paths -join $LF))
    $text = $text.Replace('@SERVERS@', (ConvertTo-LispPath (Join-Path $PrefixPath 'servers')))
    $text = $text.Replace('@ESPEAKDEFAULT@', $espeakDefault)
    $text = $text.Replace('@CLAUSES@', ($clauses -join $LF))
    $text = $text.Replace('@LOCALPART@', ($localPart -join $LF))
    $text = $text.Replace('@OLDLOCAL@', (ConvertTo-LispPath (Join-Path $PrefixPath 'omnivox-local')))
    $text = $text.Replace('@LOCAL@', (ConvertTo-LispPath (Join-Path $PrefixPath 'emacspeak-local')))
    $text = $text.Replace('@SETUP@', (ConvertTo-LispPath (Join-Path $PrefixPath 'lisp\emacspeak-setup.el')))
    return $text + $LF
}

# omnivox-init.el is what earlier runs wrote. Init files and shortcuts may
# still load it, so a rerun turns it into a file that loads the new one.
function Get-OldInitText {
    $template = @'
;;; omnivox-init.el --- the older name of emacspeak-init.el  -*- lexical-binding: t; coding: utf-8 -*-
;; @MARKER@, which rewrites it on every run.
;; The script now writes emacspeak-init.el. This file only loads it, so
;; init files and shortcuts that load omnivox-init.el keep working.
(load-file "@INIT@")
'@
    $text = $template.Replace($CRLF, $LF).Replace('@MARKER@', $Marker)
    return $text.Replace('@INIT@', (ConvertTo-LispPath $InitPath)) + $LF
}

# The self-tests' Lisp. A file, not --eval, so no quoting can go wrong.
function Get-SelfTestText {
    $template = @'
;;; emacspeak-selftest.el --- self-tests of install-emacspeak-windows.ps1  -*- lexical-binding: t; -*-
;; @MARKER@, which rewrites it on every run.
;; Each function prints what it found and exits Emacs: 0 means pass.
;; DTK_PROGRAM, read by the init file, names the server under test.

(defun emacspeak-selftest-load ()
  "Check that emacspeak and the server's own Lisp loaded, and Emacs finds the server."
  (let ((exe (executable-find dtk-program))
        (feature (cond ((string-match "omnivox" dtk-program) 'omnivox-voices)
                       ((string-match "sharpwin" dtk-program) 'win-voices))))
    (princ (format "emacspeak loaded: %s\n" (featurep 'emacspeak)))
    (princ (format "%s loaded: %s\n" feature (and feature (featurep feature))))
    (princ (format "dtk-program: %s\n" dtk-program))
    (princ (format "OMNIVOX_ENGINE: %s\n" (getenv "OMNIVOX_ENGINE")))
    (princ (format "emacspeak-play-program: %S\n"
                   (and (boundp 'emacspeak-play-program) emacspeak-play-program)))
    (princ (format "executable-find %s: %s\n" dtk-program exe))
    (kill-emacs (if (and (featurep 'emacspeak) feature (featurep feature) exe
                         (not (and (boundp 'emacspeak-play-program) emacspeak-play-program)))
                    0 1))))

(defun emacspeak-selftest--run (server args input &optional linger)
  "Start servers/SERVER the way `dtk-make-process' does, with ARGS.
Send INPUT, wait LINGER seconds if given, close the input, wait up
to 30 seconds, print what happened, and exit with 0 when the server
exited with 0."
  (let* ((process-connection-type nil)
         (default-directory (expand-file-name "~/"))
         (program (expand-file-name server emacspeak-servers-directory))
         (output "")
         (proc nil)
         (deadline (+ (float-time) 30)))
    (princ (format "program: %s\n" program))
    (condition-case err
        (setq proc (apply #'start-process "Speaker" nil program args))
      (error (princ (format "start-process failed: %S\n" err))
             (kill-emacs 4)))
    (princ (format "running right after start: %s\n" (process-live-p proc)))
    (set-process-filter proc (lambda (_proc text) (setq output (concat output text))))
    (when input (ignore-errors (process-send-string proc input)))
    (when linger
      (let ((until (+ (float-time) linger)))
        (while (and (process-live-p proc) (< (float-time) until))
          (accept-process-output proc 0.2))))
    (ignore-errors (process-send-eof proc))
    (while (and (process-live-p proc) (< (float-time) deadline))
      (accept-process-output proc 0.5))
    (princ (format "output: %S\n" output))
    (if (process-live-p proc)
        (progn (princ "still running after 30 seconds\n")
               (delete-process proc)
               (kill-emacs 3))
      (princ (format "exit status: %s\n" (process-exit-status proc)))
      (kill-emacs (if (eql 0 (process-exit-status proc)) 0 2)))))

(defun emacspeak-selftest-version ()
  "Start servers/omnivox with --version, which needs no sound."
  (emacspeak-selftest--run "omnivox" '("--version") nil))

(defun emacspeak-selftest-voices ()
  "Start servers/omnivox with --list-voices, which needs no sound.
OMNIVOX_ENGINE in Emacs's environment picks the engine whose voices it lists."
  (princ (format "OMNIVOX_ENGINE: %s\n" (getenv "OMNIVOX_ENGINE")))
  (emacspeak-selftest--run "omnivox" '("--list-voices") nil))

(defun emacspeak-selftest-speak ()
  "Start the server `dtk-program' names as emacspeak does, and send it version.
It speaks once, unless its environment sets its volume to 0."
  (emacspeak-selftest--run dtk-program nil "version\n"))

(defun emacspeak-selftest-speak-and-wait ()
  "Like `emacspeak-selftest-speak', with the input kept open 3 seconds.
emacspeak keeps it open too; a server that speaks in the background,
such as sharpwin, gets the time to speak before it reads the end."
  (emacspeak-selftest--run dtk-program nil "version\n" 3))
'@
    return $template.Replace($CRLF, $LF).Replace('@MARKER@', $Marker) + $LF
}

function Get-LauncherText {
    if ($RunEmacsExe) {
        $run = '"' + $RunEmacsExe + '"'
        $check = ''
    } else {
        # No Emacs was found when this was written: use the one on PATH.
        $run = 'runemacs.exe'
        $check = ('where runemacs.exe >nul 2>nul || (echo emacspeak: runemacs.exe not found. Install ' +
                  'Emacs, then rerun install-emacspeak-windows.ps1. & exit /b 1)' + $CRLF)
    }
    $first = $Engines[0]
    $lines = @(
        '@echo off',
        "rem Emacs with emacspeak. Default speech: $($EngineInfo[$first].Menu).",
        "rem $Marker, which rewrites it on every run.",
        'rem DTK_PROGRAM picks the speech server, and for omnivox, OMNIVOX_ENGINE',
        'rem picks espeak or native voices. -q skips your own init file,',
        'rem so emacspeak always starts the same way.',
        'setlocal',
        "if not defined DTK_PROGRAM set `"DTK_PROGRAM=$($EngineInfo[$first].Server)`""
    )
    if ($first -eq 'espeak') { $lines += 'if not defined OMNIVOX_ENGINE set "OMNIVOX_ENGINE=espeak"' }
    return ($lines -join $CRLF) + $CRLF + $check + $run + ' -q -l "%~dp0emacspeak-init.el" %*' + $CRLF
}

# cmd.exe reads a .cmd file in the console code page, so a path outside
# ASCII is written in that code page.
function Get-CmdEncoding([string]$Text) {
    if ($Text -notmatch '[^\x00-\x7F]') { return [Text.Encoding]::ASCII }
    try {
        return [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    } catch {
        return $Utf8NoBom
    }
}

function Test-WrittenByUs([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    return [bool](Select-String -LiteralPath $Path -SimpleMatch -Pattern $Marker -Quiet)
}

# --------------------------------------------------------------------------
# Opt-in changes outside the prefix.

function Send-SettingChange {
    # Tells running programs, Explorer above all, that the environment changed.
    try {
        if (-not ('EmacspeakInstaller.NativeMethods' -as [type])) {
            Add-Type -Namespace EmacspeakInstaller -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        [void][EmacspeakInstaller.NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    } catch {
        Write-Warn 'could not tell Windows about the change; sign out and back in for it to apply everywhere.'
    }
}

function Set-UserHome {
    $current = [Environment]::GetEnvironmentVariable('HOME', 'User')
    if ($current -and $current -eq $env:USERPROFILE) {
        Write-Info "HOME is already $current for your account."
    } elseif ($current) {
        Write-Warn "HOME is already set to $current for your account; left unchanged."
    } else {
        [Environment]::SetEnvironmentVariable('HOME', $env:USERPROFILE, 'User')
        Write-Info "Set HOME to $env:USERPROFILE for your account. Programs started from now on see it."
    }
}

function Add-UserPath {
    $key = Get-Item -LiteralPath 'HKCU:\Environment'
    $raw = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $kind = 'ExpandString'
    if ($null -ne $key.GetValue('Path', $null)) { $kind = [string]$key.GetValueKind('Path') }
    $entries = @($raw -split ';' | Where-Object { $_ })
    foreach ($e in $entries) {
        if ($e.TrimEnd([char]92) -ieq $PrefixPath) {
            Write-Info "$PrefixPath is already on your PATH."
            return
        }
    }
    $new = (@($entries) + $PrefixPath) -join ';'
    New-ItemProperty -LiteralPath 'HKCU:\Environment' -Name 'Path' -Value $new -PropertyType $kind -Force | Out-Null
    Send-SettingChange
    Write-Info "Added $PrefixPath to your PATH. New windows find the emacspeak command."
}

function New-StartMenuShortcut {
    if (-not $RunEmacsExe) {
        Write-Warn 'no Emacs was found, so no Start menu shortcut was made. Install Emacs and rerun.'
        return $null
    }
    $programs = [Environment]::GetFolderPath('Programs')
    $lnk = Join-Path $programs 'Emacspeak.lnk'
    $shell = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $lnk -PathType Leaf) {
        $old = $shell.CreateShortcut($lnk)
        if (-not ([string]$old.Description).Contains($Marker)) {
            Write-Warn "$lnk exists and was not made by this script; left unchanged."
            return $null
        }
    }
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = $RunEmacsExe
    $s.Arguments = '-q -l "' + $InitPath + '"'
    $s.WorkingDirectory = $env:USERPROFILE
    $s.Description = "Emacs with emacspeak speech. $Marker."
    $s.Save()
    Write-Info "Start menu shortcut: $lnk"
    return $lnk
}

# ==========================================================================
# Options.

$homeDir = $env:USERPROFILE
if ($env:HOME -and $env:HOME -match '^([A-Za-z]:[\\/]|[\\/][\\/])' -and
    (Test-Path -LiteralPath $env:HOME -PathType Container)) {
    $homeDir = $env:HOME
}
$DefaultPrefix = ''
if ($homeDir) { $DefaultPrefix = Join-Path $homeDir '.emacspeak' }
if ($Help) {
    Show-Usage $DefaultPrefix
    exit 0
}
# -Speech omnivox,espeak arrives as one word from cmd.exe, and as two
# from PowerShell; both mean the same.
$SpeechGiven = $PSBoundParameters.ContainsKey('Speech')
$SpeechWords = @((@($Speech) -join ',') -split '[,;\s]+' | Where-Object { $_ })
if ($SpeechWords -contains 'list') {
    Show-SpeechList
    exit 0
}
$Engines = @()
if ($SpeechGiven) { $Engines = ConvertTo-EngineList $SpeechWords }
$OmnivoxVersion = $OmnivoxVersion.TrimStart('v')
if ($OmnivoxVersion -and -not (Test-ValidVersion $OmnivoxVersion)) {
    Fail '-OmnivoxVersion needs a release number such as 1.3.0'
}
if (-not $Prefix) { $Prefix = $DefaultPrefix }
if (-not $Prefix) { Fail 'neither HOME nor USERPROFILE is set, so there is no default prefix. Use -Prefix.' }
if ($Prefix.Contains('"')) { Fail '-Prefix must not contain quotes' }
$PrefixPath = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Prefix))
$PrefixPath = $PrefixPath.TrimEnd([char]92, '/')
if ($PrefixPath -match '^[A-Za-z]:$' -or -not $PrefixPath) { Fail '-Prefix must be a folder, not the root of a drive' }
$ServersList = Join-Path $PrefixPath 'servers\.servers'
$OmnivoxDir = Join-Path $PrefixPath 'omnivox'
$OmnivoxExe = Join-Path $PrefixPath 'servers\omnivox.exe'
$LogOmnivoxExe = Join-Path $PrefixPath 'servers\log-omnivox.exe'
$InstalledFile = Join-Path $OmnivoxDir 'installed-version'
$SharpwinDir = Join-Path $PrefixPath 'sharpwin'
$SharpwinExe = Join-Path $PrefixPath 'servers\sharpwin.exe'
$LogSharpwinExe = Join-Path $PrefixPath 'servers\log-sharpwin.exe'
$SharpwinInstalledFile = Join-Path $SharpwinDir 'installed-commit'
$InitPath = Join-Path $PrefixPath 'emacspeak-init.el'
$OldInitPath = Join-Path $PrefixPath 'omnivox-init.el'
$LocalPath = Join-Path $PrefixPath 'emacspeak-local.el'
$OldLocalPath = Join-Path $PrefixPath 'omnivox-local.el'
$SelfTestPath = Join-Path $PrefixPath 'emacspeak-selftest.el'
$SpeechFile = Join-Path $PrefixPath 'speech-engines'
$Launcher = Join-Path $PrefixPath 'emacspeak.cmd'
$LogFile = Join-Path $PrefixPath 'install-emacspeak-windows.log'
$script:CompileText = 'not byte-compiled (-NoCompile): runs from source, starts slower'
$script:SharpwinText = ''

# ==========================================================================
Add-Log ("install-emacspeak-windows.ps1 started " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + $CRLF)
Write-Step 'Checking the system'
if ($env:OS -ne 'Windows_NT') {
    Fail 'this script is for Windows. For Linux and macOS, use the other installers in this folder.'
}
$os = [Environment]::OSVersion.Version
if ($os.Major -lt 10) { Fail "this needs Windows 10 or 11, and this is Windows $os" }
$psv = $PSVersionTable.PSVersion
$NativeArch = Get-NativeArch
switch ($NativeArch) {
    'AMD64' { $Arch = 'x64' }
    'ARM64' { $Arch = 'arm64' }
    default { Fail "this script supports x64 and ARM64 Windows only, and this computer is $NativeArch." }
}
# The .NET runtime identifier sharpwin is built for.
$Rid = "win-$Arch"
Write-Info "Windows $os on $Arch, PowerShell ${psv}: supported."
if (Test-Path -LiteralPath (Join-Path $PrefixPath '.git')) { Open-Log $LogFile }
Write-Info "Log: $LogFile"

# --------------------------------------------------------------------------
Write-Step 'Choosing the speech engines'
if ($SpeechGiven) {
    Write-Info "Selected with -Speech: $(Get-EngineDisplay $Engines)."
} else {
    $recorded = Read-SpeechRecord
    if ($null -ne $recorded) {
        $Engines = $recorded
        Write-Info "Selected in the last run: $(Get-EngineDisplay $Engines)."
        Write-Info "That choice is kept in $SpeechFile; rerun with -Speech to change it."
    } elseif (Test-Interactive) {
        $Engines = Read-SpeechMenu
        Write-Info "Selected: $(Get-EngineDisplay $Engines)."
    } else {
        $Engines = @($DefaultEngine)
        Write-Info "No -Speech given, and no one to ask: using the default, $($EngineInfo[$DefaultEngine].Display)."
    }
}
$Engines = @($Engines)
$UseOmnivox = ($Engines -contains 'omnivox') -or ($Engines -contains 'espeak')
$UseEspeak = $Engines -contains 'espeak'
$UseSharpwin = $Engines -contains 'sharpwin'
$DefaultServer = $EngineInfo[$Engines[0]].Server
Write-Info "The launcher's default: $($Engines[0]), through the $DefaultServer server."

# --------------------------------------------------------------------------
# Before anything is installed or downloaded: what espeak and sharpwin need.
$EspeakData = $null
$Dotnet = $null
if ($UseEspeak -or $UseSharpwin) {
    Write-Step 'Checking what the chosen speech engines need'
}
if ($UseEspeak) {
    $EspeakData = Find-EspeakData
    if ($null -ne $EspeakData) {
        Write-Info "espeak: eSpeak NG's voice data is in $($EspeakData.Path), found through $($EspeakData.How)."
    } elseif ($OmnivoxSource) {
        Write-Info "espeak: eSpeak NG's voice data comes with OmniVox's source build."
    } else {
        Fail ("espeak needs eSpeak NG's voice data (the espeak-ng-data folder), and none was " +
              "found: OmniVox's Windows zip does not include it. Install eSpeak NG with: winget " +
              "install --exact --id $EspeakWingetId, or with espeak-ng.msi from $EspeakReleases, " +
              'then rerun this script. Or rerun with -Speech without espeak.')
    }
}
if ($UseSharpwin) {
    $Dotnet = Find-DotnetSdk
    if ($null -ne $Dotnet) {
        Write-Info "sharpwin: .NET SDK $($Dotnet.Version), $($Dotnet.Exe)"
    } elseif (-not $SkipDeps) {
        Write-Info "sharpwin: no .NET 8 SDK or newer found; winget installs $DotnetWingetId below."
    } else {
        Fail ("sharpwin needs the .NET 8 SDK or newer, and dotnet --list-sdks lists none. Install " +
              "it with: winget install --exact --id $DotnetWingetId, or from " +
              'https://dotnet.microsoft.com/download/dotnet/8.0, then rerun this script. Or rerun ' +
              'without -SkipDeps to let the script install it, or with -Speech without sharpwin.')
    }
}

# --------------------------------------------------------------------------
$EmacsExe = $null
$EmacsVersion = $null
$GitExe = $null
if ($EmacsPath) {
    Write-Step 'Checking the Emacs given with -EmacsPath'
    $EmacsExe = Resolve-EmacsExe $EmacsPath
    if ($null -eq $EmacsExe) {
        Fail ("-EmacsPath: no emacs.exe at $EmacsPath. Give the full path of emacs.exe, such as " +
              'C:\Program Files\Emacs\emacs-30.2\bin\emacs.exe, or the folder of an unpacked Emacs zip.')
    }
    $EmacsVersion = Get-EmacsVersion $EmacsExe
    if ($null -eq $EmacsVersion) {
        Fail "$EmacsExe does not run in batch mode. Reinstall that Emacs, or pick another with -EmacsPath. $(Get-LogRef)"
    }
    if (-not (Test-NewEnough $EmacsVersion)) {
        Fail "emacspeak needs Emacs $MinEmacs or newer, and $EmacsExe is Emacs $EmacsVersion. Give a newer one."
    }
    Write-Info "Found Emacs $EmacsVersion."
}

if (-not $SkipDeps) {
    if ($null -eq $EmacsExe) {
        Write-Step "Looking for Emacs $MinEmacs or newer"
        $found = Find-Emacs
        if ($null -eq $found) {
            Write-Step "No Emacs $MinEmacs or newer found: installing $EmacsWingetId with winget"
            $r = Install-WithWinget $EmacsWingetId 'GNU Emacs'
            $found = Find-Emacs
            if ($null -eq $found) {
                Show-LogTail
                Fail ("winget did not install a usable Emacs (exit status $($r.ExitCode)). Install " +
                      'GNU Emacs from https://www.gnu.org/software/emacs/download.html, then rerun ' +
                      'with -EmacsPath and the path of its emacs.exe.')
            }
        }
        $EmacsExe = $found.Path
        $EmacsVersion = $found.Version
    }
    if ($null -eq (Find-Git)) {
        Write-Step "No git found: installing $GitWingetId with winget"
        $r = Install-WithWinget $GitWingetId 'Git for Windows'
        if ($null -eq (Find-Git)) {
            Show-LogTail
            Fail ("winget did not install git (exit status $($r.ExitCode)). Install Git for Windows " +
                  'from https://git-scm.com, then rerun this script.')
        }
    }
    if ($UseSharpwin -and $null -eq $Dotnet) {
        Write-Step "No .NET 8 SDK or newer found, which sharpwin needs: installing $DotnetWingetId with winget"
        $r = Install-WithWinget $DotnetWingetId 'the .NET 8 SDK' 'machine'
        $Dotnet = Find-DotnetSdk
        if ($null -eq $Dotnet) {
            Show-LogTail
            Fail ("winget did not install the .NET 8 SDK (exit status $($r.ExitCode)). Install it " +
                  'from https://dotnet.microsoft.com/download/dotnet/8.0, then rerun this script; ' +
                  'or rerun with -Speech without sharpwin.')
        }
        Write-Info "sharpwin: .NET SDK $($Dotnet.Version), $($Dotnet.Exe)"
    }
}

Write-Step 'Checking Emacs and git'
if ($null -eq $EmacsExe) {
    $found = Find-Emacs
    if ($null -ne $found) {
        $EmacsExe = $found.Path
        $EmacsVersion = $found.Version
    }
}
$RunEmacsExe = $null
if ($null -ne $EmacsExe) {
    Write-Info "Emacs ${EmacsVersion}: new enough. Using $EmacsExe"
    $candidate = Join-Path (Split-Path -Parent $EmacsExe) 'runemacs.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $RunEmacsExe = $candidate
    } else {
        Write-Warn "no runemacs.exe beside $EmacsExe; the launcher starts emacs.exe instead."
        $RunEmacsExe = $EmacsExe
    }
} else {
    Write-Warn ("no Emacs $MinEmacs or newer found, so the steps that need Emacs are skipped: " +
                'the autoloads, the byte-compiling and the Emacs self-tests. Install Emacs, ' +
                'then rerun this script, with -EmacsPath if Emacs is somewhere unusual.')
}
$GitExe = Find-Git
if ($null -eq $GitExe) {
    Fail 'git not found. Install Git for Windows from https://git-scm.com, or rerun without -SkipDeps.'
}
$gitVersion = (Invoke-Program -FilePath $GitExe -Arguments @('--version') -Seconds 60).Output.Trim()
Write-Info "Git: $gitVersion, $GitExe"
$SourceTools = $null
if ($OmnivoxSource -and -not $UseOmnivox) {
    Write-Warn '-OmnivoxSource does nothing this time: neither omnivox nor espeak was chosen.'
}
if ($OmnivoxSource -and $UseOmnivox) {
    $SourceTools = Find-SourceTools
    if ($SourceTools.Missing.Count -gt 0) {
        foreach ($m in $SourceTools.Missing) { Write-Info "Missing for -OmnivoxSource: $m" }
        Fail ('-OmnivoxSource needs Rust, CMake, LLVM and the Visual Studio C++ build tools, ' +
              'which this script does not install. Install the missing ones listed above, or ' +
              'leave out -OmnivoxSource to use the prebuilt release.')
    }
    $rustText = (Invoke-Program -FilePath $SourceTools.Rustc -Arguments @('--version') -Seconds 60).Output.Trim()
    $m = [regex]::Match($rustText, '^rustc 1\.([0-9]+)')
    if (-not $m.Success -or [int]$m.Groups[1].Value -lt 70) {
        Fail "OmniVox needs Rust 1.70 or newer, and this is: $rustText. Update it: rustup update"
    }
    Write-Info "For -OmnivoxSource: $rustText, CMake, and libclang in $($SourceTools.LibClang)."
}

# --------------------------------------------------------------------------
$OldHead = ''
$script:Hint = ("Check the internet connection and the -Repo and -Ref values. For an update, " +
                "also undo your own changes in $PrefixPath (git -C $PrefixPath status).")
if (Test-Path -LiteralPath (Join-Path $PrefixPath '.git')) {
    Write-Step "Updating emacspeak in $PrefixPath from $Repo ($Ref)"
    # Undo this script's change to servers\.servers first, so git sees an
    # unmodified file. The names are added back after the update.
    Unregister-Omnivox
    $OldHead = (Invoke-Logged -What 'reading the current commit' -FilePath $GitExe -Environment $GitEnv `
        -Arguments @('-C', $PrefixPath, 'rev-parse', 'HEAD')).Output.Trim()
    Invoke-Logged -What "updating the clone in $PrefixPath" -FilePath $GitExe -Environment $GitEnv `
        -Arguments @('-C', $PrefixPath, 'pull', '-q', '--ff-only', $Repo, $Ref) | Out-Null
    if ($UseOmnivox -or (Test-Path -LiteralPath $OmnivoxExe -PathType Leaf)) { Register-Omnivox }
} elseif ((Test-Path -LiteralPath $PrefixPath) -and
          @(Get-ChildItem -LiteralPath $PrefixPath -Force -ErrorAction SilentlyContinue).Count -gt 0) {
    Fail "$PrefixPath exists but is not a git clone of emacspeak. Move it away or use -Prefix."
} else {
    Write-Step "Cloning emacspeak ($Ref) from $Repo into $PrefixPath"
    Invoke-Logged -What 'git clone' -FilePath $GitExe -Environment $GitEnv `
        -Arguments @('clone', '-q', '--depth', '1', '--branch', $Ref, $Repo, $PrefixPath) | Out-Null
    Open-Log $LogFile
}
Add-GitExcludes
$NewHead = (Invoke-Program -FilePath $GitExe -Arguments @('-C', $PrefixPath, 'rev-parse', 'HEAD')).Output.Trim()
$sourceText = (Invoke-Program -FilePath $GitExe -Arguments @(
    '-C', $PrefixPath, 'log', '-1', '--format=commit %h of %cd', '--date=short')).Output.Trim()
Write-Info "Emacspeak source: $sourceText"

$LispDir = Join-Path $PrefixPath 'lisp'
$Loaddefs = Join-Path $LispDir 'emacspeak-loaddefs.el'
if ($null -ne $EmacsExe) {
    $script:Hint = ("The lines above name the Lisp file that failed. Make sure $EmacsExe starts, " +
                    'then rerun; if it still fails, ask on the emacspeak mailing list.')
    if (-not (Test-Path -LiteralPath $Loaddefs -PathType Leaf)) {
        Write-Step "Generating emacspeak's autoloads (emacspeak-loaddefs.el)"
    } elseif ($OldHead -and $OldHead -ne $NewHead) {
        Write-Step "Regenerating emacspeak's autoloads for the new commits"
    } else {
        Write-Step "Emacspeak's autoloads are in place"
    }
    if (-not (Test-Path -LiteralPath $Loaddefs -PathType Leaf) -or ($OldHead -and $OldHead -ne $NewHead)) {
        Invoke-Logged -What 'generating emacspeak-loaddefs.el' -FilePath $EmacsExe -WorkingDirectory $LispDir `
            -Arguments ($EmacsBatch + @('-l', './emacspeak-preamble.el', '-l', './emacspeak-autoload.el',
                                        '-f', 'emacspeak-auto-generate-autoloads')) | Out-Null
        if (-not (Test-Path -LiteralPath $Loaddefs -PathType Leaf)) {
            Fail "Emacs finished, but $Loaddefs is missing. $script:Hint $(Get-LogRef)"
        }
        Write-Info 'Written.'
    } else {
        Write-Info 'emacspeak-loaddefs.el is up to date.'
    }
    if ($NoCompile) {
        Write-Step 'Not byte-compiling emacspeak (-NoCompile): it runs from source'
    } else {
        Write-Step "Byte-compiling emacspeak's Lisp (each file in its own Emacs, a few minutes)"
        Invoke-ByteCompile $LispDir
    }
} else {
    $script:CompileText = 'not set up: no Emacs found'
}

# --------------------------------------------------------------------------
# OmniVox, for omnivox and espeak. When neither is chosen, an OmniVox that
# an earlier run installed stays as it is.
$Installed = ''
if (Test-Path -LiteralPath $InstalledFile -PathType Leaf) {
    $Installed = ([IO.File]::ReadAllText($InstalledFile)).Trim()
}
$RouteText = ''
if (-not $UseOmnivox) {
    if ($Installed) {
        $OmnivoxVersion = ($Installed -split ' ')[0]
        $RouteText = 'as installed by an earlier run, not updated this time'
        Write-Step "OmniVox $Installed stays as it is: neither omnivox nor espeak was chosen"
    }
} else {
    New-Item -ItemType Directory -Force -Path $OmnivoxDir | Out-Null
    Write-Step 'Choosing the OmniVox release'
    # Latest by default, so rerunning this script also updates OmniVox. The
    # checksum file comes from the same release: it catches a damaged download.
    if ($OmnivoxVersion) {
        Write-Info "OmniVox $OmnivoxVersion, as asked with -OmnivoxVersion."
    } else {
        $latest = Get-LatestOmnivoxVersion
        if ($latest) {
            $OmnivoxVersion = $latest
            Write-Info "Latest OmniVox release: $OmnivoxVersion"
        } elseif ($Installed) {
            $OmnivoxVersion = ($Installed -split ' ')[0]
            Write-Warn "could not ask GitHub for the latest OmniVox release; keeping $OmnivoxVersion."
        } else {
            $OmnivoxVersion = $OmnivoxFallback
            Write-Warn "could not ask GitHub for the latest OmniVox release; using $OmnivoxVersion."
        }
    }
    if ($OmnivoxSource) {
        $Want = "$OmnivoxVersion source"
        $RouteText = 'built from source'
    } else {
        $Want = "$OmnivoxVersion windows-$Arch"
        $RouteText = "prebuilt for $Arch, checksum verified"
    }
    if ($Installed -eq $Want -and (Test-Path -LiteralPath $OmnivoxExe -PathType Leaf) -and
        (Test-Path -LiteralPath $LogOmnivoxExe -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $OmnivoxDir 'elisp\omnivox-voices.el') -PathType Leaf)) {
        Write-Info "OmniVox $OmnivoxVersion ($RouteText) is already installed; keeping it."
    } elseif ($OmnivoxSource) {
        Build-OmnivoxFromSource $OmnivoxVersion
    } else {
        Install-PrebuiltOmnivox $OmnivoxVersion
    }

    Write-Step "Registering OmniVox in $ServersList"
    Register-Omnivox
    Write-Info 'Listed: omnivox, log-omnivox.'
}

# --------------------------------------------------------------------------
# sharpwin. emacspeak's servers\.servers already lists sharpwin and
# log-sharpwin, so it is left alone.
if ($UseSharpwin) {
    New-Item -ItemType Directory -Force -Path $SharpwinDir | Out-Null
    Install-Sharpwin
} elseif (Test-Path -LiteralPath $SharpwinExe -PathType Leaf) {
    if (Test-Path -LiteralPath $SharpwinInstalledFile -PathType Leaf) {
        $script:SharpwinText = 'as built by an earlier run, not updated this time'
    }
    Write-Step 'sharpwin stays as it is: it was not chosen this time'
}

# --------------------------------------------------------------------------
Write-Step "Writing $InitPath"
[IO.File]::WriteAllText($InitPath, (Get-InitText), $Utf8NoBom)
[IO.File]::WriteAllText($SelfTestPath, (Get-SelfTestText), $Utf8NoBom)
Write-Info 'Written, with the self-test file emacspeak-selftest.el beside it.'
if ((Test-Path -LiteralPath $OldInitPath -PathType Leaf) -and (Test-WrittenByUs $OldInitPath)) {
    [IO.File]::WriteAllText($OldInitPath, (Get-OldInitText), $Utf8NoBom)
    Write-Info "omnivox-init.el, the init file of earlier runs, now only loads emacspeak-init.el."
}

Write-Step "Writing the launcher $Launcher"
if (-not (Test-WrittenByUs $Launcher)) {
    Fail "$Launcher exists and was not written by this script. Move it away, then rerun."
}
$launcherText = Get-LauncherText
[IO.File]::WriteAllText($Launcher, $launcherText, (Get-CmdEncoding $launcherText))
if ($RunEmacsExe) {
    Write-Info "Launcher written; it starts $RunEmacsExe"
} else {
    Write-Info 'Launcher written; it starts the runemacs.exe on PATH, since no Emacs was found.'
}

$Shortcut = $null
if ($StartMenuShortcut) {
    Write-Step 'Adding Emacspeak to the Start menu (-StartMenuShortcut)'
    $Shortcut = New-StartMenuShortcut
}
if ($SetHome) {
    Write-Step 'Setting HOME for your account (-SetHome)'
    Set-UserHome
}
if ($AddToPath) {
    Write-Step 'Adding the prefix to your PATH (-AddToPath)'
    Add-UserPath
}

# --------------------------------------------------------------------------
# Self-tests: two general ones, then each chosen engine's own, the
# launcher's default first. Only the default engine's last test speaks,
# and only with a sound output device. Without Emacs, the tests that need
# it are skipped. A failure stops the script, except for sharpwin, whose
# failures are warnings: a 2025 report says it fails on some Windows 11
# systems, and the other engines do not depend on it.

function New-TestGroup([string]$Name, [int]$Count) {
    return [pscustomobject]@{
        Name = $Name; Count = $Count; Number = 0; Passed = 0; Warned = @()
        Skipped = (New-Object System.Collections.Specialized.OrderedDictionary)
    }
}

function Start-Test($Group, [string]$Title) {
    $Group.Number++
    if ($Group.Name) {
        $script:TestLabel = "$($Group.Name) self-test $($Group.Number) of $($Group.Count)"
    } else {
        $script:TestLabel = "Self-test $($Group.Number) of $($Group.Count)"
    }
    Write-Step "${script:TestLabel}: $Title"
}

function Complete-Test($Group, [string]$Text) {
    Write-Info "Pass: $Text"
    $Group.Passed++
}

# Skipped test numbers are kept by reason, for one short summary line.
function Skip-Test($Group, [string]$Why) {
    Write-Info "Skipped: $Why."
    $reason = ($Why -split ';')[0]
    if (-not $Group.Skipped.Contains($reason)) { $Group.Skipped[$reason] = @() }
    $Group.Skipped[$reason] = @($Group.Skipped[$reason]) + $Group.Number
}

function Write-TestWarning($Group, [string]$Text) {
    Write-Warn $Text
    $Group.Warned += $Group.Number
}

function Stop-Test([string]$Text) {
    Fail "$script:TestLabel failed: $Text"
}

# Pass, Warning or Skipped, for the summary.
function Get-TestVerdict($Group) {
    if (@($Group.Warned).Count -gt 0) { return 'Warning' }
    if ($Group.Passed -eq 0) { return 'Skipped' }
    return 'Pass'
}

# Such as: all 6 passed. Or: 5 of 6 passed; test 6 skipped, no sound output device.
function Get-TestText($Group) {
    if ($Group.Passed -eq $Group.Count) { return "all $($Group.Count) passed" }
    $notes = @()
    foreach ($n in @($Group.Warned)) { $notes += "test $n warned" }
    foreach ($reason in $Group.Skipped.Keys) {
        $numbers = @($Group.Skipped[$reason])
        if ($numbers.Count -eq 1) {
            $notes += "test $($numbers[0]) skipped, $reason"
        } else {
            $notes += "tests $($numbers -join ', ') skipped, $reason"
        }
    }
    return "$($Group.Passed) of $($Group.Count) passed; " + ($notes -join '; ')
}

# Runs Emacs in batch mode with the init and self-test files, then the
# self-test FUNCTION, with ENVIRONMENT changed as given.
function Invoke-EmacsTest([string]$Function, [hashtable]$Environment, [int]$Seconds = 120) {
    return Invoke-Program -FilePath $EmacsExe -Seconds $Seconds -Environment $Environment `
        -Arguments @('-Q', '--batch', '-l', $InitPath, '-l', $SelfTestPath, '-f', $Function)
}

function Test-ServersListed([string[]]$Names) {
    $listed = Get-ServersNames ([IO.File]::ReadAllText($ServersList))
    foreach ($name in $Names) {
        if ($listed -notcontains $name) { Stop-Test "$ServersList does not list $name. Rerun the script." }
    }
}

function Test-Omnivox {
    $g = $Groups['omnivox']
    # The Windows voices, even when OMNIVOX_ENGINE is set elsewhere.
    $native = @{ DTK_PROGRAM = 'omnivox'; OMNIVOX_ENGINE = 'native' }

    Start-Test $g 'OmniVox reports its version'
    $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--version') -Seconds 30
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Stop-Test "$OmnivoxExe --version did not run. Rerun with -OmnivoxSource to build it here. $(Get-LogRef)"
    }
    $out = $r.Output.Trim()
    if ($out -notmatch '^omnivox [0-9]') {
        Stop-Test "$OmnivoxExe --version printed: $out. Rerun the script."
    }
    Complete-Test $g "$out."

    Start-Test $g 'OmniVox lists the Windows voices'
    $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--list-voices') -Seconds 60 -Environment $native
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Stop-Test "$OmnivoxExe --list-voices did not finish. $SpeechFix $(Get-LogRef)"
    }
    $m = [regex]::Match($r.Output + $LF + $r.ErrorOutput, '(?m)^Found ([0-9]+) voices')
    if (-not $m.Success -or [int]$m.Groups[1].Value -lt 1) {
        Stop-Test "OmniVox found no voices. $SpeechFix"
    }
    Complete-Test $g "$($m.Groups[1].Value) voices."

    Start-Test $g "OmniVox's own check synthesizes speech"
    if ($NoSound) {
        Skip-Test $g $NoSoundReason
    } else {
        Write-Info 'With a sound device, you may hear a tone and: Omnivox is ready.'
        $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--check') -Seconds 120 -Environment $native
        if (-not $r.Started -or $r.TimedOut) {
            Stop-Test "$OmnivoxExe --check did not finish. $SpeechFix $(Get-LogRef)"
        }
        $report = $r.Output + $LF + $r.ErrorOutput
        if ($report -notmatch 'Status: OK - ') {
            Stop-Test "OmniVox could not synthesize speech. $SpeechFix Its report is in the log. $(Get-LogRef)"
        }
        $script:Sound = $report -match 'Audio device: OK'
        if ($script:Sound) {
            Complete-Test $g 'speech synthesized, and a sound output device was found.'
        } else {
            Complete-Test $g 'speech synthesized. No sound output device was found.'
        }
    }

    Start-Test $g 'Emacs loads the init file and finds OmniVox (no speech)'
    if ($null -eq $EmacsExe) {
        Skip-Test $g 'no Emacs found'
    } else {
        $r = Invoke-EmacsTest 'emacspeak-selftest-load' $native 300
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
            Show-LogTail
            Stop-Test ("Emacs could not load $InitPath, or emacspeak does not find " +
                       "$OmnivoxExe. Rerun the script to rebuild both. $(Get-LogRef)")
        }
        Complete-Test $g 'emacspeak and omnivox-voices load, and Emacs finds omnivox.exe.'
    }

    Start-Test $g 'Emacs starts servers/omnivox by its bare name, as emacspeak does (no speech)'
    if ($null -eq $EmacsExe) {
        Skip-Test $g 'no Emacs found'
    } else {
        $r = Invoke-EmacsTest 'emacspeak-selftest-version' $native
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $r.Output -notmatch 'output: "omnivox [0-9]') {
            Show-LogTail
            Stop-Test ("Emacs's start-process could not run $PrefixPath\servers\omnivox " +
                       "without its .exe, which is how emacspeak starts its server. Report this to the " +
                       "maintainers of this script with the log. $(Get-LogRef)")
        }
        Complete-Test $g 'start-process ran servers/omnivox, which is omnivox.exe, and it printed its version.'
    }

    Start-Test $g 'OmniVox is registered in servers\.servers'
    Test-ServersListed @('omnivox', 'log-omnivox')
    if (-not (Test-Path -LiteralPath $LogOmnivoxExe -PathType Leaf)) {
        Stop-Test "$LogOmnivoxExe is missing. Rerun the script."
    }
    Complete-Test $g 'omnivox and log-omnivox are listed, and log-omnivox.exe is there.'

    if ($Engines[0] -eq 'omnivox') {
        Start-Test $g 'the OmniVox server speaks, started the way emacspeak starts it'
        if ($NoSound) {
            Skip-Test $g $NoSoundReason
        } elseif ($null -eq $EmacsExe) {
            Skip-Test $g 'no Emacs found'
        } elseif (-not $script:Sound) {
            Skip-Test $g 'no sound output device; connect speakers or headphones, then rerun'
        } else {
            Write-Info "This speaks once. You should hear: Omnivox version $OmnivoxVersion."
            $r = Invoke-EmacsTest 'emacspeak-selftest-speak' $native
            if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
                Show-LogTail
                Stop-Test ("the server did not start or exit cleanly. Check the sound " +
                           "output in Settings, System, Sound, then rerun. $(Get-LogRef)")
            }
            Complete-Test $g 'the server spoke its version and exited cleanly.'
        }
    }
}

function Test-Espeak {
    $g = $Groups['espeak']
    $espeakFix = ("Install eSpeak NG 1.52 or newer with: winget install --exact --id $EspeakWingetId, " +
                  "or with espeak-ng.msi from $EspeakReleases, then rerun this script.")

    Start-Test $g "OmniVox finds eSpeak NG's voice data"
    $data = Find-EspeakData
    if ($null -eq $data) {
        Stop-Test "no espeak-ng-data folder was found. $espeakFix"
    }
    $script:EspeakData = $data
    Complete-Test $g "$($data.Path), found through $($data.How)."

    Start-Test $g "OmniVox's espeak-ng engine lists its voices"
    $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--engine', 'espeak', '--list-voices') -Seconds 60
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Stop-Test "$OmnivoxExe --engine espeak --list-voices did not finish. $(Get-LogRef)"
    }
    $m = [regex]::Match($r.Output + $LF + $r.ErrorOutput, '(?m)^Found ([0-9]+) voices')
    if (-not $m.Success -or [int]$m.Groups[1].Value -lt 1 -or $r.Output -notmatch '\[espeak:') {
        Stop-Test "espeak-ng found no voices in $($data.Path); that eSpeak NG may be too old. $espeakFix"
    }
    Complete-Test $g "$($m.Groups[1].Value) voices."

    Start-Test $g 'espeak-ng synthesizes speech into a file (no sound)'
    $wav = Join-Path $OmnivoxDir 'selftest-espeak.wav'
    $r = Invoke-Program -FilePath $OmnivoxExe -Seconds 60 -Arguments @(
        '--engine', 'espeak', '--dump-wav', '', $wav, 'Emacspeak')
    $m = [regex]::Match($r.Output, 'Raw: .*\(([0-9]+) samples')
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or -not $m.Success -or
        [int64]$m.Groups[1].Value -lt 1000) {
        Stop-Test "espeak-ng made no audio. OmniVox's report is in the log. $espeakFix $(Get-LogRef)"
    }
    Complete-Test $g "$($m.Groups[1].Value) samples, in $wav"

    Start-Test $g 'Emacs starts servers/omnivox with OMNIVOX_ENGINE=espeak, and it lists eSpeak NG voices (no speech)'
    Test-ServersListed @('omnivox')
    if ($null -eq $EmacsExe) {
        Skip-Test $g 'no Emacs found'
    } else {
        # As the launcher's default, the init file sets OMNIVOX_ENGINE
        # itself; otherwise it is set before Emacs starts, as people do.
        $environment = @{ DTK_PROGRAM = 'omnivox'; OMNIVOX_ENGINE = 'espeak' }
        $how = 'Emacs passed OMNIVOX_ENGINE=espeak on to servers/omnivox'
        if ($Engines[0] -eq 'espeak') {
            $environment['OMNIVOX_ENGINE'] = $null
            $how = 'the init file set OMNIVOX_ENGINE=espeak for servers/omnivox'
        }
        $r = Invoke-EmacsTest 'emacspeak-selftest-voices' $environment 300
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or
            $r.Output -notmatch '(?m)^OMNIVOX_ENGINE: espeak' -or $r.Output -notmatch '\[espeak:') {
            Show-LogTail
            Stop-Test "Emacs did not start OmniVox with its espeak-ng engine. Rerun the script. $(Get-LogRef)"
        }
        Complete-Test $g "$how, and it listed eSpeak NG voices."
    }

    if ($Engines[0] -eq 'espeak') {
        Start-Test $g 'the OmniVox server speaks with eSpeak NG, started the way emacspeak starts it'
        if (-not $NoSound -and $null -eq $script:Sound) { $script:Sound = Test-SoundOutput }
        if ($NoSound) {
            Skip-Test $g $NoSoundReason
        } elseif ($null -eq $EmacsExe) {
            Skip-Test $g 'no Emacs found'
        } elseif (-not $script:Sound) {
            Skip-Test $g 'no sound output device; connect speakers or headphones, then rerun'
        } else {
            Write-Info "This speaks once, with an eSpeak NG voice. You should hear: Omnivox version $OmnivoxVersion."
            $r = Invoke-EmacsTest 'emacspeak-selftest-speak' @{ DTK_PROGRAM = 'omnivox'; OMNIVOX_ENGINE = $null }
            if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
                Show-LogTail
                Stop-Test ("the server did not start or exit cleanly. Check the sound " +
                           "output in Settings, System, Sound, then rerun. $(Get-LogRef)")
            }
            Complete-Test $g 'the server spoke its version and exited cleanly.'
        }
    }
}

# Whether sharpwin started and exited cleanly. It catches its own errors,
# prints them as lines starting with Error:, and still exits with 0.
function Test-SharpwinRan($Result) {
    return ($Result.Started -and -not $Result.TimedOut -and $Result.ExitCode -eq 0 -and
            $Result.Output -notmatch '(?m)^(output: ")?Error: ')
}

# Explains a sharpwin start that failed, with the first error line.
function Write-SharpwinWarning($Group, $Result) {
    $text = $Result.Output + $LF + $Result.ErrorOutput
    $line = Get-FirstErrorLine $text
    if (-not $line) {
        if ($Result.TimedOut) {
            $line = 'Emacs did not finish within its time limit'
        } elseif ($text -match 'still running after 30 seconds') {
            $line = 'it was still running 30 seconds after its input closed'
        } else {
            $m = [regex]::Match($text, '(?m)^exit status: (\S+)')
            if ($m.Success) { $line = "it exited with status $($m.Groups[1].Value)" }
            else { $line = "Emacs exited with status $($Result.ExitCode)" }
        }
    }
    Write-TestWarning $Group "sharpwin did not start and exit cleanly: $line"
    Write-Info 'A 2025 report says sharpwin fails on some Windows 11 systems,'
    Write-Info 'where System.Speech or audio parts are missing.'
    Write-Info 'Fix: install a Windows voice in Settings, Time and language, Speech.'
    Write-Info 'On an N edition of Windows, also add the Media Feature Pack'
    Write-Info 'in Settings, Apps, Optional features. Then rerun this script.'
    Write-Info "The full output is in $LogFile"
    Write-Info 'The other engines do not depend on sharpwin.'
    if ($Engines[0] -eq 'sharpwin' -and $Engines.Count -gt 1) {
        Write-Info "sharpwin is the launcher's default; rerun with -Speech $($Engines[1]),sharpwin to change that."
    }
}

function Test-Sharpwin {
    $g = $Groups['sharpwin']
    # sharpwin writes an empty debug log into the temporary folder each
    # time it starts; the tests' logs go into the prefix instead.
    $temp = Join-Path $SharpwinDir 'selftest-temp'
    New-Item -ItemType Directory -Force -Path $temp | Out-Null

    Start-Test $g 'sharpwin.exe and log-sharpwin.exe are in place, and servers\.servers lists both'
    foreach ($f in @($SharpwinExe, $LogSharpwinExe)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Stop-Test "$f is missing. Rerun the script." }
    }
    Test-ServersListed @('sharpwin', 'log-sharpwin')
    Complete-Test $g 'both programs are there, and both names are listed.'

    Start-Test $g 'Emacs loads the init file and finds sharpwin (no speech)'
    if ($null -eq $EmacsExe) {
        Skip-Test $g 'no Emacs found'
    } else {
        $r = Invoke-EmacsTest 'emacspeak-selftest-load' @{ DTK_PROGRAM = 'sharpwin' } 300
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
            Show-LogTail
            Stop-Test ("Emacs could not load $InitPath with DTK_PROGRAM=sharpwin, or does not find " +
                       "$SharpwinExe. Rerun the script. $(Get-LogRef)")
        }
        Complete-Test $g 'emacspeak and win-voices load, and Emacs finds sharpwin.exe.'
    }

    $started = $false
    Start-Test $g 'Emacs starts servers/sharpwin by its bare name and sends version, at voice volume 0 (no speech)'
    if ($NoSound) {
        # Volume 0 should keep it silent, but it is a server reading input.
        Skip-Test $g $NoSoundReason
    } elseif ($null -eq $EmacsExe) {
        Skip-Test $g 'no Emacs found'
    } else {
        $silent = @{ DTK_PROGRAM = 'sharpwin'; SHARPWIN_VOICE_VOLUME = '0'; TEMP = $temp; TMP = $temp }
        $r = Invoke-EmacsTest 'emacspeak-selftest-speak-and-wait' $silent
        if (-not (Test-SharpwinRan $r)) {
            Write-SharpwinWarning $g $r
        } else {
            $started = $true
            Complete-Test $g 'sharpwin started, read version, and exited cleanly.'
        }
    }

    if ($Engines[0] -eq 'sharpwin') {
        Start-Test $g 'the sharpwin server speaks, started the way emacspeak starts it'
        if (-not $NoSound -and $null -eq $script:Sound) { $script:Sound = Test-SoundOutput }
        if ($NoSound) {
            Skip-Test $g $NoSoundReason
        } elseif ($null -eq $EmacsExe) {
            Skip-Test $g 'no Emacs found'
        } elseif (-not $started) {
            Skip-Test $g 'sharpwin did not start in the test before'
        } elseif (-not $script:Sound) {
            Skip-Test $g 'no sound output device; connect speakers or headphones, then rerun'
        } else {
            Write-Info 'This speaks once. You should hear sharpwin say its version.'
            $r = Invoke-EmacsTest 'emacspeak-selftest-speak-and-wait' @{ DTK_PROGRAM = 'sharpwin'; TEMP = $temp; TMP = $temp }
            if (-not (Test-SharpwinRan $r)) {
                Write-SharpwinWarning $g $r
            } else {
                Complete-Test $g 'the server spoke its version and exited cleanly.'
            }
        }
    }
}

$SpeechFix = ('Install a voice in Settings, Time and language, Speech, and run this in your own ' +
              'signed-in Windows session, not over a remote shell.')
# $null until a test finds out whether there is a sound output device.
$script:Sound = $null
$NoSoundReason = 'not run with -NoSound, since it can make a sound'
$script:TestLabel = ''
$General = New-TestGroup '' 2
$Groups = @{
    omnivox  = New-TestGroup 'omnivox' (6 + [int]($Engines[0] -eq 'omnivox'))
    espeak   = New-TestGroup 'espeak' (4 + [int]($Engines[0] -eq 'espeak'))
    sharpwin = New-TestGroup 'sharpwin' (3 + [int]($Engines[0] -eq 'sharpwin'))
}
if (-not $NoTest) {
    Start-Test $General "Emacs is $MinEmacs or newer"
    if ($null -eq $EmacsExe) {
        Skip-Test $General 'no Emacs found'
    } else {
        $v = Get-EmacsVersion $EmacsExe
        if ($null -eq $v -or -not (Test-NewEnough $v)) {
            Stop-Test "$EmacsExe is not Emacs $MinEmacs or newer. Install a newer one, or use -EmacsPath."
        }
        Complete-Test $General "Emacs $v."
    }

    Start-Test $General "the launcher is in place, with $($Engines[0]) as its default"
    if (-not (Test-Path -LiteralPath $Launcher -PathType Leaf)) {
        Stop-Test "$Launcher is missing. Rerun the script."
    }
    $text = [IO.File]::ReadAllText($Launcher)
    if (-not $text.Contains("DTK_PROGRAM=$DefaultServer`"") -or
        ($Engines[0] -eq 'espeak' -and -not $text.Contains('OMNIVOX_ENGINE=espeak'))) {
        Stop-Test "$Launcher does not start $($Engines[0]) by default. Rerun the script."
    }
    Complete-Test $General "$Launcher starts $($Engines[0]) by default."

    foreach ($engine in $Engines) {
        switch ($engine) {
            'omnivox' { Test-Omnivox }
            'espeak' { Test-Espeak }
            'sharpwin' { Test-Sharpwin }
        }
    }
}

# --------------------------------------------------------------------------
# A rerun without -Speech installs the same engines again.
[IO.File]::WriteAllText($SpeechFile, (($Engines -join $CRLF) + $CRLF), $Utf8NoBom)

$initLine = '(load-file "' + (ConvertTo-LispPath $InitPath) + '")'
if ($env:HOME) {
    $emacsHome = $env:HOME
} else {
    $emacsHome = $env:APPDATA
}
if ($null -ne $EmacsExe) {
    Write-Step 'Done: emacspeak is installed'
} else {
    Write-Step 'Done, but incomplete: no Emacs found'
}
$omnivoxThere = Test-Path -LiteralPath $OmnivoxExe -PathType Leaf
$sharpwinThere = Test-Path -LiteralPath $SharpwinExe -PathType Leaf
$summary = @("Speech engines, the launcher's default first:")
foreach ($engine in $Engines) {
    $server = $EngineInfo[$engine].Server
    if ($engine -eq 'espeak') { $server = 'omnivox, with OMNIVOX_ENGINE=espeak' }
    if ($NoTest) {
        $summary += "${engine}: Skipped. Server: $server. Self-tests skipped (-NoTest)."
    } else {
        $g = $Groups[$engine]
        $summary += "${engine}: $(Get-TestVerdict $g). Server: $server. Self-tests: $(Get-TestText $g)."
    }
}
if ($NoTest) {
    $summary += 'Other self-tests: skipped (-NoTest).'
} else {
    $summary += "Other self-tests: $(Get-TestText $General)."
}
$defaultText = "DTK_PROGRAM=$DefaultServer"
if ($Engines[0] -eq 'espeak') { $defaultText += ' and OMNIVOX_ENGINE=espeak' }
$summary += @(
    "Launcher's default: $($Engines[0]), that is $defaultText.",
    "The chosen engines are kept in $SpeechFile",
    "Emacspeak is in $PrefixPath",
    "Its Lisp is $($script:CompileText)."
)
if ($omnivoxThere) {
    $summary += "OmniVox: $OmnivoxVersion, $RouteText, in $PrefixPath\servers"
}
if ($UseEspeak -and $null -ne $script:EspeakData) {
    $summary += "eSpeak NG voice data: $($script:EspeakData.Path)"
}
if ($sharpwinThere) {
    if ($script:SharpwinText) {
        $summary += "sharpwin: $($script:SharpwinText), in $PrefixPath\servers"
    } else {
        $summary += "sharpwin: in $PrefixPath\servers"
    }
}
if ($null -ne $EmacsExe) {
    $summary += "Emacs ${EmacsVersion}: $EmacsExe"
} else {
    $summary += 'Emacs: none found. Install Emacs 29.1 or newer, then rerun this script.'
}
$summary += @(
    "Launcher: $Launcher",
    "Log: $LogFile",
    '',
    'To start it, run the launcher from File Explorer, the Run box,',
    'a Command Prompt or PowerShell:',
    "  $Launcher",
    'It starts Emacs without your own init file (-q), with the',
    "$DefaultServer speech server."
)
if ($Engines[0] -eq 'espeak') {
    $summary[-1] = "$DefaultServer speech server and its espeak-ng engine."
}
$others = @()
if ($omnivoxThere -and $DefaultServer -ne 'omnivox') { $others += 'omnivox' }
if ($sharpwinThere -and $DefaultServer -ne 'sharpwin') { $others += 'sharpwin' }
if ($others.Count -gt 0) {
    $other = $others[0]
    $summary += @(
        "Other speech servers installed: $($others -join ', ').",
        'To start another one, set DTK_PROGRAM first. In a Command Prompt:',
        "  set DTK_PROGRAM=$other",
        "  `"$Launcher`"",
        'In PowerShell:',
        "  `$env:DTK_PROGRAM = '$other'",
        "  & '$Launcher'",
        'Inside Emacs, M-x dtk-select-server switches to another server.'
    )
} else {
    $summary += @(
        'Only this speech server is installed. Rerun with -Speech to add',
        'others; -Speech list describes them. With more than one, set',
        'DTK_PROGRAM=<server> before the launcher picks one, and',
        'M-x dtk-select-server switches inside Emacs.'
    )
}
if ($Engines -contains 'omnivox' -and $Engines -contains 'espeak') {
    $summary += @(
        'OmniVox speaks with the Windows voices or with eSpeak NG.',
        'To pick one before the launcher, in a Command Prompt:',
        '  set OMNIVOX_ENGINE=espeak',
        'or native for the Windows voices. In PowerShell:',
        "  `$env:OMNIVOX_ENGINE = 'espeak'",
        'To switch inside Emacs: M-x setenv RET OMNIVOX_ENGINE RET',
        'espeak RET (or native), then M-x dtk-select-server RET',
        'omnivox RET, which restarts OmniVox with that engine.'
    )
}
$summary += @(
    'To load emacspeak from your own Emacs init file instead, put',
    'this line at the very top of it:',
    "  $initLine",
    "Emacs looks for your init file in $emacsHome\.emacs.d",
    '',
    'NVDA and JAWS speak over emacspeak unless you pause them.',
    'NVDA: press NVDA+Shift+S in the Emacs window for sleep mode',
    '(NVDA+Shift+Z on the laptop layout); press it again to wake NVDA.',
    'JAWS has a similar sleep mode: INSERT+SPACEBAR, then Z.',
    ''
)
if ($omnivoxThere) {
    $summary += @(
        'Speech rate: OmniVox starts at 60, about twice normal speed with',
        'the Windows voices. M-x omnivox-set-rate RET 50 RET is normal',
        'speed, and higher numbers are faster. To keep a rate, put this line',
        '  (setq omnivox-speech-rate 50)',
        'in this file, which the script never changes:',
        "  $LocalPath",
        'To choose a voice in Emacs: M-x omnivox-select-voice',
        'Known OmniVox issue: text after two semicolons may not be spoken.'
    )
} else {
    $summary += @(
        'Keep your own Emacs settings in this file, which the script never changes:',
        "  $LocalPath"
    )
}
if (Test-Path -LiteralPath $OldLocalPath -PathType Leaf) {
    $summary += "Your $OldLocalPath, its older name, is still loaded too."
}
if ($Shortcut) { $summary += @('', "Start menu: Emacspeak, $Shortcut") }
$notUsed = @()
if (-not $AddToPath) {
    $notUsed += @('  -AddToPath puts the prefix on your PATH, so typing emacspeak',
                  '  starts it in any new window.')
}
if (-not $SetHome) {
    $notUsed += @('  -SetHome sets HOME to your profile folder, as OmniVox advises',
                  '  for loading emacspeak from your own init file. Emacs then',
                  '  looks for .emacs.d there instead of in %APPDATA%, so move',
                  '  your .emacs.d there first if you have one.')
}
if (-not $StartMenuShortcut) {
    $notUsed += '  -StartMenuShortcut adds Emacspeak to your Start menu.'
}
if ($notUsed.Count -gt 0) {
    $summary += @('', 'Left unchanged, as by default. Rerun with these to change them:') + $notUsed
}
$summary += @('', 'To update emacspeak and its speech engines later, run this script again.')
foreach ($line in $summary) { Write-Info $line }
exit 0
