#!/usr/bin/env python3

#############################################################################################################
## Description: Program to execute commands, copy files or compare paths on remote Linux systems over SSH
##
## Author: Matteo Z.
#############################################################################################################

import argparse
import difflib
import fnmatch
import getpass
import glob
import ipaddress
import logging
import os
import posixpath
import re
import shlex
import stat
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from fabric import Config, Connection

SEP = "=" * 80
USAGE = """\
USAGE
  {prog} [--object-list FILE] [options]               copy mode
  {prog} --exec FILE [options]                        exec mode
  {prog} --diff -L PATH -R PATH [options]             diff mode

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
  {prog} --dry-run
  {prog} --object-list /tmp/object.txt
  {prog} --exec /tmp/commands.txt --dry-run
  {prog} --exec /tmp/commands.txt
  {prog} --exec /tmp/commands.txt --ask-always-cred
  {prog} --diff -L /tmp/to-copy.txt -R /tmp/to-copy.txt --user admin

EXIT CODES
  0 = all ok   1 = at least one error   2 = invalid parameters or input files
"""
logger = logging.getLogger("remote_oper")

# ==================================================================
# DANGEROUS COMMANDS (disable with --allow-dangerous)
# To block one more command, just add it to one of the two lists
# ==================================================================

# ALWAYS blocked: they shut down/restart the system or wipe disks ("mkfs" also blocks mkfs.ext4, mkfs.xfs, ...; "init" also blocks "init 3")
DANGEROUS_COMMANDS = ["shutdown", "reboot", "halt", "poweroff", "init",
                      "mkfs", "dd", "fdisk", "parted", "wipefs"]

# Blocked ONLY when they act on the root "/" or on a main system folder (e.g. "rm -rf /", "rm -rf /etc", "chmod -R 777 /usr")
DANGEROUS_ON_ROOT = ["rm", "chmod", "chown", "mv"]

# Main system folders protected from the commands above (their sub-folders are not)
PROTECTED_PATHS = ["/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64",
                   "/proc", "/root", "/sbin", "/sys", "/usr", "/var"]


def is_dangerous_command(line):
    """Returns True if the line contains a dangerous command."""
    # Fork bomb  :(){ :|:& };:  (written with or without spaces)
    if ":(){" in line.replace(" ", ""):
        return True

    # A line can contain several commands, e.g. "cd /tmp && reboot" or "ls | sort"
    # We split it on the separators  &&  ||  ;  |  &  and check every piece
    for part in re.split(r"&&|\|\||[;|&]", line):
        words = part.replace('"', "").replace("'", "").split()

        if words and words[0] == "sudo":          # "sudo reboot" -> "reboot"
            words = words[1:]

        if not words:
            continue

        # We only look at the command NAME (the first word), so
        # "last reboot" or "grep shutdown /var/log/messages" are NOT blocked.
        name = os.path.basename(words[0])         # "/sbin/reboot" -> "reboot"

        if name in DANGEROUS_COMMANDS or name.startswith("mkfs."):
            return True
        
        if name == "systemctl" and any(w in ("reboot", "poweroff", "halt") for w in words):
            return True
        
        if name in DANGEROUS_ON_ROOT:
            for word in words[1:]:
                if not word.startswith("/"):      # only absolute paths, so "rm *" is not blocked
                    continue

                # "/etc", "/etc/" and "/etc/*" all mean the folder /etc
                path = word.rstrip("*").rstrip("/") or "/"

                if path in PROTECTED_PATHS:
                    return True
                
    return False


def has_wildcards(text):
    """True if the text contains a wildcard character: * ? ["""
    return any(character in text for character in "*?[")


def is_excluded(name, exclusions):
    """True if the name matches one of the exclusions (wildcards allowed, e.g. "2026*" or "*.log")."""
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in exclusions)


