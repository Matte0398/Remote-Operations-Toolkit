################################################################################################################
## Description: Program to execute commands, copy files or compare paths on remote Windows systems over WinRM
##
## Author: Matteo Z.
################################################################################################################

#requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'ReuseCredential', PositionalBinding = $false)]
param(
    [string] $PathOper = 'C:\temp',
    [string] $SystemList,
    [string] $ObjectList,
    [string] $ResultsPath,
    [Alias('ExecFile')][string] $Exec,
    [switch] $Diff,
    [Alias('L', 'Local')][string] $LocalPath,
    [Alias('R', 'Remote')][string] $RemotePath,
    [ValidateRange(1, 64)][int] $ThrottleLimit = 5,
    [ValidateRange(1, 2147483)][int] $ConnectTimeout = 10,
    [ValidateRange(0, 2147483)][int] $CommandTimeout = 0,
    [switch] $AllowDangerous,
    [switch] $UseSSL,
    [ValidateRange(0, 65535)][int] $Port = 0,
    [ValidateSet('Default', 'Kerberos', 'Negotiate', 'Basic')]
    [string] $Authentication = 'Default',
    [switch] $UseIPAddress,
    [Parameter(ParameterSetName = 'ProvidedCredential')]
    [PSCredential] $Credential,
    [Parameter(Mandatory = $true, ParameterSetName = 'AlwaysPrompt')]
    [switch] $AskAlwaysCred,
    [switch] $Help,
    [Parameter(Position = 0)][ValidateSet('--help')][string] $HelpOption
)

Set-StrictMode -Version Latest

$Usage = @'
USAGE
  .\__SCRIPT__ [-ObjectList FILE] [options]                     copy mode
  .\__SCRIPT__ -Exec FILE [options]                             exec mode
  .\__SCRIPT__ -Diff -LocalPath PATH -RemotePath PATH [options] diff mode

MODES (only one at a time)
  (none)                 Copy the objects listed in object.txt to the same remote paths
  -Exec FILE             Run one line per command: a PowerShell command or
                         COPY "local path" "remote path"
  -Diff                  Compare -LocalPath with -RemotePath (read-only)
    -LocalPath  / -L     local file or folder
    -RemotePath / -R     remote absolute path (e.g. D:\app\config)

CREDENTIALS
  (default)              Ask once, use for all systems
  -AskAlwaysCred         Ask for every system
  -Credential CRED       Use this credential, ask nothing (e.g. -Credential (Get-Credential))

FILES
  -PathOper DIR          Base folder for default files (default C:\temp)
  -SystemList FILE       hostname,ip list (default <PathOper>\systems.txt)
  -ObjectList FILE       Objects to copy (default <PathOper>\object.txt)
  -ResultsPath DIR       Results base folder (default <PathOper>\Results)
                         -> <ResultsPath>\<timestamp>\execution.log  and  results.txt

CONNECTION
  -ThrottleLimit N       Systems processed together (default 5, max 64)
  -ConnectTimeout N      Seconds to open the session (default 10)
  -CommandTimeout N      Max seconds per command, 0 = no limit (default 0)
  -UseIPAddress          Connect to the IP instead of the hostname
  -UseSSL                WinRM over HTTPS (port 5986)
  -Port N                Custom WinRM port
  -Authentication X      Default | Kerberos | Negotiate | Basic (Basic requires -UseSSL)

SAFETY
  -AllowDangerous        Do not block potentially destructive commands

OTHER
  -Help, --help          Show this help

EXIT CODES
  0 = all ok   1 = at least one error   2 = invalid parameters or input files
'@

# =============================================================================
# DANGEROUS COMMANDS
# This is a "common sense" check, not complete protection: command files
# must still be trusted. It is disabled with -AllowDangerous.
# To block one more command, just add it to one of the two lists.
# =============================================================================

