from __future__ import annotations

import hashlib
import os
import shutil
import time
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.manifest import build_typed_manifest, write_manifest
from framework.utils import command_to_string, write_text_file, run_command_logged
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0089GitRsyncMonitorUploadIdentity(MonitorModeTestCaseBase):
    """Issue #3930: a loose Git tag named v1.0.0 must not become _api/v2.0.0."""

    case_id = "0089"
    name = "monitor Git repository rsync upload identity"
    description = (
        "Run monitor while Git/rsync mirrors a real repository into the sync tree; "
        "accept either validated upload or safe rejection of a Graph-misrouted DriveItem"
    )

    @staticmethod
    def _file_hashes(root: Path) -> dict[str, str]:
        result: dict[str, str] = {}
        if root.exists():
            for path in sorted(root.rglob("*")):
                if path.is_file() and not path.is_symlink():
                    result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        return result

    @staticmethod
    def _git_rsync_fixture(source_repo: Path, mirror_repo: Path, log_dir: Path, context: E2EContext) -> None:
        """Create and mirror a real Git repository using the existing command runner."""
        for binary in ("git", "rsync"):
            if shutil.which(binary) is None:
                raise RuntimeError(f"Required E2E dependency not found: {binary}")
        source_repo.mkdir(parents=True, exist_ok=True)
        commands = [
            (["git", "init", "--initial-branch=main", str(source_repo)], None),
        ]
        (source_repo / "README.md").write_text("TC0089 Git backup fixture\n", encoding="utf-8")
        (source_repo / "example.txt").write_text("E2E git test content\n", encoding="utf-8")
        commands += [
            (["git", "add", "README.md", "example.txt"], source_repo),
            (["git", "-c", "user.name=E2E Harness", "-c", "user.email=e2e@example.invalid",
              "commit", "-m", "TC0089 initial fixture"], source_repo),
        ]
        commands += [(["git", "tag", name], source_repo)
                     for name in ("v0.4.1", "v1.0.0", "v1.0.1", "v2.0.0")]
        commands += [(["rsync", "-a", "--delete", str(source_repo) + "/", str(mirror_repo) + "/"], None)]
        for index, (command, cwd) in enumerate(commands, 1):
            context.log("TC0089: " + command_to_string(command))
            result = run_command_logged(command, log_dir / f"fixture_{index:02d}.stdout.log",
                                        log_dir / f"fixture_{index:02d}.stderr.log", cwd=cwd)
            if result.returncode != 0:
                raise RuntimeError(f"Fixture command failed ({result.returncode}): {command_to_string(command)}")
        for tag in ("v0.4.1", "v1.0.0", "v1.0.1", "v2.0.0"):
            if not (source_repo / ".git" / "refs" / "tags" / tag).is_file():
                raise RuntimeError(f"Expected loose tag missing: {tag}")

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0089", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir
        source_root = work / "source"
        sync_root = work / "syncroot"
        verify_root = work / "verifyroot"
        conf_main = work / "conf-main"
        conf_verify = work / "conf-verify"
        app_log_dir = logs / "app-logs"
        root_name = f"ZZ_E2E_TC0089_{context.run_id}_{os.getpid()}"
        relative_repo = Path(root_name) / "Projects-backup" / "test-git-repository"
        source_repo = source_root / "test-git-repository"
        mirror_repo = sync_root / relative_repo
        verify_repo = verify_root / relative_repo

        monitor_stdout, monitor_stderr = logs / "monitor_stdout.log", logs / "monitor_stderr.log"
        fixture_logs = logs / "fixture"
        fixture_logs.mkdir(parents=True, exist_ok=True)
        verify_stdout, verify_stderr = logs / "verify_stdout.log", logs / "verify_stderr.log"
        source_manifest_file, verify_manifest_file = state / "source_manifest.txt", state / "verify_manifest.txt"
        metadata_file = state / "metadata.txt"
        artifacts = [str(x) for x in (monitor_stdout, monitor_stderr, fixture_logs,
                                     verify_stdout, verify_stderr, source_manifest_file, verify_manifest_file,
                                     metadata_file, app_log_dir)]
        details: dict[str, object] = {"root_name": root_name, "issue": "3930", "relative_repo": relative_repo.as_posix()}

        # Establish existing parent directories BEFORE monitor starts, ensuring inotify
        # watches the target directory and no full-scan fallback is needed.
        mirror_repo.mkdir(parents=True, exist_ok=True)
        write_text_file(mirror_repo / "baseline.txt", "TC0089 monitor initial anchor\n")
        context.prepare_minimal_config_dir(conf_main, self._build_config_text(sync_root, app_log_dir))
        context.prepare_minimal_config_dir(
            conf_verify,
            f'# tc0089 independent remote verification\nsync_dir = "{verify_root}"\nbypass_data_preservation = "true"\n',
        )
        command = [context.onedrive_bin, "--display-running-config", "--monitor", "--verbose",
                   "--resync", "--resync-auth", "--single-directory", root_name,
                   "--syncdir", str(sync_root), "--confdir", str(conf_main)]
        context.log(f"TC0089 monitor: {command_to_string(command)}")
        process, started = self._launch_monitor_process(context, command, monitor_stdout, monitor_stderr)
        try:
            details["initial_sync_complete"] = started
            if not started:
                return self.fail_result(reason="Monitor initial sync did not complete", artifacts=artifacts, details=details)
            offset = self._prepare_monitor_for_local_mutation(process, monitor_stdout, details)
            if not details["monitor_ready_after_initial_sync"]:
                return self.fail_result(reason="Monitor not quiet/ready for filesystem mutation", artifacts=artifacts, details=details)

            # The harness manages the monitor process; invoke Git and rsync directly
            # from this test case, as other monitor-mode cases do for local mutations.
            try:
                self._git_rsync_fixture(source_repo, mirror_repo, fixture_logs, context)
            except RuntimeError as error:
                return self.fail_result(reason=str(error), artifacts=artifacts, details=details)

            tag_relative = (relative_repo / ".git/refs/tags/v1.0.0").as_posix()
            control_relative = (relative_repo / ".git/refs/tags/v0.4.1").as_posix()
            details["tag_file_exists"] = (mirror_repo / ".git/refs/tags/v1.0.0").is_file()
            if not details["tag_file_exists"]:
                return self.fail_result(reason="Mutator did not create a loose v1.0.0 tag", artifacts=artifacts, details=details)
            # Two permitted outcomes: the API creates the requested object, or
            # our destination validator rejects the returned wrong DriveItem.
            # The control upload must always work.
            control_done = f"Uploading new file: {control_relative} ... done"
            rejection = f"Uploading new file: {tag_relative} ... failed (Graph destination mismatch)!"
            tag_done = f"Uploading new file: {tag_relative} ... done"
            deadline_patterns = [[control_done, rejection], [control_done, tag_done]]
            outcome = -1
            segment = ""
            # Poll only the new monitor output; don't wait for BOTH success logs.
            deadline = time.monotonic() + 240
            while time.monotonic() < deadline:
                segment = self._read_monitor_output_from_offsets(monitor_stdout, offset)
                outcome = self._find_monitor_pattern_group(segment, deadline_patterns)
                if outcome >= 0 or process.poll() is not None:
                    break
                time.sleep(1)
            details["upload_outcome"] = "rejected" if outcome == 0 else ("accepted" if outcome == 1 else "unobserved")
            details["foreign_key_failure"] = "FOREIGN KEY constraint failed" in segment
            details["identity_error"] = "Graph destination mismatch" in segment or "Graph API upload destination mismatch" in segment
            details["monitor_alive_after_mutation"] = process.poll() is None
            details["local_tag_preserved"] = (mirror_repo / ".git/refs/tags/v1.0.0").is_file()
            if not details["local_tag_preserved"]:
                return self.fail_result(reason="Local v1.0.0 tag was removed", artifacts=artifacts, details=details)
            if details["foreign_key_failure"]:
                return self.fail_result(reason="Unexpected SQLite foreign key error", artifacts=artifacts, details=details)
            if outcome == -1:
                return self.fail_result(reason="No complete upload/rejection outcome observed", artifacts=artifacts, details=details)
            if outcome == 0 and not details["identity_error"]:
                return self.fail_result(reason="Rejected upload lacked destination diagnostic", artifacts=artifacts, details=details)
        finally:
            self._shutdown_monitor_process(process, details)
            self._write_metadata(metadata_file, details)

        source_manifest = build_typed_manifest(source_repo)
        write_manifest(source_manifest_file, source_manifest)
        source_hashes = self._file_hashes(source_repo)
        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
                          "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                          "--syncdir", str(verify_root), "--confdir", str(conf_verify)]
        context.log(f"TC0089 remote verification: {command_to_string(verify_command)}")
        verification = self._run_verify_command(context, verify_command, verify_stdout, verify_stderr)
        actual_manifest = build_typed_manifest(verify_repo)
        write_manifest(verify_manifest_file, actual_manifest)
        actual_hashes = self._file_hashes(verify_repo)
        details.update({"verify_returncode": verification.returncode,
                        "source_count": len(source_manifest), "remote_count": len(actual_manifest),
                        "missing_remote_entries": sorted(set(source_manifest) - set(actual_manifest)),
                        "unexpected_remote_entries": sorted(set(actual_manifest) - set(source_manifest)),
                        "hash_mismatches": sorted(k for k in set(source_hashes) | set(actual_hashes)
                                                  if source_hashes.get(k) != actual_hashes.get(k)),
                        "unexpected_api_path": (verify_repo / ".git/refs/tags/_api/v2.0.0").exists(),
                        "v1_tag_verified": (verify_repo / ".git/refs/tags/v1.0.0").is_file()})
        self._write_metadata(metadata_file, details)
        if verification.returncode != 0:
            return self.fail_result(reason=f"Independent remote verification exited {verification.returncode}", artifacts=artifacts, details=details)
        # Verify control is present and byte-exact in BOTH permitted outcomes.
        if actual_hashes.get(".git/refs/tags/v0.4.1") != source_hashes.get(".git/refs/tags/v0.4.1"):
            return self.fail_result(reason="Control loose Git tag missing or corrupted", artifacts=artifacts, details=details)
        if details["upload_outcome"] == "rejected":
            if details["v1_tag_verified"]:
                return self.fail_result(reason="Validator rejected upload but requested object exists remotely", artifacts=artifacts, details=details)
            details["pass_variant"] = "Graph misroute detected and rejected without SQLite failure"
            return self.pass_result(artifacts=artifacts, details=details)
        if details["identity_error"]:
            return self.fail_result(reason="Upload was reported successful despite an identity mismatch", artifacts=artifacts, details=details)
        # Accepted means a complete independently verified remote tree, not
        # merely an HTTP 201 or the local client's success message.
        if details["unexpected_api_path"] or not details["v1_tag_verified"]:
            return self.fail_result(reason="Accepted upload has wrong remote identity", artifacts=artifacts, details=details)
        if details["missing_remote_entries"] or details["unexpected_remote_entries"] or details["hash_mismatches"]:
            return self.fail_result(reason="Git repository remote manifest or content differs from source", artifacts=artifacts, details=details)
        details["pass_variant"] = "Graph created the expected remote Git tree"
        return self.pass_result(artifacts=artifacts, details=details)
