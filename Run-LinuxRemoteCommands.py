#!/usr/bin/env python3

#############################################################################################################
## Description: Program to execute commands, copy files or compare paths on remote Linux systems over SSH
##
## Author: Matteo Z.
#############################################################################################################

import argparse
import difflib
import getpass
import logging
import os
import posixpath
import re
import shlex
import stat
import sys
import ipaddress
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from fabric import Config, Connection

SEP = "=" * 80
USAGE = """
USAGE
  {prog} --exec FILE [options]                     exec mode
  {prog} --diff -L PATH -R PATH [options]          diff mode

MODES (one is required)
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
  --results-dir DIR      Results base folder (default /tmp/Results)
                         -> <results-dir>/<timestamp>/execution.log  and  results.txt

CONNECTION
  --parallel N           Systems processed together (default 5)
  --connect-timeout N    Seconds to connect (default 10)
  --command-timeout N    Max seconds per command, 0 = no limit (default 0)

SAFETY
  --allow-dangerous      Do not block potentially destructive commands

OTHER
  -h, --help             Show the help

EXIT CODES
  0 = all ok   1 = at least one error   2 = invalid parameters or input files
"""
logger = logging.getLogger("remote_oper")


# =============================================================================
# DANGEROUS COMMANDS
# This is a "common sense" check, not complete protection: command files
# must still be trusted. It is disabled with --allow-dangerous.
# To block one more command, just add it to one of the two lists.
# =============================================================================

# ALWAYS blocked: they shut down/restart the system or wipe disks.
# ("mkfs" also blocks mkfs.ext4, mkfs.xfs, ...; "init" also blocks "init 3")
DANGEROUS_COMMANDS = ["shutdown", "reboot", "halt", "poweroff", "init",
                      "mkfs", "dd", "fdisk", "parted", "wipefs"]

# Blocked ONLY when they act on the root "/" (e.g. "rm -rf /", "chmod -R 777 /").
DANGEROUS_ON_ROOT = ["rm", "chmod", "chown", "mv"]


def is_dangerous_command(line):
    """Returns True if the line contains a dangerous command."""
    # Fork bomb  :(){ :|:& };:  (written with or without spaces)
    if ":(){" in line.replace(" ", ""):
        return True

    # A line can contain several commands, e.g. "cd /tmp && reboot" or "ls | sort".
    # We split it on the separators  &&  ||  ;  |  &  and check every piece.
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
        
        if name in DANGEROUS_ON_ROOT and ("/" in words or "/*" in words):
            return True
        
    return False


# =============================================================================
# REMOTE SYSTEM: SSH connection, commands and files (SFTP)
# =============================================================================

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
            # (important when working on several systems in parallel).
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

    def copy(self, local, remote):
        """Copies a local file or directory to the remote system (exception on failure)."""
        sftp = self.connection.sftp()
        
        if os.path.isfile(local):
            # If the destination is an existing directory, the file goes INSIDE it.
            if self.kind(remote) == "directory":
                remote = posixpath.join(remote, os.path.basename(local))

            self.mkdirs(posixpath.dirname(remote))
            sftp.put(local, remote)
        elif os.path.isdir(local):
            # os.walk visits the directory and all subdirectories (empty ones too).
            for folder, _subfolders, files in os.walk(local):
                relative = os.path.relpath(folder, local)
                target = remote if relative == "." else posixpath.join(remote, relative)
                self.mkdirs(target)

                for name in files:
                    sftp.put(os.path.join(folder, name), posixpath.join(target, name))
        else:
            raise FileNotFoundError(f"local path not found: {local}")

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


# =============================================================================
# COMPARISON (--diff)
# =============================================================================

def local_tree(root):
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
    
    # A zero byte or non-UTF-8 text means a binary file: no line-by-line comparison.
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
    # everything else is only in the local file or only in the remote file.
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


# =============================================================================
# COMMAND EXECUTION (--exec)
# =============================================================================

def run_commands(remote, commands, allow_dangerous):
    """Runs the commands on one system. Returns (output_lines, ok)."""
    lines, ok = [], True

    for command in commands:
        lines += ["", f"$ {command}"]
        first_word = command.split()[0]

        if first_word.upper() == "COPY":
            # COPY is not sent to the remote shell: the copy is done via SFTP.
            # Paths containing spaces must be quoted.
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


