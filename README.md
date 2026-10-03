# Remote Operations

This project contains **two programs to run commands remotely** – one for Linux servers (SSH) and one for Windows servers (WinRM) – that perform the **same operations on many servers at once** and save a clean report of what happened:

| Program                                                          | Targets         | Connection          | Runs on                      |
| ---------------------------------------------------------------- | --------------- | ------------------- | ---------------------------- |
| [`Run-LinuxRemoteCommands.py`](Run-LinuxRemoteCommands.py)       | Linux servers   | SSH / SFTP (Fabric) | any machine with Python 3    |
| [`Run-WindowsRemoteCommands.ps1`](Run-WindowsRemoteCommands.ps1) | Windows servers | WinRM / PSSession   | Windows with PowerShell 5.1+ |

Both programs work the same way: same input files, same credential options, same dangerous-command protection, same results folder.

**What they can do**

- **Exec**: run a list of commands on every server (with a `COPY` pseudo-command to send files).
- **Diff**: compare a local file or folder with the same one on every server (read-only).
- **Copy**: copy a list of files/folders (`object.txt`) to the same paths on every server.

---

## Contents

- [Repository structure](#repository-structure)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Input files](#input-files)
- [Modes](#modes)
- [Dry run: try before running](#dry-run-try-before-running)
- [Credentials](#credentials)
- [Results: execution.log and results.txt](#results-executionlog-and-resultstxt)
- [Reading the diff output](#reading-the-diff-output)
- [Dangerous commands](#dangerous-commands)
- [Usage reference](#usage-reference)
- [Exit codes](#exit-codes)
- [Differences between the two programs](#differences-between-the-two-programs)
- [Troubleshooting](#troubleshooting)

---

## Repository structure

```
.
├── README.md
├── Run-LinuxRemoteCommands.py
├── Run-WindowsRemoteCommands.ps1
├── requirements.txt
└── examples/
    ├── linux/
    │   ├── systems.txt
    │   ├── commands.txt
    │   ├── object.txt
    │   ├── to-copy.txt
    │   └── Results/
    │       ├── 2026-10-02_19-10-31/
    │       └── 2026-10-02_19-10-36/
    └── windows/
        ├── systems.txt
        ├── commands.txt
        ├── object.txt
        ├── to-copy.txt
        └── Results/
            ├── 2026-10-02_19-15-04/
            ├── 2026-10-02_19-16-22/
            └── 2026-10-02_19-18-47/
```

### The examples

The examples tell a small story that you can follow on both platforms:

1. **Diff** first: the local `to-copy.txt` is compared with the same file on the servers. The remote copy is
   older: another port and an extra `debug=true` line.
2. **Exec** then: the commands file shows some information about each server, sends `to-copy.txt` with `COPY`,
   prints it, runs a command that fails on purpose and tries a `reboot` / `Restart-Computer`, which is blocked.
3. **Copy**: `object.txt` sends the same `to-copy.txt` to the same path on every server.
4. In every run `host3` is unreachable, so you can see how a connection error is reported.

The example files are written for the default locations: copy all of them to `/tmp` (Linux) or `C:\temp`
(Windows), next to each other. `to-copy.txt` must stay in the same folder as `systems.txt`, because the
examples refer to `/tmp/to-copy.txt` and `C:\temp\to-copy.txt`.

> **Host names and IP addresses are placeholders** (`host1,<IP1>`, `host2,<IP2>`, ...).
> Replace them with your real servers before running: a line like `host1,<IP1>` is not a valid IP address,
> so the program would skip it with a warning.

---

## Requirements

### Linux program

- Python **3.8** or newer on the machine that runs the program.
- The [Fabric](https://www.fabfile.org/) library:
  ```bash
  pip3 install -r requirements.txt      # or: pip3 install fabric
  ```
- SSH access to the servers (password, SSH key or ssh-agent).

### Windows program

- **Windows PowerShell 5.1** or newer on the machine that runs the program.
- WinRM enabled on every server (run once, as administrator, on each server):
  ```powershell
  Enable-PSRemoting -Force
  ```
- When connecting by IP address (`-UseIPAddress`) or to servers outside your domain, the servers must be in the
  `TrustedHosts` list of the machine that runs the program, or you must use HTTPS (`-UseSSL`).
- No extra modules: the program is a single file.

---

## Quick start

### Linux

```bash
# 1. Prepare the input files (default location: /tmp)
cp examples/linux/*.txt /tmp/
#    ...and replace host1,<IP1> ... with your servers in /tmp/systems.txt

# 2. Check what would be done (no credentials asked, no connection opened)
python3 Run-LinuxRemoteCommands.py --exec /tmp/commands.txt --dry-run

# 3. Run
python3 Run-LinuxRemoteCommands.py --exec /tmp/commands.txt

# 4. Read the results
ls /tmp/Results/
```

You can also make the program executable once and call it directly:

```bash
chmod +x Run-LinuxRemoteCommands.py
./Run-LinuxRemoteCommands.py --exec /tmp/commands.txt
```

### Windows

```powershell
# 1. Prepare the input files (default location: C:\temp)
Copy-Item examples\windows\*.txt C:\temp\
#    ...and replace host1,<IP1> ... with your servers in C:\temp\systems.txt

# 2. Check what would be done (no credentials asked, no connection opened)
.\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt -WhatIf

# 3. Run
.\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt

# 4. Read the results
Get-ChildItem C:\temp\Results
```

From `cmd`, a scheduled task, or if the PowerShell execution policy blocks it:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\RemoteOperations\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt
```

If you downloaded the file from the internet, you may need to unblock it once:
`Unblock-File .\Run-WindowsRemoteCommands.ps1`.

---

## Input files

### systems.txt – the list of servers (both programs)

One server per line, in the form `hostname,ip`:

```
# Lines starting with # are comments
host1,<IP1>
host2,<IP2>
host3,<IP3>
```

Replace `host1`, `<IP1>` ... with real names and addresses, for example `web01,10.0.0.11`.

Rules:

- Both fields are **required**.
- Empty lines and lines starting with `#` are ignored.
- Malformed lines are **skipped with a warning** on screen, and the program continues with the next line:
  ```
  WARNING: invalid IP address, line ignored in systems.txt: host3,pippo
  WARNING: invalid line ignored in systems.txt (expected hostname,ip): host4,
  WARNING: invalid line ignored in systems.txt (expected hostname,ip): host5
  WARNING: invalid line ignored in systems.txt (expected hostname,ip): host6,127.0.0.1,
  ```
- IPv4 must be complete, IPv6 is accepted (`fe80::1`).
- If no valid line is left, the program stops with exit code 2.
- Which field is used to connect:
  - **Linux** connects to the **IP**.
  - **Windows** connects to the **hostname** (needed by Kerberos); use `-UseIPAddress` to connect to the IP.

Default location: `/tmp/systems.txt` (Linux), `C:\temp\systems.txt` (Windows).
Examples: [Linux](examples/linux/systems.txt), [Windows](examples/windows/systems.txt).

### commands.txt – the list of commands (exec mode, both programs)

One command per line, run in order on every server:

- **Linux**: shell commands, run with the remote user's shell.
- **Windows**: PowerShell commands, each one in a new PowerShell process on the server.

Every line is **independent**: a `cd` or a variable does not carry over to the next line.
Join commands on one line when they belong together (`cd /opt/app && ./run.sh`).

The special line `COPY <local_path> <remote_path>` copies a file or a folder from the machine that runs the
program to every server. It is not sent to the remote shell. Put paths that contain spaces between double quotes.

```
# Linux: send /tmp/to-copy.txt to the same path on the servers
COPY /tmp/to-copy.txt /tmp/to-copy.txt

# Windows (the remote path must be absolute, e.g. C:\...)
COPY "C:\temp\to-copy.txt" "C:\temp\to-copy.txt"
```

A wrong line (for example a `COPY` with only one path, a `COPY` of a local file that does not exist, or a
PowerShell command with a syntax error) does **not** stop the run: the other lines still run. The Windows
program warns about it at the start and reports it as `SKIPPED` on every server; the Linux program reports
it as `FAILED` on every server. In both cases it counts as an error (exit code 1).

Examples: [Linux](examples/linux/commands.txt), [Windows](examples/windows/commands.txt).

### object.txt – the list of objects to copy (copy mode, both programs)

Each object is copied to the **same path** on every server.

```
# Linux:   [file:|dir:]/path[/*.ext][:exclusion1,exclusion2]
file:/tmp/to-copy.txt               # one file
dir:/opt/scripts:old,*.tmp          # a folder, skipping "old" and every "*.tmp"
file:/etc/myapp/*.conf              # all the .conf files in a folder

# Windows: [file:|dir:]C:\path[\*.ext][:exclusion1,exclusion2]
file:C:\temp\to-copy.txt            # one file
dir:C:\scripts:old,*.tmp            # a folder, skipping "old" and every "*.tmp"
file:C:\certs\*.pem                 # all the .pem files in a folder
```

- `file:` (default) means files, `dir:` means folders (copied with all their content).
- Wildcards (`*`, `?`) are allowed only in the last part of the path.
- After the path, `:name1,name2` lists names to skip, at any depth. **Wildcards are allowed** in the
  exclusions too: `dir:C:\temp\Results:2026*` copies the `Results` folder without the `2026-...` sub-folders.
- Symbolic links / reparse points inside the folders are skipped.
- Comments must be on their own line (the comments above are only for this README).
- The example files contain only the `to-copy.txt` line; the other forms are listed there as comments.

**Wrong lines are skipped, not fatal.** A line with a mistake is shown as a warning at the start, and it
is reported as `SKIPPED` (with the reason) on every server, while all the other lines are copied normally:

```
WARNING: line skipped: fil:C:\temp\to-copy.txt   (unknown prefix 'fil:', use file: or dir:)
WARNING: line skipped: file:C:\temp\Dir   (this is a folder, use dir:)
WARNING: line skipped: file:C:\temp\hostss   (local path not found: C:\temp\hostss)
```

Recognised mistakes: unknown prefix (`fil:`, `fi:`...), `file:` on a folder or `dir:` on a file, path not
found, folder not found, wildcard with no match, wildcard in an intermediate folder, relative path.
A skipped line counts as an error (exit code 1). If no line at all is valid, the program stops with exit code 2.

Default location: `/tmp/object.txt` (Linux), `C:\temp\object.txt` (Windows).
Examples: [Linux](examples/linux/object.txt), [Windows](examples/windows/object.txt).

---

## Modes

Only one mode at a time.

| Mode | Linux                                    | Windows                                  | What it does                                                                  |
| ---- | ---------------------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------- |
| Exec | `--exec FILE`                            | `-Exec FILE`                             | Runs every line of the commands file on every server.                         |
| Diff | `--diff -L PATH -R PATH`                 | `-Diff -LocalPath PATH -RemotePath PATH` | Compares a local file/folder with the remote one. Read-only.                  |
| Copy | _(no mode option)_, `--object-list FILE` | _(no mode option)_, `-ObjectList FILE`   | Copies the objects in `object.txt`. Used when neither exec nor diff is given. |

### Diff details

- Works on a single file or on a whole folder (recursively).
- For folders it reports: files only on the local side, files only on the remote side, type differences
  (file vs folder), and the line-by-line differences of every changed text file.
- Binary files are reported as `Binary files differ`, without details.
- On Windows, files larger than 5 MB are reported as `Files differ` without the line-by-line details,
  to keep the memory use low.
- Symbolic links / reparse points are listed but not followed.
- Differences do **not** count as errors: a diff run with differences ends with exit code 0.

---

## Dry run: try before running

Add `--dry-run` (Linux) or `-WhatIf` (Windows) to any command line to see **what would be done**, without
doing it. The program reads and checks all the input files exactly as in a real run, then shows the valid
servers and the list of operations, and stops:

- **no credentials are asked**, **no connection is opened**, **no file is written** (no `Results` folder);
- every command is marked `RUN`, `COPY`, `DIFF`, or `BLOCKED` (dangerous command);
- invalid lines of `systems.txt` are reported as usual;
- the exit code is `0`, or `2` if the input files are not valid.

```
DRY RUN (--dry-run) - nothing is executed, no connection is opened, no file is written.

Systems (2 valid):
  host1  (connect to: <IP1>)
  host2  (connect to: <IP2>)

Operations, in this order, on every system:
  RUN      whoami
  RUN      df -h /tmp
  COPY     /tmp/to-copy.txt -> /tmp/to-copy.txt
  BLOCKED  reboot   (use --allow-dangerous to run it)

Operations: 4 per system (1 blocked).
```

A dry run shows what **would be sent** to the servers, not what **would happen** there: it cannot know
whether a command will fail, and it does not check that the servers are reachable.

---

## Credentials

The credentials are asked **before** the work starts, one server at a time, so prompts never overlap.
Both programs ask the user name and the password **in the terminal** (the password is not shown while
you type it). The Windows program does not use the `Get-Credential` window, because on Windows 11 it can
stay hidden behind Windows Terminal.

| What you want                                | Linux                 | Windows                                       |
| -------------------------------------------- | --------------------- | --------------------------------------------- |
| Ask once, use for all servers (default)      | _(nothing)_           | _(nothing)_                                   |
| Ask for every server                         | `--ask-always-cred`   | `-AskAlwaysCred`                              |
| Pass the credential, ask nothing             | –                     | `-Credential $cred` (a `PSCredential` object) |
| Give the user name, ask only the password    | `--user NAME`         | –                                             |
| Use an SSH key, no password                  | `--key ~/.ssh/id_rsa` | –                                             |
| Use ssh-agent / `~/.ssh/config`, no password | `--no-password`       | –                                             |

On Linux, if you press Enter without typing a user name, the local user name is used.
On Windows, an empty user name cancels the run.

How to prepare `$cred` for `-Credential` on Windows (the password is asked in the terminal):

```powershell
$cred = New-Object PSCredential 'DOMAIN\admin', (Read-Host 'Password' -AsSecureString)
.\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt -Credential $cred
```

---

## Results: execution.log and results.txt

Every run creates a new folder named after its start time, with two files inside:

```
/tmp/Results/                          (Windows: C:\temp\Results\)
└── 2026-10-02_19-10-36/
    ├── execution.log
    └── results.txt
```

| File            | Content                                                                                                                                                                                                          | Use it to...                        |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `execution.log` | **Events only**, one line each, with date and time to the millisecond: start, connections, every command and its exit code, copies, blocked commands (`WARNING`), errors (`ERROR`), end of each server, summary. | ...see _what happened and when_.    |
| `results.txt`   | A header (date, mode, input files), then the **full output of every server**: stdout/stderr of each command, copy results, diffs, and the final summary.                                                         | ...see _what the servers answered_. |

Example `execution.log` lines (same format in both programs):

```
2026-10-02 19:10:37,066 - INFO: [host1] Exit code 0: whoami
2026-10-02 19:10:37,317 - WARNING: [host1] Skipped dangerous command: reboot
2026-10-02 19:10:39,809 - ERROR: [host3] Failed: timed out
```

Example block in `results.txt` (Linux):

```
================================================================================
HOST: host1 (<IP1>)
================================================================================

$ whoami
status: EXIT 0
--- stdout ---
admin

$ ls /tmp/missing-folder
status: EXIT 2
--- stderr ---
ls: cannot access '/tmp/missing-folder': No such file or directory
```

The same output is also printed on screen, followed by the paths of the two files:

```
Overall: systems=3, with errors=3.
Results: /tmp/Results/2026-10-02_19-10-36/results.txt
Log:     /tmp/Results/2026-10-02_19-10-36/execution.log
```

Notes:

- Change the base folder with `--results-dir DIR` (Linux) or `-ResultsPath DIR` (Windows).
- Each server is shown **as soon as it finishes**: a slow or unreachable server does not hold back
  the others. That is why the servers in `results.txt` are in the order in which they finished.
- `results.txt` is updated while the run is going on, so you can open it before the end.
- `execution.log` is in **chronological order**: the events of the servers working in parallel are
  mixed, exactly as they happened.
- Warnings about invalid lines in `systems.txt` are shown on screen only.

All the [examples](#where-to-find-the-examples) contain a complete `Results` folder.

---

## Reading the diff output

For every changed text file, the diff says **where** each different line is:

```
Differences found: /tmp/to-copy.txt
  local file : /tmp/to-copy.txt
  remote file: /tmp/to-copy.txt
  only LOCAL  (line    3): port=8443
  only REMOTE (line    3): port=8080
  only REMOTE (line    5): debug=true
```

- `only LOCAL (line N)`: the line is in the local file (line number N) but not in the remote one.
- `only REMOTE (line N)`: the line is in the remote file but not in the local one.
- A changed line appears twice: once as `only LOCAL` (old value) and once as `only REMOTE` (new value).
- Empty lines are shown as `(empty line)`.
- When comparing folders, the diff also lists `Only local:` / `Only remote:` files and
  `Identical common files: N`.
- If the files differ only in line endings (Windows CRLF vs Linux LF), the diff says so instead of listing lines.

Full examples: [Linux diff](examples/linux/Results/2026-10-02_19-10-31/results.txt),
[Windows diff](examples/windows/Results/2026-10-02_19-15-04/results.txt).

Both programs use an exact line-by-line comparison that follows the order of the lines and reports the
smallest possible number of different lines. On Windows, when two files have more than about a thousand
changed lines each, the details are replaced by a short message (`too many changed lines to list them`).

---

## Dangerous commands

Before running a command, both programs check it against **two lists** defined at the top of the program file.
A blocked command is reported as `SKIPPED`, written to the log as a `WARNING` and counted as an error.
Use `--allow-dangerous` / `-AllowDangerous` to run it anyway.

| List                                  | Meaning                                                                                                                                  | Linux                                                                                                                                              | Windows                                                                                                                                                                                                                                |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Always blocked**                    | Commands with no harmless use in a mass operation (shutdown, restart, disk wiping). Blocked whatever their arguments.                    | `shutdown`, `reboot`, `halt`, `poweroff`, `init`, `mkfs*`, `dd`, `fdisk`, `parted`, `wipefs`, `systemctl reboot/poweroff/halt`                     | `Stop-Computer`, `Restart-Computer`, `shutdown`, `Format-Volume`, `Clear-Disk`, `Initialize-Disk`, `Remove-Partition`, `format`, `diskpart`, `bcdedit`                                                                                 |
| **Blocked on protected folders only** | Everyday commands that are dangerous only on the root of the system or on a main system folder. Their sub-folders are **not** protected. | `rm`, `chmod`, `chown`, `mv` on `/`, `/bin`, `/boot`, `/dev`, `/etc`, `/home`, `/lib`, `/lib64`, `/proc`, `/root`, `/sbin`, `/sys`, `/usr`, `/var` | `Remove-Item` and its aliases (`rm`, `ri`, `del`, `erase`, `rd`, `rmdir`) on the root of any drive (`C:\`, `D:\` ...), `C:\Windows`, `C:\Windows\System32`, `C:\Program Files`, `C:\Program Files (x86)`, `C:\ProgramData`, `C:\Users` |

`/etc`, `/etc/` and `/etc/*` (or `C:\Windows`, `C:\Windows\` and `C:\Windows\*`) all count as the protected folder.
Upper and lower case do not matter on Windows.

The command **name** decides the list; for the second list the **paths** in the command are checked too:

| Command                                    | Result  | Why                                                 |
| ------------------------------------------ | ------- | --------------------------------------------------- |
| `reboot`                                   | blocked | always-blocked list                                 |
| `sudo reboot`                              | blocked | `sudo` is ignored, the command is `reboot`          |
| `/sbin/shutdown -h now`                    | blocked | the name counts, not the path                       |
| `cd /tmp && reboot`                        | blocked | every command on the line is checked                |
| `last reboot`                              | runs    | the command is `last`; `reboot` is just an argument |
| `rm -f /tmp/old.log`                       | runs    | `/tmp` is not protected                             |
| `rm -rf /`                                 | blocked | protected folder `/`                                |
| `rm /etc` or `rm -rf /etc/*`               | blocked | protected folder `/etc`                             |
| `chmod -R 777 /var`                        | blocked | protected folder `/var`                             |
| `rm -rf /etc/myapp`                        | runs    | sub-folders are not protected                       |
| `rm *`                                     | runs    | only absolute paths are checked                     |
| `Get-Content C:\logs\shutdown.log`         | runs    | the command is `Get-Content`                        |
| `Remove-Item C:\ -Recurse`                 | blocked | root of a drive                                     |
| `Remove-Item "C:\Program Files\" -Recurse` | blocked | protected folder `C:\Program Files`                 |
| `Remove-Item C:\Windows\Temp\old.log`      | runs    | sub-folders are not protected                       |

To block another command, add it to the right list at the top of the program file. To protect another
folder, add it to `PROTECTED_PATHS` (Linux) or `$ProtectedPaths` (Windows).

> This is a best-effort safety net, not a security boundary: **only use command files you trust.**

---

## Usage reference

The same text is printed by `--help` (Linux) and `-Help` / `--help` (Windows). In the printed help the
program name is always the real file name, so it stays correct if you rename the file.

### Linux

```
USAGE
  Run-LinuxRemoteCommands.py [--object-list FILE] [options]               copy mode
  Run-LinuxRemoteCommands.py --exec FILE [options]                        exec mode
  Run-LinuxRemoteCommands.py --diff -L PATH -R PATH [options]             diff mode

MODES (only one at a time)
  (none)                 Copy the objects listed in object.txt to the same remote paths
  --exec FILE            Run one line per command: a shell command or
                         COPY <local_path> <remote_path>  (quote paths with spaces)
  --diff                 Compare -L with -R (read-only)
    -L, --local PATH     local file or folder
    -R, --remote PATH    remote file or folder

CREDENTIALS
  (default)              Ask user and password once, use for all systems
  --ask-always-cred      Ask user and password for every system
  --user NAME            Do not ask the user (the password is still asked)
  --key FILE             SSH private key: no password asked
  --no-password          Use ssh-agent / ~/.ssh/config: no password asked

FILES
  --systems FILE         hostname,ip list (default /tmp/systems.txt)
  --object-list FILE     Objects to copy (default /tmp/object.txt)
  --results-dir DIR      Results base folder (default /tmp/Results)
                         -> <results-dir>/<timestamp>/execution.log  and  results.txt

CONNECTION
  --parallel N           Systems processed together (default 5)
  --connect-timeout N    Seconds to connect (default 10)
  --command-timeout N    Max seconds per command, 0 = no limit (default 0)

SAFETY
  --allow-dangerous      Do not block potentially destructive commands
  --dry-run              Show what would be done, without asking credentials
                         and without connecting to any system

OTHER
  -h, --help             Show this help

INPUT FILES (empty lines and lines starting with # are ignored)
  systems.txt            One system per line: hostname,ip (both required)
                             host1,<IP1>
                             host2,<IP2>
                             host3,<IP3>

  commands file          One shell command per line, run in order on every system
  (--exec)               (each line is independent: a "cd" does not carry over)
                             whoami
                             df -h /tmp
                             COPY /tmp/to-copy.txt /tmp/to-copy.txt
                             cat /tmp/to-copy.txt

  object.txt             One object per line, copied to the SAME path on every system:
  (copy mode)            [file:|dir:]/path[/*.ext][:exclusion1,exclusion2]
                         (exclusions accept wildcards; wrong lines are skipped)
                             file:/tmp/to-copy.txt
                             dir:/opt/scripts:old,*.tmp
                             file:/etc/myapp/*.conf

EXAMPLES
  Run-LinuxRemoteCommands.py --dry-run
  Run-LinuxRemoteCommands.py --object-list /tmp/object.txt
  Run-LinuxRemoteCommands.py --exec /tmp/commands.txt --dry-run
  Run-LinuxRemoteCommands.py --exec /tmp/commands.txt
  Run-LinuxRemoteCommands.py --exec /tmp/commands.txt --ask-always-cred
  Run-LinuxRemoteCommands.py --diff -L /tmp/to-copy.txt -R /tmp/to-copy.txt --user admin

EXIT CODES
  0 = all ok   1 = at least one error   2 = invalid parameters or input files
```

Examples:

```bash
./Run-LinuxRemoteCommands.py --exec /tmp/commands.txt --dry-run
./Run-LinuxRemoteCommands.py --exec /tmp/commands.txt
./Run-LinuxRemoteCommands.py --exec /tmp/commands.txt --ask-always-cred
./Run-LinuxRemoteCommands.py --exec /tmp/commands.txt --user root --key ~/.ssh/id_rsa
./Run-LinuxRemoteCommands.py --exec /tmp/commands.txt --systems /tmp/web-servers.txt --parallel 10
./Run-LinuxRemoteCommands.py --diff -L /tmp/to-copy.txt -R /tmp/to-copy.txt --user admin
./Run-LinuxRemoteCommands.py --diff -L /srv/app/config -R /srv/app/config      # whole folders
```

### Windows

```
USAGE
  .\Run-WindowsRemoteCommands.ps1 [-ObjectList FILE] [options]                     copy mode
  .\Run-WindowsRemoteCommands.ps1 -Exec FILE [options]                             exec mode
  .\Run-WindowsRemoteCommands.ps1 -Diff -LocalPath PATH -RemotePath PATH [options] diff mode

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
                         (exclusions accept wildcards; wrong lines are skipped)
                             file:C:\temp\to-copy.txt
                             dir:C:\scripts:old,*.tmp
                             file:C:\certs\*.pem

EXAMPLES
  .\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt -WhatIf
  .\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt
  .\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt -AskAlwaysCred
  .\Run-WindowsRemoteCommands.ps1 -Diff -L C:\temp\to-copy.txt -R C:\temp\to-copy.txt
  .\Run-WindowsRemoteCommands.ps1 -ObjectList C:\temp\object.txt -Credential $cred

EXIT CODES
  0 = all ok   1 = at least one error   2 = invalid parameters or input files
```

Examples:

```powershell
.\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt -WhatIf
.\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt
.\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt -AskAlwaysCred
.\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt -Credential $cred -ThrottleLimit 10
.\Run-WindowsRemoteCommands.ps1 -Diff -L C:\temp\to-copy.txt -R C:\temp\to-copy.txt
.\Run-WindowsRemoteCommands.ps1 -Diff -L C:\app\config -R D:\app\config   # whole folders
.\Run-WindowsRemoteCommands.ps1 -ObjectList C:\temp\object.txt
.\Run-WindowsRemoteCommands.ps1 -PathOper D:\ops        # systems.txt, object.txt and Results under D:\ops
```

---

## Exit codes

| Code | Meaning                                                                                                                                           |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0`  | Everything OK (diff differences are **not** errors).                                                                                              |
| `1`  | At least one error: unreachable server, command with a non-zero exit code, failed copy, blocked dangerous command, or results files not writable. |
| `2`  | Invalid parameters or input files (missing file, no valid server, missing `-L`/`-R`...). Nothing is run.                                          |

Useful in scheduled jobs: check the exit code, then open `results.txt` for the details.

---

## Differences between the two programs

| Topic                                                           | Linux                                            | Windows                                                  |
| --------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------- |
| Protocol                                                        | SSH (commands) + SFTP (files)                    | WinRM (PSSession)                                        |
| Connects to                                                     | IP                                               | hostname (IP with `-UseIPAddress`)                       |
| Copy of a file where the server has a folder with the same name | the file goes inside the folder                  | error: give the full remote file path                    |
| Hidden files matched by `*` in `object.txt`                     | not included (name them explicitly, or use `.*`) | included                                                 |
| Dry-run option                                                  | `--dry-run`                                      | `-WhatIf` (the standard PowerShell name)                 |
| Diff of large files                                             | always line by line                              | files over 5 MB: `Files differ`, without details         |
| Command timeout                                                 | the command is reported as timed out             | the command **and every process it started** are stopped |

---

## Troubleshooting

**Linux: `/usr/bin/env: 'python3\r': No such file or directory`**
The `.py` file was saved with Windows line endings. Fix it with `sed -i 's/\r$//' Run-LinuxRemoteCommands.py`
(or `dos2unix`), or always run it as `python3 Run-LinuxRemoteCommands.py ...`.
The repository's `.gitattributes` keeps the correct line endings when you clone it with Git.

**Linux: a command hangs until the timeout**
Commands do not receive keyboard input. A command that asks for something (for example `sudo` asking for a
password) waits forever. Use `sudo` with `NOPASSWD` for the needed commands, and set `--command-timeout`.

**Linux: unknown host keys**
Fabric accepts the key of a server it has never seen before. If you need strict host-key checking,
connect once with `ssh` to each server, or manage `~/.ssh/known_hosts` beforehand.

**Windows: `WinRM cannot complete the operation`**
WinRM is not enabled on the server, a firewall blocks ports 5985/5986, or the name cannot be resolved.
Check with `Test-WSMan SERVERNAME`.

**Windows: errors connecting by IP or outside the domain**
Kerberos needs the hostname. With an IP address, add the servers to `TrustedHosts`
(`Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'host1,host2,host3'`) or use `-UseSSL`.

**Windows: `running scripts is disabled on this system`**
Use `powershell.exe -ExecutionPolicy Bypass -File ...` or change the policy for your user:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