def load_objects(path):
    """Reads object.txt and returns the plan: the list of operations, the same for all systems.
    Every operation is a dictionary with "kind" = "copy", "skipped" (excluded) or "invalid".
    A wrong line does NOT stop the run: a warning is shown now, and the line is reported
    as SKIPPED (and counted as an error) on every system, while the other lines still run.
    Line format:  [file:|dir:]/path[/*.ext][:exclusion1,exclusion2]
    """
    plan = []
    
    for line in read_lines(path):
        try:
            # 1. Prefix: "file:" (default) or "dir:"; any other word before ":" is a typo
            mode, pattern = "file", line
            prefix = re.match(r"^([A-Za-z]+):(.*)$", line)

            if prefix:
                if prefix.group(1).lower() not in ("file", "dir"):
                    raise ValueError(f"unknown prefix '{prefix.group(1)}:', use file: or dir:")
                
                mode, pattern = prefix.group(1).lower(), prefix.group(2)

            # 2. Exclusions: everything after the next ":" (e.g. /var/app:logs,*.tmp)
            exclusions = []

            if ":" in pattern:
                pattern, rest = pattern.split(":", 1)
                exclusions = [name.strip() for name in rest.split(",") if name.strip()]

            pattern = pattern.strip()

            # 3. Checks on the path.
            if not pattern.startswith("/"):
                raise ValueError("the path must be absolute, e.g. /etc/app.conf")
            
            pattern = pattern.rstrip("/") or "/"
            parent, last = os.path.split(pattern)

            if has_wildcards(parent):
                raise ValueError("wildcards are allowed only in the last part of the path")
            
            if not os.path.isdir(parent):
                raise ValueError(f"local folder not found: {parent}")

            # 4. Find the local files/folders
            if has_wildcards(last):
                items = sorted(item for item in glob.glob(pattern) if os.path.isdir(item) == (mode == "dir"))

                if not items:
                    raise ValueError(f"no local {mode} matches {pattern}")
            else:
                if not os.path.exists(pattern):
                    raise ValueError(f"local path not found: {pattern}")
                
                if mode == "file" and os.path.isdir(pattern):
                    raise ValueError("this is a folder, use dir:")
                
                if mode == "dir" and not os.path.isdir(pattern):
                    raise ValueError("this is a file, use file:")
                
                items = [pattern]

            # 5. One copy for every item (to the SAME path on the remote systems)
            for item in items:
                if is_excluded(os.path.basename(item), exclusions):
                    plan.append({"kind": "skipped", "text": f"Excluded: {item}"})
                else:
                    plan.append({"kind": "copy", "source": item, "exclusions": exclusions,
                                 "text": f"COPY {item} -> {item}"})
        except ValueError as exc:
            print(f"WARNING: line skipped: {line}   ({exc})", file=sys.stderr)
            plan.append({"kind": "invalid", "text": line, "reason": str(exc)})

    return plan


# ===========================================================
# REMOTE SYSTEM: SSH connection, commands and files (SFTP)
# ===========================================================

