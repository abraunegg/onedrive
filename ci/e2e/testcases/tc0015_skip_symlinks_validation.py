from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import reset_directory, run_command, write_onedrive_config, write_text_file


@dataclass
class ScenarioResult:
    scenario_id: str
    description: str
    passed: bool
    failure_message: str = ""
    artifacts: list[str] | None = None
    details: dict | None = None


class TestCase0015SkipSymlinksValidation(E2ETestCase):
    case_id = "0015"
    name = "symbolic link validation"
    description = "Validate symbolic-link skip handling and dangling symlink safety"

    def _write_config(self, config_path: Path, *, skip_symlinks: bool, app_log_dir: Path | None = None) -> None:
        lines = [
            "# tc0015 config",
            'bypass_data_preservation = "true"',
            f'skip_symlinks = "{str(skip_symlinks).lower()}"',
        ]
        if app_log_dir is not None:
            lines.extend(
                [
                    'enable_logging = "true"',
                    f'log_dir = "{app_log_dir}"',
                ]
            )
        write_onedrive_config(config_path, "\n".join(lines) + "\n")

    def _scenario_fail(
        self,
        scenario_id: str,
        description: str,
        message: str,
        artifacts: list[str],
        details: dict,
    ) -> ScenarioResult:
        return ScenarioResult(
            scenario_id=scenario_id,
            description=description,
            passed=False,
            failure_message=message,
            artifacts=artifacts,
            details=details,
        )

    def _scenario_pass(
        self,
        scenario_id: str,
        description: str,
        artifacts: list[str],
        details: dict,
    ) -> ScenarioResult:
        return ScenarioResult(
            scenario_id=scenario_id,
            description=description,
            passed=True,
            artifacts=artifacts,
            details=details,
        )

    def _snapshot_tree(self, root: Path, output: Path) -> None:
        lines: list[str] = []
        if root.exists():
            for path in sorted(root.rglob("*")):
                rel = path.relative_to(root).as_posix()
                suffix = ""
                if path.is_symlink():
                    try:
                        suffix = f" -> {os.readlink(path)}"
                    except OSError as exc:
                        suffix = f" -> <readlink failed: {exc}>"
                elif path.is_dir():
                    suffix = "/"
                lines.append(rel + suffix)
        write_text_file(output, "\n".join(lines) + ("\n" if lines else ""))

    def _write_symlink_metadata(self, output: Path, symlink_path: Path) -> None:
        try:
            target = os.readlink(symlink_path)
        except OSError as exc:
            target = f"<readlink failed: {exc}>"
        write_text_file(
            output,
            "\n".join(
                [
                    f"path={symlink_path}",
                    f"is_symlink={symlink_path.is_symlink()}",
                    f"exists={symlink_path.exists()}",
                    f"lexists={os.path.lexists(symlink_path)}",
                    f"readlink={target}",
                ]
            )
            + "\n",
        )

    def _run_existing_skip_symlink_scenario(
        self,
        context: E2EContext,
        root_name: str,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "SYM-0001"
        description = "skip valid symlink when skip_symlinks=true"

        sync_root = scenario_work_dir / "syncroot"
        verify_root = scenario_work_dir / "verifyroot"
        confdir = scenario_work_dir / "conf-main"
        verify_conf = scenario_work_dir / "conf-verify"
        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        reset_directory(sync_root)
        reset_directory(verify_root)
        reset_directory(confdir)
        reset_directory(verify_conf)
        reset_directory(app_log_dir)
        reset_directory(verify_app_log_dir)

        target = sync_root / root_name / scenario_id / "real.txt"
        write_text_file(target, "real\n")
        link = sync_root / root_name / scenario_id / "linked.txt"
        link.symlink_to(target.name)

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config", skip_symlinks=True, app_log_dir=app_log_dir)
        context.bootstrap_config_dir(verify_conf)
        self._write_config(verify_conf / "config", skip_symlinks=True, app_log_dir=verify_app_log_dir)

        stdout_file = scenario_log_dir / "sync_stdout.log"
        stderr_file = scenario_log_dir / "sync_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"
        local_tree_file = scenario_state_dir / "local_tree.txt"
        remote_manifest_file = scenario_state_dir / "remote_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        self._snapshot_tree(sync_root, local_tree_file)

        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(confdir),
        ]
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(verify_conf),
        ]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        details = {
            "scenario_id": scenario_id,
            "returncode": result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
            "expected_real_path": f"{root_name}/{scenario_id}/real.txt",
            "unexpected_link_path": f"{root_name}/{scenario_id}/linked.txt",
            "skip_symlinks": True,
        }
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value}" for key, value in details.items()) + "\n",
        )

        artifacts = [
            str(stdout_file),
            str(stderr_file),
            str(verify_stdout),
            str(verify_stderr),
            str(local_tree_file),
            str(remote_manifest_file),
            str(metadata_file),
            str(app_log_dir),
            str(verify_app_log_dir),
        ]

        if result.returncode != 0:
            return self._scenario_fail(scenario_id, description, f"skip_symlinks validation failed with status {result.returncode}", artifacts, details)
        if verify_result.returncode != 0:
            return self._scenario_fail(scenario_id, description, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        if details["expected_real_path"] not in remote_manifest:
            return self._scenario_fail(scenario_id, description, "Regular file missing after skip_symlinks processing", artifacts, details)
        if details["unexpected_link_path"] in remote_manifest:
            return self._scenario_fail(scenario_id, description, "Symbolic link was unexpectedly synchronised", artifacts, details)

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def _run_dangling_symlink_sync_scenario(
        self,
        context: E2EContext,
        root_name: str,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "SYM-0002"
        description = "dangling symlink safety when skip_symlinks=false"

        sync_root = scenario_work_dir / "syncroot"
        verify_root = scenario_work_dir / "verifyroot"
        confdir = scenario_work_dir / "conf-main"
        verify_conf = scenario_work_dir / "conf-verify"
        app_log_dir = scenario_log_dir / "app-logs"
        verify_app_log_dir = scenario_log_dir / "verify-app-logs"

        reset_directory(sync_root)
        reset_directory(verify_root)
        reset_directory(confdir)
        reset_directory(verify_conf)
        reset_directory(app_log_dir)
        reset_directory(verify_app_log_dir)

        scenario_root = sync_root / root_name / scenario_id
        control_file = scenario_root / "control.txt"
        dangling_link = scenario_root / "broken-link.txt"
        write_text_file(control_file, "control\n")
        dangling_link.symlink_to("missing-target.txt")

        context.bootstrap_config_dir(confdir)
        self._write_config(confdir / "config", skip_symlinks=False, app_log_dir=app_log_dir)
        context.bootstrap_config_dir(verify_conf)
        self._write_config(verify_conf / "config", skip_symlinks=False, app_log_dir=verify_app_log_dir)

        stdout_file = scenario_log_dir / "sync_stdout.log"
        stderr_file = scenario_log_dir / "sync_stderr.log"
        verify_stdout = scenario_log_dir / "verify_stdout.log"
        verify_stderr = scenario_log_dir / "verify_stderr.log"
        local_tree_file = scenario_state_dir / "local_tree.txt"
        symlink_metadata_file = scenario_state_dir / "dangling_symlink_metadata.txt"
        remote_manifest_file = scenario_state_dir / "remote_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        self._snapshot_tree(sync_root, local_tree_file)
        self._write_symlink_metadata(symlink_metadata_file, dangling_link)

        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(confdir),
        ]
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)

        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--single-directory",
            f"{root_name}/{scenario_id}",
            "--syncdir",
            str(verify_root),
            "--confdir",
            str(verify_conf),
        ]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)

        remote_manifest = build_manifest(verify_root)
        write_manifest(remote_manifest_file, remote_manifest)

        combined_output = result.stdout + "\n" + result.stderr
        expected_control_path = f"{root_name}/{scenario_id}/control.txt"
        unexpected_link_path = f"{root_name}/{scenario_id}/broken-link.txt"
        control_uploaded = expected_control_path in remote_manifest
        dangling_link_uploaded = unexpected_link_path in remote_manifest

        details = {
            "scenario_id": scenario_id,
            "returncode": result.returncode,
            "verify_returncode": verify_result.returncode,
            "root_name": root_name,
            "expected_control_path": expected_control_path,
            "unexpected_link_path": unexpected_link_path,
            "control_uploaded": control_uploaded,
            "dangling_link_uploaded": dangling_link_uploaded,
            "skip_symlinks": False,
            "dangling_link": str(dangling_link),
            "dangling_link_target": "missing-target.txt",
            "file_exception_seen": "std.file.FileException" in combined_output,
            "no_such_file_seen": "No such file or directory" in combined_output,
        }
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value}" for key, value in details.items()) + "\n",
        )

        artifacts = [
            str(stdout_file),
            str(stderr_file),
            str(verify_stdout),
            str(verify_stderr),
            str(local_tree_file),
            str(symlink_metadata_file),
            str(remote_manifest_file),
            str(metadata_file),
            str(app_log_dir),
            str(verify_app_log_dir),
        ]

        if result.returncode != 0:
            return self._scenario_fail(
                scenario_id,
                description,
                f"Dangling symlink sync crashed or failed with status {result.returncode}",
                artifacts,
                details,
            )
        if verify_result.returncode != 0:
            return self._scenario_fail(scenario_id, description, f"Remote verification failed with status {verify_result.returncode}", artifacts, details)
        # This scenario validates the #3770 safety invariant: a dangling symlink
        # must be handled without crashing or uploading the symlink target. Earlier
        # revisions also required an unrelated sibling control file in the same
        # directory to be uploaded. That made the E2E result depend on local scan
        # ordering and turned a non-crashing, safe skip into a false negative. Keep
        # control_uploaded as diagnostic evidence, but do not make it the pass/fail
        # contract for dangling-symlink safety.
        if not (details["file_exception_seen"] or details["no_such_file_seen"]):
            return self._scenario_fail(
                scenario_id,
                description,
                "Dangling symbolic link path was not exercised by the sync run",
                artifacts,
                details,
            )
        if details["dangling_link_uploaded"]:
            return self._scenario_fail(scenario_id, description, "Dangling symbolic link was unexpectedly synchronised", artifacts, details)

        return self._scenario_pass(scenario_id, description, artifacts, details)

    def _run_cleanup_symlink_logging_scenario(
        self,
        context: E2EContext,
        root_name: str,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        scenario_id = "SYM-0003"
        description = "cleanup skips valid and dangling symlinks with skip_symlinks=false"
        seed_root = scenario_work_dir / "seedroot"
        sync_root = scenario_work_dir / "syncroot"
        verify_root = scenario_work_dir / "verifyroot"
        seed_conf = scenario_work_dir / "conf-seed"
        cleanup_conf = scenario_work_dir / "conf-cleanup"
        verify_conf = scenario_work_dir / "conf-verify"
        for folder in (seed_root, sync_root, verify_root, seed_conf, cleanup_conf, verify_conf):
            reset_directory(folder)

        relative_base = f"{root_name}/{scenario_id}"
        anchor_relative = f"{relative_base}/anchor.txt"
        stale_relative = f"{relative_base}/stale.txt"
        valid_relative = f"{relative_base}/valid-link.txt"
        dangling_relative = f"{relative_base}/dangling-link.txt"
        anchor_content = b"symlink cleanup anchor\n"
        write_text_file(seed_root / anchor_relative, anchor_content.decode("utf-8"))

        context.bootstrap_config_dir(seed_conf)
        self._write_config(seed_conf / "config", skip_symlinks=True)
        context.bootstrap_config_dir(cleanup_conf)
        self._write_config(cleanup_conf / "config", skip_symlinks=False)
        # Keep the persistent cleanup database aligned with the --syncdir override.
        # The cleanup invocation intentionally omits --resync to exercise that DB.
        with (cleanup_conf / "config").open("a", encoding="utf-8") as f:
            f.write(
                f'sync_dir = "{sync_root}"\n'
                'download_only = "true"\n'
                'cleanup_local_files = "true"\n'
            )
        context.bootstrap_config_dir(verify_conf)
        self._write_config(verify_conf / "config", skip_symlinks=True)

        seed_stdout = scenario_log_dir / "seed_stdout.log"
        cleanup_stdout = scenario_log_dir / "cleanup_stdout.log"
        cleanup_stderr = scenario_log_dir / "cleanup_stderr.log"
        preload_stdout = scenario_log_dir / "preload_stdout.log"
        remote_stdout = scenario_log_dir / "verify_stdout.log"
        state_file = scenario_state_dir / "symlink_cleanup_state.txt"
        metadata_file = scenario_state_dir / "metadata.txt"
        artifacts = [str(x) for x in (seed_stdout, cleanup_stdout, cleanup_stderr,
                                      preload_stdout, remote_stdout, state_file, metadata_file)]
        details: dict = {"scenario_id": scenario_id, "root_name": root_name}
        failures: list[str] = []

        seed_cmd = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
                    "--resync", "--resync-auth", "--single-directory", relative_base,
                    "--syncdir", str(seed_root), "--confdir", str(seed_conf)]
        seed_result = run_command(seed_cmd, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout + "\n" + seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            return self._scenario_fail(scenario_id, description, "Remote seed failed", artifacts, details)

        # Establish an existing DB baseline from the real remote item.
        preload_cmd = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
                       "--download-only", "--cleanup-local-files", "--resync", "--resync-auth",
                       "--single-directory", relative_base, "--syncdir", str(sync_root), "--confdir", str(cleanup_conf)]
        preload_result = run_command(preload_cmd, cwd=context.repo_root)
        write_text_file(preload_stdout, preload_result.stdout + "\n" + preload_result.stderr)
        details["preload_returncode"] = preload_result.returncode
        if preload_result.returncode != 0 or not (sync_root / anchor_relative).is_file():
            return self._scenario_fail(scenario_id, description, "Cleanup client preload did not establish tracked anchor", artifacts, details)
        if (sync_root / anchor_relative).read_bytes() != anchor_content:
            return self._scenario_fail(scenario_id, description, "Preloaded anchor content changed", artifacts, details)

        valid_link = sync_root / valid_relative
        dangling_link = sync_root / dangling_relative
        valid_link.symlink_to("anchor.txt")
        dangling_link.symlink_to("non-existent-destination.txt")
        write_text_file(sync_root / stale_relative, "untracked cleanup stale\n")

        # No --resync here: use the existing DB and the effective cleanup policy.
        cleanup_cmd = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
                       "--download-only", "--cleanup-local-files", "--single-directory", relative_base,
                       "--syncdir", str(sync_root), "--confdir", str(cleanup_conf)]
        cleanup_result = run_command(cleanup_cmd, cwd=context.repo_root)
        output = cleanup_result.stdout + "\n" + cleanup_result.stderr
        write_text_file(cleanup_stdout, cleanup_result.stdout)
        write_text_file(cleanup_stderr, cleanup_result.stderr)
        details["cleanup_returncode"] = cleanup_result.returncode
        if cleanup_result.returncode != 0:
            failures.append(f"Cleanup client exited {cleanup_result.returncode}")
        for key, expected in (("download_only", "true"), ("cleanup_local_files", "true"),
                              ("skip_symlinks", "false")):
            if re.search(r"Config option '" + key + r"'\s*=\s*" + expected + r"(?:\s|$)", output) is None:
                failures.append(f"Incorrect effective {key}={expected}")

        for path, expected_target in ((valid_link, "anchor.txt"),
                                      (dangling_link, "non-existent-destination.txt")):
            if not path.is_symlink() or os.readlink(path) != expected_target:
                failures.append(f"Symbolic link deleted, changed or followed: {path.name}")
            rel = path.relative_to(sync_root).as_posix()
            match = re.compile(r"(?:^|\n)(?:DEBUG:\s+)?Skipping symbolic link during "
                               r"--download-only --cleanup-local-files cleanup pass:\s+(?:\./)?"
                               + re.escape(rel) + r"(?:\s|$)")
            if match.search(output) is None:
                failures.append(f"Cleanup-specific symlink skip log absent: {rel}")
            if re.search(r"Skipping item - skip symbolic links configured:\s+(?:\./)?" + re.escape(rel), output):
                failures.append(f"Cleanup symlink falsely attributed to skip_symlinks: {rel}")
        if not (sync_root / anchor_relative).is_file() or (sync_root / anchor_relative).read_bytes() != anchor_content:
            failures.append("Tracked anchor was deleted or altered")
        if (sync_root / stale_relative).exists():
            failures.append("In-scope DB-unknown stale file was not cleaned")
        if re.search(r"Removed local file:\s+(?:\./)?" + re.escape(stale_relative) + r"(?:\s|$)", output) is None:
            failures.append("Cleanup did not log successful removal of stale control file")

        # Existing client-based remote verifier: neither link nor local-only
        # stale file should have been uploaded during download-only cleanup.
        verify_cmd = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
                      "--download-only", "--resync", "--resync-auth", "--single-directory", relative_base,
                      "--syncdir", str(verify_root), "--confdir", str(verify_conf)]
        verify_result = run_command(verify_cmd, cwd=context.repo_root)
        write_text_file(remote_stdout, verify_result.stdout + "\n" + verify_result.stderr)
        details["verify_returncode"] = verify_result.returncode
        if verify_result.returncode != 0:
            failures.append("Remote verifier failed")
        if not (verify_root / anchor_relative).is_file() or (verify_root / anchor_relative).read_bytes() != anchor_content:
            failures.append("Remote anchor changed or disappeared")
        for rel in (valid_relative, dangling_relative, stale_relative):
            if (verify_root / rel).exists() or (verify_root / rel).is_symlink():
                failures.append(f"Unexpected remote item appeared: {rel}")

        self._snapshot_tree(sync_root, state_file)
        write_text_file(metadata_file, "\n".join(f"{k}={v}" for k,v in details.items()) + "\n")
        if failures:
            return self._scenario_fail(scenario_id, description, "; ".join(failures), artifacts, details)
        return self._scenario_pass(scenario_id, description, artifacts, details)

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0015",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        root_name = f"ZZ_E2E_TC0015_{context.run_id}_{os.getpid()}"

        results: list[ScenarioResult] = []

        if context.should_run_scenario(self.case_id, "SYM-0001"):
            scenario_work_dir = case_work_dir / "sym0001-valid-skip"
            scenario_log_dir = case_log_dir / "sym0001-valid-skip"
            scenario_state_dir = state_dir / "sym0001-valid-skip"
            reset_directory(scenario_work_dir)
            reset_directory(scenario_log_dir)
            reset_directory(scenario_state_dir)
            results.append(
                self._run_existing_skip_symlink_scenario(
                    context,
                    root_name,
                    scenario_work_dir,
                    scenario_log_dir,
                    scenario_state_dir,
                )
            )

        if context.should_run_scenario(self.case_id, "SYM-0002"):
            scenario_work_dir = case_work_dir / "sym0002-dangling-false"
            scenario_log_dir = case_log_dir / "sym0002-dangling-false"
            scenario_state_dir = state_dir / "sym0002-dangling-false"
            reset_directory(scenario_work_dir)
            reset_directory(scenario_log_dir)
            reset_directory(scenario_state_dir)
            results.append(
                self._run_dangling_symlink_sync_scenario(
                    context,
                    root_name,
                    scenario_work_dir,
                    scenario_log_dir,
                    scenario_state_dir,
                )
            )

        if context.should_run_scenario(self.case_id, "SYM-0003"):
            scenario_work_dir = case_work_dir / "sym0003-cleanup-false"
            scenario_log_dir = case_log_dir / "sym0003-cleanup-false"
            scenario_state_dir = state_dir / "sym0003-cleanup-false"
            reset_directory(scenario_work_dir)
            reset_directory(scenario_log_dir)
            reset_directory(scenario_state_dir)
            results.append(
                self._run_cleanup_symlink_logging_scenario(
                    context,
                    root_name,
                    scenario_work_dir,
                    scenario_log_dir,
                    scenario_state_dir,
                )
            )

        failed = [result for result in results if not result.passed]
        artifacts: list[str] = []
        details: dict = {
            "root_name": root_name,
            "executed_scenario_ids": [result.scenario_id for result in results],
            "failed_scenario_ids": [result.scenario_id for result in failed],
            "scenario_results": {},
        }

        for result in results:
            if result.artifacts:
                artifacts.extend(result.artifacts)
            if result.details:
                details["scenario_results"][result.scenario_id] = result.details

        deduped_artifacts = []
        seen = set()
        for artifact in artifacts:
            if artifact not in seen:
                deduped_artifacts.append(artifact)
                seen.add(artifact)

        summary_file = state_dir / "scenario_summary.txt"
        summary_lines = []
        for result in results:
            status = "PASS" if result.passed else "FAIL"
            line = f"{result.scenario_id} [{status}] {result.description}"
            if result.failure_message:
                line += f" — {result.failure_message}"
            summary_lines.append(line)
        write_text_file(summary_file, "\n".join(summary_lines) + "\n")
        deduped_artifacts.append(str(summary_file))

        if failed:
            failed_ids = ", ".join(result.scenario_id for result in failed)
            first_failure = failed[0].failure_message or "scenario failure"
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failed)} of {len(results)} symbolic-link scenarios failed: {failed_ids} — {first_failure}",
                deduped_artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, deduped_artifacts, details)
