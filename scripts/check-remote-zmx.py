#!/usr/bin/env python3
"""Check zmx persistence through real SSH PTYs in a private socket namespace."""
import argparse
import fcntl
import json
import os
import pty
import re
import select
import shlex
import signal
import struct
import subprocess
import termios
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", help="SSH destination; omitted for a local PTY check")
    parser.add_argument("--zmx-binary", required=True, help="Absolute zmx path on the target")
    parser.add_argument("--concurrent-sessions", type=int, default=0, help="Additionally keep this many independent SSH PTYs live")
    args = parser.parse_args()
    namespace = "/tmp/czx-" + uuid.uuid4().hex[:10]
    session = "persistence-check"
    clients = []
    masters = []
    sessions = [session]
    preamble = f"unset ZMX_SESSION ZMX_SESSION_PREFIX; export ZMX_DIR={shlex.quote(namespace)}; "

    def target_command(command, tty=False):
        script = preamble + command
        if args.host:
            return ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "RemoteCommand=none", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                    "-o", "ControlPersist=no", "-tt" if tty else "-T", "--", args.host, script]
        return ["/bin/sh", "-c", script]

    def command(*words, check=True):
        return subprocess.run(target_command(shlex.join([args.zmx_binary, *words])),
            capture_output=True, text=True, timeout=15, check=check).stdout.strip()

    def read_until(fd, pattern, timeout=15):
        data = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], max(0, deadline-time.monotonic()))
            if not ready:
                break
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
            match = re.search(pattern, data)
            if match:
                return match
        raise RuntimeError(f"PTY did not produce expected marker: {data[-1200:]!r}")

    def attach(create, name=session):
        master, slave = pty.openpty()
        masters.append(master)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        # Existing-only attach uses the same discovery check as the native binding.
        script = ""
        if not create:
            script = f"names=$({shlex.quote(args.zmx_binary)} list --short) || exit $?; "
            script += f"printf '%s\\n' \"$names\" | /usr/bin/grep -Fx -- {shlex.quote(name)} >/dev/null || exit 44; "
        script += "exec " + shlex.join([args.zmx_binary, "attach", name, "/bin/sh"])
        def establish_terminal():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        client = subprocess.Popen(target_command(script, tty=True), stdin=slave,
            stdout=slave, stderr=slave, env={**os.environ, "TERM": "xterm-256color"},
            preexec_fn=establish_terminal)
        os.close(slave)
        clients.append(client)
        marker = ("CMUX_PID_" + uuid.uuid4().hex[:8]).encode()
        os.write(master, b"echo " + marker + b"=$$\n")
        pid = read_until(master, marker + rb"=(\d+)").group(1).decode()
        return client, master, pid

    def wait_for_exit(client, fd):
        deadline = time.monotonic() + 15
        output = b""
        while client.poll() is None and time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                    output += chunk
                except OSError:
                    break
        try:
            return client.wait(timeout=1)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Client failed to exit: {output[-1200:]!r}") from None

    try:
        assert command("list", "--short") == ""
        first, fd, first_pid = attach(create=True)
        before = command("list")
        assert session in before
        # Ctrl+backslash deliberately detaches the current zmx client.
        os.write(fd, b"\x1c")
        wait_for_exit(first, fd)
        assert first.returncode == 0, f"detach status {first.returncode}"
        second, fd, second_pid = attach(create=False)
        assert first_pid == second_pid, "reattach started another shell"
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 60, 0, 0))
        os.kill(second.pid, signal.SIGWINCH)
        os.write(fd, b"stty size\n")
        read_until(fd, rb"(?:\r?\n)20 60(?:\r?\n)")
        # An abrupt SSH client loss must also preserve the remote shell.
        os.killpg(second.pid, signal.SIGTERM)
        wait_for_exit(second, fd)
        third, fd, third_pid = attach(create=False)
        assert third_pid == first_pid, "transport loss killed the remote shell"
        os.write(fd, b"\x1c")
        wait_for_exit(third, fd)
        assert third.returncode == 0
        simultaneous = []
        for index in range(args.concurrent_sessions):
            name = f"parallel-{index}"
            sessions.append(name)
            simultaneous.append(attach(create=True, name=name))
        if simultaneous:
            assert set(command("list", "--short").splitlines()) == set(sessions)
            assert len({pid for _, _, pid in simultaneous}) == len(simultaneous)
            for client, fd, _ in simultaneous:
                os.write(fd, b"\x1c")
                assert wait_for_exit(client, fd) == 0
        print(json.dumps({"attach_detach_reattach_resize_transport_loss": "passed",
                          "same_remote_shell_pid": True, "simultaneous_sessions": len(simultaneous),
                          "version": command("version").splitlines()[0]}))
    finally:
        command("kill", *sessions, "--force", check=False)
        for client in clients:
            if client.poll() is None:
                client.kill()
                client.wait(timeout=10)
        for fd in masters:
            os.close(fd)
        subprocess.run(target_command("rmdir -- " + shlex.quote(namespace)),
                       capture_output=True, timeout=15, check=False)


if __name__ == "__main__":
    main()
