<#
.SYNOPSIS
Builds a portable emacspeak stack for Windows in one folder: neomacs,
OmniVox and emacspeak.

.DESCRIPTION
neomacs (https://github.com/eval-exec/neomacs) is a fork of GNU Emacs
with its C core rewritten in Rust and a GPU display. OmniVox
(https://github.com/robertmeta/omnivox) is an emacspeak speech server
written in Rust that speaks with the Windows system voices. Together
they replace emacspeak's Tcl speech servers and Emacs's C core. The
audio desktop itself is EmacsVox (https://github.com/robertmeta/emacsvox),
a fork of emacspeak modernized for Emacs 31 by the OmniVox author;
-EmacspeakRepo tvraman/emacspeak builds upstream emacspeak instead.

The script downloads the latest release of neomacs and of OmniVox,
checks both against the SHA256SUMS files they publish, and downloads a
zip snapshot of EmacsVox or emacspeak from GitHub (no git needed). It
unpacks the parts needed at run time, generates the autoloads and
byte-compiles the Lisp with neomacs, builds a fast-start dump with it
preloaded, and writes an init file and launchers.

Everything lives in one folder, the prefix. HOME points into it, so
nothing in your profile changes: no installs, no administrator rights,
no PATH or registry changes. The folder can move as a whole.

Run it as your normal user, in Windows PowerShell 5.1 or PowerShell 7:
  powershell -ExecutionPolicy Bypass -File scripts\build-emacspeak-stack-windows.ps1
A rerun repairs and re-verifies what is installed; -Update (or
update.cmd in the folder) refreshes everything to the latest.

If emacspeak cannot run on neomacs, the script stops and says what
failed. scripts\install-emacspeak-windows.ps1 then remains the working
route: emacspeak on GNU Emacs.

.PARAMETER Prefix
The stack folder. Default: emacspeak-stack in your profile folder.

.PARAMETER NeomacsVersion
The neomacs release to use, such as 0.0.19. Default: the latest, or on
a rerun without -Update, the one installed.

.PARAMETER OmnivoxVersion
The OmniVox release to use, such as 1.3.0. Default: the latest, or on
a rerun without -Update, the one installed.

.PARAMETER EmacspeakRepo
The GitHub repository of the audio desktop, as owner/name or its URL.
Default: robertmeta/emacsvox, or on a rerun, the one installed.
tvraman/emacspeak builds upstream emacspeak.

.PARAMETER EmacspeakRef
The branch, tag or commit to use. Default: master.

.PARAMETER SetupFile
The setup file in the snapshot's lisp folder that starts the audio
desktop. Default: emacsvox-setup.el when the snapshot has it, otherwise
emacspeak-setup.el. Its name, without -setup.el, is the prefix of the
other core files: emacsvox-preamble.el, emacsvox-autoload.el.

.PARAMETER Update
Refresh neomacs, OmniVox and the emacspeak snapshot to the latest. The
home folder, with your local.el, is kept. Older versions stay in the
folder until you delete them.

.PARAMETER QuietDisplay
Turn off neomacs's cursor, scroll, buffer-switch and window animations.
Later runs keep this choice until -AnimatedDisplay.

.PARAMETER AnimatedDisplay
Turn neomacs's animations back on after -QuietDisplay. This is the
default.

.PARAMETER NoDump
Do not build the fast-start dump; neomacs then loads emacspeak at every
start. Later runs keep this choice until -Dump.

.PARAMETER Dump
Build the fast-start dump again after -NoDump. This is the default.

.PARAMETER NoTest
Skip the self-tests and the startup timing at the end.

.PARAMETER NoSound
Skip only the self-tests that can make a sound: OmniVox's own check,
which plays a tone and speech, and the server speaking its version.

.PARAMETER Help
Show a short usage text.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\build-emacspeak-stack-windows.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\build-emacspeak-stack-windows.ps1 -Prefix D:\emacspeak-stack -QuietDisplay

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\build-emacspeak-stack-windows.ps1 -Update
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Prefix = '',
    [string]$NeomacsVersion = '',
    [string]$OmnivoxVersion = '',
    [string]$EmacspeakRepo = '',
    [string]$EmacspeakRef = '',
    [string]$SetupFile = '',
    [switch]$Update,
    [switch]$QuietDisplay,
    [switch]$AnimatedDisplay,
    [switch]$NoDump,
    [switch]$Dump,
    [switch]$NoTest,
    [switch]$NoSound,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptName = 'build-emacspeak-stack-windows.ps1'
$Marker = "Written by $ScriptName"
$NeomacsRepo = 'eval-exec/neomacs'
$OmnivoxRepo = 'robertmeta/omnivox'
# EmacsVox, the OmniVox author's emacspeak fork for Emacs 31, by default;
# tvraman/emacspeak, upstream emacspeak, when asked for.
$DefaultEmacspeakRepo = 'robertmeta/emacsvox'
$DefaultEmacspeakRef = 'master'
# EmacsVox master does not load: a misplaced paren in emacsvox-speak.el
# asks a question at load time. Its pull request 2 fixes the Lisp and
# passed every self-test here, so the EmacsVox default is pinned to that
# pull request's head until it merges. Lift the pin when it does.
$DefaultEmacsvoxRef = '7f14ecee9044826e4f5a4e578a4287feeb532418'
# The releases this script was written against. They are used only when
# GitHub cannot be asked for the latest release and nothing is installed.
$NeomacsFallback = '0.0.19'
$OmnivoxFallback = '1.3.0'
# emacspeak's own minimum.
$MinEmacs = '29.1'
# The parts of an emacspeak snapshot that emacspeak reads at run time.
# The rest (soundscapes, recorded talks, the blog archive, web pages)
# stays in the downloaded archive.
$EmacspeakRuntime = @('lisp/', 'servers/', 'sounds/', 'etc/', 'xsl/', 'info/', 'media/radio/')
# Archive entries are written only with plain names: letters, digits,
# dot, dash, underscore and plus, in folders separated by slashes.
$SafeEntry = '^[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*/?$'
$StampName = 'stack-unpacked.txt'
$LF = [string][char]10
$CRLF = [string][char]13 + [string][char]10
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
# GNU Emacs reads these; set for a GNU Emacs, they would send neomacs to
# the wrong Lisp and data folders, so neomacs always runs without them.
$GnuEmacsVars = @('EMACSLOADPATH', 'EMACSDATA', 'EMACSDOC', 'EMACSPATH')

# --------------------------------------------------------------------------
# Output and the log. Every line on screen also goes to the log. Until the
# prefix exists the log is kept in memory.
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

# A snapshot whose Lisp asks a question while it loads is broken in
# itself: in batch mode the question reads standard input and fails, and
# an interactive start would ask it at every start, on GNU Emacs too.
function Stop-IfSnapshotAsks([string]$Output, [string]$What) {
    if ($Output -notmatch 'Error reading from stdin') { return }
    $question = ''
    $m = [regex]::Match($Output, '(?m)([^\r\n?]*\?\s*\((yes or no|y or n)\))')
    if ($m.Success) { $question = " It asked: $($m.Groups[1].Value.Trim())" }
    Fail ("$What stopped because a file of the $EmacspeakRepo snapshot asks a question while it " +
          "loads.$question That is a bug in the snapshot, not in neomacs, and GNU Emacs would " +
          'ask it too. Pick another branch or commit with -EmacspeakRef, or upstream emacspeak with ' +
          "-EmacspeakRepo tvraman/emacspeak. $(Get-LogRef)")
}

# For a failure that means emacspeak does not run on this neomacs.
function Stop-NoNeomacs([string]$Text) {
    Fail ("$Text This means $BaseDisplay does not run on neomacs $NeomacsVersion here. The " +
          'plain installer, scripts\install-emacspeak-windows.ps1 in the same repository, ' +
          "installs emacspeak with GNU Emacs and is the working alternative. $(Get-LogRef)")
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
        "Usage: powershell -ExecutionPolicy Bypass -File $ScriptName [options]",
        '',
        'Builds emacspeak on neomacs, with OmniVox speech, in one folder.',
        'Run it as your normal user. Nothing outside the folder changes.',
        '',
        'Options:',
        '  -Prefix DIR            the stack folder',
        "                         (default $DefaultPrefix)",
        '  -NeomacsVersion VER    neomacs release, such as 0.0.19',
        '                         (default: the latest)',
        '  -OmnivoxVersion VER    OmniVox release, such as 1.3.0',
        '                         (default: the latest)',
        '  -EmacspeakRepo REPO    GitHub repository of the audio desktop',
        "                         (default $DefaultEmacspeakRepo;",
        '                         tvraman/emacspeak for upstream)',
        '  -EmacspeakRef REF      branch, tag or commit (default: for',
        '                         EmacsVox the pinned commit 7f14ecee9044,',
        '                         else master)',
        '  -SetupFile FILE        its setup file in lisp (default: the',
        '                         emacsvox-setup.el or emacspeak-setup.el',
        '                         found there)',
        '  -Update                refresh neomacs, OmniVox and emacspeak',
        '                         to the latest; the home folder is kept',
        '  -QuietDisplay          turn neomacs animations off',
        '  -AnimatedDisplay       turn them back on (the default)',
        '  -NoDump                do not build the fast-start dump',
        '  -Dump                  build it again (the default)',
        '  -NoTest                skip the self-tests and the timing',
        '  -NoSound               skip only the self-tests that make sound',
        '  -Help                  show this help',
        '',
        'A rerun without -Update repairs and re-verifies the folder.',
        'Get-Help on this script shows more about each option.'
    )
    foreach ($line in $lines) { Write-Host $line }
}

# --------------------------------------------------------------------------
# Running programs. Windows PowerShell 5.1 mangles quotes in native
# arguments and turns native error output into exceptions, so programs run
# through System.Diagnostics.Process, with their output appended to the log.

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

function New-StartInfo([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [hashtable]$Environment) {
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
    return $psi
}

# Appends a program's output to the log, without terminal color codes.
function Add-OutputLog([string]$Out, [string]$Err) {
    foreach ($text in @($Out, $Err)) {
        if ($text) {
            $plain = [regex]::Replace($text, ([string][char]27) + '\[[0-9;]*[A-Za-z]', '')
            Add-Log $plain
            if (-not $plain.EndsWith($LF)) { Add-Log $CRLF }
        }
    }
}

# Runs a program with its input closed (or given INPUT), stops it after
# SECONDS, and returns its exit status, output and time. Never throws. In
# ENVIRONMENT, a name with the value $null is taken out of the program's
# environment.
function Invoke-Program {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$Seconds = 600,
        [string]$WorkingDirectory = '',
        [string]$InputText = '',
        [hashtable]$Environment = @{},
        [switch]$NoOutputLog
    )
    $psi = New-StartInfo $FilePath $Arguments $WorkingDirectory $Environment
    Add-Log ('> ' + $FilePath + ' ' + $psi.Arguments + $CRLF)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Add-Log ('(could not start: ' + $_.Exception.Message + ')' + $CRLF)
        return [pscustomobject]@{ Started = $false; ExitCode = -1; TimedOut = $false
                                  Output = ''; ErrorOutput = $_.Exception.Message; Milliseconds = 0 }
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
    $watch.Stop()
    $out = ''
    $err = ''
    if ($outTask.Wait(10000)) { $out = $outTask.Result }
    if ($errTask.Wait(10000)) { $err = $errTask.Result }
    $code = -1
    if (-not $timedOut) { $code = $process.ExitCode }
    if ($NoOutputLog) {
        Add-Log ('(its screen output is left out of the log)' + $CRLF)
    } else {
        Add-OutputLog $out $err
    }
    if ($timedOut) { Add-Log ("(stopped after $Seconds seconds)" + $CRLF) }
    Add-Log ("(exit status $code, $([math]::Round($watch.Elapsed.TotalMilliseconds)) ms)" + $CRLF)
    return [pscustomobject]@{ Started = $true; ExitCode = $code; TimedOut = $timedOut
                              Output = $out; ErrorOutput = $err
                              Milliseconds = $watch.Elapsed.TotalMilliseconds }
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

# The environment every neomacs run gets: HOME in the stack, the stack's
# speech server, and none of GNU Emacs's path variables.
function Get-NeomacsEnvironment([hashtable]$Extra = @{}) {
    $e = @{ HOME = $HomeDir; DTK_PROGRAM = 'omnivox'; OMNIVOX_ENGINE = 'native' }
    foreach ($name in $GnuEmacsVars) { $e[$name] = $null }
    foreach ($name in $Extra.Keys) { $e[$name] = $Extra[$name] }
    return $e
}

# The first line of TEXT that reports a failure, without Lisp quoting.
function Get-FirstErrorLine([string]$Text) {
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $plain = ($line -replace '^output: "', '').Trim()
        if ($plain -match 'obsolete') { continue }
        if ($plain -match '(?i)exception|error|fail|void|not found|cannot|could not|missing|panic') { return $plain }
    }
    return ''
}

# --------------------------------------------------------------------------
# The machine.

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

# Whether Windows has a sound output device, asked without making a sound.
function Test-SoundOutput {
    try {
        if (-not ('EmacspeakStack.WinMM' -as [type])) {
            Add-Type -Namespace EmacspeakStack -Name WinMM -MemberDefinition @'
[DllImport("winmm.dll")]
public static extern uint waveOutGetNumDevs();
'@
        }
        return [EmacspeakStack.WinMM]::waveOutGetNumDevs() -gt 0
    } catch {
        return $false
    }
}

function ConvertTo-LispPath([string]$Path) {
    return $Path.Replace([string][char]92, '/')
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($Utf8NoBom.GetBytes($Text))
    } finally {
        $sha.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-ValidVersion([string]$Version) {
    return $Version -match '^[0-9]+\.[0-9]+[0-9A-Za-z.-]*$'
}

# cmd.exe reads a .cmd file in the console code page, so text outside
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

# Writes a file this script owns, unless something else wrote it.
function Write-OwnFile([string]$Path, [string]$Text, $Encoding) {
    if (-not (Test-WrittenByUs $Path)) {
        Fail "$Path exists and was not written by this script. Move it away, then rerun."
    }
    try {
        [IO.File]::WriteAllText($Path, $Text, $Encoding)
    } catch {
        Fail "could not write $Path ($($_.Exception.Message)). If emacspeak is running, quit it, then rerun."
    }
}

# --------------------------------------------------------------------------
# GitHub. The API is asked for release and commit names; a token in
# GH_TOKEN or GITHUB_TOKEN raises its rate limit. Downloads go to
# github.com itself, never with the token.

function Invoke-GitHubApi([string]$Path) {
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $token = $env:GH_TOKEN
    if (-not $token) { $token = $env:GITHUB_TOKEN }
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers -UseBasicParsing -TimeoutSec 30
    } catch {
        $detail = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        Add-Log ("GitHub API $Path : " + $_.Exception.Message + ' ' + $detail + $CRLF)
        if ($detail -match '(?i)rate limit') {
            $script:ApiNote = ('the GitHub API rate limit for this network is used up; it resets within the hour. ' +
                               'A GitHub token in GH_TOKEN or GITHUB_TOKEN raises the limit.')
        }
        return $null
    }
}

# Why the API gave no answer, for a warning, when it is known.
function Get-ApiNote {
    if ($script:ApiNote) { return " Reason: $($script:ApiNote)" }
    return ''
}

# The latest release of REPO, such as 0.0.19, or $null.
function Get-LatestRelease([string]$Repo) {
    $release = Invoke-GitHubApi "repos/$Repo/releases/latest"
    if ($null -eq $release) { return $null }
    $tag = $release.PSObject.Properties['tag_name']
    if ($null -eq $tag) { return $null }
    $v = ([string]$tag.Value).TrimStart('v')
    if (Test-ValidVersion $v) { return $v }
    return $null
}

# The commit REF names in REPO, as @{ Sha; Date }, or $null.
function Get-RefCommit([string]$Repo, [string]$Ref) {
    $c = Invoke-GitHubApi "repos/$Repo/commits/$([uri]::EscapeDataString($Ref))"
    if ($null -eq $c) { return $null }
    $sha = $c.PSObject.Properties['sha']
    if ($null -eq $sha -or ([string]$sha.Value) -notmatch '^[0-9a-f]{40}$') { return $null }
    $date = ''
    try { $date = ([datetime]$c.commit.committer.date).ToUniversalTime().ToString('yyyy-MM-dd') } catch { }
    return @{ Sha = [string]$sha.Value; Date = $date }
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
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -TimeoutSec 900
    } catch {
        Add-Log ($_.Exception.Message + $CRLF)
        Fail "could not download $Url ($($_.Exception.Message)). $script:Hint"
    }
    Move-Item -LiteralPath $part -Destination $Path -Force
    $size = (Get-Item -LiteralPath $Path).Length
    $sizeText = "$([math]::Round($size / 1MB, 1)) MB"
    if ($size -lt 1MB) { $sizeText = "$([math]::Ceiling($size / 1KB)) KB" }
    Write-Info "Downloaded $(Split-Path -Leaf $Path), $sizeText."
}

# The hash a checksum file lists for NAME, or $null. Both "hash  name" and
# the "hash  ./name" of sha256sum ./* are understood.
function Read-ChecksumFile([string]$Path, [string]$Name) {
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $m = [regex]::Match($line.Trim(), '^([0-9A-Fa-f]{64})\s+\*?(?:\./)?(.+)$')
        if ($m.Success -and $m.Groups[2].Value -eq $Name) { return $m.Groups[1].Value.ToLowerInvariant() }
    }
    return $null
}

