################################################################################################################
## Description: Program to execute commands, copy files or compare paths on remote Windows systems over WinRM
##
## Author: Matteo Z.
################################################################################################################

#requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'ReuseCredential', PositionalBinding = $false, SupportsShouldProcess = $true)]
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

CREDENTIALS (user name and password are asked in the console)
  (default)              Ask once, use for all systems
  -AskAlwaysCred         Ask for every system
  -Credential CRED       Use this PSCredential, ask nothing (e.g. -Credential $cred)

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
  -WhatIf                Dry run: show what would be done, without asking
                         credentials and without connecting to any system

OTHER
  -Help, --help          Show this help

INPUT FILES (empty lines and lines starting with # are ignored)
  systems.txt            One system per line: hostname,ip (both required)
                             host1,<IP1>
                             host2,<IP2>
                             host3,<IP3>

  commands file          One PowerShell command per line, run in order on every system
  (-Exec)                (each line runs in its own process: variables do not carry over)
                             Get-Service -Name WinRM
                             (Get-CimInstance Win32_OperatingSystem).Caption
                             COPY "C:\temp\to-copy.txt" "C:\temp\to-copy.txt"
                             Get-Content C:\temp\to-copy.txt

  object.txt             One object per line, copied to the SAME path on every system:
  (copy mode)            [file:|dir:]C:\path[\*.ext][:exclusion1,exclusion2]
                             file:C:\temp\to-copy.txt
                             dir:C:\scripts:old,temp
                             file:C:\certs\*.pem

EXAMPLES
  .\__SCRIPT__ -Exec C:\temp\commands.txt -WhatIf
  .\__SCRIPT__ -Exec C:\temp\commands.txt
  .\__SCRIPT__ -Exec C:\temp\commands.txt -AskAlwaysCred
  .\__SCRIPT__ -Diff -L C:\temp\to-copy.txt -R C:\temp\to-copy.txt
  .\__SCRIPT__ -ObjectList C:\temp\object.txt -Credential $cred

EXIT CODES
  0 = all ok   1 = at least one error   2 = invalid parameters or input files
'@

# ==================================================================
# DANGEROUS COMMANDS (disable with -AllowDangerous)
# To block one more command, just add it to one of the two lists
# ==================================================================

# ALWAYS blocked: they shut down/restart the system or wipe disks
$DangerousCommands = @('Stop-Computer', 'Restart-Computer', 'shutdown',
    'Format-Volume', 'Clear-Disk', 'Initialize-Disk', 'Remove-Partition',
    'format', 'diskpart', 'bcdedit')

# Blocked ONLY when they act on the root of a drive or on a main system folder (e.g. "Remove-Item C:\ -Recurse", "Remove-Item C:\Windows -Recurse")
$DangerousOnRoot = @('Remove-Item', 'rm', 'ri', 'del', 'erase', 'rd', 'rmdir')

# Main system folders protected from the commands above (their sub-folders are not)
# The root of every drive (C:\, D:\ ...) is always protected
$ProtectedPaths = @('C:\Windows', 'C:\Windows\System32', 'C:\Program Files', 'C:\Program Files (x86)',
    'C:\ProgramData', 'C:\Users')


function Test-DangerousCommand {
    # PowerShell parses the line and gives us the list of commands it contains (also those after | and ; or inside { }). We only look at the command NAMES,
    # so "Get-Content C:\logs\shutdown.log" is NOT blocked
    param([string] $Line)

    $tokens = $null; $errors = $null
    $parsed = [Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$errors)

    if ($errors.Count -gt 0) { throw "invalid PowerShell syntax: $($errors[0].Message)" }

    $commands = $parsed.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)

    foreach ($command in $commands) {
        $name = $command.GetCommandName()            # e.g. "C:\Windows\System32\shutdown.exe"

        if (-not $name) { continue }

        $name = ($name -split '\\')[-1]                # remove the folder    -> "shutdown.exe"
        $name = $name -replace '\.(exe|com)$', ''      # remove the extension -> "shutdown"

        if ($DangerousCommands -contains $name) { return $true }

        if ($DangerousOnRoot -contains $name) {
            foreach ($element in $command.CommandElements) {
                $argument = $element.Extent.Text.Trim('"', "'")          # argument without quotes

                if ($argument -notmatch '^([A-Za-z]:|\\)') { continue }  # only absolute paths, so "Remove-Item *" is not blocked

                # "C:\Windows", "C:\Windows\" and "C:\Windows\*" all mean the folder C:\Windows
                $path = $argument.TrimEnd('*').TrimEnd('\')

                if ($path -eq '' -or $path -match '^[A-Za-z]:$') { return $true }    # root of a drive: C:  C:\  C:\*  \  \*
                if ($ProtectedPaths -contains $path) { return $true }                # system folder (not case-sensitive)
            }
        }
    }

    return $false
}


function Read-InputLines {
    # Lines of a text file, without empty lines and comments (#)
    param([string] $Path)

    @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}


function Read-Credential {
    # Asks user name and password in the console. The Get-Credential window is not used because it can stay hidden
    param([string] $Target)

    $user = Read-Host "Username for $Target"

    if (-not $user) { return $null }          # empty user name = request cancelled

    $password = Read-Host "Password for $user on $Target" -AsSecureString
    New-Object System.Management.Automation.PSCredential($user, $password)
}


function Resolve-RemotePath {
    # Remote paths must be absolute (e.g. D:\app) and without wildcards
    param([string] $Path)

    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2) -match '[:*?"<>|]') {
        throw "Use an absolute remote drive path without wildcards: '$Path'."
    }

    return [IO.Path]::GetFullPath($Path)
}


