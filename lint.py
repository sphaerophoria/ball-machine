#!/usr/bin/env python3

import subprocess
import signal
import tempfile
import sys

from pathlib import Path

process = None


def signal_handler(sig, frame):
    if process is not None:
        process.kill()
    sys.exit(0)


def main():
    global process
    signal.signal(signal.SIGINT, signal_handler)
    subprocess.run(["zig", "fmt", "build.zig", "--check"], check=True)
    subprocess.run(["zig", "fmt", "src", "--check"], check=True)
    subprocess.run(["prettier", "-c", "src/"], check=True)
    subprocess.run(["jshint", "src/"], check=True)
    subprocess.run(
        ["clang-format", "-n", "-Werror", "src/chambers/plinko.c"], check=True
    )
    subprocess.run(["black", "--check", "src", "test", "lint.py"], check=True)
    subprocess.run(["zig", "build", "--summary", "all"], check=True)
    subprocess.run(["zig", "build", "test"], check=True)
    subprocess.run(["zig", "build", "-Doptimize=ReleaseSafe"], check=True)
    subprocess.run(["zig", "build", "chambers", "-Doptimize=ReleaseSmall"], check=True)

    for chamber_path in Path("./zig-out/bin/").glob("*.wasm"):
        subprocess.run(["./zig-out/bin/test_chamber", str(chamber_path)], check=True)

    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["./zig-out/bin/generate_test_db", str(d)], check=True)

        process = subprocess.Popen(
            [
                "valgrind",
                "--suppressions=suppressions.valgrind",
                "--leak-check=full",
                "--track-fds=yes",
                "--error-exitcode=1",
                "./zig-out/bin/ball-machine",
                "--port",
                "8000",
                "--client-id",
                "1234",
                "--client-secret",
                "5678",
                "--admin-id",
                "twitch_admin",
                "--server-url",
                "http://localhost:8000",
                "--db",
                str(d),
            ]
        )

        try:
            subprocess.run(["python", "./test/integration.py"], check=True)
            process.send_signal(signal.SIGINT)
            ret_code = process.wait()
            if ret_code != 0:
                raise RuntimeError("Process did not exit cleanly")
        except Exception as e:
            process.kill()
            raise e


if __name__ == "__main__":
    main()