# Moves damaged downloads aside, so the next run fetches them afresh.
function Set-Aside([string[]]$Paths) {
    foreach ($f in $Paths) {
        if (Test-Path -LiteralPath $f -PathType Leaf) { Move-Item -LiteralPath $f -Destination ($f + '.bad') -Force }
    }
}

# Checks ZIP against the checksum file SUMS and returns its SHA-256.
function Confirm-Checksum([string]$Zip, [string]$Sums, [string]$What) {
    $name = Split-Path -Leaf $Zip
    $expected = Read-ChecksumFile $Sums ($AssetNames[$Zip])
    if ($null -eq $expected) {
        Set-Aside @($Sums)
        Fail ("the checksum list of $What has no line for $($AssetNames[$Zip]), so it cannot be checked. " +
              "Pick another release, or rerun to download the list afresh.")
    }
    $actual = Get-Sha256 $Zip
    if ($actual -ne $expected) {
        Set-Aside @($Zip, $Sums)
        Fail ("checksum mismatch for ${name}: expected $expected, got $actual. The download is damaged " +
              "or was changed. Both files were set aside with .bad added to their names in " +
              "$DownloadsDir. Run the script again to download them afresh.")
    }
    Write-Info "Checksum verified: $name, SHA-256 $actual"
    return $actual
}