function New-InvalidOperation {
    # A line of the commands file or of object.txt that cannot be used.
    # The run does NOT stop: a warning is shown now, and the line is reported as SKIPPED
    # (and counted as failed) on every system, while all the other lines still run
    param([string] $Line, [string] $Reason)

    Write-Warning "line skipped: $Line   ($Reason)"
    [pscustomobject]@{ Kind = 'Invalid'; Text = $Line; Reason = $Reason }
}


function New-CopyOperation {
    # Prepares one copy. Errors (e.g. a local path that does not exist) are thrown and the
    # caller turns them into an "Invalid" operation
    param([string] $Source, [string] $Destination, [string[]] $Exclusions = @())

    $remotePath = Resolve-RemotePath $Destination

    if (-not (Test-Path -LiteralPath $Source)) { throw "local path not found: $Source" }

    $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    [pscustomobject]@{
        Kind = 'Copy'; Source = $item.FullName; Destination = $remotePath
        Exclusions = @($Exclusions); Text = "COPY '$($item.FullName)' '$Destination'"
    }
}


function Test-Excluded {
    # True if $Name matches one of the exclusions (wildcards allowed, e.g. "2026*" or "*.log")
    param([string] $Name, [string[]] $Exclusions)

    foreach ($exclusion in $Exclusions) { if ($Name -like $exclusion) { return $true } }

    return $false
}


