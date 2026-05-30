from __future__ import annotations

import subprocess

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file
from testcases_business_shared_folders.shared_folder_common import (
    case_sync_root,
    reset_local_sync_root,
    stop_monitor_process,
    wait_for_stdout_marker,
    write_case_config,
)


EXPECTED_QUERY_LINE = "Office 365 Library Name Query: *"
EXPECTED_RESULT_HEADER = "The following SharePoint site names were returned:"

EXPECTED_SITE_MARKERS = [
    "Data Monitoring",
    "Shared_Folder_Testing",
]

BUG_MARKERS = [
    "application is already running",
    "database is locked",
    "blocked by another process",
]


class BusinessSharedFolderTestCase0005GetSharePointDriveIdWhileMonitoring(E2ETestCase):
    case_id = "bsftc0005"
    name = "get-sharepoint-drive-id while monitor active"
    description = (
        "Validate that --get-sharepoint-drive-id '*' can run successfully using the "
        "same configuration directory while a --monitor client process is already active"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name=self.case_id,
            ensure_refresh_token=True,
        )

        sync_root = case_sync_root(self.case_id)
        confdir = layout.work_dir / "conf"
        reset_local_sync_root(sync_root)
        write_case_config(context, confdir, self.case_id)

        monitor_stdout_file = layout.log_dir / "monitor_stdout.log"
        monitor_stderr_file = layout.log_dir / "monitor_stderr.log"
        query_stdout_file = layout.log_dir / "query_stdout.log"
        query_stderr_file = layout.log_dir / "query_stderr.log"
        metadata_file = layout.state_dir / "metadata.txt"
        failure_markers_file = layout.state_dir / "failure_markers.txt"
        missing_markers_file = layout.state_dir / "missing_expected_markers.txt"

        monitor_command = [
            context.onedrive_bin,
            "--monitor",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--confdir",
            str(confdir),
        ]

        query_command = [
            context.onedrive_bin,
            "--get-sharepoint-drive-id",
            "*",
            "--confdir",
            str(confdir),
        ]

        context.log(f"Executing Test Case {self.case_id} monitor: {command_to_string(monitor_command)}")

        with monitor_stdout_file.open("w", encoding="utf-8") as monitor_stdout_fp, \
             monitor_stderr_file.open("w", encoding="utf-8") as monitor_stderr_fp:

            monitor_process = subprocess.Popen(
                monitor_command,
                cwd=str(context.repo_root),
                stdout=monitor_stdout_fp,
                stderr=monitor_stderr_fp,
                text=True,
            )

            try:
                initial_sync_complete = wait_for_stdout_marker(
                    monitor_stdout_file,
                    "Sync with Microsoft OneDrive is complete",
                    timeout_seconds=1200,
                )

                if not initial_sync_complete:
                    monitor_returncode = stop_monitor_process(monitor_process)
                    reason = "monitor mode did not complete initial sync before SharePoint library query"
                    self._write_case_metadata(
                        metadata_file,
                        monitor_command=monitor_command,
                        query_command=query_command,
                        monitor_returncode=monitor_returncode,
                        query_returncode=None,
                        sync_root=sync_root,
                        confdir=confdir,
                        initial_sync_complete=initial_sync_complete,
                        failures=[reason],
                    )
                    return self.fail_result(
                        self.case_id,
                        self.name,
                        reason,
                        self._artifacts(
                            monitor_stdout_file,
                            monitor_stderr_file,
                            query_stdout_file,
                            query_stderr_file,
                            metadata_file,
                            failure_markers_file,
                            missing_markers_file,
                        ),
                        {
                            "monitor_command": monitor_command,
                            "query_command": query_command,
                            "monitor_returncode": monitor_returncode,
                            "initial_sync_complete": initial_sync_complete,
                            "sync_root": str(sync_root),
                            "config_dir": str(confdir),
                        },
                    )

                context.log(f"Executing Test Case {self.case_id} query: {command_to_string(query_command)}")
                query_result = run_command(query_command, cwd=context.repo_root)

                write_text_file(query_stdout_file, query_result.stdout)
                write_text_file(query_stderr_file, query_result.stderr)

                query_output = f"{query_result.stdout}\n{query_result.stderr}"
                query_output_lower = query_output.lower()

                missing_markers = []
                failure_markers = []
                failures = []

                expected_markers = [
                    EXPECTED_QUERY_LINE,
                    EXPECTED_RESULT_HEADER,
                    *EXPECTED_SITE_MARKERS,
                ]

                for marker in expected_markers:
                    if marker not in query_output:
                        missing_markers.append(marker)

                for marker in BUG_MARKERS:
                    if marker in query_output_lower:
                        failure_markers.append(marker)

                if query_result.returncode != 0:
                    failures.append(f"--get-sharepoint-drive-id exited with status {query_result.returncode}")

                if missing_markers:
                    failures.append("expected SharePoint library enumeration output was not present")

                if failure_markers:
                    failures.append("unexpected active-client or database-lock failure marker was present")

                write_text_file(missing_markers_file, "\n".join(missing_markers) + ("\n" if missing_markers else ""))
                write_text_file(failure_markers_file, "\n".join(failure_markers) + ("\n" if failure_markers else ""))

                monitor_returncode = stop_monitor_process(monitor_process)

                self._write_case_metadata(
                    metadata_file,
                    monitor_command=monitor_command,
                    query_command=query_command,
                    monitor_returncode=monitor_returncode,
                    query_returncode=query_result.returncode,
                    sync_root=sync_root,
                    confdir=confdir,
                    initial_sync_complete=initial_sync_complete,
                    failures=failures,
                    missing_markers=missing_markers,
                    failure_markers=failure_markers,
                )

                artifacts = self._artifacts(
                    monitor_stdout_file,
                    monitor_stderr_file,
                    query_stdout_file,
                    query_stderr_file,
                    metadata_file,
                    failure_markers_file,
                    missing_markers_file,
                )

                details = {
                    "monitor_command": monitor_command,
                    "query_command": query_command,
                    "monitor_returncode": monitor_returncode,
                    "query_returncode": query_result.returncode,
                    "initial_sync_complete": initial_sync_complete,
                    "sync_root": str(sync_root),
                    "config_dir": str(confdir),
                    "missing_markers": missing_markers,
                    "failure_markers": failure_markers,
                }

                if monitor_returncode not in (0, 130, -2):
                    failures.append(f"monitor mode exited with unexpected status {monitor_returncode}")

                if failures:
                    return self.fail_result(
                        self.case_id,
                        self.name,
                        "; ".join(failures),
                        artifacts,
                        details,
                    )

                return self.pass_result(self.case_id, self.name, artifacts, details)

            finally:
                stop_monitor_process(monitor_process)

    def _artifacts(self, *paths) -> list[str]:
        return [str(path) for path in paths]

    def _write_case_metadata(
        self,
        metadata_file,
        *,
        monitor_command,
        query_command,
        monitor_returncode,
        query_returncode,
        sync_root,
        confdir,
        initial_sync_complete,
        failures,
        missing_markers=None,
        failure_markers=None,
    ) -> None:
        lines = [
            f"case_id={self.case_id}",
            f"name={self.name}",
            f"monitor_command={command_to_string(monitor_command)}",
            f"query_command={command_to_string(query_command)}",
            f"monitor_returncode={monitor_returncode}",
            f"query_returncode={query_returncode}",
            f"sync_root={sync_root}",
            f"config_dir={confdir}",
            f"initial_sync_complete={initial_sync_complete}",
            f"failures={failures!r}",
            f"missing_markers={missing_markers or []!r}",
            f"failure_markers={failure_markers or []!r}",
        ]
        write_text_file(metadata_file, "\n".join(lines) + "\n")