# ALWAYS blocked: they shut down/restart the system or wipe disks.
$DangerousCommands = @('Stop-Computer', 'Restart-Computer', 'shutdown',
    'Format-Volume', 'Clear-Disk', 'Initialize-Disk', 'Remove-Partition',
    'format', 'diskpart', 'bcdedit')

# Blocked ONLY when they act on the root of a drive (e.g. "Remove-Item C:\ -Recurse").
$DangerousOnRoot = @('Remove-Item', 'rm', 'ri', 'del', 'erase', 'rd', 'rmdir')


function Test-DangerousCommand {
    param([string] $Line)
    # PowerShell parses the line and gives us the list of commands it contains
    # (also those after | and ; or inside { }). We only look at the command NAMES,
    # so "Get-Content C:\logs\shutdown.log" is NOT blocked.
    $tokens = $null; $errors = $null
    $parsed = [Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$errors)

    if ($errors.Count -gt 0) { throw "Invalid PowerShell command: '$Line' ($($errors[0].Message))" }

    $commands = $parsed.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)

    foreach ($command in $commands) {
        $name = $command.GetCommandName()            # e.g. "C:\Windows\System32\shutdown.exe"

        if (-not $name) { continue }

        $name = ($name -split '\\')[-1]                # remove the folder    -> "shutdown.exe"
        $name = $name -replace '\.(exe|com)$', ''      # remove the extension -> "shutdown"

        if ($DangerousCommands -contains $name) { return $true }

        if ($DangerousOnRoot -contains $name) {
            # Command arguments without quotes, e.g. 'C:\' or "C:\*"
            $arguments = @($command.CommandElements | ForEach-Object { $_.Extent.Text.Trim('"', "'") })
            # Root of a drive: C:  C:\  C:\*  \  \*
            foreach ($argument in $arguments) {
                if ($argument -match '^([A-Za-z]:\\?|\\)\*?$') { return $true }
            }
        }
    }

    return $false
}


# =============================================================================
# PLAN PREPARATION (done only once, before connecting)
# =============================================================================

function Read-InputLines {
    # Lines of a text file, without empty lines and comments (#).
    param([string] $Path)

    @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}


function Resolve-RemotePath {
    # Remote paths must be absolute (e.g. D:\app) and without wildcards.
    param([string] $Path)

    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2) -match '[:*?"<>|]') {
        throw "Use an absolute remote drive path without wildcards: '$Path'."
    }

    return [IO.Path]::GetFullPath($Path)
}


function New-CopyOperation {
    param([string] $Source, [string] $Destination, [string[]] $Exclusions = @())

    $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    [pscustomobject]@{
        Kind = 'Copy'; Source = $item.FullName; Destination = (Resolve-RemotePath $Destination)
        Exclusions = @($Exclusions); Text = "COPY '$($item.FullName)' '$Destination'"
    }
}