function Get-OperationPlan {
    # Turns the parameters and input files into a list of operations (Copy, Command, Blocked, Skipped, Invalid, Diff), the same for all systems.
    # A wrong line does not stop the run: it becomes an "Invalid" operation (see New-InvalidOperation)
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
            try {
                if ($line -match '^(?i)COPY\s') {
                    # Format: COPY <local> <remote>; paths containing spaces need double quotes
                    if ($line -notmatch '^(?i)COPY\s+("[^"]+"|\S+)\s+("[^"]+"|\S+)\s*$') {
                        throw 'expected: COPY <local_path> <remote_path>'
                    }

                    $plan += New-CopyOperation $matches[1].Trim('"') $matches[2].Trim('"')
                } elseif ((Test-DangerousCommand $line) -and -not $AllowDangerous) {
                    $plan += [pscustomobject]@{ Kind = 'Blocked'; Text = $line }
                } else {
                    $plan += [pscustomobject]@{ Kind = 'Command'; Text = $line }
                }
            } catch {
                $plan += New-InvalidOperation $line $_.Exception.Message
            }
        }
    } else {
        # object.txt: [file:|dir:]C:\path[\*.ext][:exclusion1,exclusion2]
        foreach ($line in (Read-InputLines $ObjectList)) {
            try {
                $mode = 'file'; $pattern = $line; $exclusions = @()

                if ($pattern -match '^(?i)(file|dir):(.+)$') {
                    $mode = $matches[1].ToLowerInvariant(); $pattern = $matches[2].Trim()
                } elseif ($pattern -match '^([A-Za-z]{2,}):') {
                    # A word before ":" that is not a drive letter (e.g. "fil:"): a typo in the prefix
                    throw "unknown prefix '$($matches[1]):', use file: or dir:"
                }

                if ($pattern -notmatch '^[A-Za-z]:\\') { throw 'the path must be an absolute drive path (e.g. C:\...)' }

                $separator = $pattern.IndexOf(':', 2)      # a ":" after "C:" starts the exclusions

                if ($separator -ge 0) {
                    $exclusions = @($pattern.Substring($separator + 1).Split(',') |
                        ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    $pattern = $pattern.Substring(0, $separator).Trim()
                }

                $parent = Split-Path $pattern -Parent

                if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($parent)) {
                    throw 'wildcards are allowed only in the last part of the path'
                }

                if (-not (Test-Path -LiteralPath $parent)) { throw "local folder not found: $parent" }

                if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($pattern)) {
                    $items = @(Get-ChildItem -LiteralPath $parent -Filter (Split-Path $pattern -Leaf) -Force -ErrorAction Stop |
                        Where-Object { ($mode -eq 'dir') -eq $_.PSIsContainer })

                    if ($items.Count -eq 0) { throw "no local $mode matches $pattern" }
                } else {
                    if (-not (Test-Path -LiteralPath $pattern)) { throw "local path not found: $pattern" }

                    $items = @(Get-Item -LiteralPath $pattern -Force -ErrorAction Stop)

                    if ($mode -eq 'file' -and $items[0].PSIsContainer) { throw 'this is a folder, use dir:' }
                    if ($mode -eq 'dir' -and -not $items[0].PSIsContainer) { throw 'this is a file, use file:' }
                }

                foreach ($item in $items) {
                    if (Test-Excluded $item.Name $exclusions) {
                        $plan += [pscustomobject]@{ Kind = 'Skipped'; Text = "Excluded: $($item.FullName)" }
                    } else {
                        $plan += New-CopyOperation $item.FullName $item.FullName $exclusions
                    }
                }
            } catch {
                $plan += New-InvalidOperation $line $_.Exception.Message
            }
        }
    }

    # Stop only if nothing at all can be done
    if (@($plan | Where-Object { $_.Kind -ne 'Invalid' -and $_.Kind -ne 'Skipped' }).Count -eq 0) {
        throw 'No valid operations (all the lines were skipped or excluded).'
    }

    return $plan
}