class RemoteSystem:
    def __init__(self, hostname, ip, user, password, key, connect_timeout, command_timeout):
        self.hostname = hostname
        self.address = ip
        self.user = user
        self.password = password
        self.key = key
        self.connect_timeout = connect_timeout
        self.command_timeout = command_timeout or None    # 0 = no limit
        self.connection = None

    def connect(self):
        """Opens the SSH connection. Raises an exception on failure."""
        logger.info("Connecting to %s (%s) as '%s'", self.hostname, self.address, self.user)
        options = {"timeout": self.connect_timeout}

        if self.password is not None:
            options["password"] = self.password

        if self.key:
            options["key_filename"] = self.key

        self.connection = Connection(self.address, user=self.user, connect_kwargs=options,
                                     config=Config(overrides={"run": {"warn": True}}))
        self.connection.open()

    def disconnect(self):
        if self.connection:
            self.connection.close()
            self.connection = None

    def execute(self, command):
        """Runs a remote command and returns (exit_code, stdout, stderr)."""
        logger.info("[%s] Executing: %s", self.hostname, command)

        try:
            # in_stream=False: the remote command does not read the local keyboard
            # (important when working on several systems in parallel)
            result = self.connection.run(command, hide=True, warn=True, in_stream=False,
                                         timeout=self.command_timeout)
            
            return result.return_code, result.stdout, result.stderr
        except Exception as exc:          # e.g. command timeout
            logger.error("[%s] Command error: %s", self.hostname, exc)
            return -1, "", str(exc)

    def kind(self, path):
        """Returns "directory", "file" or None if the remote path does not exist."""
        try:
            mode = self.connection.sftp().stat(path).st_mode
        except OSError:
            return None
        
        return "directory" if stat.S_ISDIR(mode) else "file"

    def read_bytes(self, path):
        with self.connection.sftp().open(path, "rb") as handle:
            return handle.read()

    def mkdirs(self, path):
        """Like "mkdir -p": creates the remote directory and any missing parent."""
        sftp = self.connection.sftp()
        current = "/" if path.startswith("/") else ""

        for part in path.split("/"):
            if not part:
                continue

            current = posixpath.join(current, part)

            try:
                sftp.stat(current)
            except OSError:
                sftp.mkdir(current)

    def copy(self, local, remote, exclusions=()):
        """Copies a local file or directory to the remote system (exception on failure).
        In folders, the names matching the exclusions and the symbolic links are skipped,
        at any depth. Returns (number of copied files, list of skipped local paths)."""
        sftp = self.connection.sftp()
        copied, skipped = 0, []

        if os.path.isfile(local):
            # If the destination is an existing directory, the file goes INSIDE it
            if self.kind(remote) == "directory":
                remote = posixpath.join(remote, os.path.basename(local))

            self.mkdirs(posixpath.dirname(remote))
            sftp.put(local, remote)
            copied = 1
        elif os.path.isdir(local):
            # os.walk visits the directory and all subdirectories (empty ones too)
            for folder, subfolders, files in os.walk(local):
                # Excluded folders and links are removed from "subfolders": os.walk will not enter them
                for name in list(subfolders):
                    path = os.path.join(folder, name)

                    if is_excluded(name, exclusions) or os.path.islink(path):
                        subfolders.remove(name)
                        skipped.append(path)

                relative = os.path.relpath(folder, local)
                target = remote if relative == "." else posixpath.join(remote, relative)
                self.mkdirs(target)

                for name in files:
                    path = os.path.join(folder, name)

                    if is_excluded(name, exclusions) or os.path.islink(path):
                        skipped.append(path)
                        continue

                    sftp.put(path, posixpath.join(target, name))
                    copied += 1
        else:
            raise FileNotFoundError(f"local path not found: {local}")
        
        return copied, skipped

    def list_tree(self, root):
        """Returns {relative_path: type} for the whole content of a remote directory.
        Symbolic links are listed but not followed."""
        result = {}
        folders = [""]

        while folders:
            relative = folders.pop()

            for item in self.connection.sftp().listdir_attr(posixpath.join(root, relative)):
                path = posixpath.join(relative, item.filename)

                if stat.S_ISLNK(item.st_mode):
                    result[path] = "symlink"
                elif stat.S_ISDIR(item.st_mode):
                    result[path] = "directory"
                    folders.append(path)
                else:
                    result[path] = "file"

        return result


def local_tree(root):
    """Like RemoteSystem.list_tree, but for a local directory."""
    result = {}

    for path in Path(root).rglob("*"):
        relative = path.relative_to(root).as_posix()

        if path.is_symlink():
            result[relative] = "symlink"
        elif path.is_dir():
            result[relative] = "directory"
        else:
            result[relative] = "file"

    return result


