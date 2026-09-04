from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0012SkipDirValidation(E2ETestCase):
    case_id = "0012"
    name = "skip_dir validation"
    description = (
        "Validate skip_dir loose matching, skip_dir_strict_match behaviour, "
        "and sync-root anchored full-path matching"
    )

    def _write_config(self, config_path: Path, skip_dir_value: str, strict: bool) -> None:
        lines = [
            "# tc0012 config",
            'bypass_data_preservation = "true"',
            f'skip_dir = "{skip_dir_value}"',
            f'skip_dir_strict_match = "{"true" if strict else "false"}"',
        ]
        write_onedrive_config(config_path, "\n".join(lines) + "\n")

    def _run_loose(self, context: E2EContext, case_log_dir: Path, all_artifacts: list[str], failures: list[str]) -> None:
        scenario_root = context.work_root / "tc0012" / "loose_match"; scenario_state = context.state_dir / "tc0012" / "loose_match"
        reset_directory(scenario_root); reset_directory(scenario_state)
        sync_root = scenario_root / "syncroot"; confdir = scenario_root / "conf-loose"; verify_root = scenario_root / "verifyroot"; verify_conf = scenario_root / "conf-verify-loose"
        root = f"ZZ_E2E_TC0012_LOOSE_{context.run_id}_{os.getpid()}"
        write_text_file(sync_root / root / "Cache" / "top.txt", "skip top\n")
        write_text_file(sync_root / root / "App" / "Cache" / "nested.txt", "skip nested\n")
        write_text_file(sync_root / root / "Keep" / "ok.txt", "ok\n")
        context.bootstrap_config_dir(confdir); self._write_config(confdir / "config", "Cache", False)
        context.bootstrap_config_dir(verify_conf); write_onedrive_config(verify_conf / "config", "# verify\nbypass_data_preservation = \"true\"\n")
        stdout_file = case_log_dir / "loose_match_stdout.log"; stderr_file = case_log_dir / "loose_match_stderr.log"; verify_stdout = case_log_dir / "loose_match_verify_stdout.log"; verify_stderr = case_log_dir / "loose_match_verify_stderr.log"; manifest_file = scenario_state / "remote_verify_manifest.txt"
        result = run_command([context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(confdir)], cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout); write_text_file(stderr_file, result.stderr)
        verify_result = run_command([context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--syncdir", str(verify_root), "--confdir", str(verify_conf)], cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout); write_text_file(verify_stderr, verify_result.stderr); manifest = build_manifest(verify_root); write_manifest(manifest_file, manifest)
        all_artifacts.extend([str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(manifest_file)])
        if result.returncode != 0: failures.append(f"Loose skip_dir scenario failed with status {result.returncode}"); return
        if verify_result.returncode != 0: failures.append(f"Loose skip_dir verification failed with status {verify_result.returncode}"); return
        if f"{root}/Keep/ok.txt" not in manifest: failures.append("Loose skip_dir scenario did not synchronise expected non-skipped content")
        for unwanted in [f"{root}/Cache/top.txt", f"{root}/App/Cache/nested.txt"]:
            if unwanted in manifest: failures.append(f"Loose skip_dir scenario unexpectedly synchronised skipped directory content: {unwanted}")

    def _run_strict(self, context: E2EContext, case_log_dir: Path, all_artifacts: list[str], failures: list[str]) -> None:
        scenario_root = context.work_root / "tc0012" / "strict_match"; scenario_state = context.state_dir / "tc0012" / "strict_match"
        reset_directory(scenario_root); reset_directory(scenario_state)
        sync_root = scenario_root / "syncroot"; confdir = scenario_root / "conf-strict"; verify_root = scenario_root / "verifyroot"; verify_conf = scenario_root / "conf-verify-strict"
        root = f"ZZ_E2E_TC0012_STRICT_{context.run_id}_{os.getpid()}"
        write_text_file(sync_root / root / "Cache" / "top.txt", "top should remain\n")
        write_text_file(sync_root / root / "App" / "Cache" / "nested.txt", "nested should skip\n")
        write_text_file(sync_root / root / "Keep" / "ok.txt", "ok\n")
        context.bootstrap_config_dir(confdir); self._write_config(confdir / "config", f"{root}/App/Cache", True)
        context.bootstrap_config_dir(verify_conf); write_onedrive_config(verify_conf / "config", "# verify\nbypass_data_preservation = \"true\"\n")
        stdout_file = case_log_dir / "strict_match_stdout.log"; stderr_file = case_log_dir / "strict_match_stderr.log"; verify_stdout = case_log_dir / "strict_match_verify_stdout.log"; verify_stderr = case_log_dir / "strict_match_verify_stderr.log"; manifest_file = scenario_state / "remote_verify_manifest.txt"
        result = run_command([context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--resync", "--resync-auth", "--syncdir", str(sync_root), "--confdir", str(confdir)], cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout); write_text_file(stderr_file, result.stderr)
        verify_result = run_command([context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--download-only", "--resync", "--resync-auth", "--syncdir", str(verify_root), "--confdir", str(verify_conf)], cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout); write_text_file(verify_stderr, verify_result.stderr); manifest = build_manifest(verify_root); write_manifest(manifest_file, manifest)
        all_artifacts.extend([str(stdout_file), str(stderr_file), str(verify_stdout), str(verify_stderr), str(manifest_file)])
        if result.returncode != 0: failures.append(f"Strict skip_dir scenario failed with status {result.returncode}"); return
        if verify_result.returncode != 0: failures.append(f"Strict skip_dir verification failed with status {verify_result.returncode}"); return
        if f"{root}/Keep/ok.txt" not in manifest: failures.append("Strict skip_dir scenario did not synchronise expected non-skipped content")
        if f"{root}/Cache/top.txt" not in manifest: failures.append("Strict skip_dir scenario incorrectly skipped top-level Cache directory")
        if f"{root}/App/Cache/nested.txt" in manifest: failures.append("Strict skip_dir scenario unexpectedly synchronised strict-matched directory content")

    def _run_sync_root_anchored(
        self,
        context: E2EContext,
        case_log_dir: Path,
        all_artifacts: list[str],
        failures: list[str],
    ) -> None:
        scenario_root = context.work_root / "tc0012" / "sync_root_anchored"
        scenario_state = context.state_dir / "tc0012" / "sync_root_anchored"
        reset_directory(scenario_root)
        reset_directory(scenario_state)

        seed_root = scenario_root / "seed-syncroot"
        seed_conf = scenario_root / "conf-seed"
        loose_root = scenario_root / "loose-syncroot"
        loose_conf = scenario_root / "conf-anchored-loose"
        strict_root = scenario_root / "strict-syncroot"
        strict_conf = scenario_root / "conf-anchored-strict"

        unique_suffix = f"{context.run_id}_{os.getpid()}"
        anchored_name = f"ZZ_E2E_TC0012_ANCHORED_{unique_suffix}"
        container_name = f"ZZ_E2E_TC0012_CONTAINER_{unique_suffix}"

        root_skipped_file = f"{anchored_name}/root-only.txt"
        nested_required_file = f"{container_name}/{anchored_name}/nested-must-sync.txt"
        control_required_file = f"{container_name}/keep.txt"

        # Seed the online state through an unfiltered client so the filtered
        # clients below must evaluate these directories from remote /delta data.
        write_text_file(seed_root / root_skipped_file, "root anchored directory must be skipped\n")
        write_text_file(seed_root / nested_required_file, "same-named nested directory must remain in scope\n")
        write_text_file(seed_root / control_required_file, "unrelated control file\n")

        context.bootstrap_config_dir(seed_conf)
        write_onedrive_config(
            seed_conf / "config",
            '# tc0012 anchored remote seed\nbypass_data_preservation = "true"\n',
        )
        context.bootstrap_config_dir(loose_conf)
        self._write_config(loose_conf / "config", f"/{anchored_name}", False)
        context.bootstrap_config_dir(strict_conf)
        self._write_config(strict_conf / "config", f"/{anchored_name}", True)

        seed_stdout = case_log_dir / "sync_root_anchored_seed_stdout.log"
        seed_stderr = case_log_dir / "sync_root_anchored_seed_stderr.log"
        loose_stdout = case_log_dir / "sync_root_anchored_loose_stdout.log"
        loose_stderr = case_log_dir / "sync_root_anchored_loose_stderr.log"
        strict_stdout = case_log_dir / "sync_root_anchored_strict_stdout.log"
        strict_stderr = case_log_dir / "sync_root_anchored_strict_stderr.log"
        loose_manifest_file = scenario_state / "loose_local_manifest.txt"
        strict_manifest_file = scenario_state / "strict_local_manifest.txt"

        all_artifacts.extend(
            [
                str(seed_stdout),
                str(seed_stderr),
                str(loose_stdout),
                str(loose_stderr),
                str(strict_stdout),
                str(strict_stderr),
                str(loose_manifest_file),
                str(strict_manifest_file),
            ]
        )

        seed_result = run_command(
            [
                context.onedrive_bin,
                "--display-running-config",
                "--sync",
                "--verbose",
                "--resync",
                "--resync-auth",
                "--syncdir",
                str(seed_root),
                "--confdir",
                str(seed_conf),
            ],
            cwd=context.repo_root,
        )
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        if seed_result.returncode != 0:
            failures.append(f"Sync-root anchored seed scenario failed with status {seed_result.returncode}")
            return

        scenarios = [
            ("strict=false", loose_root, loose_conf, loose_stdout, loose_stderr, loose_manifest_file),
            ("strict=true", strict_root, strict_conf, strict_stdout, strict_stderr, strict_manifest_file),
        ]

        for label, sync_root, confdir, stdout_file, stderr_file, manifest_file in scenarios:
            result = run_command(
                [
                    context.onedrive_bin,
                    "--display-running-config",
                    "--sync",
                    "--verbose",
                    "--download-only",
                    "--resync",
                    "--resync-auth",
                    "--syncdir",
                    str(sync_root),
                    "--confdir",
                    str(confdir),
                ],
                cwd=context.repo_root,
            )
            write_text_file(stdout_file, result.stdout)
            write_text_file(stderr_file, result.stderr)

            manifest = build_manifest(sync_root)
            write_manifest(manifest_file, manifest)

            if result.returncode != 0:
                failures.append(
                    f"Sync-root anchored skip_dir scenario ({label}) failed with status {result.returncode}"
                )
                continue

            if root_skipped_file in manifest:
                failures.append(
                    f"Sync-root anchored skip_dir scenario ({label}) synchronised the explicitly skipped root path: "
                    f"{root_skipped_file}"
                )

            if nested_required_file not in manifest:
                failures.append(
                    f"Sync-root anchored skip_dir scenario ({label}) incorrectly skipped the same-named nested directory: "
                    f"{nested_required_file}"
                )

            if control_required_file not in manifest:
                failures.append(
                    f"Sync-root anchored skip_dir scenario ({label}) did not synchronise the unrelated control file: "
                    f"{control_required_file}"
                )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0012",
            ensure_refresh_token=True,
        )
        case_log_dir = layout.log_dir
        all_artifacts = []; failures = []
        self._run_loose(context, case_log_dir, all_artifacts, failures)
        self._run_strict(context, case_log_dir, all_artifacts, failures)
        self._run_sync_root_anchored(context, case_log_dir, all_artifacts, failures)
        details = {"failures": failures}
        if failures: return self.fail_result(self.case_id, self.name, "; ".join(failures), all_artifacts, details)
        return self.pass_result(self.case_id, self.name, all_artifacts, details)