function Get-PathSnapshot {
    # List of files/directories under $Root with type, size and SHA256 hash. Runs both locally and on the remote system. Links are not followed
    param([string] $Root)

    $ErrorActionPreference = 'Stop'
    $pending = New-Object 'System.Collections.Generic.Queue[object]'
    $pending.Enqueue([pscustomobject]@{ Item = (Get-Item -LiteralPath $Root -Force); Relative = '' })

    while ($pending.Count) {
        $entry = $pending.Dequeue(); $item = $entry.Item
        $isLink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        $kind = if ($isLink) { 'Link' } elseif ($item.PSIsContainer) { 'Directory' } else { 'File' }
        $hash = if ($kind -eq 'File') { (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash } else { '' }
        $size = if ($kind -eq 'File') { $item.Length } else { 0 }
        [pscustomobject]@{ Relative = $entry.Relative; Kind = $kind; Hash = $hash; Length = $size }

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
    # so we get separate stdout/stderr, the exit code ("exit N") and a real timeout
    param([string] $Text, [int] $Timeout)

    function Stop-ProcessTree {
        # Stops a process AND every process it started (children, grandchildren...). Windows remembers the parent of each process (ParentProcessId), so we start
        # from our process and collect its descendants level by level. Only processes created after $StartedAfter are considered, so an old process
        # that reuses the same id is never touched
        param([int] $ProcessId, [datetime] $StartedAfter)

        $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $tree = @($ProcessId)
        $index = 0

        while ($index -lt $tree.Count) {
            foreach ($candidate in $allProcesses) {
                if ($candidate.ParentProcessId -eq $tree[$index] -and $candidate.CreationDate -ge $StartedAfter -and
                    $tree -notcontains [int]$candidate.ProcessId) {
                    $tree += [int]$candidate.ProcessId
                }
            }

            $index++
        }

        foreach ($id in $tree) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    }

    $executable = Join-Path $PSHOME 'powershell.exe'

    if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe')) { $executable = Join-Path $PSHOME 'pwsh.exe' }

    $program = @'
$ProgressPreference = 'SilentlyContinue'
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
    $startTime = (Get-Date).AddSeconds(-1)

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
            # Time is over: stop the command and everything it started, otherwise programs
            # launched by the command (e.g. an .exe) would keep running on the server.
            Stop-ProcessTree -ProcessId $process.Id -StartedAfter $startTime
            return [pscustomobject]@{ ExitCode = -1; Stdout = ''; Stderr = "Command timed out after $Timeout seconds (the command and its child processes were stopped)." }
        }

        $errorText = $stderr.GetAwaiter().GetResult()

        if ($errorText.StartsWith('#< CLIXML')) {
            # PowerShell wrote its streams as XML: keep only the real error messages (progress bars and other records are dropped)
            try {
                $xml = [xml]$errorText.Substring(9)
                $messages = @($xml.Objs.ChildNodes |
                    Where-Object { $_.Name -eq 'S' -and $_.GetAttribute('S') -eq 'Error' } |
                    ForEach-Object { $_.InnerText })
                $errorText = ($messages -join '') -replace '_x000D__x000A_', "`n" -replace '_x000A_', "`n"
            } catch { }       # not valid XML: keep the text as it is
        }

        [pscustomobject]@{ ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $errorText }
    } finally {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }   # ignore if it never started

        $process.Dispose()
    }
}


