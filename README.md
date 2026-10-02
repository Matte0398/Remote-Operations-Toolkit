# Remote Operations Toolkit

This project contains **two programs to run commands remotely** – one for Linux servers (SSH) and one for Windows servers (WinRM) – that perform the **same operations on many servers at once** and save a clean report of what happened:

| Program                                                          | Targets         | Connection          | Runs on                      |
| ---------------------------------------------------------------- | --------------- | ------------------- | ---------------------------- |
| [`Run-LinuxRemoteCommands.py`](Run-LinuxRemoteCommands.py)       | Linux servers   | SSH / SFTP (Fabric) | any machine with Python 3    |
| [`Run-WindowsRemoteCommands.ps1`](Run-WindowsRemoteCommands.ps1) | Windows servers | WinRM / PSSession   | Windows with PowerShell 5.1+ |

Both programs work the same way: same input files, same credential options, same dangerous-command protection, same results folder.

**What they can do**

- **Exec**: run a list of commands on every server (with a `COPY` pseudo-command to send files).
- **Diff**: compare a local file or folder with the same one on every server (read-only).
- **Copy** _(Windows only)_: copy a list of files/folders to the same paths on every server.

---

## Contents

- [Repository structure](#repository-structure)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Input files](#input-files)
- [Modes](#modes)
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
├── Run-LinuxRemoteCommands.py          Linux program
├── Run-WindowsRemoteCommands.ps1       Windows program
├── requirements.txt                    Python dependency (Fabric)
└── examples/
    ├── linux/                          copy these files to /tmp
    │   ├── systems.txt                 list of servers
    │   ├── commands.txt                list of commands (exec mode)
    │   ├── to-copy.txt                 file sent by COPY and used by the diff
    │   └── Results/
    │       ├── 2026-10-02_19-10-31/    diff run  -> execution.log, results.txt
    │       └── 2026-10-02_19-10-36/    exec run  -> execution.log, results.txt
    └── windows/                        copy these files to C:\temp
        ├── systems.txt                 list of servers
        ├── commands.txt                list of commands (exec mode)
        ├── object.txt                  list of objects (copy mode)
        ├── to-copy.txt                 file sent by COPY / object.txt and used by the diff
        └── Results/
            ├── 2026-10-02_19-15-04/    diff run  -> execution.log, results.txt
            ├── 2026-10-02_19-16-22/    exec run  -> execution.log, results.txt
            └── 2026-10-02_19-18-47/    copy run  -> execution.log, results.txt
```

### Where to find the examples

| What                     | Linux                                                                     | Windows                                                                     |
| ------------------------ | ------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Servers list             | [examples/linux/systems.txt](examples/linux/systems.txt)                  | [examples/windows/systems.txt](examples/windows/systems.txt)                |
| Commands list            | [examples/linux/commands.txt](examples/linux/commands.txt)                | [examples/windows/commands.txt](examples/windows/commands.txt)              |
| Objects list (copy mode) | –                                                                         | [examples/windows/object.txt](examples/windows/object.txt)                  |
| File to copy / compare   | [examples/linux/to-copy.txt](examples/linux/to-copy.txt)                  | [examples/windows/to-copy.txt](examples/windows/to-copy.txt)                |
| **Diff** run: log        | [execution.log](examples/linux/Results/2026-10-02_19-10-31/execution.log) | [execution.log](examples/windows/Results/2026-10-02_19-15-04/execution.log) |
| **Diff** run: results    | [results.txt](examples/linux/Results/2026-10-02_19-10-31/results.txt)     | [results.txt](examples/windows/Results/2026-10-02_19-15-04/results.txt)     |
| **Exec** run: log        | [execution.log](examples/linux/Results/2026-10-02_19-10-36/execution.log) | [execution.log](examples/windows/Results/2026-10-02_19-16-22/execution.log) |
| **Exec** run: results    | [results.txt](examples/linux/Results/2026-10-02_19-10-36/results.txt)     | [results.txt](examples/windows/Results/2026-10-02_19-16-22/results.txt)     |
| **Copy** run: log        | –                                                                         | [execution.log](examples/windows/Results/2026-10-02_19-18-47/execution.log) |
| **Copy** run: results    | –                                                                         | [results.txt](examples/windows/Results/2026-10-02_19-18-47/results.txt)     |

The examples tell a small story that you can follow on both platforms:

1. **Diff** first: the local `to-copy.txt` is compared with the same file on the servers. The remote copy is
   older: another port and an extra `debug=true` line.
2. **Exec** then: the commands file shows some information about each server, sends `to-copy.txt` with `COPY`,
   prints it, runs a command that fails on purpose and tries a `reboot` / `Restart-Computer`, which is blocked.
3. **Copy** _(Windows only)_: `object.txt` sends the same `to-copy.txt` to the same path on every server.
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
cp examples/linux/systems.txt examples/linux/commands.txt examples/linux/to-copy.txt /tmp/
#    ...and replace host1,<IP1> ... with your servers in /tmp/systems.txt

# 2. Run
python3 Run-LinuxRemoteCommands.py --exec /tmp/commands.txt

# 3. Read the results
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

# 2. Run
.\Run-WindowsRemoteCommands.ps1 -Exec C:\temp\commands.txt

# 3. Read the results
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

Replace `host1`, `<IP1>` with real names and addresses.

Rules:

- Both fields are **required**.
- Empty lines and lines starting with `#` are ignored.
- Malformed lines are **skipped with a warning** on screen, and the program continues with the next line:
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

Examples: [Linux](examples/linux/commands.txt), [Windows](examples/windows/commands.txt).

### object.txt – the list of objects to copy (copy mode, Windows only)

Each object is copied to the **same path** on every server.

```
# [file:|dir:]C:\path[\*.ext][:exclusion1,exclusion2]
file:C:\temp\to-copy.txt            # one file
dir:C:\scripts:old,temp              # a folder, skipping "old" and "temp"
file:C:\certs\*.pem                 # all the .pem files in a folder
```

- `file:` (default) means files, `dir:` means folders (copied with all their content).
- Wildcards (`*`, `?`) are allowed only in the last part of the path.
- After the path, `:name1,name2` lists names to skip, at any depth.
- Comments must be on their own line (the comments above are only for this README).
- The example file contains only `file:C:\temp\to-copy.txt`; the other forms are listed there as comments.

Default location: `C:\temp\object.txt`. Example: [examples/windows/object.txt](examples/windows/object.txt).

---

## Modes

Only one mode at a time.

| Mode | Linux                    | Windows                                  | What it does                                                                        |
| ---- | ------------------------ | ---------------------------------------- | ----------------------------------------------------------------------------------- |
| Exec | `--exec FILE`            | `-Exec FILE`                             | Runs every line of the commands file on every server.                               |
| Diff | `--diff -L PATH -R PATH` | `-Diff -LocalPath PATH -RemotePath PATH` | Compares a local file/folder with the remote one. Read-only.                        |
| Copy | –                        | _(no mode option)_                       | Copies the objects in `object.txt`. Used when neither `-Exec` nor `-Diff` is given. |

### Diff details

- Works on a single file or on a whole folder (recursively).
- For folders it reports: files only on the local side, files only on the remote side, type differences
  (file vs folder), and the line-by-line differences of every changed text file.
- Binary files are reported as `Binary files differ`, without details.
- Symbolic links / reparse points are listed but not followed.
- Differences do **not** count as errors: a diff run with differences ends with exit code 0.

---

## Credentials

The credentials are asked **before** the work starts, one server at a time, so prompts never overlap.

| What you want                                | Linux                 | Windows                        |
| -------------------------------------------- | --------------------- | ------------------------------ |
| Ask once, use for all servers (default)      | _(nothing)_           | _(nothing)_                    |
| Ask for every server                         | `--ask-always-cred`   | `-AskAlwaysCred`               |
| Pass the credential, ask nothing             | –                     | `-Credential (Get-Credential)` |
| Give the user name, ask only the password    | `--user NAME`         | –                              |
| Use an SSH key, no password                  | `--key ~/.ssh/id_rsa` | –                              |
| Use ssh-agent / `~/.ssh/config`, no password | `--no-password`       | –                              |

On Linux, if you press Enter without typing a user name, the local user name is used.

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
- On Linux `results.txt` is updated while the run is going on, so you can open it before the end.
- On **Linux** the log is in pure chronological order. On **Windows** the servers run in separate
  PowerShell runspaces: each one collects its own events and they are written when that server finishes,
  so the log is **grouped by server** (each line still has the real time of the event).
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
- On Windows, when you compare a single file (not a folder), its name is shown as `(root)`.
- If the files differ only in line endings (Windows CRLF vs Linux LF), the diff says so instead of listing lines.

Full examples: [Linux diff](examples/linux/Results/2026-10-02_19-10-31/results.txt),
[Windows diff](examples/windows/Results/2026-10-02_19-15-04/results.txt).

> On Windows the comparison uses `Compare-Object`: local lines are listed first, then remote lines.
> A line that only moved to another position may not be reported. On Linux the comparison follows the
> order of the lines exactly.

---

## Dangerous commands

Before running a command, both programs check it against **two lists** defined at the top of the program file.
A blocked command is reported as `SKIPPED`, written to the log as a `WARNING` and counted as an error.
Use `--allow-dangerous` / `-AllowDangerous` to run it anyway.

| List                         | Meaning                                                                                                               | Linux                                                                                                                          | Windows                                                                                                                                                |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Always blocked**           | Commands with no harmless use in a mass operation (shutdown, restart, disk wiping). Blocked whatever their arguments. | `shutdown`, `reboot`, `halt`, `poweroff`, `init`, `mkfs*`, `dd`, `fdisk`, `parted`, `wipefs`, `systemctl reboot/poweroff/halt` | `Stop-Computer`, `Restart-Computer`, `shutdown`, `Format-Volume`, `Clear-Disk`, `Initialize-Disk`, `Remove-Partition`, `format`, `diskpart`, `bcdedit` |
| **Blocked on the root only** | Everyday commands that are dangerous only on the root of the system.                                                  | `rm`, `chmod`, `chown`, `mv` on `/` or `/*`                                                                                    | `Remove-Item` and its aliases (`rm`, `ri`, `del`, `erase`, `rd`, `rmdir`) on `C:\`, `C:\*`, `\` ...                                                    |

Only the **command name** is checked, not the words after it:

| Command                            | Result  | Why                                                 |
| ---------------------------------- | ------- | --------------------------------------------------- |
| `reboot`                           | blocked | always-blocked list                                 |
| `sudo reboot`                      | blocked | `sudo` is ignored, the command is `reboot`          |
| `/sbin/shutdown -h now`            | blocked | the name counts, not the path                       |
| `cd /tmp && reboot`                | blocked | every command on the line is checked                |
| `last reboot`                      | runs    | the command is `last`; `reboot` is just an argument |
| `rm -f /tmp/old.log`               | runs    | `rm` is not on `/`                                  |
| `rm -rf /`                         | blocked | root-only list, argument `/`                        |
| `Get-Content C:\logs\shutdown.log` | runs    | the command is `Get-Content`                        |
| `Remove-Item C:\ -Recurse`         | blocked | root-only list, argument `C:\`                      |

To block another command, add it to the right list at the top of the program file.

> This is a best-effort safety net, not a security boundary: **only use command files you trust.**

---

## Differences between the two programs

| Topic                                  | Linux                                         | Windows                                           |
| -------------------------------------- | --------------------------------------------- | ------------------------------------------------- |
| Protocol                               | SSH (commands) + SFTP (files)                 | WinRM (PSSession)                                 |
| Connects to                            | IP                                            | hostname (IP with `-UseIPAddress`)                |
| Copy mode with `object.txt`            | not available (use `COPY` lines in exec mode) | available (default mode)                          |
| `COPY` of a file to an existing folder | the file goes inside the folder               | error: give the full remote file path             |
| Invalid `COPY` line                    | reported on every server (exit code 1)        | detected before starting (exit code 2)            |
| Order of `execution.log`               | chronological                                 | grouped by server                                 |
| Diff algorithm                         | exact, follows line order                     | `Compare-Object` (local lines first, then remote) |

---

## Troubleshooting

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