# The comment of a zip file: GitHub writes the commit of a snapshot there.
function Get-ZipComment([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $len = [int][Math]::Min(65557, $fs.Length)
        [void]$fs.Seek(-$len, [IO.SeekOrigin]::End)
        $buf = New-Object byte[] $len
        $read = 0
        while ($read -lt $len) {
            $n = $fs.Read($buf, $read, $len - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        for ($i = $len - 22; $i -ge 0; $i--) {
            if ($buf[$i] -eq 0x50 -and $buf[$i + 1] -eq 0x4b -and $buf[$i + 2] -eq 5 -and $buf[$i + 3] -eq 6) {
                $cl = $buf[$i + 20] + 256 * $buf[$i + 21]
                if ($i + 22 + $cl -le $len) { return [Text.Encoding]::ASCII.GetString($buf, $i + 22, $cl) }
            }
        }
    } finally {
        $fs.Dispose()
    }
    return ''
}

# --------------------------------------------------------------------------
# Unpacking. Entries are written straight into their final folder, so
# nothing needs to be removed afterwards. A stamp file records the archive's
# SHA-256 once every file is written. A rerun with the same stamp checks
# that each file is there with its size and rewrites only those that are
# not; without it, every file is written again.

function Test-StartsWithAny([string]$Text, [string[]]$Prefixes) {
    foreach ($p in $Prefixes) {
        if ($Text.StartsWith($p, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Install-ZipContent {
    param(
        [Parameter(Mandatory = $true)][string]$Zip,
        [Parameter(Mandatory = $true)][string]$ZipHash,
        [Parameter(Mandatory = $true)][string]$Dest,
        [string]$Strip = '',
        [string[]]$Include = @(),
        [string[]]$Unchecked = @(),
        [Parameter(Mandatory = $true)][string]$What
    )
    $stamp = Join-Path $Dest $StampName
    $full = $true
    if (Test-Path -LiteralPath $stamp -PathType Leaf) {
        $full = ([IO.File]::ReadAllText($stamp).Trim() -ne $ZipHash)
    }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $destFull = [IO.Path]::GetFullPath($Dest).TrimEnd([char]92) + [string][char]92
    $written = 0
    $files = 0
    $refused = New-Object System.Collections.Generic.List[string]
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if (-not $name.StartsWith($Strip, [StringComparison]::Ordinal)) { $refused.Add($name); continue }
            $rel = $name.Substring($Strip.Length)
            if (-not $rel) { continue }
            if ($Include.Count -gt 0 -and -not (Test-StartsWithAny $rel $Include)) { continue }
            if ($rel -notmatch $SafeEntry -or $rel -match '(^|/)\.\.?(/|$)') { $refused.Add($name); continue }
            $path = [IO.Path]::GetFullPath([IO.Path]::Combine($destFull, $rel.Replace('/', [string][char]92)))
            if (-not $path.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { $refused.Add($name); continue }
            if ($rel.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($path)
                continue
            }
            $files++
            if (-not $full) {
                if ($Unchecked -contains $rel) { continue }
                $fi = New-Object IO.FileInfo $path
                if ($fi.Exists -and $fi.Length -eq $entry.Length) { continue }
                Add-Log ("Missing or changed, written again: $path" + $CRLF)
            }
            $parent = [IO.Path]::GetDirectoryName($path)
            if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
            try {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $true)
            } catch {
                Fail ("could not write $path ($($_.Exception.Message)). If emacspeak or neomacs " +
                      'is running, quit it, then rerun.')
            }
            $written++
        }
    } finally {
        $archive.Dispose()
    }
    if ($refused.Count -gt 0) {
        foreach ($n in $refused) { Add-Log ("Not unpacked, unexpected name: $n" + $CRLF) }
        Write-Warn "$($refused.Count) entries of $What have unexpected names and were not unpacked; they are listed in the log."
    }
    if ($files -eq 0) {
        Fail "$(Split-Path -Leaf $Zip) holds none of the expected files of $What; its layout may have changed. $(Get-LogRef)"
    }
    [IO.File]::WriteAllText($stamp, $ZipHash + $CRLF, $Utf8NoBom)
    if ($full) {
        Write-Info "Unpacked $written files of $What into $Dest"
    } elseif ($written -gt 0) {
        Write-Info "Repaired $What in ${Dest}: $written of $files files were missing or changed, and were written again."
    } else {
        Write-Info "Verified $What in ${Dest}: all $files files are in place."
    }
    return $full
}

# --------------------------------------------------------------------------
# The manifest: one "key: value" line per fact. A rerun reads it back to
# learn what is installed.

function Read-Manifest {
    $values = @{}
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $values }
    foreach ($line in [IO.File]::ReadAllLines($ManifestPath)) {
        $m = [regex]::Match($line, '^([a-z0-9-]+): (.*)$')
        if ($m.Success) { $values[$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
    }
    return $values
}

function Get-Recorded([string]$Key) {
    if ($Recorded.ContainsKey($Key)) { return [string]$Recorded[$Key] }
    return ''
}

function Write-Manifest {
    $lines = @(
        "# emacspeak stack manifest. $Marker, which rewrites it on every run.",
        '# Every version, commit and SHA-256 of what is in this folder.',
        "written: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') local time",
        "prefix: $PrefixPath",
        "architecture: $Arch",
        "neomacs-version: $NeomacsVersion",
        "neomacs-asset: $NeomacsAsset",
        "neomacs-zip-sha256: $NeomacsZipHash",
        "neomacs-sums-sha256: $NeomacsSumsHash",
        "neomacs-exe-sha256: $(Get-Sha256 $NeomacsExe)",
        "neomacs-folder: neomacs\$NeomacsVersion",
        "omnivox-version: $OmnivoxVersion",
        "omnivox-asset: $OmnivoxAsset",
        "omnivox-zip-sha256: $OmnivoxZipHash",
        "omnivox-sums-sha256: $OmnivoxSumsHash",
        "omnivox-exe-sha256: $(Get-Sha256 $OmnivoxExe)",
        "omnivox-folder: omnivox\$OmnivoxVersion",
        "emacspeak-repo: $EmacspeakRepo",
        "emacspeak-ref: $EmacspeakRef",
        "emacspeak-base: $BaseDisplay",
        "emacspeak-setup-file: $SetupName",
        "emacspeak-commit: $EmacspeakCommit",
        "emacspeak-commit-date: $EmacspeakCommitDate",
        "emacspeak-zip: $EmacspeakZipName",
        "emacspeak-zip-sha256: $EmacspeakZipHash",
        "emacspeak-folder: $BaseName\$EmacspeakShort",
        "emacspeak-lisp: $($script:CompileText)",
        "old-style-defadvice-functions: $($script:OldAdvice)",
        "quiet-display: $(if ($QuietDisplayOn) { 'yes' } else { 'no' })",
        "dump: $($script:DumpText)",
        "dump-key: $($script:DumpKeyText)"
    )
    foreach ($k in $script:Timings.Keys) { $lines += "${k}: $($script:Timings[$k])" }
    $lines += "self-tests: $($script:TestSummary)"
    Write-OwnFile $ManifestPath (($lines -join $CRLF) + $CRLF) $Utf8NoBom
}

# --------------------------------------------------------------------------
# emacspeak's Lisp. make is usually missing on Windows, so this does what
# lisp/Makefile does: generate the autoloads, then byte-compile each file in
# its own neomacs, with the Makefile's own options, several at a time.

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

# Runs each job (@{ Name; Arguments }) as its own neomacs, up to JOBS at a
# time, and returns the names of those that failed.
function Invoke-NeomacsJobs([object[]]$Work, [string]$WorkingDirectory, [int]$Jobs, [string]$ProgressWhat) {
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($w in $Work) { $queue.Enqueue($w) }
    $running = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[string]
    $done = 0
    $total = $queue.Count
    $environment = Get-NeomacsEnvironment
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $Jobs -and $queue.Count -gt 0) {
            $w = $queue.Dequeue()
            $psi = New-StartInfo $NeomacsExe $w.Arguments $WorkingDirectory $environment
            try {
                $p = [System.Diagnostics.Process]::Start($psi)
            } catch {
                Add-Log ("> $($w.Name): could not start neomacs: " + $_.Exception.Message + $CRLF)
                $failed.Add($w.Name)
                continue
            }
            try { $p.StandardInput.Close() } catch { }
            $running.Add(@{ Job = $w; Process = $p; Started = [DateTime]::UtcNow
                            Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() })
        }
        [void][Threading.Thread]::Sleep(40)
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $r = $running[$i]
            $p = $r.Process
            if (-not $p.HasExited -and ([DateTime]::UtcNow - $r.Started).TotalSeconds -gt 600) {
                try { $p.Kill() } catch { }
                [void]$p.WaitForExit(10000)
            }
            if (-not $p.HasExited) { continue }
            $p.WaitForExit()
            $out = ''
            $err = ''
            if ($r.Out.Wait(10000)) { $out = $r.Out.Result }
            if ($r.Err.Wait(10000)) { $err = $r.Err.Result }
            Add-Log ("> " + $r.Job.Name + $CRLF)
            Add-OutputLog $out $err
            Add-Log ("(exit status $($p.ExitCode))" + $CRLF)
            if ($p.ExitCode -ne 0 -or -not (& $r.Job.Check)) { $failed.Add($r.Job.Name) }
            $running.RemoveAt($i)
            $done++
            if ($done % 50 -eq 0) { Write-Info "$ProgressWhat`: $done of $total so far." }
        }
    }
    return , $failed.ToArray()
}

function Invoke-ByteCompile([string]$LispDir, [bool]$Force) {
    $list = Get-CompileList $LispDir
    if ($null -eq $list -or $list.Count -lt 10) {
        Write-Warn ("could not read the list of files to compile from $LispDir\Makefile; its format " +
                    "may have changed. $BaseDisplay runs from source, which starts more slowly.")
        $script:CompileText = 'not byte-compiled: the Makefile list was not readable; runs from source'
        return
    }
    $deps = @('-l', (Join-Path $LispDir "$BaseName-preamble.el"), '-l', (Join-Path $LispDir "$BaseName-loaddefs.el"))
    $current = 0
    $optedOut = 0
    $renamed = 0
    $missing = @()
    $work = @()
    foreach ($listed in $list) {
        # EmacsVox renamed emacspeak-X.el to emacsvox-X.el, but its Makefile
        # still lists the old names; the snapshot's own name stands in.
        $el = $listed
        if ($BaseName -ne 'emacspeak' -and $listed.StartsWith('emacspeak-') -and
            -not (Test-Path -LiteralPath (Join-Path $LispDir $listed) -PathType Leaf)) {
            $other = "$BaseName-" + $listed.Substring('emacspeak-'.Length)
            if (Test-Path -LiteralPath (Join-Path $LispDir $other) -PathType Leaf) {
                $el = $other
                $renamed++
            }
        }
        $src = Join-Path $LispDir $el
        $elc = $src + 'c'
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $missing += $el; continue }
        # emacspeak-loaddefs.el, for one, asks not to be compiled.
        if (Select-String -LiteralPath $src -SimpleMatch -Pattern 'no-byte-compile: t' -Quiet) {
            $optedOut++
            continue
        }
        if (-not $Force -and (Test-Path -LiteralPath $elc -PathType Leaf) -and
            (Get-Item -LiteralPath $elc).LastWriteTimeUtc -ge (Get-Item -LiteralPath $src).LastWriteTimeUtc) {
            $current++
            continue
        }
        $target = $elc
        $work += @{ Name = $el; Arguments = ($EmacsBatch + $deps + @('-f', 'batch-byte-compile', $el))
                    Check = [scriptblock]::Create("Test-Path -LiteralPath '$($target.Replace("'", "''"))' -PathType Leaf") }
    }
    $failed = @()
    if ($work.Count -gt 0) {
        Write-Info "Compiling $($work.Count) files, $CompileJobs at a time."
        $watch = [Diagnostics.Stopwatch]::StartNew()
        # The function returns its array as one object; no @() around it.
        $failed = Invoke-NeomacsJobs $work $LispDir $CompileJobs 'Compiled'
        $watch.Stop()
        Write-Info ("Compiled $($work.Count - $failed.Count) files in $([math]::Round($watch.Elapsed.TotalSeconds)) " +
                    "seconds; $current were up to date, and $optedOut ask to stay source.")
    } else {
        Write-Info "All $current compiled files are up to date; $optedOut ask to stay source."
    }
    if ($renamed -gt 0) {
        Write-Info "lisp\Makefile names $renamed files by their emacspeak- names; their $BaseName- files were compiled, in the same order."
    }
    if ($missing.Count -gt 0) {
        Write-Warn "the Makefile lists files this snapshot lacks: $($missing -join ', ')"
    }
    $script:CompileRenamed = $renamed
    $total = $list.Count - $missing.Count - $optedOut
    if ($failed.Count -gt 0) {
        Write-Warn ("$($failed.Count) files did not compile with neomacs and load from source instead: " +
                    "$($failed -join ', '). Their errors are in the log.")
    }
    $script:CompileFailed = $failed.Count
    $script:CompileText = "byte-compiled with neomacs $NeomacsVersion, $($total - $failed.Count) of $total files"
    if ($failed.Count -eq $total) {
        $script:CompileText = 'not byte-compiled: neomacs compiled none of the files; runs from source'
    }
}

# --------------------------------------------------------------------------
# servers\.servers lists the names M-x dtk-select-server offers. OmniVox
# is added under both names its README asks for.

function Register-Omnivox {
    $list = Join-Path $ServersDir '.servers'
    if (-not (Test-Path -LiteralPath $list -PathType Leaf)) {
        Fail "$list is missing from the snapshot; its layout may have changed. $(Get-LogRef)"
    }
    $text = [IO.File]::ReadAllText($list)
    $nl = $LF
    if ($text.Contains($CRLF)) { $nl = $CRLF }
    $names = @([regex]::Split($text, '\r?\n') | ForEach-Object { $_.Trim() })
    $add = ''
    if ($text.Length -gt 0 -and -not $text.EndsWith($LF)) { $add = $nl }
    foreach ($name in @('omnivox', 'log-omnivox')) {
        if ($names -notcontains $name) { $add += $name + $nl }
    }
    if ($add.Trim()) { [IO.File]::AppendAllText($list, $add, $Utf8NoBom) }
}

# Copies omnivox.exe into emacspeak's servers folder under both names,
# unless the copies there are already the same.
function Copy-OmnivoxServer {
    $want = Get-Sha256 $OmnivoxExe
    foreach ($target in @($ServerExe, $LogServerExe)) {
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-Sha256 $target) -eq $want) { continue }
        try {
            Copy-Item -LiteralPath $OmnivoxExe -Destination $target -Force
        } catch {
            Fail "could not copy omnivox.exe to $target ($($_.Exception.Message)). If emacspeak is running, quit it, then rerun."
        }
    }
}

# --------------------------------------------------------------------------
# Files this script writes into the prefix.

function Get-InitText {
    $template = @'
;;; init.el --- @BASEDISPLAY@ on neomacs with OmniVox speech  -*- lexical-binding: t; coding: utf-8 -*-
;; @MARKER@, which rewrites it on every run.
;; Your own settings go in local.el, beside this file. It is loaded
;; just before @BASEDISPLAY@ starts, and the script never changes it.
;; Built from neomacs @NEOMACS@, OmniVox @OMNIVOX@ and @BASEDISPLAY@ commit @COMMIT@.

;;; Where things are. Found from this file, so the folder can move.
(defconst emacspeak-stack-directory
  (file-name-as-directory
   (expand-file-name "../.." (file-name-directory (or load-file-name buffer-file-name))))
  "The stack folder, which holds neomacs, OmniVox, @BASEDISPLAY@ and home.")
(defconst emacspeak-stack--init-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "The folder of this file and of local.el.")
(defconst emacspeak-stack-emacspeak-directory
  (expand-file-name "@SPEAKDIR@/" emacspeak-stack-directory)
  "The @BASEDISPLAY@ snapshot in use.")
(defconst emacspeak-stack-omnivox-directory
  (expand-file-name "omnivox/@OMNIVOX@/" emacspeak-stack-directory)
  "OmniVox's own Lisp, omnivox-voices.")

;; A newer .el wins over an older .elc, so a stale compiled file never loads.
(setq load-prefer-newer t)
;; The compiled preamble calls `cl-proclaim' while it loads.
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name "lisp" emacspeak-stack-emacspeak-directory))
(add-to-list 'load-path emacspeak-stack-omnivox-directory)
@COMPAT@;; servers/omnivox is started by its name; Emacs finds omnivox.exe here.
(add-to-list 'exec-path (expand-file-name "servers" emacspeak-stack-emacspeak-directory))

;; The speech server: DTK_PROGRAM, which the launchers set to omnivox
;; unless it is set already.
(setq dtk-program (or (getenv "DTK_PROGRAM") "omnivox"))
;; OmniVox plays the auditory icons itself.
(setq @BASE@-play-program nil)
;; No splash screen to draw before speech starts.
(setq inhibit-startup-screen t)

;;; Only for the build script's console self-test, which sets
;;; EMACSPEAK_STACK_TEST_OUTPUT: if the start stalls, write what
;;; *Messages* holds to that file after 60 seconds, and exit.
(when (getenv "EMACSPEAK_STACK_TEST_OUTPUT")
  (run-at-time
   60 nil
   (lambda ()
     (with-temp-file (getenv "EMACSPEAK_STACK_TEST_OUTPUT")
       (insert "stalled: t\nmessages:\n"
               (with-current-buffer "*Messages*"
                 (buffer-substring-no-properties (max (point-min) (- (point-max) 4000)) (point-max)))))
     (kill-emacs 9))))

;;; Speech servers on exit. After an interactive session, neomacs @NEOMACS@
;;; leaves the notification server running when it exits; GNU Emacs
;;; ends its subprocesses. This ends them, last of the exit hooks.
(defun emacspeak-stack--end-processes ()
  "Delete every subprocess, so no speech server outlives neomacs."
  (dolist (process (process-list))
    (ignore-errors (delete-process process))))
(add-hook 'kill-emacs-hook #'emacspeak-stack--end-processes 90)

;;; The clipboard. neomacs @NEOMACS@ on Windows has no
;;; `w32-set-clipboard-data', so in the console every kill signals an
;;; error after the text is already in the kill ring, and the speech
;;; that follows a kill never comes. Until neomacs has it, kills stay
;;; inside Emacs whenever the Windows clipboard function is missing.
(defun emacspeak-stack--select-text (select &rest args)
  "Run SELECT with ARGS, ignoring a missing clipboard function."
  (condition-case nil
      (apply select args)
    (void-function nil)))
(when (and (eq system-type 'windows-nt) (not (fboundp 'w32-set-clipboard-data)))
  (advice-add 'gui-select-text :around #'emacspeak-stack--select-text))

;;; Faster start. emacspeak looks up about 25 programs with
;;; `executable-find' while it loads, and on Windows each lookup tries six
;;; suffixes in every folder on PATH: about a second in all. Until startup
;;; ends, lookups use one listing of each folder instead, with the same
;;; answers. EMACSPEAK_STACK_NO_EXEC_CACHE=1 in the environment turns this off.
(defvar emacspeak-stack--exec-cache nil
  "While starting: `exec-path' as listed, and each folder's file names.")

(defun emacspeak-stack--exec-listing ()
  "The listing of `exec-path', made again whenever `exec-path' changes."
  (unless (eq (car emacspeak-stack--exec-cache) exec-path)
    (let ((seen (make-hash-table :test #'equal))
          (dirs nil))
      (dolist (dir exec-path)
        (when (stringp dir)
          (let ((key (downcase (directory-file-name (expand-file-name dir)))))
            (unless (gethash key seen)
              (puthash key t seen)
              (let ((names (make-hash-table :test #'equal)))
                (dolist (name (and (file-directory-p dir)
                                   (ignore-errors (directory-files dir nil nil t))))
                  (puthash (downcase name) t names))
                (push (cons dir names) dirs))))))
      (setq emacspeak-stack--exec-cache (cons exec-path (nreverse dirs)))))
  (cdr emacspeak-stack--exec-cache))

(defun emacspeak-stack--executable-find (find command &optional remote)
  "Look COMMAND up in the startup listing; FIND does any other lookup."
  (if (or remote (file-name-directory command) (file-name-extension command))
      (funcall find command remote)
    (let ((lower (downcase command)))
      (catch 'found
        (dolist (entry (emacspeak-stack--exec-listing))
          (dolist (suffix exec-suffixes)
            (unless (string-empty-p suffix)
              (when (gethash (concat lower (downcase suffix)) (cdr entry))
                (let ((file (expand-file-name (concat command suffix) (car entry))))
                  (when (file-executable-p file)
                    (throw 'found file)))))))
        nil))))

(defun emacspeak-stack--exec-cache-done ()
  "End the startup listing: from now on lookups search PATH as usual."
  (advice-remove 'executable-find #'emacspeak-stack--executable-find)
  (setq emacspeak-stack--exec-cache nil))

(unless (getenv "EMACSPEAK_STACK_NO_EXEC_CACHE")
  (advice-add 'executable-find :around #'emacspeak-stack--executable-find)
  (add-hook 'emacs-startup-hook #'emacspeak-stack--exec-cache-done))

;;; Speech latency. neomacs @NEOMACS@ already uses these values; they are
;;; set here so that a later neomacs following GNU's defaults keeps them.
;; Read the speech server's replies as soon as they arrive.
(setq process-adaptive-read-buffering nil)
;; GNU Emacs on Windows waits 50 ms before reading from a pipe.
(setq w32-pipe-read-delay 0)
(setq read-process-output-max (* 64 1024))

;;; OmniVox's voice list. omnivox-voices.el asks omnivox.exe for its
;;; voices through cmd.exe with 2>/dev/null, which cmd.exe refuses, so on
;;; Windows the list comes back empty. Ask omnivox.exe directly instead,
;;; and only when a command first needs the list, such as
;;; M-x omnivox-select-voice: asking while speech starts costs half a
;;; second or more.
(defvar emacspeak-stack-query-voices-at-startup nil
  "Non-nil asks OmniVox for its voices while speech starts, as omnivox-voices.el does.")
(defvar emacspeak-stack--starting-speech nil
  "Non-nil while OmniVox's setup runs.")

(declare-function omnivox--find-executable "omnivox-voices" ())

(defun emacspeak-stack--omnivox-query-voices ()
  "Return OmniVox's voices, from omnivox.exe --list-voices-alist without a shell."
  (unless (and emacspeak-stack--starting-speech
               (not emacspeak-stack-query-voices-at-startup))
    (let ((exe (omnivox--find-executable)))
      (when exe
        (condition-case nil
            (with-temp-buffer
              (when (eql 0 (call-process exe nil (list t nil) nil "--list-voices-alist"))
                (goto-char (point-min))
                (when (search-forward "(" nil t)
                  (backward-char)
                  (read (current-buffer)))))
          (error nil))))))

(defun emacspeak-stack--omnivox-configure (configure &rest args)
  "Run CONFIGURE, OmniVox's setup, without waiting for the voice list."
  (let ((emacspeak-stack--starting-speech t))
    (apply configure args)))

(with-eval-after-load 'omnivox-voices
  (advice-add 'omnivox-query-voices :override #'emacspeak-stack--omnivox-query-voices)
  (advice-add 'omnivox-configure-tts :around #'emacspeak-stack--omnivox-configure))

;; OmniVox's own Lisp, before emacspeak; it adds omnivox to `tts-multi-engines'.
(require 'omnivox-voices)

;;; Display. neomacs animates the cursor and window changes on the GPU.
;;; -QuietDisplay turns those animations off, and with them scrolling and
;;; buffer-switch transitions; the script writes t or nil below. To keep
;;; the animations whatever the script says, set this to nil in local.el.
(defvar emacspeak-stack-quiet-display nil
  "Non-nil turns off neomacs's cursor, scroll, buffer-switch and window animations.")
(setq emacspeak-stack-quiet-display @QUIET@)

(defun emacspeak-stack-quiet-display ()
  "Turn off neomacs's cursor, scroll, buffer-switch and window animations."
  (interactive)
  (when (require 'neomacs-effects nil t)
    (dolist (setting '((neomacs-cursor-motion-enabled . nil)
                       (neomacs-cursor-size-transition-enabled . nil)
                       (neomacs-buffer-transition-enabled . nil)
                       (neomacs-scroll-transition-enabled . nil)
                       (neomacs-window-animations-off . t)))
      (when (boundp (car setting))
        (customize-set-variable (car setting) (cdr setting)))))
  ;; Newer neomacs releases describe a single profile function.
  (when (fboundp 'neomacs-effects-apply)
    (ignore-errors
      (funcall 'neomacs-effects-apply
               '((cursor-motion :enabled nil)
                 (buffer-transition :enabled nil)
                 (scroll-transition :enabled nil))))))

(defun emacspeak-stack--quiet-display-wanted-p ()
  "Non-nil when the animations should go and a GUI renderer is there to tell.
The console (-nw) has no animations, and loading neomacs-effects there
would only slow the start."
  (and emacspeak-stack-quiet-display
       (or window-system (featurep 'neomacs-effects))))

(defun emacspeak-stack--quiet-display-again ()
  "Repeat the quiet display once the first frame is up, unless local.el said no."
  (when (emacspeak-stack--quiet-display-wanted-p)
    (emacspeak-stack-quiet-display)))

(when (emacspeak-stack--quiet-display-wanted-p)
  (emacspeak-stack-quiet-display))
(when emacspeak-stack-quiet-display
  (add-hook 'window-setup-hook #'emacspeak-stack--quiet-display-again))

;;; Your own settings. Left out while the fast-start dump is made.
(unless (getenv "EMACSPEAK_STACK_DUMPING")
  (load (expand-file-name "local" emacspeak-stack--init-directory) t t))

;;; @BASEDISPLAY@. In batch mode it loads without speaking.
(load-file (expand-file-name "lisp/@SETUP@" emacspeak-stack-emacspeak-directory))
'@
    $text = $template.Replace($CRLF, $LF)
    $text = $text.Replace('@MARKER@', $Marker)
    $text = $text.Replace('@NEOMACS@', $NeomacsVersion)
    $text = $text.Replace('@OMNIVOX@', $OmnivoxVersion)
    $text = $text.Replace('@COMMIT@', $EmacspeakShort)
    $text = $text.Replace('@SPEAKDIR@', "$BaseName/$EmacspeakShort")
    $text = $text.Replace('@BASEDISPLAY@', $BaseDisplay)
    $text = $text.Replace('@BASE@', $BaseName)
    $text = $text.Replace('@SETUP@', $SetupName)
    $compat = ''
    if ($BaseName -ne 'emacspeak') {
        $compat = (";; OmniVox's Lisp requires emacspeak-preamble; tools/compat gives it" + $LF +
                   ";; $BaseDisplay's renamed preamble and variables." + $LF +
                   '(add-to-list ''load-path (expand-file-name "tools/compat" emacspeak-stack-directory))' + $LF)
    }
    $text = $text.Replace('@COMPAT@', $compat)
    if ($QuietDisplayOn) { $quiet = 't' } else { $quiet = 'nil' }
    $text = $text.Replace('@QUIET@', $quiet)
    return $text + $LF
}

# OmniVox's omnivox-voices.el requires emacspeak-preamble and uses
# emacspeak-servers-directory and emacspeak-play-program. On EmacsVox
# this file, named emacspeak-preamble.el, provides those names.
function Get-CompatText {
    $template = @'
;;; emacspeak-preamble.el --- lets OmniVox's Lisp load on @BASEDISPLAY@  -*- lexical-binding: t; coding: utf-8 -*-
;; @MARKER@, which rewrites it on every run.
;; OmniVox's omnivox-voices.el requires emacspeak-preamble and uses two of
;; emacspeak's variables. @BASEDISPLAY@ renamed them from emacspeak- to
;; @BASE@-, so this file loads @BASE@-preamble and gives the old names
;; to the new variables. Nothing else uses it.
(require '@BASE@-preamble)
(defvaralias 'emacspeak-servers-directory '@BASE@-servers-directory)
(defvaralias 'emacspeak-play-program '@BASE@-play-program)
(provide 'emacspeak-preamble)
'@
    $text = $template.Replace($CRLF, $LF).Replace('@MARKER@', $Marker)
    return $text.Replace('@BASEDISPLAY@', $BaseDisplay).Replace('@BASE@', $BaseName) + $LF
}

function Get-LocalText {
    $template = @'
;;; local.el --- your own settings for the emacspeak stack  -*- lexical-binding: t; coding: utf-8 -*-
;; Made once by build-emacspeak-stack-windows.ps1, which never changes it
;; again. init.el loads it just before emacspeak starts.
;; Lines that start with ;; are comments. Remove the ;; to use a setting.

;; Speech rate: 50 is normal speed with the Windows voices, and the
;; default, 60, is faster. M-x omnivox-set-rate changes it for a session.
;; (setq omnivox-speech-rate 50)

;; A voice. M-x omnivox-select-voice lists the installed ones.
;; (setq omnivox-voice-id "en-US:Microsoft David")

;; Ask OmniVox for its voice list while speech starts (a slower start):
;; (setq emacspeak-stack-query-voices-at-startup t)

;; Keep neomacs's animations, even after a run with -QuietDisplay:
;; (setq emacspeak-stack-quiet-display nil)

;; With the fast-start dump, emacspeak is already loaded when this file
;; runs. A setting emacspeak reads while it loads works only after a
;; rerun with -NoDump, or for one start with EMACSPEAK_STACK_NO_DUMP=1.
'@
    return $template.Replace($CRLF, $LF) + $LF
}

# The self-tests' Lisp. A file, not --eval, so no quoting can go wrong.
function Get-SelfTestText {
    $template = @'
;;; selftest.el --- self-tests of build-emacspeak-stack-windows.ps1  -*- lexical-binding: t; -*-
;; @MARKER@, which rewrites it on every run.
;; Loaded after init.el, in batch mode, where @BASEDISPLAY@ loads but does
;; not speak, or in a console start with a silent stand-in speech server.
;; Each function prints what it found and exits: 0 means pass.

(require 'cl-lib)

(defun stack-selftest-load ()
  "Check that @BASEDISPLAY@ and omnivox-voices loaded from this stack."
  (when (fboundp 'emacspeak-stack--exec-cache-done) (emacspeak-stack--exec-cache-done))
  (let* ((exe (executable-find dtk-program))
         (want (file-name-as-directory (expand-file-name emacspeak-stack-emacspeak-directory)))
         (have (and (boundp '@BASE@-directory)
                    (file-name-as-directory (expand-file-name @BASE@-directory))))
         (same (and have (string-equal (downcase want) (downcase have))))
         (play (and (boundp '@BASE@-play-program) @BASE@-play-program)))
    (princ (format "emacs-version: %s\n" emacs-version))
    (princ (format "@BASE@ loaded: %s\n" (featurep '@BASE@)))
    (princ (format "omnivox-voices loaded: %s\n" (featurep 'omnivox-voices)))
    (princ (format "dtk-program: %s\n" dtk-program))
    (princ (format "@BASE@-directory: %s\n" have))
    (princ (format "@BASE@-directory is this stack's: %s\n" same))
    (princ (format "executable-find %s: %s\n" dtk-program exe))
    (princ (format "@BASE@-play-program: %S\n" play))
    (princ (format "omnivox in tts-multi-engines: %s\n"
                   (and (boundp 'tts-multi-engines) (member "omnivox" tts-multi-engines) t)))
    (princ (format "dump file: %s\n"
                   (and (fboundp 'pdumper-stats) (cdr (assq 'dump-file-name (pdumper-stats))))))
    (kill-emacs (if (and (featurep '@BASE@) (featurep 'omnivox-voices) exe same (not play)) 0 1))))

(defun stack-selftest--run (server args input)
  "Start servers/SERVER the way `dtk-make-process' does, with ARGS.
Send INPUT if given, close the input, wait up to 30 seconds, print
what happened, and exit with 0 when the server exited with 0."
  (let* ((process-connection-type nil)
         (default-directory (expand-file-name "~/"))
         (program (expand-file-name server @BASE@-servers-directory))
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
    (ignore-errors (process-send-eof proc))
    (while (and (process-live-p proc) (< (float-time) deadline))
      (accept-process-output proc 0.2))
    (accept-process-output nil 0.1)
    (princ (format "output: %S\n" output))
    (if (process-live-p proc)
        (progn (princ "still running after 30 seconds\n")
               (delete-process proc)
               (kill-emacs 3))
      (princ (format "exit status: %s\n" (process-exit-status proc)))
      (kill-emacs (if (eql 0 (process-exit-status proc)) 0 2)))))

(defun stack-selftest-version ()
  "Start servers/omnivox by its bare name with --version, which needs no sound."
  (stack-selftest--run "omnivox" '("--version") nil))

(defun stack-selftest-voices ()
  "Ask OmniVox for its voices the way init.el makes omnivox-voices ask."
  (let ((voices (omnivox-query-voices)))
    (princ (format "voices: %d\n" (length voices)))
    (dolist (v voices) (princ (format "voice: %s\n" (car v))))
    (kill-emacs (if (> (length voices) 0) 0 1))))

(defun stack-selftest-speak ()
  "Start the server `dtk-program' names as @BASEDISPLAY@ does, and send it version.
It speaks once."
  (stack-selftest--run dtk-program nil "version\n"))

(defun stack-selftest-from-source ()
  "Load every Lisp file from source, for the startup timing."
  (setq load-suffixes '(".el")))

(defun stack-selftest--old-advice ()
  "How many functions carry old-style `defadvice' advice."
  (if (boundp 'ad-advised-functions) (length ad-advised-functions) 0))

(defun stack-selftest--to-spaces ()
  "Put point inside the run of spaces on the second line."
  (forward-line 1) (forward-word 1) (forward-char 1))

(defun stack-selftest-advice ()
  "Load the speech advice, as a start does, and run a few commands.
Speech and auditory icons are counted instead of sent to a server.
Exit with 0 when every command produced speech or an icon, without error."
  (when (fboundp 'emacspeak-stack--exec-cache-done) (emacspeak-stack--exec-cache-done))
  (ems--fastload "@BASE@-advice")
  (princ (format "advice file loaded: %s\n" (featurep '@BASE@-advice)))
  (princ (format "old-style defadvice functions: %d\n" (stack-selftest--old-advice)))
  (let ((bad 0))
    (dolist (test '((next-line . ignore) (forward-word . ignore) (end-of-line . ignore)
                    (kill-line . ignore) (delete-horizontal-space . stack-selftest--to-spaces)))
      (with-temp-buffer
        (insert "first line here\nsecond   line there\nthird line\n")
        (goto-char (point-min))
        (funcall (cdr test))
        (let ((spoken 0) (icons 0) (err nil))
          (cl-letf (((symbol-function 'dtk-speak) (lambda (&rest _) (setq spoken (1+ spoken))))
                    ((symbol-function 'dtk-notify) (lambda (&rest _) (setq spoken (1+ spoken))))
                    ((symbol-function '@BASE@-icon) (lambda (&rest _) (setq icons (1+ icons)))))
            (condition-case e (command-execute (car test)) (error (setq err e))))
          (when (or err (zerop (+ spoken icons))) (setq bad (1+ bad)))
          (princ (format "command %s: spoke %d, icons %d, error %S\n" (car test) spoken icons err)))))
    (kill-emacs (if (zerop bad) 0 1))))

(defun stack-selftest-console ()
  "Report on a console start whose speech server is a silent stand-in.
The stand-in reads what it is sent and prints it when its input closes.
The report goes to the file EMACSPEAK_STACK_TEST_OUTPUT names."
  (let ((lines nil)
        (speaker (and (boundp 'dtk-speaker-process) dtk-speaker-process)))
    (push (format "noninteractive: %s" noninteractive) lines)
    (push (format "advice loaded: %s" (featurep '@BASE@-advice)) lines)
    (push (format "speaker running: %s" (and speaker (process-live-p speaker) t)) lines)
    (push (format "notify running: %s" (and (boundp 'dtk-notify-process) dtk-notify-process
                                            (process-live-p dtk-notify-process) t))
          lines)
    (push (format "old-style defadvice functions: %d" (stack-selftest--old-advice)) lines)
    (when (and speaker (process-live-p speaker))
      (push (format "dtk-speak error: %S" (condition-case e (progn (dtk-speak "stack self test") nil) (error e)))
            lines)
      (with-current-buffer (get-buffer-create "*stack self test*")
        (insert "first line\nsecond line\n")
        (goto-char (point-min))
        (switch-to-buffer (current-buffer))
        (push (format "next-line error: %S" (condition-case e (progn (command-execute 'next-line) nil) (error e)))
              lines))
      (let ((received ""))
        (set-process-filter speaker (lambda (_proc text) (setq received (concat received text))))
        (process-send-eof speaker)
        (let ((deadline (+ (float-time) 15)))
          (while (and (process-live-p speaker) (< (float-time) deadline))
            (accept-process-output speaker 0.2)))
        (push (format "speech lines received: %d"
                      (cl-count-if (lambda (l) (string-prefix-p "q " l)) (split-string received "\n")))
              lines)))
    (with-temp-file (getenv "EMACSPEAK_STACK_TEST_OUTPUT")
      (insert (mapconcat #'identity (nreverse lines) "\n") "\n"))
    (kill-emacs 0)))
'@
    $text = $template.Replace($CRLF, $LF).Replace('@MARKER@', $Marker)
    return $text.Replace('@BASEDISPLAY@', $BaseDisplay).Replace('@BASE@', $BaseName) + $LF
}

function Get-DumpLispText {
    $template = @'
;;; dump.el --- makes the fast-start dump  -*- lexical-binding: t; -*-
;; @MARKER@, which rewrites it on every run.
;; Loaded after init.el in batch mode with EMACSPEAK_STACK_DUMPING set,
;; so local.el is left out. Writes the file EMACSPEAK_STACK_DUMP_FILE names.
(emacspeak-stack--exec-cache-done)
;; The setup file loads its autoloads only outside batch mode.
(load "@BASE@-loaddefs" nil t)
(dump-emacs-portable (getenv "EMACSPEAK_STACK_DUMP_FILE"))
'@
    return $template.Replace($CRLF, $LF).Replace('@MARKER@', $Marker).Replace('@BASE@', $BaseName) + $LF
}

# The lines both launchers share: HOME in the folder, the speech server,
# and the fast-start dump when it was built for this folder.
function Get-LauncherHead([string]$What) {
    $lines = @(
        '@echo off',
        "rem $What",
        "rem $Marker, which rewrites it on every run.",
        'rem HOME is the home folder here, so neomacs reads home\.emacs.d\init.el',
        'rem and keeps its files there; nothing in your profile changes.',
        'setlocal',
        'set "STACK=%~dp0"',
        'set "HOME=%STACK%home"'
    )
    foreach ($name in $GnuEmacsVars) { $lines += "set `"$name=`"" }
    $lines += @(
        'if not defined DTK_PROGRAM set "DTK_PROGRAM=omnivox"',
        'if not defined OMNIVOX_ENGINE set "OMNIVOX_ENGINE=native"',
        'set "DUMP="'
    )
    if ($script:DumpOk) {
        $lines += @(
            'rem The fast-start dump has emacspeak preloaded. It is used only when it',
            'rem was built for this folder; EMACSPEAK_STACK_NO_DUMP=1 skips it.',
            'if defined EMACSPEAK_STACK_NO_DUMP goto start',
            'if not exist "%STACK%dump\emacspeak.pdump" goto start',
            'set "DUMPSTAMP="',
            'set /p DUMPSTAMP=<"%STACK%dump\emacspeak-dump-stamp.txt"',
            "if /i not `"%DUMPSTAMP%`"==`"%STACK%#$($script:DumpKey)`" (",
            '  echo emacspeak: the fast-start dump was built for another folder or version;',
            '  echo starting without it. Run update.cmd here to build it again.',
            '  goto start',
            ')',
            'set DUMP=--dump-file "%STACK%dump\emacspeak.pdump"'
        )
    }
    $lines += ':start'
    return $lines
}

function Get-LauncherText {
    $lines = Get-LauncherHead ("$BaseDisplay on neomacs, with OmniVox speech, in its own window, " +
                               'which has no accessibility tree yet: speech only.')
    $lines += "`"%STACK%neomacs\$NeomacsVersion\runneomacs.exe`" %DUMP% %*"
    return ($lines -join $CRLF) + $CRLF
}

function Get-ConsoleLauncherText {
    $lines = Get-LauncherHead ("$BaseDisplay on neomacs, with OmniVox speech, in this console window, " +
                               'which screen readers and Braille displays can read.')
    $lines += "`"%STACK%neomacs\$NeomacsVersion\neomacs.exe`" -nw %DUMP% %*"
    return ($lines -join $CRLF) + $CRLF
}

function Get-UpdateCmdText {
    $lines = @(
        '@echo off',
        'rem Updates neomacs, OmniVox and emacspeak in this folder to the latest',
        'rem releases and snapshot. The home folder, with local.el, is kept.',
        "rem $Marker, which rewrites it on every run.",
        'rem Options are passed on, such as -NoSound or -QuietDisplay.',
        'setlocal',
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0tools\$ScriptName`" -Prefix `"%~dp0.`" -Update %*",
        'set "STATUS=%ERRORLEVEL%"',
        'if not defined EMACSPEAK_STACK_NO_PAUSE pause',
        'exit /b %STATUS%'
    )
    return ($lines -join $CRLF) + $CRLF
}

function Get-ReadmeText {
    $quietLine = 'Animations: on, as neomacs ships them. Rerun with -QuietDisplay to turn them off.'
    if ($QuietDisplayOn) { $quietLine = 'Animations: off (-QuietDisplay). Rerun with -AnimatedDisplay to turn them on.' }
    $dumpLines = @("Fast-start dump: not built (-NoDump). neomacs loads $BaseDisplay at every start.")
    if ($script:DumpOk) {
        $dumpLines = @(
            'Fast-start dump: dump\emacspeak.pdump, a neomacs image with',
            "$BaseDisplay preloaded. The launchers use it only when it was",
            'built for this folder; after moving the folder, run update.cmd to',
            'build it again. EMACSPEAK_STACK_NO_DUMP=1 skips it for one start.'
        )
    }
    $baseLines = @("The audio desktop is upstream emacspeak, commit $EmacspeakShort.")
    if ($BaseName -eq 'emacsvox') {
        $baseLines = @(
            "The audio desktop is EmacsVox, commit ${EmacspeakShort}: a fork of",
            'emacspeak modernized for Emacs 31 by the author of OmniVox.',
            'The build script with -EmacspeakRepo tvraman/emacspeak builds',
            'upstream emacspeak instead.'
        )
    }
    $lines = @(
        "$BaseDisplay on neomacs, with OmniVox speech",
        "$Marker, which rewrites it on every run.",
        ''
    ) + $baseLines + @(
        '',
        'Start',
        'emacspeak.cmd: neomacs in its own window. Speech only.',
        'emacspeak-console.cmd: neomacs in the console window. Use it when',
        'NVDA, JAWS or a Braille display must read the screen.',
        '',
        'Screen readers and Braille',
        "neomacs's window has no accessibility tree yet. AccessKit support",
        'is planned for neomacs 0.0.21, with no date. Until then NVDA, JAWS',
        "and a Braille display get nothing from that window, and $BaseDisplay's",
        'speech is the whole interface there.',
        'emacspeak-console.cmd runs neomacs as text in the console window,',
        'which screen readers and Braille displays read like any console.',
        'Windows Terminal is a good host for it.',
        "NVDA and JAWS speak over $BaseDisplay unless you pause them.",
        'NVDA: NVDA+Shift+S toggles sleep mode for the focused program',
        '(NVDA+Shift+Z on the laptop layout).',
        'JAWS: INSERT+SPACEBAR, then Z.',
        '',
        'Settings',
        'home\.emacs.d\local.el: your own settings, never changed.',
        'home\.emacs.d\init.el: rewritten on every run.',
        "local.el is loaded just before $BaseDisplay starts.",
        '',
        'Update',
        "update.cmd: the latest neomacs, OmniVox and $BaseDisplay.",
        'The home folder, with local.el, is kept.',
        'A rerun of the script without -Update repairs the folder.',
        'Older versions stay until you delete their folders by hand.',
        '',
        'Speech',
        'OmniVox speaks with the Windows voices. Its rate starts at 60,',
        'faster than normal; (setq omnivox-speech-rate 50) in local.el is',
        'normal speed. M-x omnivox-select-voice picks a voice.',
        'Known OmniVox issue: text after two semicolons may not be spoken.',
        '',
        'Display',
        $quietLine,
        '',
        'Startup'
    ) + $dumpLines + @(
        '',
        'Windows security',
        'neomacs and OmniVox are not code-signed. The script downloads them',
        'itself, so Windows does not mark them as coming from the internet,',
        'and SmartScreen should not stop them. If Windows still shows',
        '"Windows protected your PC" on the first start, choose More info,',
        'then Run anyway. With Smart App Control turned on (Windows 11),',
        'Windows blocks unsigned programs, and the stack cannot start.',
        '',
        'What is where',
        "neomacs\${NeomacsVersion}: neomacs $NeomacsVersion.",
        "omnivox\${OmnivoxVersion}: OmniVox $OmnivoxVersion.",
        "$BaseName\${EmacspeakShort}: $BaseDisplay commit $EmacspeakShort.",
        'home: HOME while it runs.',
        'dump: the fast-start dump.',
        'downloads: the verified downloads.',
        'tools: the build script, for update.cmd, and its Lisp helpers.',
        'manifest.txt: every version, commit and SHA-256.',
        'build.log: the output of the last run.',
        '',
        'Nothing outside this folder was changed. To remove the stack,',
        'delete the folder.',
        '',
        'If it misbehaves on neomacs, which is a work in progress,',
        'scripts\install-emacspeak-windows.ps1 in emacspeak-installer',
        'installs emacspeak with GNU Emacs.'
    )
    return ($lines -join $CRLF) + $CRLF
}

# --------------------------------------------------------------------------
# The fast-start dump: neomacs's own image with emacspeak and
# omnivox-voices loaded on top, written with dump-emacs-portable. The
# launchers pass it with --dump-file.

function Test-StackLoad([string[]]$Before) {
    return Invoke-Program -FilePath $NeomacsExe -Seconds 300 -Environment (Get-NeomacsEnvironment) `
        -Arguments (@('-Q', '--batch') + $Before + @('-l', $InitPath, '-l', $SelfTestPath, '-f', 'stack-selftest-load'))
}

function Build-Dump {
    $script:DumpOk = $false
    $script:DumpKey = "$NeomacsVersion+$EmacspeakShort+$OmnivoxVersion+$((Get-TextSha256 $InitText).Substring(0, 12))"
    $script:DumpKeyText = $script:DumpKey
    # The launchers compare this line with their own folder and this key.
    $stampLine = "$PrefixPath\#$($script:DumpKey)"
    New-Item -ItemType Directory -Force -Path $DumpDir | Out-Null
    if ((Test-Path -LiteralPath $DumpPath -PathType Leaf) -and (Test-Path -LiteralPath $DumpStamp -PathType Leaf) -and
        ([IO.File]::ReadAllText($DumpStamp).Trim() -eq $stampLine)) {
        $r = Test-StackLoad @('--dump-file', $DumpPath)
        if ($r.Started -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
            Write-Info 'The fast-start dump is up to date and loads; keeping it.'
            $script:DumpOk = $true
            $script:DumpText = "dump\emacspeak.pdump, SHA-256 $(Get-Sha256 $DumpPath)"
            return
        }
        Write-Info 'The fast-start dump does not load any more; building it again.'
    }
    $new = Join-Path $DumpDir 'emacspeak-new.pdump'
    $r = Invoke-Program -FilePath $NeomacsExe -Seconds 600 -Environment (Get-NeomacsEnvironment @{
            EMACSPEAK_STACK_DUMPING = '1'; EMACSPEAK_STACK_DUMP_FILE = $new }) `
        -Arguments @('-Q', '--batch', '-l', $InitPath, '-l', $DumpLispPath)
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $new -PathType Leaf)) {
        $line = Get-FirstErrorLine ($r.Output + $LF + $r.ErrorOutput)
        Write-Warn ("neomacs could not write the fast-start dump ($line). $BaseDisplay starts without " +
                    "it, a little more slowly. $(Get-LogRef)")
        $script:DumpText = 'not built: neomacs could not write it'
        return
    }
    $r = Test-StackLoad @('--dump-file', $new)
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Write-Warn "the new fast-start dump does not load $BaseDisplay, so it is not used. $(Get-LogRef)"
        $script:DumpText = 'not used: the new dump did not load emacspeak'
        return
    }
    try {
        Move-Item -LiteralPath $new -Destination $DumpPath -Force
    } catch {
        Write-Warn ("could not replace $DumpPath ($($_.Exception.Message)). If emacspeak is running, " +
                    'quit it and rerun; until then it starts without the dump.')
        $script:DumpText = 'not used: the old dump could not be replaced'
        return
    }
    [IO.File]::WriteAllText($DumpStamp, $stampLine + $CRLF, (Get-CmdEncoding $stampLine))
    $script:DumpOk = $true
    $size = [math]::Round((Get-Item -LiteralPath $DumpPath).Length / 1MB, 1)
    $script:DumpText = "dump\emacspeak.pdump, SHA-256 $(Get-Sha256 $DumpPath)"
    Write-Info "Built and checked $DumpPath ($size MB)."
}

# --------------------------------------------------------------------------
# Startup timing: neomacs in batch mode with the init file, the proxy for
# a real start, which cannot be timed without a window and speech. One
# round runs every variant once; the first round warms the file cache,
# and the median of the next five counts. Taking the variants in turn
# spreads any other load on the computer evenly over them.

function Measure-Startup {
    $runs = 5
    $script:Timings['startup-measured'] = "$(Get-Date -Format 'yyyy-MM-dd HH:mm') local time, with this build"
    $base = @('-Q', '--batch')
    $tail = @('-l', $InitPath, '-f', 'kill-emacs')
    $variants = New-Object System.Collections.Generic.List[object]
    $variants.Add(@{ Key = 'startup-neomacs-alone-ms'; Label = 'neomacs alone, no init file'
                     Arguments = $base + @('-f', 'kill-emacs'); Env = @{} })
    if ($script:DumpOk) {
        $variants.Add(@{ Key = 'startup-dump-ms'; Label = "$BaseDisplay with the fast-start dump, as the launchers start it"
                         Arguments = $base + @('--dump-file', $DumpPath) + $tail; Env = @{} })
    }
    $variants.Add(@{ Key = 'startup-compiled-ms'; Label = "$BaseDisplay byte-compiled, without the dump"
                     Arguments = $base + $tail; Env = @{} })
    $variants.Add(@{ Key = 'startup-no-lookup-cache-ms'; Label = 'the same without the startup program-lookup cache'
                     Arguments = $base + $tail; Env = @{ EMACSPEAK_STACK_NO_EXEC_CACHE = '1' } })
    $variants.Add(@{ Key = 'startup-source-ms'; Label = 'everything loaded from source, without the dump'
                     Arguments = $base + @('-l', $SelfTestPath, '-f', 'stack-selftest-from-source') + $tail; Env = @{} })
    $times = @{}
    $failed = @{}
    foreach ($v in $variants) { $times[$v.Key] = New-Object System.Collections.Generic.List[double] }
    for ($i = 0; $i -le $runs; $i++) {
        foreach ($v in $variants) {
            if ($failed.ContainsKey($v.Key)) { continue }
            $r = Invoke-Program -FilePath $NeomacsExe -Seconds 300 -Arguments $v.Arguments `
                -Environment (Get-NeomacsEnvironment $v.Env)
            if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
                Write-Warn "the timing run for '$($v.Label)' failed; see the log."
                $failed[$v.Key] = $true
                continue
            }
            if ($i -gt 0) { $times[$v.Key].Add($r.Milliseconds) }
        }
    }
    foreach ($v in $variants) {
        if ($failed.ContainsKey($v.Key) -or $times[$v.Key].Count -eq 0) { continue }
        $sorted = @($times[$v.Key] | Sort-Object)
        $median = [math]::Round($sorted[[int][math]::Floor($sorted.Count / 2)])
        $script:Timings[$v.Key] = "$median"
        Write-Info "$median ms: $($v.Label)."
    }
}

# --------------------------------------------------------------------------
# Self-tests, numbered, the silent ones first.

function New-TestGroup([int]$Count) {
    return [pscustomobject]@{
        Count = $Count; Number = 0; Passed = 0; Warned = @()
        Skipped = (New-Object System.Collections.Specialized.OrderedDictionary)
    }
}

function Start-Test($Group, [string]$Title) {
    $Group.Number++
    $script:TestLabel = "Self-test $($Group.Number) of $($Group.Count)"
    Write-Step "${script:TestLabel}: $Title"
}

function Complete-Test($Group, [string]$Text) {
    Write-Info "Pass: $Text"
    $Group.Passed++
}

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

# Such as: all 10 passed. Or: 10 of 12 passed; tests 11, 12 skipped, -NoSound.
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

function Invoke-SelfTestLisp([string]$Function, [hashtable]$Extra = @{}, [int]$Seconds = 300) {
    return Invoke-Program -FilePath $NeomacsExe -Seconds $Seconds -Environment (Get-NeomacsEnvironment $Extra) `
        -Arguments @('-Q', '--batch', '-l', $InitPath, '-l', $SelfTestPath, '-f', $Function)
}

# The stand-in speech server of the console test: a copy of Windows's own
# sort.exe, which reads everything it is sent, says nothing, and prints
# the lines sorted once its input closes. Its name holds "omnivox", so the
# OmniVox setup runs against it as against the real server.
function Get-StandInServer {
    $sort = Join-Path $env:SystemRoot 'System32\sort.exe'
    if (-not $env:SystemRoot -or -not (Test-Path -LiteralPath $sort -PathType Leaf)) { return $null }
    $standIn = Join-Path $ToolsDir 'silent-omnivox.exe'
    if (-not (Test-Path -LiteralPath $standIn -PathType Leaf) -or (Get-Sha256 $standIn) -ne (Get-Sha256 $sort)) {
        Copy-Item -LiteralPath $sort -Destination $standIn -Force
    }
    return $standIn
}

# Stand-in servers still running, which only an earlier neomacs can have left.
function Get-StandInProcesses([string]$StandIn) {
    $found = @()
    foreach ($p in @(Get-Process -Name 'silent-omnivox' -ErrorAction SilentlyContinue)) {
        $path = ''
        try { $path = $p.Path } catch { }
        if ($path -and [string]::Equals($path, $StandIn, [StringComparison]::OrdinalIgnoreCase)) { $found += $p }
    }
    return , $found
}

function Invoke-ConsoleStart {
    $result = @{ Ran = $false; Report = @{}; Lines = @(); Left = 0; Seconds = 0; Why = '' }
    $standIn = Get-StandInServer
    if ($null -eq $standIn) {
        $result.Why = 'Windows has no sort.exe to stand in for the speech server'
        return $result
    }
    $reportPath = Join-Path $ToolsDir 'console-test.txt'
    [IO.File]::WriteAllText($reportPath, '', $Utf8NoBom)
    $arguments = @('-nw')
    if ($script:DumpOk) { $arguments += @('--dump-file', $DumpPath) }
    $arguments += @('-l', $SelfTestPath, '-f', 'stack-selftest-console')
    $environment = Get-NeomacsEnvironment @{
        DTK_PROGRAM = (ConvertTo-LispPath ($standIn.Substring(0, $standIn.Length - 4)))
        EMACSPEAK_STACK_TEST_OUTPUT = $reportPath }
    # The console's screen output is terminal codes, so it stays out of the log.
    $r = Invoke-Program -FilePath $NeomacsExe -Arguments $arguments -Seconds 120 -Environment $environment -NoOutputLog
    $result.Ran = $r.Started -and -not $r.TimedOut
    $result.Seconds = [math]::Round($r.Milliseconds / 1000, 1)
    [void][Threading.Thread]::Sleep(1500)
    $left = Get-StandInProcesses $standIn
    $result.Left = $left.Count
    foreach ($p in $left) {
        Add-Log ("Stopping a stand-in speech server neomacs left running: process $($p.Id)" + $CRLF)
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    # Emacs quotes names with curly quotes; plain ones read better in Braille.
    $result.Lines = @([IO.File]::ReadAllLines($reportPath, $Utf8NoBom) | ForEach-Object {
        $_.Replace([string][char]0x2018, "'").Replace([string][char]0x2019, "'").Replace(
            [string][char]0x201C, '"').Replace([string][char]0x201D, '"') })
    foreach ($line in $result.Lines) {
        Add-Log ("console test: $line" + $CRLF)
        $m = [regex]::Match($line, '^([a-z -]+): (.*)$')
        if ($m.Success) { $result.Report[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    if (-not $result.Ran) { $result.Why = 'neomacs did not finish within 120 seconds' }
    return $result
}

function Invoke-SelfTests {
    $count = 13
    if ($script:DumpOk) { $count = 14 }
    $g = New-TestGroup $count
    $soundReason = 'not run with -NoSound, since it makes a sound'
    $speechFix = ('Install a voice in Settings, Time and language, Speech, and run this in your own ' +
                  'signed-in Windows session, not over a remote shell.')

    Start-Test $g 'neomacs reports its version'
    $r = Invoke-Program -FilePath $NeomacsExe -Arguments @('--version') -Seconds 60 -Environment (Get-NeomacsEnvironment)
    $first = ([regex]::Split($r.Output.Trim(), '\r?\n'))[0]
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $first -notmatch '^Neomacs [0-9]') {
        Stop-Test "$NeomacsExe --version printed: $first. Rerun the script to repair the folder. $(Get-LogRef)"
    }
    Complete-Test $g "$first."

    Start-Test $g "neomacs evaluates Lisp in batch mode, as Emacs $minNeeded or newer"
    $r = Invoke-Program -FilePath $NeomacsExe -Seconds 60 -Environment (Get-NeomacsEnvironment) `
        -Arguments @('-Q', '--batch', '--eval', '(princ emacs-version)')
    $v = $r.Output.Trim()
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $v -notmatch '^[0-9]+(\.[0-9]+)+$') {
        Stop-Test "neomacs --batch did not print its Emacs version. $(Get-LogRef)"
    }
    if (([version]$v) -lt ([version]$minNeeded)) {
        Stop-Test "neomacs reports Emacs $v, and $BaseDisplay needs $minNeeded or newer."
    }
    Complete-Test $g "Emacs $v."

    Start-Test $g "the autoloads and byte-compiled Lisp of $BaseDisplay are in place"
    if (-not (Test-Path -LiteralPath $Loaddefs -PathType Leaf)) {
        Stop-Test "$Loaddefs is missing. Rerun the script."
    }
    $elc = @(Get-ChildItem -LiteralPath $LispDir -Filter '*.elc' -File).Count
    if ($script:CompileFailed -gt 0 -or $elc -eq 0) {
        Write-TestWarning $g "the Lisp of $BaseDisplay is $($script:CompileText); the rest loads from source."
    } else {
        Complete-Test $g "the autoloads are generated, and $BaseDisplay is $($script:CompileText)."
    }

    Start-Test $g "neomacs loads $BaseDisplay and omnivox-voices through init.el (no speech)"
    $r = Invoke-SelfTestLisp 'stack-selftest-load'
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Show-LogTail
        Stop-Test ("neomacs could not load $InitPath with $BaseDisplay and omnivox-voices: " +
                   "$(Get-FirstErrorLine ($r.Output + $LF + $r.ErrorOutput)). $(Get-LogRef)")
    }
    Complete-Test $g "$BaseDisplay and omnivox-voices load from this folder, and neomacs finds omnivox.exe."

    Start-Test $g 'OmniVox reports its version'
    $r = Invoke-Program -FilePath $ServerExe -Arguments @('--version') -Seconds 30
    $out = $r.Output.Trim()
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $out -notmatch '^omnivox [0-9]') {
        Stop-Test "$ServerExe --version printed: $out. Rerun the script. $(Get-LogRef)"
    }
    Complete-Test $g "$out."

    Start-Test $g 'OmniVox lists the Windows voices (no speech)'
    $r = Invoke-Program -FilePath $ServerExe -Arguments @('--list-voices') -Seconds 60 -Environment @{ OMNIVOX_ENGINE = 'native' }
    $m = [regex]::Match($r.Output + $LF + $r.ErrorOutput, '(?m)^Found ([0-9]+) voices')
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or -not $m.Success -or [int]$m.Groups[1].Value -lt 1) {
        Stop-Test "OmniVox found no Windows voices. $speechFix $(Get-LogRef)"
    }
    Complete-Test $g "$($m.Groups[1].Value) voices."

    Start-Test $g "neomacs starts servers/omnivox by its bare name, as $BaseDisplay does (no speech)"
    $r = Invoke-SelfTestLisp 'stack-selftest-version'
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $r.Output -notmatch 'output: "omnivox [0-9]') {
        Show-LogTail
        Stop-NoNeomacs ("$script:TestLabel failed: neomacs's start-process could not run " +
                        "$ServersDir\omnivox without its .exe, which is how the speech server is started.")
    }
    Complete-Test $g 'start-process ran servers/omnivox, which is omnivox.exe, and it printed its version.'

    Start-Test $g "OmniVox's voice list reaches neomacs without a shell (no speech)"
    $r = Invoke-SelfTestLisp 'stack-selftest-voices'
    $m = [regex]::Match($r.Output, '(?m)^voices: ([0-9]+)')
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or -not $m.Success) {
        Write-TestWarning $g ("M-x omnivox-select-voice will find no voices: the list did not reach neomacs. " +
                              "$(Get-LogRef)")
    } else {
        Complete-Test $g "$($m.Groups[1].Value) voices, as M-x omnivox-select-voice will offer them."
    }

    Start-Test $g "the speech advice of $BaseDisplay runs after interactive commands (no speech)"
    $r = Invoke-SelfTestLisp 'stack-selftest-advice'
    $m = [regex]::Match($r.Output, '(?m)^old-style defadvice functions: ([0-9]+)')
    if ($m.Success) { $script:OldAdvice = $m.Groups[1].Value }
    $commands = @([regex]::Matches($r.Output, '(?m)^command (\S+): spoke ([0-9]+), icons ([0-9]+), error (.*)$'))
    $bad = @($commands | Where-Object { $_.Groups[4].Value.Trim() -ne 'nil' -or ([int]$_.Groups[2].Value + [int]$_.Groups[3].Value) -eq 0 })
    if (-not $r.Started -or $r.TimedOut -or $commands.Count -eq 0) {
        Write-TestWarning $g ("the speech advice did not load: " +
                              "$(Get-FirstErrorLine ($r.Output + $LF + $r.ErrorOutput)). $(Get-LogRef)")
    } elseif ($bad.Count -gt 0) {
        $what = @($bad | ForEach-Object {
            if ($_.Groups[4].Value.Trim() -ne 'nil') { "$($_.Groups[1].Value) signaled $($_.Groups[4].Value.Trim())" }
            else { "$($_.Groups[1].Value) was silent" } }) -join '; '
        Write-TestWarning $g "of $($commands.Count) commands, $($bad.Count) did not speak as they should: $what."
    } else {
        Complete-Test $g ("all $($commands.Count) commands spoke or played an icon; " +
                          "$($script:OldAdvice) functions carry old-style defadvice advice.")
    }

    Start-Test $g "$BaseDisplay starts in a console neomacs, with a silent stand-in speech server"
    $c = Invoke-ConsoleStart
    $rep = $c.Report
    if ($rep['stalled'] -eq 't') {
        $errors = @($c.Lines | Where-Object { $_ -match '(?i)error|unexpected|void-|wrong-type|not found' -and
                                              $_ -notmatch '(?i)obsolete|warning:' } | Select-Object -First 4)
        $said = 'nothing that names the cause'
        if ($errors.Count -gt 0) { $said = ($errors | ForEach-Object { $_.Trim() }) -join ' | ' }
        Show-LogTail
        Stop-Test ("the console start of $BaseDisplay did not finish within 60 seconds. It logged: $said. " +
                   "A start that stops there leaves $BaseDisplay unusable. Upstream emacspeak " +
                   '(-EmacspeakRepo tvraman/emacspeak), or scripts\install-emacspeak-windows.ps1 with GNU Emacs, ' +
                   "are the alternatives. $(Get-LogRef)")
    }
    if ($c.Why -and -not $c.Ran -and $c.Why -notmatch 'sort\.exe') {
        Stop-NoNeomacs ("$script:TestLabel failed: $($c.Why) while $BaseDisplay started in the console, " +
                        'so something in that start blocks.')
    } elseif ($c.Why -match 'sort\.exe') {
        Skip-Test $g $c.Why
    } else {
        $problems = @()
        if ($rep['advice loaded'] -ne 't') { $problems += 'the speech advice was not loaded' }
        if ($rep['speaker running'] -ne 't') { $problems += 'the speech server was not running' }
        if ($rep['dtk-speak error'] -and $rep['dtk-speak error'] -ne 'nil') { $problems += "dtk-speak signaled $($rep['dtk-speak error'])" }
        if ($rep['next-line error'] -and $rep['next-line error'] -ne 'nil') { $problems += "next-line signaled $($rep['next-line error'])" }
        $lines = 0
        if ($rep['speech lines received']) { $lines = [int]$rep['speech lines received'] }
        if ($lines -lt 1) { $problems += 'no speech reached the server' }
        if ($c.Left -gt 0) { $problems += "$($c.Left) speech servers were still running after neomacs exited" }
        if ($problems.Count -gt 0) {
            Write-TestWarning $g ("the console start finished in $($c.Seconds) s, but " + ($problems -join '; ') +
                                  ". The report is in $ToolsDir\console-test.txt.")
        } else {
            $notify = 'and the notification server'
            if ($rep['notify running'] -ne 't') { $notify = 'without a notification server' }
            Complete-Test $g ("started in $($c.Seconds) s with its speech advice $notify; $lines lines of " +
                              'speech reached the stand-in, and no server outlived neomacs.')
        }
    }

    Start-Test $g 'the launchers, init files, manifest and README are in place'
    foreach ($f in @($Launcher, $ConsoleLauncher, $UpdateCmd, $ReadmePath, $ManifestPath, $InitPath, $LocalPath, $ToolsScript)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Stop-Test "$f is missing. Rerun the script." }
    }
    $text = [IO.File]::ReadAllText($Launcher)
    if (-not $text.Contains("neomacs\$NeomacsVersion\runneomacs.exe") -or -not $text.Contains('HOME=%STACK%home')) {
        Stop-Test "$Launcher does not start neomacs $NeomacsVersion with HOME in the folder. Rerun the script."
    }
    $text = [IO.File]::ReadAllText($ConsoleLauncher)
    if (-not $text.Contains("neomacs\$NeomacsVersion\neomacs.exe`" -nw")) {
        Stop-Test "$ConsoleLauncher does not start neomacs $NeomacsVersion in the console. Rerun the script."
    }
    $manifest = Read-Manifest
    if (-not $manifest.ContainsKey('neomacs-version') -or $manifest['neomacs-version'] -ne $NeomacsVersion -or
        $manifest['emacspeak-commit'] -ne $EmacspeakCommit) {
        Stop-Test "$ManifestPath does not record this build. Rerun the script."
    }
    Complete-Test $g 'emacspeak.cmd, emacspeak-console.cmd, update.cmd, README.txt, manifest.txt, init.el and local.el.'

    if ($script:DumpOk) {
        Start-Test $g "the fast-start dump starts neomacs with $BaseDisplay loaded (no speech)"
        $r = Test-StackLoad @('--dump-file', $DumpPath)
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $r.Output -notmatch '(?m)^dump file: .*emacspeak\.pdump') {
            Stop-Test "neomacs did not start from $DumpPath. Rerun the script, or rerun with -NoDump. $(Get-LogRef)"
        }
        Complete-Test $g "$BaseDisplay is preloaded, from this folder."
    }

    Start-Test $g "OmniVox's own check plays a tone and speech"
    $script:Sound = $false
    if ($NoSound) {
        Skip-Test $g $soundReason
    } else {
        Write-Info 'With a sound device, you may hear a tone and: Omnivox is ready.'
        $r = Invoke-Program -FilePath $ServerExe -Arguments @('--check') -Seconds 120 -Environment @{ OMNIVOX_ENGINE = 'native' }
        $report = $r.Output + $LF + $r.ErrorOutput
        $script:Sound = ($report -match 'Audio device: OK') -and (Test-SoundOutput)
        if (-not $r.Started -or $r.TimedOut -or $report -notmatch 'Status: OK') {
            Write-TestWarning $g "OmniVox could not synthesize speech. $speechFix Its report is in the log."
        } elseif (-not $script:Sound) {
            Write-TestWarning $g 'speech was synthesized, but there is no sound output device to play it.'
        } else {
            Complete-Test $g 'speech synthesized and played on the sound output device.'
        }
    }

    Start-Test $g "the OmniVox server speaks, started from neomacs as $BaseDisplay starts it"
    if ($NoSound) {
        Skip-Test $g $soundReason
    } elseif (-not $script:Sound) {
        Skip-Test $g 'no sound output device; connect speakers or headphones, then rerun'
    } else {
        Write-Info "This speaks once. You should hear: Omnivox version $OmnivoxVersion."
        $r = Invoke-SelfTestLisp 'stack-selftest-speak'
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
            Write-TestWarning $g "the server did not start or exit cleanly. Check the sound output, then rerun. $(Get-LogRef)"
        } else {
            Complete-Test $g 'the server spoke its version and exited cleanly.'
        }
    }
    return $g
}

# ==========================================================================
# Options.

$DefaultPrefix = ''
if ($env:USERPROFILE) { $DefaultPrefix = Join-Path $env:USERPROFILE 'emacspeak-stack' }
if ($Help) {
    Show-Usage $DefaultPrefix
    exit 0
}
$NeomacsVersion = $NeomacsVersion.TrimStart('v')
$OmnivoxVersion = $OmnivoxVersion.TrimStart('v')
if ($NeomacsVersion -and -not (Test-ValidVersion $NeomacsVersion)) {
    Fail '-NeomacsVersion needs a release number such as 0.0.19 (see https://github.com/eval-exec/neomacs/releases).'
}
if ($OmnivoxVersion -and -not (Test-ValidVersion $OmnivoxVersion)) {
    Fail '-OmnivoxVersion needs a release number such as 1.3.0 (see https://github.com/robertmeta/omnivox/releases).'
}
if ($EmacspeakRepo) {
    $EmacspeakRepo = $EmacspeakRepo.Trim() -replace '^https?://github\.com/', '' -replace '\.git$', '' -replace '/+$', ''
    if ($EmacspeakRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        Fail '-EmacspeakRepo needs a GitHub repository, such as tvraman/emacspeak or https://github.com/tvraman/emacspeak.'
    }
}
if ($EmacspeakRef -and $EmacspeakRef -notmatch '^[A-Za-z0-9._/-]+$') {
    Fail '-EmacspeakRef needs a branch, tag or commit name, such as master.'
}
if ($SetupFile -and $SetupFile -notmatch '^[a-z][a-z0-9]*-setup\.el$') {
    Fail '-SetupFile needs the name of a setup file in the snapshot''s lisp folder, such as emacsvox-setup.el or emacspeak-setup.el.'
}
if ($QuietDisplay -and $AnimatedDisplay) { Fail '-QuietDisplay and -AnimatedDisplay contradict each other; give one of them.' }
if ($NoDump -and $Dump) { Fail '-NoDump and -Dump contradict each other; give one of them.' }
if (-not $Prefix) { $Prefix = $DefaultPrefix }
if (-not $Prefix) { Fail 'USERPROFILE is not set, so there is no default folder. Use -Prefix.' }
if ($Prefix -match '["%!]') { Fail '-Prefix must not contain quotes, percent signs or exclamation marks, which break the .cmd launchers.' }
$PrefixPath = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Prefix))
$PrefixPath = $PrefixPath.TrimEnd([char]92, '/')
if ($PrefixPath -match '^[A-Za-z]:$' -or -not $PrefixPath) { Fail '-Prefix must be a folder, not the root of a drive.' }

$DownloadsDir = Join-Path $PrefixPath 'downloads'
$HomeDir = Join-Path $PrefixPath 'home'
$EmacsDir = Join-Path $HomeDir '.emacs.d'
$ToolsDir = Join-Path $PrefixPath 'tools'
$DumpDir = Join-Path $PrefixPath 'dump'
$DumpPath = Join-Path $DumpDir 'emacspeak.pdump'
$DumpStamp = Join-Path $DumpDir 'emacspeak-dump-stamp.txt'
$InitPath = Join-Path $EmacsDir 'init.el'
$LocalPath = Join-Path $EmacsDir 'local.el'
$SelfTestPath = Join-Path $ToolsDir 'selftest.el'
$DumpLispPath = Join-Path $ToolsDir 'dump.el'
$ToolsScript = Join-Path $ToolsDir $ScriptName
$Launcher = Join-Path $PrefixPath 'emacspeak.cmd'
$ConsoleLauncher = Join-Path $PrefixPath 'emacspeak-console.cmd'
$UpdateCmd = Join-Path $PrefixPath 'update.cmd'
$ReadmePath = Join-Path $PrefixPath 'README.txt'
$ManifestPath = Join-Path $PrefixPath 'manifest.txt'
$LogFile = Join-Path $PrefixPath 'build.log'
$script:CompileText = 'not built'
$script:CompileFailed = 0
$script:DumpOk = $false
$script:DumpKey = ''
$script:DumpText = 'not built (-NoDump)'
$script:DumpKeyText = 'none'
$script:Timings = New-Object System.Collections.Specialized.OrderedDictionary
$script:TestSummary = 'not run yet'
$script:TestLabel = ''
$script:OldAdvice = 'not counted'
$script:CompileRenamed = 0
$BaseName = 'emacspeak'
$BaseDisplay = 'emacspeak'
$minNeeded = $MinEmacs
$script:ApiNote = ''
$AssetNames = @{}

# ==========================================================================
Add-Log ("$ScriptName started " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + $CRLF)
Write-Step 'Checking the system'
if ($env:OS -ne 'Windows_NT') {
    Fail 'this script is for Windows.'
}
$os = [Environment]::OSVersion.Version
if ($os.Major -lt 10) { Fail "this needs Windows 10 or 11, and this is Windows $os." }
$NativeArch = Get-NativeArch
switch ($NativeArch) {
    'AMD64' { $Arch = 'x64'; $NeomacsTarget = 'x86_64-pc-windows-msvc' }
    'ARM64' { $Arch = 'arm64'; $NeomacsTarget = 'aarch64-pc-windows-msvc' }
    default { Fail "neomacs and OmniVox are built for x64 and ARM64 Windows only, and this computer is $NativeArch." }
}
Write-Info "Windows $os on $Arch, PowerShell $($PSVersionTable.PSVersion): supported."
# Windows PowerShell 5.1 on older Windows 10 may not offer TLS 1.2, which GitHub requires.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # PowerShell 7 does this itself.
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$CompileJobs = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount))

# --------------------------------------------------------------------------
Write-Step "Checking the folder $PrefixPath"
if (Test-Path -LiteralPath $PrefixPath -PathType Leaf) {
    Fail "$PrefixPath is a file. Use -Prefix to name a folder."
}
if (Test-Path -LiteralPath $PrefixPath -PathType Container) {
    $entries = @(Get-ChildItem -LiteralPath $PrefixPath -Force -ErrorAction SilentlyContinue)
    $ours = $false
    foreach ($f in @($ManifestPath, $LogFile)) {
        if ((Test-Path -LiteralPath $f -PathType Leaf) -and (Select-String -LiteralPath $f -SimpleMatch -Pattern $ScriptName -Quiet)) { $ours = $true }
    }
    if ($entries.Count -gt 0 -and -not $ours) {
        Fail "$PrefixPath exists and was not made by this script. Move it away, or use -Prefix to name another folder."
    }
}
foreach ($d in @($PrefixPath, $DownloadsDir, $HomeDir, $EmacsDir, $ToolsDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Open-Log $LogFile
Add-Log ("# $Marker." + $CRLF)
Write-Info "Log: $LogFile"
$Recorded = Read-Manifest

# Remembered choices: a switch given now wins, otherwise the last run's.
# They are pairs of switches, because powershell -File cannot pass
# -QuietDisplay:$false.
$QuietDisplayOn = (Get-Recorded 'quiet-display') -eq 'yes'
if ($QuietDisplay) { $QuietDisplayOn = $true }
if ($AnimatedDisplay) { $QuietDisplayOn = $false }
$DumpWanted = (Get-Recorded 'dump') -notmatch '^not built \(-NoDump\)'
if ($NoDump) { $DumpWanted = $false }
if ($Dump) { $DumpWanted = $true }

# --------------------------------------------------------------------------
Write-Step 'Choosing the versions'
foreach ($item in @(
        @{ Name = 'neomacs'; Var = 'NeomacsVersion'; Repo = $NeomacsRepo; Fallback = $NeomacsFallback; Key = 'neomacs-version' },
        @{ Name = 'OmniVox'; Var = 'OmnivoxVersion'; Repo = $OmnivoxRepo; Fallback = $OmnivoxFallback; Key = 'omnivox-version' })) {
    $given = (Get-Variable -Name $item.Var -ValueOnly)
    $installed = Get-Recorded $item.Key
    if ($given) {
        $value = $given
        Write-Info "$($item.Name) $value, as asked."
    } elseif ($installed -and -not $Update) {
        $value = $installed
        Write-Info "$($item.Name) $value, the installed release (-Update moves to the latest)."
    } else {
        $value = Get-LatestRelease $item.Repo
        if ($value) {
            Write-Info "$($item.Name) $value, the latest release."
        } elseif ($installed) {
            $value = $installed
            Write-Warn "could not ask GitHub for the latest $($item.Name) release; keeping $value.$(Get-ApiNote)"
        } else {
            $value = $item.Fallback
            Write-Warn ("could not ask GitHub for the latest $($item.Name) release; using $value, the release " +
                        "this script was written against.$(Get-ApiNote)")
        }
    }
    Set-Variable -Name $item.Var -Value $value
}
if (-not $EmacspeakRepo) { $EmacspeakRepo = Get-Recorded 'emacspeak-repo' }
if (-not $EmacspeakRepo) { $EmacspeakRepo = $DefaultEmacspeakRepo }
if (-not $EmacspeakRef) { $EmacspeakRef = Get-Recorded 'emacspeak-ref' }
if (-not $EmacspeakRef) {
    if ($EmacspeakRepo -eq $DefaultEmacspeakRepo) { $EmacspeakRef = $DefaultEmacsvoxRef }
    else { $EmacspeakRef = $DefaultEmacspeakRef }
}
$EmacspeakCommit = ''
$EmacspeakCommitDate = ''
$sameSource = ((Get-Recorded 'emacspeak-repo') -eq $EmacspeakRepo) -and ((Get-Recorded 'emacspeak-ref') -eq $EmacspeakRef)
if ($sameSource -and -not $Update -and (Get-Recorded 'emacspeak-commit') -match '^[0-9a-f]{40}$') {
    $EmacspeakCommit = Get-Recorded 'emacspeak-commit'
    $EmacspeakCommitDate = Get-Recorded 'emacspeak-commit-date'
    Write-Info "Commit $($EmacspeakCommit.Substring(0, 12)) of $EmacspeakRepo $EmacspeakRef, the installed snapshot."
} else {
    $c = Get-RefCommit $EmacspeakRepo $EmacspeakRef
    if ($null -ne $c) {
        $EmacspeakCommit = $c.Sha
        $EmacspeakCommitDate = $c.Date
        Write-Info "Commit $($EmacspeakCommit.Substring(0, 12)) of $EmacspeakCommitDate, the current snapshot of $EmacspeakRepo $EmacspeakRef."
    } elseif ($sameSource -and (Get-Recorded 'emacspeak-commit') -match '^[0-9a-f]{40}$') {
        $EmacspeakCommit = Get-Recorded 'emacspeak-commit'
        $EmacspeakCommitDate = Get-Recorded 'emacspeak-commit-date'
        Write-Warn "could not ask GitHub for the current commit of $EmacspeakRepo; keeping $($EmacspeakCommit.Substring(0, 12)).$(Get-ApiNote)"
    } else {
        Write-Warn "could not ask GitHub for the current commit of $EmacspeakRepo; the snapshot itself names it.$(Get-ApiNote)"
    }
}

# --------------------------------------------------------------------------
$NeomacsAsset = "neomacs-$NeomacsVersion-$NeomacsTarget.zip"
$NeomacsZip = Join-Path $DownloadsDir $NeomacsAsset
$NeomacsSums = Join-Path $DownloadsDir "neomacs-$NeomacsVersion-SHA256SUMS"
$AssetNames[$NeomacsZip] = $NeomacsAsset
$NeomacsDir = Join-Path $PrefixPath "neomacs\$NeomacsVersion"
$NeomacsExe = Join-Path $NeomacsDir 'neomacs.exe'
Write-Step "neomacs ${NeomacsVersion}: $NeomacsAsset"
$script:Hint = ("Check the internet connection. If neomacs release $NeomacsVersion lacks this file, pick " +
                "another with -NeomacsVersion; the releases are at https://github.com/$NeomacsRepo/releases")
$base = "https://github.com/$NeomacsRepo/releases/download/v$NeomacsVersion"
Save-Download "$base/SHA256SUMS" $NeomacsSums
Save-Download "$base/$NeomacsAsset" $NeomacsZip
$NeomacsSumsHash = Get-Sha256 $NeomacsSums
$NeomacsZipHash = Confirm-Checksum $NeomacsZip $NeomacsSums "neomacs $NeomacsVersion"
[void](Install-ZipContent -Zip $NeomacsZip -ZipHash $NeomacsZipHash -Dest $NeomacsDir `
    -Strip "neomacs-$NeomacsVersion-$NeomacsTarget/" -What "neomacs $NeomacsVersion")
foreach ($f in @('neomacs.exe', 'runneomacs.exe', 'neomacs.pdump')) {
    if (-not (Test-Path -LiteralPath (Join-Path $NeomacsDir $f) -PathType Leaf)) {
        Fail "$NeomacsAsset has no $f; the release layout may have changed. Pick another release with -NeomacsVersion."
    }
}

# --------------------------------------------------------------------------
$OmnivoxAsset = "omnivox-$OmnivoxVersion-windows-$Arch.zip"
$OmnivoxZip = Join-Path $DownloadsDir $OmnivoxAsset
$OmnivoxSums = Join-Path $DownloadsDir "omnivox-$OmnivoxVersion-sha256sums.txt"
$AssetNames[$OmnivoxZip] = $OmnivoxAsset
$OmnivoxDir = Join-Path $PrefixPath "omnivox\$OmnivoxVersion"
$OmnivoxExe = Join-Path $OmnivoxDir 'omnivox.exe'
Write-Step "OmniVox ${OmnivoxVersion}: $OmnivoxAsset"
$script:Hint = ("Check the internet connection. If OmniVox release $OmnivoxVersion lacks this file, pick " +
                "another with -OmnivoxVersion; the releases are at https://github.com/$OmnivoxRepo/releases")
$base = "https://github.com/$OmnivoxRepo/releases/download/v$OmnivoxVersion"
Save-Download "$base/sha256sums.txt" $OmnivoxSums
Save-Download "$base/$OmnivoxAsset" $OmnivoxZip
$OmnivoxSumsHash = Get-Sha256 $OmnivoxSums
$OmnivoxZipHash = Confirm-Checksum $OmnivoxZip $OmnivoxSums "OmniVox $OmnivoxVersion"
[void](Install-ZipContent -Zip $OmnivoxZip -ZipHash $OmnivoxZipHash -Dest $OmnivoxDir -What "OmniVox $OmnivoxVersion")
foreach ($f in @('omnivox.exe', 'omnivox-voices.el')) {
    if (-not (Test-Path -LiteralPath (Join-Path $OmnivoxDir $f) -PathType Leaf)) {
        Fail "$OmnivoxAsset has no $f; the release layout may have changed. Pick another release with -OmnivoxVersion."
    }
}
$r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--version') -Seconds 30
if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
    Fail "$OmnivoxExe does not run on this computer. $(Get-LogRef)"
}
Write-Info "$($r.Output.Trim()) runs."

# --------------------------------------------------------------------------
Write-Step "The audio desktop: a snapshot of $EmacspeakRepo $EmacspeakRef"
$script:Hint = ("Check the internet connection, and the -EmacspeakRepo and -EmacspeakRef values. " +
                "The snapshot comes from https://github.com/$EmacspeakRepo")
$RepoName = ($EmacspeakRepo -split '/')[1]
$EmacspeakZipHash = ''
$EmacspeakZipName = ''
if ($EmacspeakCommit) {
    $EmacspeakZipName = "$RepoName-$EmacspeakCommit.zip"
    $zip = Join-Path $DownloadsDir $EmacspeakZipName
    $recordedHash = ''
    if ((Get-Recorded 'emacspeak-commit') -eq $EmacspeakCommit) { $recordedHash = Get-Recorded 'emacspeak-zip-sha256' }
    if ((Test-Path -LiteralPath $zip -PathType Leaf) -and $recordedHash -and (Get-Sha256 $zip) -ne $recordedHash) {
        Write-Warn "$EmacspeakZipName differs from the one recorded in the manifest; set aside as .bad and downloaded again."
        Set-Aside @($zip)
    }
    Save-Download "https://github.com/$EmacspeakRepo/archive/$EmacspeakCommit.zip" $zip
} else {
    $zip = Join-Path $DownloadsDir "$RepoName-snapshot.zip"
    if (Test-Path -LiteralPath $zip -PathType Leaf) { Set-Aside @($zip) }
    Save-Download "https://github.com/$EmacspeakRepo/archive/$EmacspeakRef.zip" $zip
}
# GitHub writes the commit of a snapshot into the zip's comment.
$comment = (Get-ZipComment $zip).Trim()
if ($comment -match '^[0-9a-f]{40}$') {
    if ($EmacspeakCommit -and $comment -ne $EmacspeakCommit) {
        Set-Aside @($zip)
        Fail "the snapshot holds commit $comment, not $EmacspeakCommit as asked; it was set aside. Run the script again."
    }
    if (-not $EmacspeakCommit) {
        $EmacspeakCommit = $comment
        $EmacspeakZipName = "$RepoName-$EmacspeakCommit.zip"
        $final = Join-Path $DownloadsDir $EmacspeakZipName
        Move-Item -LiteralPath $zip -Destination $final -Force
        $zip = $final
    }
} elseif (-not $EmacspeakCommit) {
    Fail 'the snapshot does not say which commit it holds, and GitHub could not be asked. Run the script again later.'
}
$EmacspeakZipHash = Get-Sha256 $zip
$EmacspeakZip = $zip
$recordedHash = ''
if ((Get-Recorded 'emacspeak-commit') -eq $EmacspeakCommit) { $recordedHash = Get-Recorded 'emacspeak-zip-sha256' }
if ($recordedHash -and $recordedHash -ne $EmacspeakZipHash) {
    Write-Info "GitHub served archive bytes that differ from the recorded ones; the commit inside, $EmacspeakCommit, is the same."
}
Write-Info "Snapshot of commit $EmacspeakCommit, SHA-256 $EmacspeakZipHash, recorded in the manifest."
$EmacspeakShort = $EmacspeakCommit.Substring(0, 12)

# Which audio desktop the snapshot holds, from its setup file: EmacsVox
# renamed emacspeak's core files from emacspeak- to emacsvox-, so the
# setup file's name, without -setup.el, is the prefix of the others.
$top = ''
$lispNames = @{}
$probe = [IO.Compression.ZipFile]::OpenRead($EmacspeakZip)
try {
    if ($probe.Entries.Count -gt 0) {
        $top = ($probe.Entries[0].FullName -split '/')[0] + '/'
        # GitHub dates every entry of a snapshot with its commit's time.
        if (-not $EmacspeakCommitDate) { $EmacspeakCommitDate = $probe.Entries[0].LastWriteTime.ToString('yyyy-MM-dd') }
    }
    foreach ($entry in $probe.Entries) {
        $m = [regex]::Match($entry.FullName, '^[^/]+/lisp/([^/]+)$')
        if ($m.Success) { $lispNames[$m.Groups[1].Value] = $true }
    }
} finally {
    $probe.Dispose()
}
$CommitDateText = ''
if ($EmacspeakCommitDate) { $CommitDateText = " of $EmacspeakCommitDate" }
$SetupName = $SetupFile
if (-not $SetupName -and ((Get-Recorded 'emacspeak-commit') -eq $EmacspeakCommit)) { $SetupName = Get-Recorded 'emacspeak-setup-file' }
if (-not $SetupName) {
    foreach ($candidate in @('emacsvox-setup.el', 'emacspeak-setup.el')) {
        if ($lispNames.ContainsKey($candidate)) { $SetupName = $candidate; break }
    }
}
if (-not $SetupName) {
    Fail ("the snapshot of $EmacspeakRepo has neither lisp\emacsvox-setup.el nor lisp\emacspeak-setup.el; " +
          'is it EmacsVox or emacspeak? Check -EmacspeakRepo, or name the setup file with -SetupFile.')
}
if (-not $lispNames.ContainsKey($SetupName)) {
    Fail "the snapshot of $EmacspeakRepo has no lisp\$SetupName. Check -SetupFile and -EmacspeakRepo."
}
$BaseName = $SetupName.Substring(0, $SetupName.Length - '-setup.el'.Length)
foreach ($part in @('preamble', 'autoload')) {
    if (-not $lispNames.ContainsKey("$BaseName-$part.el")) {
        Fail ("the snapshot has lisp\$SetupName but no lisp\$BaseName-$part.el, which the build needs. " +
              'Check -SetupFile and -EmacspeakRepo.')
    }
}
$BaseDisplay = $BaseName
if ($BaseName -eq 'emacsvox') { $BaseDisplay = 'EmacsVox' }
Write-Info "It is $BaseDisplay, started by lisp\$SetupName."

$EmacspeakDir = Join-Path $PrefixPath "$BaseName\$EmacspeakShort"
$LispDir = Join-Path $EmacspeakDir 'lisp'
$ServersDir = Join-Path $EmacspeakDir 'servers'
$ServerExe = Join-Path $ServersDir 'omnivox.exe'
$LogServerExe = Join-Path $ServersDir 'log-omnivox.exe'
$fresh = Install-ZipContent -Zip $EmacspeakZip -ZipHash $EmacspeakZipHash -Dest $EmacspeakDir -Strip $top `
    -Include $EmacspeakRuntime -Unchecked @('servers/.servers') -What "$BaseDisplay $EmacspeakShort"
Write-Info 'Kept the parts read at run time: lisp, servers, sounds, etc, xsl, info and media\radio.'

Write-Step "Putting OmniVox into $ServersDir"
Copy-OmnivoxServer
Register-Omnivox
Write-Info 'omnivox.exe and log-omnivox.exe are there, and servers\.servers lists both.'

# OmniVox's omnivox-voices.el requires emacspeak-preamble and uses two of
# its variables. On EmacsVox, a small file of the stack's own gives those
# names to EmacsVox's renamed ones.
$CompatDir = Join-Path $ToolsDir 'compat'
if ($BaseName -ne 'emacspeak') {
    New-Item -ItemType Directory -Force -Path $CompatDir | Out-Null
    Write-OwnFile (Join-Path $CompatDir 'emacspeak-preamble.el') (Get-CompatText) $Utf8NoBom
    Write-Info "OmniVox's Lisp reaches $BaseDisplay through $CompatDir\emacspeak-preamble.el."
}

# --------------------------------------------------------------------------
Write-Step "Checking that neomacs $NeomacsVersion runs here"
$r = Invoke-Program -FilePath $NeomacsExe -Arguments @('--version') -Seconds 60 -Environment (Get-NeomacsEnvironment)
$neoFirst = ''
if ($r.Started) { $neoFirst = ([regex]::Split($r.Output.Trim(), '\r?\n'))[0] }
if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
    Show-LogTail
    Stop-NoNeomacs "$NeomacsExe --version did not run ($($r.ErrorOutput.Trim()))."
}
$r = Invoke-Program -FilePath $NeomacsExe -Seconds 60 -Environment (Get-NeomacsEnvironment) `
    -Arguments @('-Q', '--batch', '--eval', '(princ emacs-version)')
$neoEmacs = $r.Output.Trim()
if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $neoEmacs -notmatch '^[0-9]+(\.[0-9]+)+$') {
    Show-LogTail
    Stop-NoNeomacs 'neomacs --batch could not evaluate Lisp.'
}
$minNeeded = $MinEmacs
if ($BaseName -eq 'emacsvox') { $minNeeded = '31.1' }
if (([version]$neoEmacs) -lt ([version]$minNeeded)) {
    Stop-NoNeomacs "neomacs reports Emacs $neoEmacs, and $BaseDisplay needs $minNeeded or newer."
}
Write-Info "$neoFirst runs, and evaluates Lisp in batch mode as Emacs $neoEmacs."

# --------------------------------------------------------------------------
$Loaddefs = Join-Path $LispDir "$BaseName-loaddefs.el"
$compiledWith = Join-Path $LispDir 'stack-compiled-with.txt'
$neomacsChanged = $true
if (Test-Path -LiteralPath $compiledWith -PathType Leaf) {
    $neomacsChanged = ([IO.File]::ReadAllText($compiledWith).Trim() -ne "neomacs $NeomacsVersion $NeomacsZipHash")
}
$script:Hint = ("The lines above name the Lisp file that failed. neomacs is a work in progress; " +
                'scripts\install-emacspeak-windows.ps1 installs emacspeak with GNU Emacs instead.')
if ($fresh -or $neomacsChanged -or -not (Test-Path -LiteralPath $Loaddefs -PathType Leaf)) {
    Write-Step "Generating the autoloads of $BaseDisplay with neomacs"
    $r = Invoke-Program -FilePath $NeomacsExe -WorkingDirectory $LispDir -Seconds 600 -Environment (Get-NeomacsEnvironment) `
        -Arguments ($EmacsBatch + @('-l', "./$BaseName-preamble.el", '-l', "./$BaseName-autoload.el",
                                    '-f', "$BaseName-auto-generate-autoloads"))
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Loaddefs -PathType Leaf)) {
        Show-LogTail
        Stop-IfSnapshotAsks ($r.Output + $LF + $r.ErrorOutput) 'Generating the autoloads'
        Stop-NoNeomacs ("neomacs could not generate the autoloads ($BaseName-loaddefs.el): " +
                        "$(Get-FirstErrorLine ($r.Output + $LF + $r.ErrorOutput)).")
    }
    Write-Info "Written: $Loaddefs"
} else {
    Write-Step "The autoloads of $BaseDisplay are in place"
}

Write-Step "Byte-compiling the Lisp of $BaseDisplay with neomacs, each file in its own neomacs"
Invoke-ByteCompile $LispDir $neomacsChanged
[IO.File]::WriteAllText($compiledWith, "neomacs $NeomacsVersion $NeomacsZipHash" + $CRLF, $Utf8NoBom)

Write-Step 'Byte-compiling omnivox-voices.el with neomacs'
$voicesEl = Join-Path $OmnivoxDir 'omnivox-voices.el'
$voicesElc = $voicesEl + 'c'
# Compiled against one base and one neomacs; either changing compiles it again.
$voicesStamp = Join-Path $OmnivoxDir 'stack-compiled-with.txt'
$voicesWant = "neomacs $NeomacsVersion $NeomacsZipHash, $BaseName $EmacspeakCommit"
$voicesCurrent = (Test-Path -LiteralPath $voicesElc -PathType Leaf) -and (Test-Path -LiteralPath $voicesStamp -PathType Leaf) -and
    ([IO.File]::ReadAllText($voicesStamp).Trim() -eq $voicesWant) -and
    (Get-Item -LiteralPath $voicesElc).LastWriteTimeUtc -ge (Get-Item -LiteralPath $voicesEl).LastWriteTimeUtc
if ($voicesCurrent) {
    Write-Info 'omnivox-voices.elc is up to date.'
} else {
    $compileArgs = @('-L', $LispDir)
    if ($BaseName -ne 'emacspeak') { $compileArgs += @('-L', $CompatDir) }
    $compileArgs += @('--eval', "(require 'cl-lib)", '-l', (Join-Path $LispDir "$BaseName-preamble.el"),
                      '-f', 'batch-byte-compile', 'omnivox-voices.el')
    $r = Invoke-Program -FilePath $NeomacsExe -WorkingDirectory $OmnivoxDir -Seconds 600 -Environment (Get-NeomacsEnvironment) `
        -Arguments ($EmacsBatch + $compileArgs)
    if ($r.Started -and -not $r.TimedOut -and $r.ExitCode -eq 0 -and (Test-Path -LiteralPath $voicesElc -PathType Leaf)) {
        [IO.File]::WriteAllText($voicesStamp, $voicesWant + $CRLF, $Utf8NoBom)
        Write-Info "Compiled: $voicesElc"
    } else {
        Write-Warn "omnivox-voices.el did not compile with neomacs, and loads from source. $(Get-LogRef)"
    }
}

# --------------------------------------------------------------------------
Write-Step "Writing the init files in $EmacsDir"
$InitText = Get-InitText
Write-OwnFile $InitPath $InitText $Utf8NoBom
if (Test-Path -LiteralPath $LocalPath -PathType Leaf) {
    Write-Info "init.el written; your local.el is kept as it is."
} else {
    [IO.File]::WriteAllText($LocalPath, (Get-LocalText), $Utf8NoBom)
    Write-Info 'init.el written, and local.el made for your own settings.'
}
Write-OwnFile $SelfTestPath (Get-SelfTestText) $Utf8NoBom
Write-OwnFile $DumpLispPath (Get-DumpLispText) $Utf8NoBom
if ($PSCommandPath -and -not [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), $ToolsScript, [StringComparison]::OrdinalIgnoreCase)) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $ToolsScript -Force
}
Write-Info "This script is kept as $ToolsScript, for update.cmd."

Write-Step "Checking that $BaseDisplay loads on neomacs $NeomacsVersion (no speech)"
$r = Invoke-SelfTestLisp 'stack-selftest-load'
if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
    Show-LogTail
    Stop-IfSnapshotAsks ($r.Output + $LF + $r.ErrorOutput) "Loading $BaseDisplay"
    Stop-NoNeomacs ("neomacs could not load $BaseDisplay and omnivox-voices through $InitPath" +
                    ": $(Get-FirstErrorLine ($r.Output + $LF + $r.ErrorOutput)).")
}
Write-Info "$BaseDisplay and omnivox-voices load, and neomacs finds omnivox.exe."

if ($DumpWanted) {
    Write-Step "Building the fast-start dump: neomacs with $BaseDisplay preloaded"
    Build-Dump
} else {
    Write-Step 'Not building the fast-start dump (-NoDump)'
    $script:DumpText = 'not built (-NoDump)'
}

Write-Step 'Writing the launchers, update.cmd, README.txt and manifest.txt'
foreach ($pair in @(@($Launcher, (Get-LauncherText)), @($ConsoleLauncher, (Get-ConsoleLauncherText)),
                    @($UpdateCmd, (Get-UpdateCmdText)))) {
    Write-OwnFile $pair[0] $pair[1] (Get-CmdEncoding $pair[1])
}
Write-OwnFile $ReadmePath (Get-ReadmeText) $Utf8NoBom
Write-Manifest
Write-Info 'emacspeak.cmd, emacspeak-console.cmd, update.cmd, README.txt and manifest.txt are written.'

# --------------------------------------------------------------------------
if ($NoTest) {
    $script:TestSummary = 'skipped (-NoTest)'
    # Keep the startup times of the last run that measured them.
    foreach ($key in @($Recorded.Keys | Where-Object { $_ -like 'startup-*' } | Sort-Object)) {
        $script:Timings[$key] = $Recorded[$key]
    }
    if ($script:Timings.Contains('startup-measured')) {
        $script:Timings['startup-measured'] = ($script:Timings['startup-measured'] -replace
            ', (with this build|by an earlier run)$', '') + ', by an earlier run'
    }
} else {
    $group = Invoke-SelfTests
    $script:TestSummary = Get-TestText $group
    Write-Step 'Timing startup in batch mode, the median of five runs each (no speech)'
    Measure-Startup
}
Write-Manifest

# --------------------------------------------------------------------------
$older = @()
foreach ($kind in @(@('neomacs', $NeomacsVersion), @('omnivox', $OmnivoxVersion), @('emacspeak', ''), @('emacsvox', ''))) {
    $dir = Join-Path $PrefixPath $kind[0]
    foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
        $current = $kind[1]
        if ($kind[0] -eq $BaseName) { $current = $EmacspeakShort }
        if ($d.Name -ne $current) { $older += "$($kind[0])\$($d.Name)" }
    }
}
Write-Step "Done: $BaseDisplay on neomacs, with OmniVox speech, is in $PrefixPath"
$summary = @("Self-tests: $($script:TestSummary).")
$summary += @(
    "neomacs ${NeomacsVersion}, checksum verified: $NeomacsDir",
    "OmniVox ${OmnivoxVersion}, checksum verified: $OmnivoxDir",
    "$BaseDisplay commit ${EmacspeakShort}${CommitDateText}, from ${EmacspeakRepo}: $EmacspeakDir",
    "Its Lisp: $($script:CompileText).",
    "Old-style defadvice advice in the loaded Lisp: $($script:OldAdvice) functions.",
    "Fast-start dump: $($script:DumpText)."
)
if ($script:Timings.Contains('startup-compiled-ms')) {
    $t = "Startup in batch mode: $($script:Timings['startup-compiled-ms']) ms without the dump"
    if ($NoTest) { $t = "Startup in batch mode, as an earlier run measured it: $($script:Timings['startup-compiled-ms']) ms without the dump" }
    if ($script:Timings.Contains('startup-dump-ms')) { $t += ", $($script:Timings['startup-dump-ms']) ms with it" }
    if ($script:Timings.Contains('startup-neomacs-alone-ms')) { $t += "; neomacs alone $($script:Timings['startup-neomacs-alone-ms']) ms" }
    $summary += "$t."
}
$summary += @(
    "Manifest, with every version and SHA-256: $ManifestPath",
    "Log: $LogFile",
    '',
    "To start $BaseDisplay in its own window, run:",
    "  $Launcher",
    'To start it in a console window, which screen readers and Braille',
    'displays can read, run:',
    "  $ConsoleLauncher",
    '',
    "neomacs's window has no accessibility tree yet. AccessKit support is",
    'planned for neomacs 0.0.21, with no date. Until then NVDA, JAWS and',
    "a Braille display get nothing from that window, and $BaseDisplay's",
    'speech is the whole interface there. Use emacspeak-console.cmd when',
    'the screen must be readable by the screen reader or Braille.',
    "NVDA and JAWS speak over $BaseDisplay unless you pause them.",
    'NVDA: press NVDA+Shift+S for sleep mode in the focused program',
    '(NVDA+Shift+Z on the laptop layout); press it again to wake NVDA.',
    'JAWS has a similar sleep mode: INSERT+SPACEBAR, then Z.',
    '',
    'Your own settings go in this file, which the script never changes:',
    "  $LocalPath",
    'The script rewrites init.el beside it on every run.',
    "To update neomacs, OmniVox and $BaseDisplay later, run:",
    "  $UpdateCmd",
    'HOME is the home folder inside, so nothing in your profile changes,',
    'and the whole folder can move.',
    'neomacs and OmniVox are not code-signed; README.txt says what to do',
    'if Windows SmartScreen or Smart App Control stops them.',
    ''
)
if ($QuietDisplayOn) {
    $summary += 'Display: animations are off (-QuietDisplay); -AnimatedDisplay turns them on.'
} else {
    $summary += @('Display: neomacs animates the cursor and window changes.',
                  'Rerun with -QuietDisplay to turn its animations off.')
}
$summary += @(
    'Speech rate: OmniVox starts at 60, faster than normal; the line',
    '(setq omnivox-speech-rate 50) in local.el is normal speed.',
    'Known OmniVox issue: text after two semicolons may not be spoken.',
    "neomacs is a work in progress. If $BaseDisplay misbehaves on it,",
    'scripts\install-emacspeak-windows.ps1 installs emacspeak with GNU Emacs.'
)
if ($older.Count -gt 0) {
    $summary += @('', 'Older versions are kept until you delete them by hand:') + @($older | ForEach-Object { "  $PrefixPath\$_" })
}
foreach ($line in $summary) { Write-Info $line }
exit 0
