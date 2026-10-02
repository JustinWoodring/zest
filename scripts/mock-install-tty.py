#!/usr/bin/env python3
"""Verify `sh < install.sh` can prompt through its controlling terminal."""
import fcntl
import os
import pty
import select
import shutil
import subprocess
import sys
import termios
import time
from pathlib import Path


def main() -> None:
    install, source_url, home, data, color_mode = sys.argv[1:]
    env = os.environ.copy()
    env.update({
        "HOME": home,
        "SHELL": "/bin/bash",
        "ZEST_DATA": data,
        "ZEST_REPO_URL": source_url,
        "ZEST_REF": "",
        "NO_COLOR": "1" if color_mode == "plain" else "",
        "TERM": "xterm-256color",
    })

    master, slave = pty.openpty()

    def acquire_controlling_terminal() -> None:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        ["/bin/sh"],
        stdin=subprocess.PIPE,
        stdout=slave,
        stderr=slave,
        env=env,
        pass_fds=(slave,),
        preexec_fn=acquire_controlling_terminal,
    )
    os.close(slave)
    output = bytearray()

    def read_until_prompt(timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while b"to your PATH" not in output:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            ready, _, _ = select.select([master], [], [], min(remaining, 0.5))
            if ready:
                try:
                    output.extend(os.read(master, 4096))
                except OSError:
                    break
            if process.poll() is not None and not ready:
                break
        return b"Add " in output and b"to your PATH" in output

    try:
        assert process.stdin is not None
        with open(install, "rb") as source:
            shutil.copyfileobj(source, process.stdin)
        process.stdin.close()

        if not read_until_prompt(180):
            raise RuntimeError(f"installer did not prompt through /dev/tty:\n{output.decode(errors='replace')}")

        os.write(master, b"y\n")
        deadline = time.monotonic() + 180
        while process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("installer did not finish after PATH approval")
            ready, _, _ = select.select([master], [], [], min(remaining, 0.5))
            if ready:
                try:
                    output.extend(os.read(master, 4096))
                except OSError:
                    break
        status = process.wait(timeout=5)
    except BaseException:
        if process.poll() is None:
            process.kill()
            process.wait()
        raise
    finally:
        os.close(master)

    text = output.decode(errors="replace")
    if status != 0:
        raise RuntimeError(f"installer exited {status}:\n{text}")
    color_marker = b"\x1b[36mzest-install:\x1b[0m"
    if color_mode == "color" and color_marker not in output:
        raise RuntimeError(f"interactive installer status was not colored:\n{text}")
    if color_mode == "plain" and b"\x1b[" in output:
        raise RuntimeError(f"NO_COLOR did not suppress ANSI escapes:\n{text}")
    if b"Add " not in output or b"to your PATH" not in output:
        raise RuntimeError(f"installer did not offer the PATH update:\n{text}")
    profile = Path(home) / ".bashrc"
    if f'export PATH="{data}/bin:$PATH"' not in profile.read_text():
        raise RuntimeError(f"PATH profile entry missing from {profile}")
    print("piped install prompted on the controlling terminal and added its bin dir to PATH")


if __name__ == "__main__":
    main()