def compare_file(local, remote_system, remote, label):
    """Compares a local file with a remote one. Returns (output_lines, ok)."""
    try:
        left = Path(local).read_bytes()
        right = remote_system.read_bytes(remote)
    except OSError as exc:
        return [f"Cannot read {label}: {exc}"], False
    
    if left == right:
        return [f"Identical: {label}"], True
    
    # A zero byte or non-UTF-8 text means a binary file: no line-by-line comparison
    try:
        if b"\0" in left or b"\0" in right:
            raise UnicodeDecodeError("utf-8", b"", 0, 1, "binary")
        
        left_lines = left.decode("utf-8").splitlines()
        right_lines = right.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        return [f"Binary files differ: {label}"], True

    lines = [f"Differences found: {label}",
             f"  local file : {local}",
             f"  remote file: {remote}"]
    # SequenceMatcher finds the blocks of lines that are equal on both sides;
    # everything else is only in the local file or only in the remote file
    matcher = difflib.SequenceMatcher(None, left_lines, right_lines, autojunk=False)

    for tag, l_start, l_end, r_start, r_end in matcher.get_opcodes():
        if tag == "equal":
            continue

        for n in range(l_start, l_end):
            lines.append(f"  only LOCAL  (line {n + 1:4}): {left_lines[n] or '(empty line)'}")

        for n in range(r_start, r_end):
            lines.append(f"  only REMOTE (line {n + 1:4}): {right_lines[n] or '(empty line)'}")

    if len(lines) == 3:
        lines.append("  (same lines: only line endings differ, e.g. Windows CRLF vs Linux LF)")

    return lines, True


def compare_paths(local, remote_system, remote):
    """Compares a local file or directory with the matching remote one."""
    local_kind = "directory" if os.path.isdir(local) else "file" if os.path.isfile(local) else None
    remote_kind = remote_system.kind(remote)

    if not local_kind:
        return ["Local path missing or inaccessible"], False
    
    if not remote_kind:
        return ["Remote path missing or inaccessible"], False
    
    if local_kind != remote_kind:
        return [f"Type mismatch: local={local_kind}, remote={remote_kind}"], True
    
    if local_kind == "file":
        return compare_file(local, remote_system, remote, local)

    left, right = local_tree(local), remote_system.list_tree(remote)
    lines, identical, ok = ["Directory comparison:"], 0, True

    for path in sorted(set(left) | set(right)):
        if path not in right:
            lines.append(f"Only local:  {path} ({left[path]})")
        elif path not in left:
            lines.append(f"Only remote: {path} ({right[path]})")
        elif left[path] != right[path]:
            lines.append(f"Type differs: {path} (local={left[path]}, remote={right[path]})")
        elif left[path] == "file":
            detail, file_ok = compare_file(os.path.join(local, path), remote_system,
                                           posixpath.join(remote, path), path)
            ok = ok and file_ok

            if detail[0].startswith("Identical:"):
                identical += 1
            else:
                lines += [""] + detail

    if len(lines) == 1:
        lines.append("Directories are identical")
    else:
        lines.append(f"\nIdentical common files: {identical}")

    return lines, ok


def run_commands(remote, commands, allow_dangerous):
    """Runs the commands on one system. Returns (output_lines, ok)."""
    lines, ok = [], True

    for command in commands:
        lines += ["", f"$ {command}"]
        first_word = command.split()[0]

        if first_word.upper() == "COPY":
            # COPY is not sent to the remote shell: the copy is done via SFTP
            # Paths containing spaces must be quoted
            try:
                paths = shlex.split(command)[1:]

                if len(paths) != 2:
                    raise ValueError("expected: COPY <local_path> <remote_path>")
                
                remote.copy(paths[0], paths[1])
                lines.append("status: OK (copy completed)")
                logger.info("[%s] Copy completed: %s -> %s", remote.hostname, paths[0], paths[1])
            except Exception as exc:
                lines.append(f"status: FAILED - {exc}")
                logger.error("[%s] Copy failed: %s (%s)", remote.hostname, command, exc)
                ok = False
        elif not allow_dangerous and is_dangerous_command(command):
            lines.append("status: SKIPPED - potentially destructive command; "
                         "use --allow-dangerous for trusted commands")
            logger.warning("[%s] Skipped dangerous command: %s", remote.hostname, command)
            ok = False
        else:
            code, stdout, stderr = remote.execute(command)
            lines.append(f"status: EXIT {code}")
            logger.info("[%s] Exit code %s: %s", remote.hostname, code, command)

            if stdout.strip():
                lines += ["--- stdout ---", stdout.rstrip()]

            if stderr.strip():
                lines += ["--- stderr ---", stderr.rstrip()]

            if code != 0:
                ok = False

    return lines, ok


