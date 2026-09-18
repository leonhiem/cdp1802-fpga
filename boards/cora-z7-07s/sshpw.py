#!/usr/bin/env python3
"""Minimal stdlib-only SSH password-auth wrapper (no sshpass/expect on
this host). Usage: sshpw.py <password> <ssh-or-scp-argv...>
Spawns the given ssh/scp command under a pty, watches for the
password prompt, sends the password once, then streams the pty
output to our stdout until the child exits."""
import os, pty, sys, select, termios, tty

password = sys.argv[1]
argv = sys.argv[2:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
else:
    buf = b""
    while True:
        try:
            r, _, _ = select.select([fd], [], [], 0.5)
        except OSError:
            break
        if fd in r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buf += data
            # Resend on every "password:" prompt, not just the first
            # -- a single spurious rejection (e.g. right after a
            # fresh board reboot) used to leave this hanging forever
            # on the retry prompt, since it only ever sent the
            # password once per whole invocation.
            if b"assword:" in buf:
                os.write(fd, (password + "\n").encode())
                buf = b""
        pid_done, status = os.waitpid(pid, os.WNOHANG)
        if pid_done != 0:
            break
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
