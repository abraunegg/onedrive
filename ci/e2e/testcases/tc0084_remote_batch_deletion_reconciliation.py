from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from testcases.monitor_case_base import MonitorModeTestCaseBase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file


class TestCase0084RemoteBatchDeletionReconciliation(MonitorModeTestCaseBase):
    """Validate production monitor full-scan true-up after independent remote deletes.

    The mutator is an independent upload-only client. The subject runs normal
    bidirectional --monitor, with native /delta enabled and a one-cycle
    full-scan cadence to keep CI bounded. The 90-second interval is permitted
    only for a bounded developer monitor run (monitor_max_loop > 0).
    No forced /children or resync is used during reconciliation.
    We cannot simulate omitted Graph tombstones.
    """

    case_id = "0084"
    name = "monitor remote batch deletion full-scan reconciliation"
    description = (
        "Validate native monitor /delta reconciliation and scheduled online full-scan "
        "true-up after independent remote batch deletion, without resync or "
        "resurrection of deleted remote objects"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0084", ensure_refresh_token=True)
        work_dir = layout.work_dir
        log_dir = layout.log_dir
        state_dir = layout.state_dir

        mutator_root = work_dir / "mutator-root"
        subject_root = work_dir / "subject-root"
        before_verify_root = work_dir / "before-verify-root"
        after_verify_root = work_dir / "after-verify-root"
        conf_mutator = work_dir / "conf-mutator"
        conf_subject = work_dir / "conf-subject"
        conf_before_verify = work_dir / "conf-before-verify"
        conf_after_verify = work_dir / "conf-after-verify"
        root_name = f"ZZ_E2E_TC0084_{context.run_id}_{os.getpid()}"
        metadata_file = state_dir / "metadata.txt"

        # Deliberately large enough to cover several nested branches, but not
        # a stress workload against the shared CI OneDrive account.
        deleted_files = {
            f"{root_name}/Batch/Group{group:02d}/item{item:02d}.txt":
                f"TC0084 remotely deleted group={group} item={item}\n"
            for group in range(6) for item in range(6)
        }
        deleted_files[f"{root_name}/Singles/removed.txt"] = "TC0084 removed single file\n"
        keep_files = {
            f"{root_name}/anchor.txt": "TC0084 anchor survives remote batch deletion\n",
            f"{root_name}/Survivor/Nested/keep.txt": "TC0084 nested survivor\n",
        }
        removed_directories = [f"{root_name}/Batch", f"{root_name}/EmptyRemoved"]
        expected_final = sorted([
            f"{root_name}/", f"{root_name}/Survivor/", f"{root_name}/Survivor/Nested/",
            f"{root_name}/Singles/", *keep_files,
        ])
        phase_names = (
            "seed", "subject_initial", "remote_delete", "remote_before",
            "subject_converge", "remote_after",
        )
        artifacts = [
            str(log_dir / f"{phase}_{stream}.log")
            for phase in phase_names for stream in ("stdout", "stderr")
        ]
        artifacts.extend((
            str(log_dir / "subject_monitor_stdout.log"),
            str(log_dir / "subject_monitor_stderr.log"),
        ))
        artifacts.extend(str(state_dir / name) for name in (
            "seed_manifest.txt", "subject_initial_manifest.txt", "remote_before_manifest.txt",
            "subject_final_manifest.txt", "remote_after_manifest.txt", "metadata.txt",
        ))
        details: dict[str, object] = {
            "root_name": root_name,
            "deleted_file_count": len(deleted_files),
            "deleted_directory_roots": removed_directories,
            "subject_force_children_scan": False,
            "subject_monitor_fullscan_frequency": 1,
            "subject_monitor_interval_seconds": 90,
            "subject_websocket_support": False,
        }

        context.prepare_minimal_config_dir(
            conf_mutator,
            f'# tc0084 independent remote mutator\nsync_dir = "{mutator_root}"\n'
            'bypass_data_preservation = "true"\n',
        )
        context.prepare_minimal_config_dir(
            conf_subject,
            f'# tc0084 tracked monitor subject\nsync_dir = "{subject_root}"\n'
            'bypass_data_preservation = "false"\n'
            'monitor_interval = "90"\n'
            'monitor_fullscan_frequency = "1"\n'
            'monitor_max_loop = "3"\n'
            'disable_websocket_support = "true"\n',
        )
        # Scope via sync_list, not --single-directory: the subject must use native /delta.
        write_text_file(conf_subject / "sync_list", f"/{root_name}\n")
        for conf_dir, sync_root in (
            (conf_before_verify, before_verify_root),
            (conf_after_verify, after_verify_root),
        ):
            context.prepare_minimal_config_dir(
                conf_dir,
                f'# tc0084 independent remote verifier\nsync_dir = "{sync_root}"\n'
                'bypass_data_preservation = "true"\n',
            )

        for relative, content in {**deleted_files, **keep_files}.items():
            write_text_file(mutator_root / relative, content)
        (mutator_root / root_name / "EmptyRemoved").mkdir(parents=True, exist_ok=True)

        mutator_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
            "--verbose", "--single-directory", root_name,
            "--confdir", str(conf_mutator),
        ]
        subject_command = [
            context.onedrive_bin, "--display-running-config", "--sync",
            "--verbose", "--confdir", str(conf_subject),
        ]
        monitor_command = [
            context.onedrive_bin, "--display-running-config", "--monitor",
            "--verbose", "--verbose", "--confdir", str(conf_subject),
        ]

        def fail(reason: str) -> TestResult:
            self.write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, reason, artifacts, details)

        def execute(phase: str, command: list[str]):
            context.log(f"Executing Test Case {self.case_id} {phase}: {command_to_string(command)}")
            result = run_command(command, cwd=context.repo_root)
            write_text_file(log_dir / f"{phase}_stdout.log", result.stdout)
            write_text_file(log_dir / f"{phase}_stderr.log", result.stderr)
            details[f"{phase}_returncode"] = result.returncode
            details[f"{phase}_command"] = command_to_string(command)
            return result

        seed = execute("seed", mutator_command + ["--resync", "--resync-auth"])
        if seed.returncode != 0 or not (conf_mutator / "items.sqlite3").is_file():
            return fail("mutator seed did not complete or establish an item database")
        seed_manifest = build_typed_manifest(mutator_root)
        write_manifest(state_dir / "seed_manifest.txt", seed_manifest)

        initial = execute("subject_initial", subject_command + ["--resync", "--resync-auth"])
        if initial.returncode != 0 or not (conf_subject / "items.sqlite3").is_file():
            return fail("initial tracked observer download did not establish an item database")
        initial_manifest = build_typed_manifest(subject_root)
        write_manifest(state_dir / "subject_initial_manifest.txt", initial_manifest)
        if initial_manifest != seed_manifest:
            return fail("observer did not acquire the complete tracked pre-deletion hierarchy")
        for relative, content in {**deleted_files, **keep_files}.items():
            if not (subject_root / relative).is_file() or (subject_root / relative).read_text(encoding="utf-8") != content:
                return fail(f"initial tracked observer content mismatch: {relative}")

        # Start a live, previously tracked, bidirectional monitor before remote
        # mutation. The helper controls the monitor process exactly as the
        # existing monitor testcases do; no subject upload-only/download-only.
        monitor_stdout = log_dir / "subject_monitor_stdout.log"
        monitor_stderr = log_dir / "subject_monitor_stderr.log"
        context.log(f"Executing Test Case {self.case_id} subject monitor: {command_to_string(monitor_command)}")
        monitor_process, monitor_ready = self._launch_monitor_process(
            context, monitor_command, monitor_stdout, monitor_stderr,
            startup_timeout_seconds=300,
        )
        details["subject_monitor_initial_sync_complete"] = monitor_ready
        details["subject_monitor_command"] = command_to_string(monitor_command)
        if not monitor_ready:
            return fail("subject monitor initial synchronisation did not complete")

        try:
            if not self._wait_for_monitor_stdout_quiet(
                monitor_process, monitor_stdout, quiet_seconds=3, timeout_seconds=40,
            ):
                return fail("subject monitor did not become idle before remote mutation")
            # Record an offset so initial-sync diagnostics cannot impersonate
            # the online full-scan pass after the mutator changed the remote.
            monitor_offset = len(self._read_stdout(monitor_stdout))
            details["monitor_post_mutation_offset"] = monitor_offset

            shutil.rmtree(mutator_root / removed_directories[0])
            (mutator_root / removed_directories[1]).rmdir()
            (mutator_root / f"{root_name}/Singles/removed.txt").unlink()
            deleted = execute("remote_delete", mutator_command)
            if deleted.returncode != 0:
                return fail("independent mutator remote batch deletion failed")

            before = execute("remote_before", [
                context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
                "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                "--confdir", str(conf_before_verify),
            ])
            if before.returncode != 0:
                return fail("fresh independent verifier failed before monitor reconciliation")
            before_manifest = build_typed_manifest(before_verify_root)
            write_manifest(state_dir / "remote_before_manifest.txt", before_manifest)
            if before_manifest != expected_final:
                return fail("remote batch deletion not confirmed before monitor reconciliation")

            # Wait for a real scheduled online true-up, not merely the local
            # database consistency check. Frequency 1 means one scheduled
            # cadence instead of the normal twelve. The bounded developer
            # monitor uses the 90-second interval allowed by config.d.
            deadline = time.monotonic() + 390
            full_scan_seen = False
            while time.monotonic() < deadline:
                post_mutation_output = self._read_stdout_from_offset(monitor_stdout, monitor_offset)
                full_scan_seen = (
                    "Perform a Full Scan True-Up: true" in post_mutation_output
                    and "Performing a full scan of online data to ensure consistent local state" in post_mutation_output
                )
                if full_scan_seen and build_typed_manifest(subject_root) == expected_final:
                    break
                if monitor_process.poll() is not None:
                    return fail("subject monitor exited before completing scheduled online full scan")
                time.sleep(1)
            else:
                details["post_mutation_monitor_log_tail"] = post_mutation_output[-5000:]
                return fail("monitor did not prove a scheduled online full scan and correct deletion convergence")

            details["full_scan_true_up_logged"] = full_scan_seen
            if "Forcing client to use /children API call rather than /delta API" in post_mutation_output:
                return fail("subject unexpectedly entered forced /children developer path")
            if any(marker in post_mutation_output for marker in (
                "Uploading file:", "Successfully created the remote directory",
                "Successfully deleted the item from Microsoft OneDrive",
            )):
                return fail("subject unexpectedly modified remote state during monitor reconciliation")
        finally:
            self._shutdown_monitor_process(monitor_process, details)

        final_manifest = build_typed_manifest(subject_root)
        write_manifest(state_dir / "subject_final_manifest.txt", final_manifest)
        if final_manifest != expected_final:
            return fail("scheduled online full-scan did not remove stale tracked items")

        # A standard standalone delta sync (no resync, no force_children_scan)
        # checks that the retained database and filesystem have converged.
        converged = execute("subject_converge", subject_command)
        if converged.returncode != 0 or build_typed_manifest(subject_root) != expected_final:
            return fail("subject did not converge to stable remote state")
        if any(marker in converged.stdout for marker in (
            "Uploading file:", "Successfully created the remote directory",
            "Successfully deleted the item from Microsoft OneDrive",
        )):
            return fail("unexpected remote mutation during subject convergence")

        after = execute("remote_after", [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
            "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_after_verify),
        ])
        if after.returncode != 0:
            return fail("fresh independent remote verifier failed after reconciliation")
        after_manifest = build_typed_manifest(after_verify_root)
        write_manifest(state_dir / "remote_after_manifest.txt", after_manifest)
        if after_manifest != expected_final:
            return fail("remote paths were recreated or remote survivors changed")
        for root in (subject_root, before_verify_root, after_verify_root):
            for relative, content in keep_files.items():
                file_path = root / relative
                if not file_path.is_file() or file_path.read_text(encoding="utf-8") != content:
                    return fail(f"surviving content mismatch at {root.name}: {relative}")
            if any("safeBackup" in p.name or ".partial" in p.name for p in root.rglob("*")):
                return fail(f"unexpected backup or partial file at {root.name}")

        details["expected_final_manifest"] = expected_final
        details["subject_final_manifest"] = final_manifest
        details["remote_after_manifest"] = after_manifest
        self.write_metadata(metadata_file, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