def run_objects(remote, plan):
    """Copy mode: copies every object of object.txt to the SAME path on one system.
    Returns (output_lines, ok)."""
    lines, ok = [], True

    for operation in plan:
        lines += ["", operation["text"]]

        if operation["kind"] == "skipped":
            lines.append("status: SKIPPED (excluded)")
        elif operation["kind"] == "invalid":
            lines.append(f"status: SKIPPED - {operation['reason']}")
            logger.error("[%s] Line skipped: %s (%s)", remote.hostname, operation["text"], operation["reason"])
            ok = False
        else:
            try:
                copied, skipped = remote.copy(operation["source"], operation["source"], operation["exclusions"])
                lines.append(f"status: OK ({copied} file(s) copied, {len(skipped)} skipped)")
                lines += [f"  skipped exclusion/link: {path}" for path in skipped]
                logger.info("[%s] Copy completed: %s (%d copied, %d skipped)",
                            remote.hostname, operation["source"], copied, len(skipped))
            except Exception as exc:
                lines.append(f"status: FAILED - {exc}")
                logger.error("[%s] Copy failed: %s (%s)", remote.hostname, operation["source"], exc)
                ok = False

    return lines, ok


def process_system(remote, args, commands, plan):
    """All the work on ONE system: connect, run the operations, disconnect.
    Runs in parallel for several systems. Returns (text_block, ok)."""
    try:
        remote.connect()

        if args.diff:
            lines, ok = compare_paths(args.local, remote, args.remote)
            logger.info("[%s] Compared %s with %s (details in results.txt)",
                        remote.hostname, args.local, args.remote)
        elif args.exec_file:
            lines, ok = run_commands(remote, commands, args.allow_dangerous)
        else:
            lines, ok = run_objects(remote, plan)
    except Exception as exc:
        logger.error("[%s] Failed: %s", remote.hostname, exc)
        lines, ok = [f"FAILED: {exc}"], False
    finally:
        remote.disconnect()

    logger.info("[%s] Finished: %s", remote.hostname, "OK" if ok else "ERRORS")

    if lines and lines[0] != "":
        lines = [""] + lines

    header = ["", SEP, f"HOST: {remote.hostname} ({remote.address})", SEP]
    footer = ["", SEP, f"Result: {'OK' if ok else 'ERRORS'}"]

    return "\n".join(header + lines + footer), ok


def read_lines(path):
    """Lines of a text file, without empty lines and comments (#)."""
    # utf-8-sig also accepts files saved with a BOM (e.g. by Windows Notepad)
    with open(path, encoding="utf-8-sig") as handle:
        return [line.strip() for line in handle
                if line.strip() and not line.strip().startswith("#")]


def load_systems(path):
    """Reads the "hostname,ip" lines and returns a list of (hostname, ip).
    Invalid lines are skipped with a warning."""
    systems = []

    for line in read_lines(path):
        parts = [x.strip() for x in line.split(",")]

        if len(parts) != 2 or not parts[0] or not parts[1]:
            print(f"WARNING: invalid line ignored in {path} (expected hostname,ip): {line}",
                  file=sys.stderr)
            continue

        # The second field must be a real IP address
        try:
            ipaddress.ip_address(parts[1])
        except ValueError:
            print(f"WARNING: invalid IP address, line ignored in {path}: {line}", file=sys.stderr)
            continue

        systems.append((parts[0], parts[1]))

    return systems


