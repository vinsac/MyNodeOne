#!/usr/bin/env python3
"""Runs a command with a real terminal on stdin and feeds it typed lines.

The disk checks look for a terminal and have no way to bypass that, so the tests
need a real one. After the given lines the terminal sends end-of-file, so a prompt
with no answer reads as empty rather than hanging.

Usage: pty_run.py [--input LINE]... [--timeout SECONDS] -- command [args...]
Exit code: the command's, or 124 on timeout.
"""
import argparse
import os
import pty
import signal
import subprocess
import sys
import termios
import threading


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', action='append', default=[])
    parser.add_argument('--timeout', type=float, default=60)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    options = parser.parse_args()
    command = options.command[1:] if options.command[:1] == ['--'] else options.command

    master, slave = pty.openpty()
    attrs = termios.tcgetattr(slave)
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attrs)

    process = subprocess.Popen(command, stdin=slave, start_new_session=True)
    os.close(slave)

    def drain():
        try:
            while os.read(master, 4096):
                pass
        except OSError:
            pass

    threading.Thread(target=drain, daemon=True).start()

    for line in options.input:
        os.write(master, line.encode() + b'\n')
    # One end-of-file per possible extra prompt.
    for _ in range(8):
        os.write(master, b'\x04')

    try:
        return process.wait(timeout=options.timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        print(f'pty_run: timed out after {options.timeout}s', file=sys.stderr)
        return 124


if __name__ == '__main__':
    sys.exit(main())