function Get-OperationPlan {
    # Turns the parameters and input files into a list of operations
    # (Copy, Command, Blocked, Skipped, Diff), the same for all systems.
    if ($Diff) {
        if (-not $LocalPath -or -not $RemotePath) { throw '-Diff requires -LocalPath and -RemotePath.' }

        $item = Get-Item -LiteralPath $LocalPath -Force -ErrorAction Stop

        return [pscustomobject]@{ Kind = 'Diff'; Source = $item.FullName
            Destination = (Resolve-RemotePath $RemotePath); Text = 'Compare paths' }
    }

    if ($LocalPath -or $RemotePath) { throw '-LocalPath and -RemotePath require -Diff.' }

    $plan = @()

    if ($Exec) {
        foreach ($line in (Read-InputLines $Exec)) {
            if ($line -match '^(?i)COPY\s') {
                # Format: COPY <local> <remote>; paths containing spaces need double quotes.
                if ($line -notmatch '^(?i)COPY\s+("[^"]+"|\S+)\s+("[^"]+"|\S+)\s*$') {
                    throw "Expected COPY <local_path> <remote_path>: '$line'."
                }

                $plan += New-CopyOperation $matches[1].Trim('"') $matches[2].Trim('"')
            } elseif ((Test-DangerousCommand $line) -and -not $AllowDangerous) {
                $plan += [pscustomobject]@{ Kind = 'Blocked'; Text = $line }
            } else {
                $plan += [pscustomobject]@{ Kind = 'Command'; Text = $line }
            }
        }
    } else {
        # object.txt: [file:|dir:]C:\path[\*.ext][:exclusion1,exclusion2]
        foreach ($line in (Read-InputLines $ObjectList)) {
            $mode = 'file'; $pattern = $line; $exclusions = @()

            if ($pattern -match '^(?i)(file|dir):(.+)$') {
                $mode = $matches[1].ToLowerInvariant(); $pattern = $matches[2].Trim()
            }

            if ($pattern -notmatch '^[A-Za-z]:\\') { throw "Object-list paths must be absolute drive paths: '$line'." }

            $separator = $pattern.IndexOf(':', 2)      # a ":" after "C:" starts the exclusions

            if ($separator -ge 0) {
                $exclusions = @($pattern.Substring($separator + 1).Split(',') |
                    ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $pattern = $pattern.Substring(0, $separator).Trim()
            }

            $parent = Split-Path $pattern -Parent

            if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($parent)) {
                throw "Wildcards in intermediate directories are unsupported: '$pattern'."
            }

            if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($pattern)) {
                $items = @(Get-ChildItem -LiteralPath $parent -Filter (Split-Path $pattern -Leaf) -Force -ErrorAction Stop |
                    Where-Object { ($mode -eq 'dir') -eq $_.PSIsContainer })
            } else {
                $items = @(Get-Item -LiteralPath $pattern -Force -ErrorAction Stop)
                if (($mode -eq 'dir') -ne $items[0].PSIsContainer) { throw "Wrong object type: '$pattern'." }
            }

            if ($items.Count -eq 0) { throw "No $mode items match '$pattern'." }

            foreach ($item in $items) {
                if ($exclusions -contains $item.Name) {
                    $plan += [pscustomobject]@{ Kind = 'Skipped'; Text = "Excluded: $($item.FullName)" }
                } else {
                    $plan += New-CopyOperation $item.FullName $item.FullName $exclusions
                }
            }
        }
    }

    if ($plan.Count -eq 0) { throw 'No operations were specified.' }

    return $plan
}


# =============================================================================
# FUNCTIONS RUN IN PARALLEL (one copy for each system)
# They only use their own parameters: no variables from the main script.
# =============================================================================