def ask_credentials(target, args):
    """Asks for user and/or password. Returns (user, password)."""
    user = args.user or input(f"Username for {target}: ").strip() or getpass.getuser()
    password = None

    if not args.key and not args.no_password:
        password = getpass.getpass(f"Password for {user} on {target}: ")

    return user, password


########## MAIN ##########

def main():
    parser = argparse.ArgumentParser(
        usage="%(prog)s [--object-list FILE | --exec FILE | --diff -L PATH -R PATH] [options]   (use --help for details)",
        add_help=False)
    parser.add_argument("-h", "--help", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--exec", dest="exec_file", metavar="FILE",
                      help="file with one command (or COPY <local> <remote>) per line")
    mode.add_argument("--diff", action="store_true", help="compare -L with -R (read-only)")
    parser.add_argument("-L", "--local", help="local path for --diff")
    parser.add_argument("-R", "--remote", help="remote path for --diff")
    parser.add_argument("--object-list", metavar="FILE",
                        help="objects to copy in copy mode (default /tmp/object.txt)")
    parser.add_argument("--systems", default="/tmp/systems.txt",
                        help="hostname,ip list (default /tmp/systems.txt)")
    parser.add_argument("--results-dir", default="/tmp/Results",
                        help="base folder for results; each run creates a "
                             "<timestamp> sub-folder (default /tmp/Results)")
    parser.add_argument("--user", help="SSH user (otherwise it is asked)")
    parser.add_argument("--ask-always-cred", action="store_true",
                        help="ask user and password for every system")
    parser.add_argument("--key", help="SSH private key (no password prompt)")
    parser.add_argument("--no-password", action="store_true",
                        help="use ssh-agent / ~/.ssh/config (no password prompt)")
    parser.add_argument("--parallel", type=int, default=5, help="systems processed together (default 5)")
    parser.add_argument("--connect-timeout", type=int, default=10, help="seconds (default 10)")
    parser.add_argument("--command-timeout", type=int, default=0, help="seconds, 0 = unlimited (default)")
    parser.add_argument("--allow-dangerous", action="store_true",
                        help="do not block potentially destructive commands")
    parser.add_argument("--dry-run", action="store_true",
                        help="show what would be done, without connecting")
    args = parser.parse_args()

    if args.help:
        print(USAGE.format(prog=parser.prog))
        return 0
    
    copy_mode = not args.exec_file and not args.diff

    if not copy_mode and args.object_list:
        parser.error("--object-list cannot be combined with --exec or --diff")

    if copy_mode and not args.object_list:
        args.object_list = "/tmp/object.txt"

    if args.diff and (not args.local or not args.remote):
        parser.error("--diff requires -L/--local and -R/--remote")

    if not args.diff and (args.local or args.remote):
        parser.error("-L/--local and -R/--remote can only be used with --diff")

    if args.key and args.no_password:
        parser.error("--key and --no-password cannot be used together")

    if args.parallel < 1 or args.connect_timeout < 1 or args.command_timeout < 0:
        parser.error("--parallel and --connect-timeout must be >= 1, --command-timeout >= 0")

    try:
        systems = load_systems(args.systems)
        commands = read_lines(args.exec_file) if args.exec_file else []
        plan = load_objects(args.object_list) if copy_mode else []
    except OSError as exc:
        parser.error(f"cannot read input file: {exc}")

    if not systems:
        parser.error(f"no valid systems in {args.systems}")

    if args.exec_file and not commands:
        parser.error(f"no commands in {args.exec_file}")

    if copy_mode and not any(operation["kind"] == "copy" for operation in plan):
        parser.error(f"no valid objects in {args.object_list} (all the lines were skipped or excluded)")

    # --- Dry run: show the plan and stop. No credentials, no connections, no files ---
    if args.dry_run:
        print("DRY RUN (--dry-run) - nothing is executed, no connection is opened, no file is written.")
        print(f"\nSystems ({len(systems)} valid):")

        for hostname, ip in systems:
            print(f"  {hostname}  (connect to: {ip})")

        print("\nOperations, in this order, on every system:")

        if args.diff:
            print(f"  DIFF     {args.local} (local) <-> {args.remote} (remote)")

        blocked = 0

        for command in commands:
            if command.split()[0].upper() == "COPY":
                try:
                    print(f"  COPY     {' -> '.join(shlex.split(command)[1:])}")
                except ValueError:
                    print(f"  COPY     {command}   (invalid quotes: it would fail)")
            elif not args.allow_dangerous and is_dangerous_command(command):
                print(f"  BLOCKED  {command}   (use --allow-dangerous to run it)")
                blocked += 1
            else:
                print(f"  RUN      {command}")

        invalid = 0

        for operation in plan:
            if operation["kind"] == "copy":
                kind = "folder" if os.path.isdir(operation["source"]) else "file"

                if operation["exclusions"]:
                    kind += ", excluding: " + ", ".join(operation["exclusions"])

                print(f"  COPY     {operation['source']} -> {operation['source']}   ({kind})")
            elif operation["kind"] == "skipped":
                print(f"  SKIP     {operation['text']}")
            else:
                print(f"  SKIPPED  {operation['text']}   ({operation['reason']})")
                invalid += 1

        operations = 1 if args.diff else len(commands) + len(plan)
        print(f"\nOperations: {operations} per system ({blocked} blocked, {invalid} skipped because of errors).")

        return 0

    run_dir = os.path.join(args.results_dir, f"{datetime.now():%Y-%m-%d_%H-%M-%S}")
    os.makedirs(run_dir, exist_ok=True)
    log_path = os.path.join(run_dir, "execution.log")
    results_path = os.path.join(run_dir, "results.txt")

    handler = logging.FileHandler(log_path, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s: %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    mode = "diff" if args.diff else "exec" if args.exec_file else "copy"
    logger.info("Starting: mode=%s, systems=%d, systems file=%s", mode, len(systems), args.systems)

    remotes = []
    shared = None

    for hostname, ip in systems:
        if args.ask_always_cred:
            user, password = ask_credentials(hostname, args)
        else:
            if shared is None:
                shared = ask_credentials("all systems", args)

            user, password = shared

        remotes.append(RemoteSystem(hostname, ip, user, password, args.key,
                                    args.connect_timeout, args.command_timeout))

    failed = 0

    with open(results_path, "w", encoding="utf-8") as results:
        results.write(f"Run started: {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        results.write(f"Mode: {mode}\n")
        results.write(f"Systems file: {args.systems}\n")

        if args.diff:
            results.write(f"Compare: {args.local} (local) <-> {args.remote} (remote)\n")
        elif args.exec_file:
            results.write(f"Commands file: {args.exec_file}\n")
        else:
            results.write(f"Object list: {args.object_list}\n")

        with ThreadPoolExecutor(max_workers=args.parallel) as pool:
            jobs = [pool.submit(process_system, remote, args, commands, plan) for remote in remotes]

            for job in as_completed(jobs):       # each result as soon as a system finishes
                text, ok = job.result()
                print(text)
                results.write(text + "\n")
                results.flush()                  # the file is readable while the run is going on

                if not ok:
                    failed += 1

        summary = f"Overall: systems={len(remotes)}, with errors={failed}."
        results.write("\n" + summary + "\n")

    logger.info(summary)
    print("\n" + summary)
    print(f"Results: {results_path}")
    print(f"Log:     {log_path}")
    
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())