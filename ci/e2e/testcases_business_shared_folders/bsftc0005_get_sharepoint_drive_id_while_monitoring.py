#!/usr/bin/env python3
"""
Business Shared Folders Test Case 0005:
Validate that --get-sharepoint-drive-id '*' can run successfully while the same
configuration directory is already being used by a live --monitor process.

This test intentionally uses the same --confdir, items.sqlite3 and refresh_token
as the running monitor process. Any output indicating that another onedrive
process is already running is a failure.
"""

import argparse
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


SETTLED_MARKER = "Sync with Microsoft OneDrive is complete"
EXPECTED_QUERY_LINE = "Office 365 Library Name Query: *"
EXPECTED_RESULT_HEADER = "The following SharePoint site names were returned:"
BUG_MARKERS = (
    "application is already running",
    "database is locked",
    "blocked by another process",
)


def run_cmd(cmd, *, cwd=None, timeout=300):
    return subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )


def wait_for_monitor_settle(proc, log_path, timeout):
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        if proc.poll() is not None:
            try:
                last = log_path.read_text(errors="replace")
            except FileNotFoundError:
                last = ""
            raise RuntimeError(
                f"monitor process exited before initial sync settled; rc={proc.returncode}\n{last[-4000:]}"
            )
        try:
            last = log_path.read_text(errors="replace")
        except FileNotFoundError:
            last = ""
        if SETTLED_MARKER in last:
            return last
        time.sleep(2)
    raise TimeoutError(f"monitor process did not settle within {timeout} seconds\n{last[-4000:]}")


def stop_monitor(proc):
    if proc.poll() is not None:
        return
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--onedrive-bin", default=os.environ.get("ONEDRIVE_BIN", "./onedrive"))
    parser.add_argument("--confdir", required=True)
    parser.add_argument("--sync-dir", required=True)
    parser.add_argument("--settle-timeout", type=int, default=900)
    args = parser.parse_args()

    onedrive_bin = str(Path(args.onedrive_bin).resolve())
    confdir = str(Path(args.confdir).resolve())
    sync_dir = str(Path(args.sync_dir).resolve())

    with tempfile.TemporaryDirectory(prefix="bsftc0005-") as tmp:
        monitor_log = Path(tmp) / "monitor.log"
        query_log = Path(tmp) / "query.log"

        monitor_cmd = [
            onedrive_bin,
            "--confdir", confdir,
            "--syncdir", sync_dir,
            "--monitor",
            "--verbose",
        ]

        with monitor_log.open("w", encoding="utf-8") as fp:
            monitor_proc = subprocess.Popen(
                monitor_cmd,
                stdout=fp,
                stderr=subprocess.STDOUT,
                text=True,
            )

        try:
            wait_for_monitor_settle(monitor_proc, monitor_log, args.settle_timeout)

            query_cmd = [
                onedrive_bin,
                "--confdir", confdir,
                "--syncdir", sync_dir,
                "--get-sharepoint-drive-id", "*",
            ]
            result = run_cmd(query_cmd, timeout=300)
            query_log.write_text(result.stdout, encoding="utf-8")

            output_lower = result.stdout.lower()
            failures = []
            if result.returncode != 0:
                failures.append(f"--get-sharepoint-drive-id exited with status {result.returncode}")
            if EXPECTED_QUERY_LINE not in result.stdout:
                failures.append("expected SharePoint wildcard query line was not printed")
            if EXPECTED_RESULT_HEADER not in result.stdout:
                failures.append("expected SharePoint site result header was not printed")
            for marker in BUG_MARKERS:
                if marker in output_lower:
                    failures.append(f"unexpected live-client/database-lock failure marker present: {marker}")

            if failures:
                print("Test Case 0005: get-sharepoint-drive-id while monitor active — FAILED")
                for failure in failures:
                    print(f" - {failure}")
                print("\n--- query output ---")
                print(result.stdout[-8000:])
                return 1

            print("Test Case 0005: get-sharepoint-drive-id while monitor active — PASSED")
            return 0
        finally:
            stop_monitor(monitor_proc)


if __name__ == "__main__":
    sys.exit(main())