function Get-PathSnapshot {
    # List of files/directories under $Root with type and SHA256 hash.
    # Runs both locally and on the remote system. Links are not followed.
    param([string] $Root)

    $ErrorActionPreference = 'Stop'
    $pending = New-Object 'System.Collections.Generic.Queue[object]'
    $pending.Enqueue([pscustomobject]@{ Item = (Get-Item -LiteralPath $Root -Force); Relative = '' })

    while ($pending.Count) {
        $entry = $pending.Dequeue(); $item = $entry.Item
        $isLink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        $kind = if ($isLink) { 'Link' } elseif ($item.PSIsContainer) { 'Directory' } else { 'File' }
        $hash = if ($kind -eq 'File') { (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash } else { '' }
        [pscustomobject]@{ Relative = $entry.Relative; Kind = $kind; Hash = $hash }

        if ($kind -eq 'Directory') {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
                $relative = if ($entry.Relative) { $entry.Relative + '\' + $child.Name } else { $child.Name }
                $pending.Enqueue([pscustomobject]@{ Item = $child; Relative = $relative })
            }
        }
    }
}


function Invoke-IsolatedCommand {
    # Runs ON THE REMOTE SYSTEM: executes a command in a separate PowerShell process,
    # so we get separate stdout/stderr, the exit code ("exit N") and a real timeout.
    param([string] $Text, [int] $Timeout)

    $executable = Join-Path $PSHOME 'powershell.exe'

    if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe')) { $executable = Join-Path $PSHOME 'pwsh.exe' }

    $program = @'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
try {
    & {
__COMMAND__
    }
    if (-not $?) { exit 1 }
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.ToString())
    exit 1
}
'@
    $program = $program.Replace('__COMMAND__', $Text)
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $executable
    $process.StartInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' +
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process.StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process.StartInfo.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')

    try {
        [void]$process.Start()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()

        if ($Timeout -gt 0) {
            # Within the time limit both the process and the output reading must finish
            # (a child process still running could keep the output open).
            $finished = $process.WaitForExit($Timeout * 1000)

            if ($finished) {
                $remaining = [math]::Max(0, ($Timeout * 1000) - [int]$timer.ElapsedMilliseconds)
                $finished = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), $remaining)
            }
        } else {
            $process.WaitForExit(); $finished = $true
        }

        if (-not $finished) {
            return [pscustomobject]@{ ExitCode = -1; Stdout = ''; Stderr = "Command timed out after $Timeout seconds." }
        }

        [pscustomobject]@{ ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
    } finally {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }   # ignore if it never started

        $process.Dispose()
    }
}


