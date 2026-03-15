from __future__ import annotations

import os
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


class TestCase0012SkipDirValidation(E2ETestCase):
    case_id = "0012"
    name = "skip_dir validation"
    description = "Validate skip_dir loose matching and skip_dir_strict_match behaviour"

    def _write_config(self, config_path: Path, skip_dir_value: str, strict: bool) -> None:
        lines = ["# tc0012 config", "bypass_data_preservation = \"true\"", f"skip_dir = \"{skip_dir_value}\""]
        if strict:
            lines.append("skip_dir_strict_match = \"true\"")
        write_text_file(config_path, "\n".join(lines) + "\n")

    def _run_loose(self, context: E2EContext, case_log_dir: Path, all_artifacts: list[str], failures: list[str]) -> None:
        scenario_root = context.work_root / "tc0012" / "loose_match"; scenario_state = context.state_dir / "tc0012" / "loose_match"
        reset_directory(scenario_root); reset_directory(scenario_state)
        sync_root = scenario_root / "syncroot"; confdir = scenario_root / "conf-loose"; verify_root = scenario_root / "verifyroot"; verify_conf = scenario_root / "conf-verify-loose"
        root = f"ZZ_E2E_TC0012_LOOSE_{context.run_id}_{os.getpid()}"
        write_text_file(sync_root / root / "Cache" / "top.txt", "skip top\n")
        write_text_file(sync_root / root / "App" / "Cache" / "nested.txt", "skip nested\n")
        write_text_file(sync_root / root / "Keep" / "ok.txt", "ok\n")
        context.bootstrap_config_dir(confdir); self._write_config(confdir / "config", "Cache", False)
        context.bootstrap_config_dir(verify_conf); write_text_file(verify_conf / "config", "# verify\nbypass_data_preservation = \"true\"\n")
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
        context.bootstrap_config_dir(verify_conf); write_text_file(verify_conf / "config", "# verify\nbypass_data_preservation = \"true\"\n")
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

    def run(self, context: E2EContext) -> TestResult:
        case_log_dir = context.logs_dir / "tc0012"; reset_directory(case_log_dir); context.ensure_refresh_token_available()
        all_artifacts = []; failures = []
        self._run_loose(context, case_log_dir, all_artifacts, failures)
        self._run_strict(context, case_log_dir, all_artifacts, failures)
        details = {"failures": failures}
        if failures: return TestResult.fail_result(self.case_id, self.name, "; ".join(failures), all_artifacts, details)
        return TestResult.pass_result(self.case_id, self.name, all_artifacts, details)