function Copy-PathToRemote {
    # Copies a file or a folder (with all its content) to the remote system.
    # To be fast it works in 3 steps, with only ONE remote call before sending the files:
    #   1. locally: list the folders to create and the files to send (no network)
    #   2. remotely, in one call: check the destinations and create all the folders
    #   3. send the files
    param($Session, [string] $Source, [string] $Destination, [string[]] $Exclusions)

    $result = [pscustomobject]@{ Copied = 0; Skipped = 0; Failed = 0; Lines = @() }

    # --- 1. Local list of folders and files (exclusions and links are skipped here) ---
    $folders = @(); $files = @()
    $pending = New-Object 'System.Collections.Generic.Queue[object]'
    $pending.Enqueue([pscustomobject]@{ Item = (Get-Item -LiteralPath $Source -Force); Target = $Destination })

    while ($pending.Count) {
        $entry = $pending.Dequeue(); $item = $entry.Item

        if ((Test-Excluded $item.Name $Exclusions) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $result.Skipped++; $result.Lines += "Skipped exclusion/link: $($item.FullName)"; continue
        }

        if (-not $item.PSIsContainer) {
            $files += [pscustomobject]@{ Source = $item.FullName; Target = $entry.Target }
            continue
        }

        $folders += $entry.Target

        try {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
                $pending.Enqueue([pscustomobject]@{ Item = $child; Target = $entry.Target.TrimEnd('\') + '\' + $child.Name })
            }
        } catch {
            $result.Failed++; $result.Lines += "FAILED: cannot read $($item.FullName): $($_.Exception.Message)"
        }
    }

    # --- 2. ONE remote call: create all the folders and check every destination ---
    # It returns the destinations that cannot be used (e.g. a file where a folder is expected)
    $fileTargets = @($files | ForEach-Object { $_.Target })
    $problems = @(Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $folders, $fileTargets -ScriptBlock {
        param([string[]] $Folders, [string[]] $Files)

        foreach ($path in $Folders) {
            try {
                if (Test-Path -LiteralPath $path -PathType Leaf) { throw 'a file with this name already exists' }

                [void][IO.Directory]::CreateDirectory($path)
            } catch { [pscustomobject]@{ Path = $path; Message = $_.Exception.Message } }
        }

        foreach ($path in $Files) {
            try {
                if (Test-Path -LiteralPath $path -PathType Container) { throw 'a folder with this name already exists' }

                [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
            } catch { [pscustomobject]@{ Path = $path; Message = $_.Exception.Message } }
        }
    })

    $unusable = @{}

    foreach ($problem in $problems) {
        $unusable[$problem.Path] = $true
        $result.Failed++; $result.Lines += "FAILED: destination $($problem.Path): $($problem.Message)"
    }

    # --- 3. Send the files (only those with a usable destination) ---
    foreach ($file in $files) {
        if ($unusable.ContainsKey($file.Target)) { continue }

        try {
            Copy-Item -LiteralPath $file.Source -Destination $file.Target -ToSession $Session -Force -ErrorAction Stop
            $result.Copied++; $result.Lines += "Copied: $($file.Source) -> $($file.Target)"
        } catch {
            $result.Failed++; $result.Lines += "FAILED: $($file.Source): $($_.Exception.Message)"
        }
    }

    return $result
}


function Get-LineDifferences {
    # Exact line-by-line comparison of two texts.
    # Outputs one line for every text line that is only in the local file or only in the remote one.
    param([string] $LocalText, [string] $RemoteText)

    # Split the texts into lines; a final line break does not create an extra empty line
    $local = [regex]::Split($LocalText, '\r\n|\n|\r')

    if ($local[-1] -eq '') { $local = @($local | Select-Object -First ($local.Count - 1)) }

    $remote = [regex]::Split($RemoteText, '\r\n|\n|\r')

    if ($remote[-1] -eq '') { $remote = @($remote | Select-Object -First ($remote.Count - 1)) }

    # 1. Skip the lines that are equal at the beginning and at the end of the files:
    #    it is fast and usually leaves only a small part to compare
    $first = 0

    while ($first -lt $local.Count -and $first -lt $remote.Count -and $local[$first] -ceq $remote[$first]) { $first++ }

    $lastLocal = $local.Count - 1; $lastRemote = $remote.Count - 1

    while ($lastLocal -ge $first -and $lastRemote -ge $first -and $local[$lastLocal] -ceq $remote[$lastRemote]) {
        $lastLocal--; $lastRemote--
    }

    $n = $lastLocal - $first + 1         # changed lines on the local side
    $m = $lastRemote - $first + 1        # changed lines on the remote side

    # 2. With too many changed lines a detailed comparison would take too long
    if ($n * $m -gt 1000000) { "  (too many changed lines to list them: $n local, $m remote)"; return }

    # 3. Table of common lines: $common[i, j] = how many lines, in the same order, the local
    #    lines from i onwards and the remote lines from j onwards have in common
    $common = New-Object 'int[,]' ($n + 1), ($m + 1)

    for ($i = $n - 1; $i -ge 0; $i--) {
        $nextI = $i + 1

        for ($j = $m - 1; $j -ge 0; $j--) {
            $nextJ = $j + 1

            if ($local[$first + $i] -ceq $remote[$first + $j]) {
                $common[$i, $j] = $common[$nextI, $nextJ] + 1
            } else {
                $below = $common[$nextI, $j]
                $right = $common[$i, $nextJ]

                if ($below -ge $right) { $common[$i, $j] = $below } else { $common[$i, $j] = $right }
            }
        }
    }

    # 4. Walk the table: equal lines are skipped, the others are "only LOCAL" or "only REMOTE".
    $i = 0; $j = 0
    
    while ($i -lt $n -or $j -lt $m) {
        $takeLocal = $false

        if ($j -ge $m) {
            $takeLocal = $true                                  # remote side finished: only local lines left
        } elseif ($i -lt $n) {
            $nextI = $i + 1; $nextJ = $j + 1
            $takeLocal = $common[$nextI, $j] -ge $common[$i, $nextJ]
        }

        if ($i -lt $n -and $j -lt $m -and $local[$first + $i] -ceq $remote[$first + $j]) {
            $i++; $j++
        } elseif ($takeLocal) {
            $text = if ($local[$first + $i]) { $local[$first + $i] } else { '(empty line)' }
            '  only LOCAL  (line {0,4}): {1}' -f ($first + $i + 1), $text
            $i++
        } else {
            $text = if ($remote[$first + $j]) { $remote[$first + $j] } else { '(empty line)' }
            '  only REMOTE (line {0,4}): {1}' -f ($first + $j + 1), $text
            $j++
        }
    }
}


function Compare-LocalRemotePath {
    # Compares a local file or directory with the matching remote one
    param($Session, [string] $Source, [string] $Destination)

    $maxBytes = 5MB     # bigger files are reported as different, without the line-by-line detail
    $local = @{}; $remote = @{}

    foreach ($entry in @(Get-PathSnapshot $Source)) { $local[$entry.Relative] = $entry }
    foreach ($entry in @(Invoke-Command -Session $Session -ScriptBlock ${function:Get-PathSnapshot} -ArgumentList $Destination -ErrorAction Stop)) {
        $remote[$entry.Relative] = $entry
    }

    $lines = @(); $different = 0; $identical = 0

    foreach ($key in @(@($local.Keys) + @($remote.Keys) | Sort-Object -Unique)) {
        # $key is the path relative to the compared folder; it is empty for the compared item itself
        $label = if ($key) { $key } else { Split-Path $Source -Leaf }

        if (-not $local.ContainsKey($key)) { $lines += "Only remote: $label ($($remote[$key].Kind))"; $different++; continue }
        if (-not $remote.ContainsKey($key)) { $lines += "Only local: $label ($($local[$key].Kind))"; $different++; continue }
        if ($local[$key].Kind -ne $remote[$key].Kind) {
            $lines += "Type differs: $label (local=$($local[$key].Kind), remote=$($remote[$key].Kind))"; $different++; continue
        }
        if ($local[$key].Kind -eq 'Link') { $lines += "Link not followed or compared: $label"; continue }
        if ($local[$key].Kind -ne 'File') { continue }
        if ($local[$key].Hash -eq $remote[$key].Hash) { $identical++; continue }

        $different++

        if ($local[$key].Length -gt $maxBytes -or $remote[$key].Length -gt $maxBytes) {
            $lines += "Files differ: $label (larger than $($maxBytes / 1MB) MB, not compared line by line)"; continue
        }

        $localFile = if ($key) { Join-Path $Source $key } else { $Source }
        $remoteFile = if ($key) { $Destination.TrimEnd('\') + '\' + $key } else { $Destination }
        $localBytes = [IO.File]::ReadAllBytes($localFile)
        $remoteBytes = [Convert]::FromBase64String((Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $remoteFile -ScriptBlock {
            param($Path) [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }))

        try {
            # A zero byte or non-UTF-8 text means a binary file
            if ($localBytes -contains 0 -or $remoteBytes -contains 0) { throw 'binary' }

            $utf8 = New-Object Text.UTF8Encoding($false, $true)
            $localText = $utf8.GetString($localBytes); $remoteText = $utf8.GetString($remoteBytes)
        } catch { $lines += "Binary files differ: $label"; continue }

        $lines += "Differences found: $label"
        $lines += "  local file : $localFile"
        $lines += "  remote file: $remoteFile"
        $details = @(Get-LineDifferences $localText $remoteText)

        if ($details.Count -eq 0) { $details = @('  (same lines: only line endings differ, e.g. Windows CRLF vs Linux LF)') }

        $lines += $details
    }

    $lines += "Comparison completed: differences=$different; identical files=$identical (links excluded)."
    
    return [pscustomobject]@{ Lines = $lines; Differences = $different }
}


function Invoke-HostOperation {
    # All the work on ONE system: open the session, run the plan, close the session
    param($Task)

    # $result.Lines -> results.txt (full output)   Add-HostLog -> execution.log (events)
    $settings = $Task.Settings
    $result = [pscustomobject]@{ Hostname = $Task.System.Hostname; Endpoint = $Task.System.Endpoint
        Copied = 0; Skipped = 0; Failed = 0; Commands = 0; Differences = 0; Lines = @() }


    function Add-HostLog {
        # Puts one execution.log line, with the current time, in the queue shared by all the systems; the main script empties the queue into the file
        # a few times a second, so the log is in chronological order
        param([string] $Level, [string] $Message)

        $Task.LogQueue.Enqueue(('{0:yyyy-MM-dd HH:mm:ss,fff} - {1}: [{2}] {3}' -f (Get-Date), $Level, $Task.System.Hostname, $Message))
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
                    'Invalid' {
                        $result.Skipped++; $result.Failed++
                        $result.Lines += "SKIPPED: $($operation.Reason)"
                        Add-HostLog ERROR "Line skipped: $($operation.Text) ($($operation.Reason))"
                    }
                    'Missing' {
                        $result.Skipped++; $result.Failed++
                        $result.Lines += "SKIPPED: local path not found: $($operation.Source)"
                        Add-HostLog ERROR "Local path not found, copy skipped: $($operation.Source)"
                    }
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
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            $result.Lines += ''
            $result.Lines += 'Session closed.'
        }
    }

    $status = if ($result.Failed) { 'ERRORS' } else { 'OK' }
    Add-HostLog INFO "Finished: $status"

    return $result
}


########## MAIN ##########

if ($Help -or $HelpOption -eq '--help') { Write-Host $Usage.Replace('__SCRIPT__', (Split-Path -Leaf $PSCommandPath)); exit 0 }

try {
    if ($Exec -and $Diff) { throw '-Exec and -Diff are mutually exclusive.' }
    if (($Exec -or $Diff) -and $ObjectList) { throw '-ObjectList cannot be combined with -Exec or -Diff.' }
    if ($Authentication -eq 'Basic' -and -not $UseSSL) { throw '-Authentication Basic requires -UseSSL.' }
    if ($UseIPAddress -and $Authentication -eq 'Kerberos') { throw 'Kerberos requires a hostname, not -UseIPAddress.' }
    if (-not $SystemList) { $SystemList = Join-Path $PathOper 'systems.txt' }
    if (-not $ObjectList) { $ObjectList = Join-Path $PathOper 'object.txt' }
    if (-not $ResultsPath) { $ResultsPath = Join-Path $PathOper 'Results' }

    # systems.txt: one "hostname,ip" line per system; invalid lines are skipped with a warning
    $systems = @(); $skippedSystems = 0

    foreach ($line in (Read-InputLines $SystemList)) {
        $parts = @($line.Split(',') | ForEach-Object { $_.Trim() })

        if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) {
            Write-Warning "invalid line ignored in $SystemList (expected hostname,ip): $line"
            $skippedSystems++; continue
        }

        # The second field must be a real IP address
        $parsed = $null
        $isIPv4 = $parts[1] -notmatch ':'

        if (-not [Net.IPAddress]::TryParse($parts[1], [ref]$parsed) -or ($isIPv4 -and $parts[1].Split('.').Count -ne 4)) {
            Write-Warning "invalid IP address, line ignored in ${SystemList}: $line"
            $skippedSystems++; continue
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


# --- Dry run (-WhatIf): show the plan and stop. No credentials, no connections, no files. ---
if ($WhatIfPreference) {
    Write-Host 'DRY RUN (-WhatIf) - nothing is executed, no connection is opened, no file is written.'
    Write-Host ''
    Write-Host "Systems ($($systems.Count) valid, $skippedSystems skipped):"

    foreach ($system in $systems) { Write-Host "  $($system.Hostname)  (connect to: $($system.Endpoint))" }

    Write-Host ''
    Write-Host 'Operations, in this order, on every system:'

    foreach ($operation in $plan) {
        switch ($operation.Kind) {
            'Command' { Write-Host "  RUN      $($operation.Text)" }
            'Blocked' { Write-Host "  BLOCKED  $($operation.Text)   (use -AllowDangerous to run it)" }
            'Skipped' { Write-Host "  SKIP     $($operation.Text)" }
            'Invalid' { Write-Host "  SKIPPED  $($operation.Text)   ($($operation.Reason))" }
            'Missing' { Write-Host "  SKIPPED  $($operation.Text)   (local path not found)" }
            'Diff'    { Write-Host "  DIFF     $($operation.Source) (local) <-> $($operation.Destination) (remote)" }
            'Copy' {
                $kind = if (Test-Path -LiteralPath $operation.Source -PathType Container) { 'folder' } else { 'file' }
                $note = if ($operation.Exclusions.Count) { ", excluding: $($operation.Exclusions -join ', ')" } else { '' }
                Write-Host "  COPY     $($operation.Source) -> $($operation.Destination)   ($kind$note)"
            }
        }
    }

    $blocked = @($plan | Where-Object { $_.Kind -eq 'Blocked' }).Count
    $invalid = @($plan | Where-Object { $_.Kind -eq 'Invalid' }).Count
    Write-Host ''
    Write-Host "Operations: $($plan.Count) per system ($blocked blocked, $invalid skipped because of errors)."
    exit 0
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
        # Appends text to execution.log or results.txt; a write error does not stop the run
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
    $logQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $sharedCredential = $Credential
    $tasks = @()

    foreach ($system in $systems) {
        if ($AskAlwaysCred) {
            $hostCredential = Read-Credential $system.Hostname
        } else {
            if (-not $sharedCredential) { $sharedCredential = Read-Credential 'all systems' }

            $hostCredential = $sharedCredential
        }

        if (-not $hostCredential) { throw "Credential request cancelled for '$($system.Hostname)'." }

        $tasks += [pscustomobject]@{ System = $system; Credential = $hostCredential; Settings = $settings; Plan = $plan; LogQueue = $logQueue }
    }

    # Each system runs in a separate PowerShell "space" (runspace) that only knows the functions listed below
    $initialState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    foreach ($functionName in 'Get-PathSnapshot', 'Invoke-IsolatedCommand', 'Copy-PathToRemote', 'Test-Excluded',
                              'Get-LineDifferences', 'Compare-LocalRemotePath', 'Invoke-HostOperation') {
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
        $workers += [pscustomobject]@{ PowerShell = $worker; Handle = $worker.BeginInvoke(); Task = $task; Done = $false }
    }

    $totals = @{ Copied = 0; Skipped = 0; Failed = 0; Commands = 0; Differences = 0 }


    function Write-QueuedLog {
        # Moves the lines waiting in the shared queue into execution.log
        $line = $null; $batch = @()

        while ($logQueue.TryDequeue([ref]$line)) { $batch += $line }

        if ($batch.Count) { Add-RunFileText $logFile $batch }
    }


    while (@($workers | Where-Object { -not $_.Done }).Count) {
        $finished = @($workers | Where-Object { -not $_.Done -and $_.Handle.IsCompleted })

        foreach ($worker in $finished) {
            $worker.Done = $true
            $output = @($worker.PowerShell.EndInvoke($worker.Handle))

            if ($output.Count -eq 1) {
                $result = $output[0]
            } else {
                $result = [pscustomobject]@{ Hostname = $worker.Task.System.Hostname; Endpoint = $worker.Task.System.Endpoint
                    Copied = 0; Skipped = 0; Failed = 1; Commands = 0; Differences = 0
                    Lines = @("Worker failed: $($worker.PowerShell.Streams.Error | Out-String)") }
                $logQueue.Enqueue(('{0:yyyy-MM-dd HH:mm:ss,fff} - ERROR: [{1}] Worker failed' -f (Get-Date), $worker.Task.System.Hostname))
            }
            $worker.PowerShell.Dispose()

            foreach ($key in @($totals.Keys)) { $totals[$key] += $result.$key }

            $text = (@('', ('=' * 80), "HOST: $($result.Hostname) ($($result.Endpoint))", ('=' * 80), '') + @($result.Lines) + '' +
                "Result: copied=$($result.Copied), skipped=$($result.Skipped), commands=$($result.Commands), differences=$($result.Differences), failed=$($result.Failed).") -join [Environment]::NewLine
            Write-Host $text
            Add-RunFileText $resultsFile $text
        }

        Write-QueuedLog

        if ($finished.Count -eq 0) { Start-Sleep -Milliseconds 200 }
    }

    Write-QueuedLog
    $pool.Close(); $pool.Dispose()
    $summary = "Overall: copied=$($totals.Copied), skipped=$($totals.Skipped), commands=$($totals.Commands), differences=$($totals.Differences), failed=$($totals.Failed)."
    Add-RunFileText $resultsFile @('', $summary)
    Add-RunFileText $logFile ('{0:yyyy-MM-dd HH:mm:ss,fff} - INFO: {1}' -f (Get-Date), $summary)
    Write-Host $summary
    Write-Host ""
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