def process_system(remote, args, commands):
    """All the work on ONE system: connect, run the operations, disconnect.
    Runs in parallel for several systems. Returns (text_block, ok)."""
    try:
        remote.connect()

        if args.diff:
            lines, ok = compare_paths(args.local, remote, args.remote)
            logger.info("[%s] Compared %s with %s (details in results.txt)",
                        remote.hostname, args.local, args.remote)
        else:
            lines, ok = run_commands(remote, commands, args.allow_dangerous)
    except Exception as exc:
        logger.error("[%s] Failed: %s", remote.hostname, exc)
        lines, ok = [f"FAILED: {exc}"], False
    finally:
        remote.disconnect()

    logger.info("[%s] Finished: %s", remote.hostname, "OK" if ok else "ERRORS")
    header = ["", SEP, f"HOST: {remote.hostname} ({remote.address})", SEP]
    footer = [SEP, f"Result: {'OK' if ok else 'ERRORS'}"]

    return "\n".join(header + lines + footer), ok


# =============================================================================
# INPUT: systems file, commands file, credentials
# =============================================================================

def read_lines(path):
    """Lines of a text file, without empty lines and comments (#)."""
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

        # The second field must be a real IP address (e.g. "pippo" is not valid)
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


# =============================================================================
# MAIN
# =============================================================================

def main():
    # add_help=False: we print our own USAGE instead of the automatic argparse help.
    parser = argparse.ArgumentParser(
        usage="%(prog)s (--exec FILE | --diff -L PATH -R PATH) [options]   (use --help for details)",
        add_help=False)
    parser.add_argument("-h", "--help", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--exec", dest="exec_file", metavar="FILE",
                      help="file with one command (or COPY <local> <remote>) per line")
    mode.add_argument("--diff", action="store_true", help="compare -L with -R (read-only)")
    parser.add_argument("-L", "--local", help="local path for --diff")
    parser.add_argument("-R", "--remote", help="remote path for --diff")
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
    args = parser.parse_args()

    if args.help:
        print(USAGE.format(prog=parser.prog))
        return 0
    
    if not args.exec_file and not args.diff:
        parser.error("one of --exec or --diff is required")

    if args.diff and (not args.local or not args.remote):
        parser.error("--diff requires -L/--local and -R/--remote")

    if not args.diff and (args.local or args.remote):
        parser.error("-L/--local and -R/--remote can only be used with --diff")

    if args.key and args.no_password:
        parser.error("--key and --no-password cannot be used together")

    if args.parallel < 1 or args.connect_timeout < 1 or args.command_timeout < 0:
        parser.error("--parallel and --connect-timeout must be >= 1, --command-timeout >= 0")

    # --- Read the input files BEFORE asking for credentials ---
    try:
        systems = load_systems(args.systems)
        commands = [] if args.diff else read_lines(args.exec_file)
    except OSError as exc:
        parser.error(f"cannot read input file: {exc}")

    if not systems:
        parser.error(f"no valid systems in {args.systems}")

    if not args.diff and not commands:
        parser.error(f"no commands in {args.exec_file}")

    # --- Run folder: <results-dir>/<timestamp>/ with execution.log and results.txt ---
    run_dir = os.path.join(args.results_dir, f"{datetime.now():%Y-%m-%d_%H-%M-%S}")
    os.makedirs(run_dir, exist_ok=True)
    log_path = os.path.join(run_dir, "execution.log")
    results_path = os.path.join(run_dir, "results.txt")

    # execution.log: only events (what happened and when), written by all threads.
    handler = logging.FileHandler(log_path, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s: %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    mode = "diff" if args.diff else "exec"
    logger.info("Starting: mode=%s, systems=%d, systems file=%s", mode, len(systems), args.systems)

    # --- Credentials: asked here, one at a time, before going parallel ---
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

    # --- Parallel work: one thread per system, at most --parallel at once ---
    # results.txt: the full output of every system. Only this (main) thread writes it.
    failed = 0

    with open(results_path, "w", encoding="utf-8") as results:
        results.write(f"Run started: {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        results.write(f"Mode: {mode}\n")
        results.write(f"Systems file: {args.systems}\n")

        if args.diff:
            results.write(f"Compare: {args.local} (local) <-> {args.remote} (remote)\n")
        else:
            results.write(f"Commands file: {args.exec_file}\n")

        with ThreadPoolExecutor(max_workers=args.parallel) as pool:
            jobs = [pool.submit(process_system, remote, args, commands) for remote in remotes]

            for job in as_completed(jobs):
                text, ok = job.result()
                print(text)
                results.write(text + "\n")
                results.flush()                  # the file is readable while the run is going on

                if not ok:
                    failed += 1

        summary = f"Overall: systems={len(remotes)}, with errors={failed}."
        results.write("\n" + summary + "\n")

    logger.info(summary)
    print(summary)
    print(f"Results: {results_path}")
    print(f"Log:     {log_path}")
    
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())