function Copy-PathToRemote {
    # Copies a file or a directory (with all its content) to the remote system.
    param($Session, [string] $Source, [string] $Destination, [string[]] $Exclusions)

    $result = [pscustomobject]@{ Copied = 0; Skipped = 0; Failed = 0; Lines = @() }
    $pending = New-Object 'System.Collections.Generic.Queue[object]'
    $pending.Enqueue([pscustomobject]@{ Item = (Get-Item -LiteralPath $Source -Force); Target = $Destination })

    while ($pending.Count) {
        $entry = $pending.Dequeue(); $item = $entry.Item; $target = $entry.Target

        try {
            if ($Exclusions -contains $item.Name -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $result.Skipped++; $result.Lines += "Skipped exclusion/link: $($item.FullName)"; continue
            }

            # On the remote system: check that the type matches and create the needed directory.
            Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $target, $item.PSIsContainer -ScriptBlock {
                param($Path, $IsDirectory)

                if ((Test-Path -LiteralPath $Path) -and (Test-Path -LiteralPath $Path -PathType Container) -ne $IsDirectory) {
                    throw "Destination type conflict: '$Path'."
                }

                $folder = if ($IsDirectory) { $Path } else { Split-Path $Path -Parent }
                [void][IO.Directory]::CreateDirectory($folder)
            }

            if ($item.PSIsContainer) {
                foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
                    $pending.Enqueue([pscustomobject]@{ Item = $child; Target = $target.TrimEnd('\') + '\' + $child.Name })
                }
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination $target -ToSession $Session -Force -ErrorAction Stop
                $result.Copied++; $result.Lines += "Copied: $($item.FullName) -> $target"
            }
        } catch {
            $result.Failed++; $result.Lines += "FAILED: $($item.FullName): $($_.Exception.Message)"
        }
    }

    return $result
}


function Compare-LocalRemotePath {
    # Compares a local file or directory with the matching remote one.
    param($Session, [string] $Source, [string] $Destination)

    $local = @{}; $remote = @{}

    foreach ($entry in @(Get-PathSnapshot $Source)) { $local[$entry.Relative] = $entry }
    foreach ($entry in @(Invoke-Command -Session $Session -ScriptBlock ${function:Get-PathSnapshot} -ArgumentList $Destination -ErrorAction Stop)) {
        $remote[$entry.Relative] = $entry
    }

    $lines = @(); $different = 0; $identical = 0

    foreach ($key in @(@($local.Keys) + @($remote.Keys) | Sort-Object -Unique)) {
        $label = if ($key) { $key } else { '(root)' }

        if (-not $local.ContainsKey($key)) { $lines += "Only remote: $label ($($remote[$key].Kind))"; $different++; continue }
        if (-not $remote.ContainsKey($key)) { $lines += "Only local: $label ($($local[$key].Kind))"; $different++; continue }
        if ($local[$key].Kind -ne $remote[$key].Kind) {
            $lines += "Type differs: $label (local=$($local[$key].Kind), remote=$($remote[$key].Kind))"; $different++; continue
        }
        if ($local[$key].Kind -eq 'Link') { $lines += "Link not followed or compared: $label"; continue }
        if ($local[$key].Kind -ne 'File') { continue }
        if ($local[$key].Hash -eq $remote[$key].Hash) { $identical++; continue }

        # Different files: read both contents to compare them line by line.
        $different++
        $localFile = if ($key) { Join-Path $Source $key } else { $Source }
        $remoteFile = if ($key) { $Destination.TrimEnd('\') + '\' + $key } else { $Destination }
        $localBytes = [IO.File]::ReadAllBytes($localFile)
        $remoteBytes = [Convert]::FromBase64String((Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $remoteFile -ScriptBlock {
            param($Path) [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }))

        try {
            # A zero byte or non-UTF-8 text means a binary file.
            if ($localBytes -contains 0 -or $remoteBytes -contains 0) { throw 'binary' }

            $utf8 = New-Object Text.UTF8Encoding($false, $true)
            $localText = $utf8.GetString($localBytes); $remoteText = $utf8.GetString($remoteBytes)
        } catch { $lines += "Binary files differ: $label"; continue }

        $lines += "Differences found: $label"
        $lines += "  local file : $localFile"
        $lines += "  remote file: $remoteFile"
        # Every line becomes an object with its number, so we can say where it is.
        $n = 0; $localRows = @($localText.TrimEnd("`r", "`n") -split '\r\n|\n|\r' |
            ForEach-Object { $n++; [pscustomobject]@{ Line = $n; Text = $_; Side = 'LOCAL ' } })
        $n = 0; $remoteRows = @($remoteText.TrimEnd("`r", "`n") -split '\r\n|\n|\r' |
            ForEach-Object { $n++; [pscustomobject]@{ Line = $n; Text = $_; Side = 'REMOTE' } })
        # Compare-Object returns the lines present on only one side (-PassThru keeps Line and Side).
        $rows = @(Compare-Object $localRows $remoteRows -Property Text -PassThru -CaseSensitive -SyncWindow 1000)

        foreach ($row in ($rows | Sort-Object Side, Line)) {
            $text = if ($row.Text) { $row.Text } else { '(empty line)' }
            $lines += '  only {0} (line {1,4}): {2}' -f $row.Side, $row.Line, $text
        }

        if ($rows.Count -eq 0) { $lines += '  (same lines: only line endings or trailing empty lines differ)' }
    }

    $lines += "Comparison completed: differences=$different; identical files=$identical (links excluded)."
    return [pscustomobject]@{ Lines = $lines; Differences = $different }
}


function Invoke-HostOperation {
    # All the work on ONE system: open the session, run the plan, close the session.
    param($Task)

    # $result.Lines -> results.txt (full output)   $result.Log -> execution.log (events)
    $settings = $Task.Settings
    $result = [pscustomobject]@{ Hostname = $Task.System.Hostname; Endpoint = $Task.System.Endpoint
        Copied = 0; Skipped = 0; Failed = 0; Commands = 0; Differences = 0; Lines = @(); Log = @() }


    function Add-HostLog {
        # Collects one execution.log line with the current time; the main script writes it.
        param([string] $Level, [string] $Message)

        $result.Log += '{0:yyyy-MM-dd HH:mm:ss,fff} - {1}: [{2}] {3}' -f (Get-Date), $Level, $Task.System.Hostname, $Message
    }

    $session = $null

    try {
        Add-HostLog INFO "Connecting to $($Task.System.Endpoint) as '$($Task.Credential.UserName)'"
        $sessionParameters = @{
            ComputerName = $Task.System.Endpoint; Credential = $Task.Credential
            Authentication = $settings.Authentication; ErrorAction = 'Stop'
            SessionOption = (New-PSSessionOption -OpenTimeout ($settings.ConnectTimeout * 1000))
        }

        if ($settings.UseSSL) { $sessionParameters.UseSSL = $true }
        if ($settings.Port -gt 0) { $sessionParameters.Port = $settings.Port }

        $session = New-PSSession @sessionParameters
        $result.Lines += "Connected using WinRM: $($Task.System.Endpoint)"
        Add-HostLog INFO 'Connected'

        foreach ($operation in $Task.Plan) {
            $result.Lines += ''; $result.Lines += $operation.Text

            try {
                switch ($operation.Kind) {
                    'Blocked' {
                        $result.Skipped++; $result.Failed++
                        $result.Lines += 'SKIPPED: potentially destructive command; use -AllowDangerous for trusted commands.'
                        Add-HostLog WARNING "Skipped dangerous command: $($operation.Text)"
                    }
                    'Skipped' { $result.Skipped++ }
                    'Copy' {
                        $copy = Copy-PathToRemote $session $operation.Source $operation.Destination $operation.Exclusions
                        $result.Copied += $copy.Copied; $result.Skipped += $copy.Skipped; $result.Failed += $copy.Failed
                        $result.Lines += $copy.Lines
                        $level = if ($copy.Failed) { 'ERROR' } else { 'INFO' }
                        Add-HostLog $level "$($operation.Text): copied=$($copy.Copied), skipped=$($copy.Skipped), failed=$($copy.Failed)"
                    }
                    'Diff' {
                        $comparison = Compare-LocalRemotePath $session $operation.Source $operation.Destination
                        $result.Differences += $comparison.Differences
                        $result.Lines += $comparison.Lines
                        Add-HostLog INFO "Compared $($operation.Source) with $($operation.Destination): differences=$($comparison.Differences)"
                    }
                    'Command' {
                        Add-HostLog INFO "Executing: $($operation.Text)"
                        $command = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock ${function:Invoke-IsolatedCommand} `
                            -ArgumentList $operation.Text, $settings.CommandTimeout
                        $result.Commands++
                        $result.Lines += "EXIT $($command.ExitCode)"

                        if ($command.Stdout) { $result.Lines += '--- stdout ---'; $result.Lines += $command.Stdout.TrimEnd() }
                        if ($command.Stderr) { $result.Lines += '--- stderr ---'; $result.Lines += $command.Stderr.TrimEnd() }
                        if ($command.ExitCode -ne 0) { $result.Failed++ }

                        Add-HostLog INFO "Exit code $($command.ExitCode): $($operation.Text)"
                    }
                }
            } catch {
                $result.Failed++; $result.Lines += "FAILED: $($_.Exception.Message)"
                Add-HostLog ERROR "Failed: $($operation.Text) ($($_.Exception.Message))"
            }
        }
    } catch {
        $result.Failed++; $result.Lines += "FAILED: $($_.Exception.Message)"
        Add-HostLog ERROR "Failed: $($_.Exception.Message)"
    } finally {
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue; $result.Lines += 'Session closed.' }
    }

    $status = if ($result.Failed) { 'ERRORS' } else { 'OK' }
    Add-HostLog INFO "Finished: $status"
    return $result
}


# =============================================================================
# MAIN
# =============================================================================

if ($Help -or $HelpOption -eq '--help') { Write-Host $Usage.Replace('__SCRIPT__', (Split-Path -Leaf $PSCommandPath)); exit 0 }

try {
    if ($Exec -and $Diff) { throw '-Exec and -Diff are mutually exclusive.' }
    if (($Exec -or $Diff) -and $ObjectList) { throw '-ObjectList cannot be combined with -Exec or -Diff.' }
    if ($Authentication -eq 'Basic' -and -not $UseSSL) { throw '-Authentication Basic requires -UseSSL.' }
    if ($UseIPAddress -and $Authentication -eq 'Kerberos') { throw 'Kerberos requires a hostname, not -UseIPAddress.' }
    if (-not $SystemList) { $SystemList = Join-Path $PathOper 'systems.txt' }
    if (-not $ObjectList) { $ObjectList = Join-Path $PathOper 'object.txt' }
    if (-not $ResultsPath) { $ResultsPath = Join-Path $PathOper 'Results' }

    # systems.txt: one "hostname,ip" line per system; invalid lines are skipped with a warning.
    $systems = @()

    foreach ($line in (Read-InputLines $SystemList)) {
        $parts = @($line.Split(',') | ForEach-Object { $_.Trim() })
        # Exactly two fields, both filled in: "host5" or "host4," are not valid.
        if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) {
            Write-Warning "invalid line ignored in $SystemList (expected hostname,ip): $line"
            continue
        }

        # The second field must be a real IP address: "pippo" or "10.0.0.999" are not valid.
        # An IPv4 address must have 4 numbers: .NET would also accept short forms like "10" or "1.2.3".
        $parsed = $null
        $isIPv4 = $parts[1] -notmatch ':'

        if (-not [Net.IPAddress]::TryParse($parts[1], [ref]$parsed) -or ($isIPv4 -and $parts[1].Split('.').Count -ne 4)) {
            Write-Warning "invalid IP address, line ignored in ${SystemList}: $line"
            continue
        }

        $endpoint = if ($UseIPAddress) { $parts[1] } else { $parts[0] }
        $systems += [pscustomobject]@{ Hostname = $parts[0]; IP = $parts[1]; Endpoint = $endpoint }
    }

    if ($systems.Count -eq 0) { throw "No valid systems in '$SystemList'." }

    $plan = @(Get-OperationPlan)
} catch {
    Write-Host -ForegroundColor Red "Invalid configuration: $($_.Exception.Message)"
    exit 2
}

$logFile = $null

try {
    $ResultsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsPath)
    $runFolder = Join-Path $ResultsPath (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    [void][IO.Directory]::CreateDirectory($runFolder)
    $logFile = Join-Path $runFolder 'execution.log'      # events only (what happened and when)
    $resultsFile = Join-Path $runFolder 'results.txt'    # full output of every system
    $filesHealthy = $true


    function Add-RunFileText {
        # Appends text to execution.log or results.txt; a write error does not stop the run.
        param([string] $Path, [string[]] $Text)

        try { Add-Content -LiteralPath $Path -Value $Text -Encoding UTF8 -ErrorAction Stop }
        catch { $script:filesHealthy = $false; Write-Warning "Unable to write '$Path': $($_.Exception.Message)" }
    }

    $mode = if ($Diff) { 'diff' } elseif ($Exec) { 'exec' } else { 'copy' }
    Add-RunFileText $logFile ('{0:yyyy-MM-dd HH:mm:ss,fff} - INFO: Starting: mode={1}, systems={2}, systems file={3}' -f (Get-Date), $mode, $systems.Count, $SystemList)
    $header = @(("Run started: {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)), "Mode: $mode", "Systems file: $SystemList")

    if ($Diff) { $header += "Compare: $LocalPath (local) <-> $RemotePath (remote)" }
    elseif ($Exec) { $header += "Commands file: $Exec" }
    else { $header += "Object list: $ObjectList" }

    Add-RunFileText $resultsFile $header

    $settings = @{ UseSSL = [bool]$UseSSL; Port = $Port; Authentication = $Authentication
        ConnectTimeout = $ConnectTimeout; CommandTimeout = $CommandTimeout }
    $sharedCredential = $Credential
    $tasks = @()

    foreach ($system in $systems) {
        if ($AskAlwaysCred) {
            $hostCredential = Get-Credential -Message "Enter the credential for '$($system.Hostname)'"
        } else {
            if (-not $sharedCredential) { $sharedCredential = Get-Credential -Message 'Enter the credential for all remote systems' }

            $hostCredential = $sharedCredential
        }

        if (-not $hostCredential) { throw "Credential request cancelled for '$($system.Hostname)'." }

        $tasks += [pscustomobject]@{ System = $system; Credential = $hostCredential; Settings = $settings; Plan = $plan }
    }

    $initialState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    foreach ($functionName in 'Get-PathSnapshot', 'Invoke-IsolatedCommand', 'Copy-PathToRemote',
                              'Compare-LocalRemotePath', 'Invoke-HostOperation') {
        $definition = (Get-Item "function:$functionName").Definition
        $initialState.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry $functionName, $definition))
    }

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit, $initialState, $Host)
    $pool.Open()
    $workers = @()

    foreach ($task in $tasks) {
        $worker = [PowerShell]::Create()
        $worker.RunspacePool = $pool
        [void]$worker.AddScript('param($Task) Set-StrictMode -Version Latest; Invoke-HostOperation $Task').AddArgument($task)
        $workers += [pscustomobject]@{ PowerShell = $worker; Handle = $worker.BeginInvoke(); Task = $task }
    }

    $totals = @{ Copied = 0; Skipped = 0; Failed = 0; Commands = 0; Differences = 0 }

    foreach ($worker in $workers) {
        $output = @($worker.PowerShell.EndInvoke($worker.Handle))

        if ($output.Count -eq 1) {
            $result = $output[0]
        } else {
            $result = [pscustomobject]@{ Hostname = $worker.Task.System.Hostname; Endpoint = $worker.Task.System.Endpoint
                Copied = 0; Skipped = 0; Failed = 1; Commands = 0; Differences = 0
                Lines = @("Worker failed: $($worker.PowerShell.Streams.Error | Out-String)")
                Log = @('{0:yyyy-MM-dd HH:mm:ss,fff} - ERROR: [{1}] Worker failed' -f (Get-Date), $worker.Task.System.Hostname) }
        }

        $worker.PowerShell.Dispose()

        foreach ($key in @($totals.Keys)) { $totals[$key] += $result.$key }

        $text = (@('', ('=' * 80), "HOST: $($result.Hostname) ($($result.Endpoint))", ('=' * 80)) + @($result.Lines) +
            "Result: copied=$($result.Copied), skipped=$($result.Skipped), commands=$($result.Commands), differences=$($result.Differences), failed=$($result.Failed).") -join [Environment]::NewLine
        Write-Host $text
        Add-RunFileText $resultsFile $text

        if ($result.Log) { Add-RunFileText $logFile $result.Log }
    }

    $pool.Close(); $pool.Dispose()

    $summary = "Overall: copied=$($totals.Copied), skipped=$($totals.Skipped), commands=$($totals.Commands), differences=$($totals.Differences), failed=$($totals.Failed)."
    Add-RunFileText $resultsFile @('', $summary)
    Add-RunFileText $logFile ('{0:yyyy-MM-dd HH:mm:ss,fff} - INFO: {1}' -f (Get-Date), $summary)
    Write-Host $summary
    Write-Host "Results: $resultsFile"
    Write-Host "Log:     $logFile"

    if ($totals.Failed -gt 0 -or -not $filesHealthy) { exit 1 }

    exit 0
} catch {
    $message = "Operation failed: $($_.Exception.Message)"
    Write-Host -ForegroundColor Red $message

    if ($logFile) { Add-RunFileText $logFile ('{0:yyyy-MM-dd HH:mm:ss,fff} - ERROR: {1}' -f (Get-Date), $message) }
    
    exit 1
}