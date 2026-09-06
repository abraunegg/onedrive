from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


@dataclass(frozen=True)
class SkipDirScenario:
    scenario_id: str
    description: str
    direction: str
    skip_dir_entries: tuple[str, ...]
    strict: bool
    files: tuple[tuple[str, str], ...]
    expected_present: tuple[str, ...]
    expected_absent: tuple[str, ...]
    single_directory: str | None = None


@dataclass
class ScenarioResult:
    scenario_id: str
    description: str
    passed: bool
    failure_messages: list[str]
    artifacts: list[str]
    details: dict[str, object]


class TestCase0012SkipDirValidation(E2ETestCase):
    case_id = "0012"
    name = "skip_dir validation"
    description = (
        "Validate skip_dir semantic contracts across local and remote processing, including "
        "unanchored matching, strict full-path matching, sync-root anchored paths, wildcards, "
        "case-insensitive matching and multiple configured patterns"
    )

    LOCAL_TO_REMOTE = "local_to_remote"
    REMOTE_TO_LOCAL = "remote_to_local"

    def _write_config(
        self,
        config_path: Path,
        *,
        skip_dir_entries: tuple[str, ...] = (),
        strict: bool = False,
        label: str,
    ) -> None:
        lines = [
            f"# tc0012 {label} config",
            'bypass_data_preservation = "true"',
        ]

        for entry in skip_dir_entries:
            lines.append(f'skip_dir = "{entry}"')

        if skip_dir_entries:
            lines.append(
                f'skip_dir_strict_match = "{"true" if strict else "false"}"'
            )

        write_onedrive_config(config_path, "\n".join(lines) + "\n")

    @staticmethod
    def _write_metadata(path: Path, details: dict[str, object]) -> None:
        write_text_file(
            path,
            "\n".join(
                f"{key}={value!r}" for key, value in sorted(details.items())
            )
            + "\n",
        )

    @staticmethod
    def _append_scope(command: list[str], single_directory: str | None) -> None:
        if single_directory:
            command.extend(["--single-directory", single_directory])

    def _build_scenarios(self, suffix: str) -> list[SkipDirScenario]:
        loose_local_root = f"ZZ_E2E_TC0012_SD0001_{suffix}"
        loose_remote_root = f"ZZ_E2E_TC0012_SD0002_{suffix}"

        strict_local_root = f"ZZ_E2E_TC0012_SD0003_{suffix}"
        strict_remote_root = f"ZZ_E2E_TC0012_SD0004_{suffix}"

        anchored_loose = f"ZZ_E2E_TC0012_ANCHORED_LOOSE_{suffix}"
        anchored_loose_container = f"ZZ_E2E_TC0012_CONTAINER_LOOSE_{suffix}"

        anchored_strict = f"ZZ_E2E_TC0012_ANCHORED_STRICT_{suffix}"
        anchored_strict_container = f"ZZ_E2E_TC0012_CONTAINER_STRICT_{suffix}"

        multi_loose_root = f"ZZ E2E TC0012 SD0007 Project Files {suffix}"
        multi_strict_root = f"ZZ E2E TC0012 SD0008 Project Files {suffix}"

        mixed_local_root = f"ZZ_E2E_TC0012_SD0009_{suffix}"
        mixed_remote_root = f"ZZ_E2E_TC0012_SD0010_{suffix}"

        return [
            SkipDirScenario(
                scenario_id="SD-0001",
                description="unanchored directory name, non-strict, local to remote",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=("Cache",),
                strict=False,
                files=(
                    (f"{loose_local_root}/Cache/top.txt", "skip top\n"),
                    (f"{loose_local_root}/App/Cache/nested.txt", "skip nested\n"),
                    (f"{loose_local_root}/Keep/ok.txt", "keep\n"),
                ),
                expected_present=(f"{loose_local_root}/Keep/ok.txt",),
                expected_absent=(
                    f"{loose_local_root}/Cache/top.txt",
                    f"{loose_local_root}/App/Cache/nested.txt",
                ),
                single_directory=loose_local_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0002",
                description="unanchored directory name, non-strict, remote to local",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=("Cache",),
                strict=False,
                files=(
                    (f"{loose_remote_root}/Cache/top.txt", "skip top\n"),
                    (f"{loose_remote_root}/App/Cache/nested.txt", "skip nested\n"),
                    (f"{loose_remote_root}/Keep/ok.txt", "keep\n"),
                ),
                expected_present=(f"{loose_remote_root}/Keep/ok.txt",),
                expected_absent=(
                    f"{loose_remote_root}/Cache/top.txt",
                    f"{loose_remote_root}/App/Cache/nested.txt",
                ),
                single_directory=loose_remote_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0003",
                description="strict explicit full path, local to remote",
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=(f"{strict_local_root}/App/Cache",),
                strict=True,
                files=(
                    (f"{strict_local_root}/Cache/top.txt", "top remains\n"),
                    (f"{strict_local_root}/App/Cache/nested.txt", "strict skip\n"),
                    (f"{strict_local_root}/Keep/ok.txt", "keep\n"),
                ),
                expected_present=(
                    f"{strict_local_root}/Cache/top.txt",
                    f"{strict_local_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{strict_local_root}/App/Cache/nested.txt",
                ),
                single_directory=strict_local_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0004",
                description="strict explicit full path, remote to local",
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"{strict_remote_root}/App/Cache",),
                strict=True,
                files=(
                    (f"{strict_remote_root}/Cache/top.txt", "top remains\n"),
                    (f"{strict_remote_root}/App/Cache/nested.txt", "strict skip\n"),
                    (f"{strict_remote_root}/Keep/ok.txt", "keep\n"),
                ),
                expected_present=(
                    f"{strict_remote_root}/Cache/top.txt",
                    f"{strict_remote_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{strict_remote_root}/App/Cache/nested.txt",
                ),
                single_directory=strict_remote_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0005",
                description=(
                    "sync-root anchored single-segment path, non-strict, "
                    "remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"/{anchored_loose}",),
                strict=False,
                files=(
                    (
                        f"{anchored_loose}/root-only.txt",
                        "must skip only at sync root\n",
                    ),
                    (
                        f"{anchored_loose_container}/{anchored_loose}/"
                        "nested-must-sync.txt",
                        "same-named nested directory must remain in scope\n",
                    ),
                    (
                        f"{anchored_loose_container}/keep.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{anchored_loose_container}/{anchored_loose}/"
                    "nested-must-sync.txt",
                    f"{anchored_loose_container}/keep.txt",
                ),
                expected_absent=(
                    f"{anchored_loose}/root-only.txt",
                ),
                single_directory=None,
            ),
            SkipDirScenario(
                scenario_id="SD-0006",
                description=(
                    "sync-root anchored single-segment path, strict, "
                    "remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"/{anchored_strict}",),
                strict=True,
                files=(
                    (
                        f"{anchored_strict}/root-only.txt",
                        "must skip only at sync root\n",
                    ),
                    (
                        f"{anchored_strict_container}/{anchored_strict}/"
                        "nested-must-sync.txt",
                        "same-named nested directory must remain in scope\n",
                    ),
                    (
                        f"{anchored_strict_container}/keep.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{anchored_strict_container}/{anchored_strict}/"
                    "nested-must-sync.txt",
                    f"{anchored_strict_container}/keep.txt",
                ),
                expected_absent=(
                    f"{anchored_strict}/root-only.txt",
                ),
                single_directory=None,
            ),
            SkipDirScenario(
                scenario_id="SD-0007",
                description=(
                    "sync-root anchored multi-segment path with spaces and "
                    "trailing slash, non-strict, remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"/{multi_loose_root}/Cache Data/",),
                strict=False,
                files=(
                    (
                        f"{multi_loose_root}/Cache Data/"
                        "root-path-must-skip.txt",
                        "root-relative multi-segment path must skip\n",
                    ),
                    (
                        f"{multi_loose_root}/Container/{multi_loose_root}/"
                        "Cache Data/nested-suffix-must-sync.txt",
                        "same suffix below another prefix must remain in scope\n",
                    ),
                    (
                        f"{multi_loose_root}/Keep/ok.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{multi_loose_root}/Container/{multi_loose_root}/"
                    "Cache Data/nested-suffix-must-sync.txt",
                    f"{multi_loose_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{multi_loose_root}/Cache Data/"
                    "root-path-must-skip.txt",
                ),
                single_directory=multi_loose_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0008",
                description=(
                    "sync-root anchored multi-segment path with spaces and "
                    "trailing slash, strict, remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(f"/{multi_strict_root}/Cache Data/",),
                strict=True,
                files=(
                    (
                        f"{multi_strict_root}/Cache Data/"
                        "root-path-must-skip.txt",
                        "root-relative multi-segment path must skip\n",
                    ),
                    (
                        f"{multi_strict_root}/Container/{multi_strict_root}/"
                        "Cache Data/nested-suffix-must-sync.txt",
                        "same suffix below another prefix must remain in scope\n",
                    ),
                    (
                        f"{multi_strict_root}/Keep/ok.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{multi_strict_root}/Container/{multi_strict_root}/"
                    "Cache Data/nested-suffix-must-sync.txt",
                    f"{multi_strict_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{multi_strict_root}/Cache Data/"
                    "root-path-must-skip.txt",
                ),
                single_directory=multi_strict_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0009",
                description=(
                    "mixed patterns, repeated skip_dir entries, wildcard and "
                    "case-insensitive matching, local to remote"
                ),
                direction=self.LOCAL_TO_REMOTE,
                skip_dir_entries=(
                    "cache*|Case?Dir",
                    f"/{mixed_local_root}/Explicit*",
                ),
                strict=False,
                files=(
                    (
                        f"{mixed_local_root}/CacheAlpha/a.txt",
                        "skip wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/Nested/CACHEBeta/b.txt",
                        "skip case-insensitive wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/CaseXDir/c.txt",
                        "skip question wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/Nested/caseYdir/d.txt",
                        "skip case-insensitive question wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/ExplicitOne/e.txt",
                        "skip anchored wildcard\n",
                    ),
                    (
                        f"{mixed_local_root}/Nested/ExplicitOne/f.txt",
                        "anchored wildcard must not match nested suffix\n",
                    ),
                    (
                        f"{mixed_local_root}/Keep/ok.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{mixed_local_root}/Nested/ExplicitOne/f.txt",
                    f"{mixed_local_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{mixed_local_root}/CacheAlpha/a.txt",
                    f"{mixed_local_root}/Nested/CACHEBeta/b.txt",
                    f"{mixed_local_root}/CaseXDir/c.txt",
                    f"{mixed_local_root}/Nested/caseYdir/d.txt",
                    f"{mixed_local_root}/ExplicitOne/e.txt",
                ),
                single_directory=mixed_local_root,
            ),
            SkipDirScenario(
                scenario_id="SD-0010",
                description=(
                    "mixed patterns, repeated skip_dir entries, wildcard and "
                    "case-insensitive matching, remote to local"
                ),
                direction=self.REMOTE_TO_LOCAL,
                skip_dir_entries=(
                    "cache*|Case?Dir",
                    f"/{mixed_remote_root}/Explicit*",
                ),
                strict=False,
                files=(
                    (
                        f"{mixed_remote_root}/CacheAlpha/a.txt",
                        "skip wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/Nested/CACHEBeta/b.txt",
                        "skip case-insensitive wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/CaseXDir/c.txt",
                        "skip question wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/Nested/caseYdir/d.txt",
                        "skip case-insensitive question wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/ExplicitOne/e.txt",
                        "skip anchored wildcard\n",
                    ),
                    (
                        f"{mixed_remote_root}/Nested/ExplicitOne/f.txt",
                        "anchored wildcard must not match nested suffix\n",
                    ),
                    (
                        f"{mixed_remote_root}/Keep/ok.txt",
                        "keep\n",
                    ),
                ),
                expected_present=(
                    f"{mixed_remote_root}/Nested/ExplicitOne/f.txt",
                    f"{mixed_remote_root}/Keep/ok.txt",
                ),
                expected_absent=(
                    f"{mixed_remote_root}/CacheAlpha/a.txt",
                    f"{mixed_remote_root}/Nested/CACHEBeta/b.txt",
                    f"{mixed_remote_root}/CaseXDir/c.txt",
                    f"{mixed_remote_root}/Nested/caseYdir/d.txt",
                    f"{mixed_remote_root}/ExplicitOne/e.txt",
                ),
                single_directory=mixed_remote_root,
            ),
        ]

    def _run_scenario(
        self,
        context: E2EContext,
        scenario: SkipDirScenario,
        *,
        scenario_work_dir: Path,
        scenario_log_dir: Path,
        scenario_state_dir: Path,
    ) -> ScenarioResult:
        reset_directory(scenario_work_dir)
        reset_directory(scenario_log_dir)
        reset_directory(scenario_state_dir)

        subject_root = scenario_work_dir / "subject-syncroot"
        subject_conf = scenario_work_dir / "conf-subject"
        other_root = scenario_work_dir / "other-syncroot"
        other_conf = scenario_work_dir / "conf-other"

        reset_directory(subject_root)
        reset_directory(other_root)

        if scenario.direction == self.LOCAL_TO_REMOTE:
            source_root = subject_root
            source_conf = subject_conf
            result_root = other_root
            result_conf = other_conf
        elif scenario.direction == self.REMOTE_TO_LOCAL:
            source_root = other_root
            source_conf = other_conf
            result_root = subject_root
            result_conf = subject_conf
        else:
            raise ValueError(
                f"Unknown TC0012 scenario direction: {scenario.direction}"
            )

        for relative_path, file_content in scenario.files:
            write_text_file(source_root / relative_path, file_content)

        context.bootstrap_config_dir(subject_conf)
        self._write_config(
            subject_conf / "config",
            skip_dir_entries=scenario.skip_dir_entries,
            strict=scenario.strict,
            label=f"{scenario.scenario_id} subject",
        )

        context.bootstrap_config_dir(other_conf)
        self._write_config(
            other_conf / "config",
            label=f"{scenario.scenario_id} unfiltered",
        )

        phase1_stdout = scenario_log_dir / "phase1_source_stdout.log"
        phase1_stderr = scenario_log_dir / "phase1_source_stderr.log"
        phase2_stdout = scenario_log_dir / "phase2_result_stdout.log"
        phase2_stderr = scenario_log_dir / "phase2_result_stderr.log"
        result_manifest_file = scenario_state_dir / "result_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"

        artifacts = [
            str(phase1_stdout),
            str(phase1_stderr),
            str(phase2_stdout),
            str(phase2_stderr),
            str(result_manifest_file),
            str(metadata_file),
        ]

        # Phase 1 always seeds the remote side from the scenario's source
        # client. For local-to-remote scenarios this is the filtered subject
        # client; for remote-to-local scenarios this is the unfiltered client.
        phase1_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(source_root),
            "--confdir",
            str(source_conf),
        ]
        self._append_scope(phase1_command, scenario.single_directory)

        context.log(
            f"Executing Test Case {self.case_id} {scenario.scenario_id} "
            f"phase 1: {command_to_string(phase1_command)}"
        )
        phase1_result = run_command(
            phase1_command,
            cwd=context.repo_root,
        )
        write_text_file(phase1_stdout, phase1_result.stdout)
        write_text_file(phase1_stderr, phase1_result.stderr)

        # Phase 2 uses a fresh client to observe what phase 1 placed online.
        # For local-to-remote scenarios this is deliberately unfiltered so the
        # resulting manifest proves that the source-side skip_dir rule worked.
        # For remote-to-local scenarios this is the filtered subject client so
        # the remote JSON filtering path is exercised directly.
        phase2_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--download-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(result_root),
            "--confdir",
            str(result_conf),
        ]
        self._append_scope(phase2_command, scenario.single_directory)

        context.log(
            f"Executing Test Case {self.case_id} {scenario.scenario_id} "
            f"phase 2: {command_to_string(phase2_command)}"
        )
        phase2_result = run_command(
            phase2_command,
            cwd=context.repo_root,
        )
        write_text_file(phase2_stdout, phase2_result.stdout)
        write_text_file(phase2_stderr, phase2_result.stderr)

        result_manifest = build_manifest(result_root)
        write_manifest(result_manifest_file, result_manifest)

        failures: list[str] = []

        if phase1_result.returncode != 0:
            failures.append(
                f"source phase failed with status {phase1_result.returncode}"
            )

        if phase2_result.returncode != 0:
            failures.append(
                f"result phase failed with status {phase2_result.returncode}"
            )

        if (
            phase1_result.returncode == 0
            and phase2_result.returncode == 0
        ):
            for expected in scenario.expected_present:
                if expected not in result_manifest:
                    failures.append(
                        f"expected included path is missing: {expected}"
                    )

            for unwanted in scenario.expected_absent:
                if unwanted in result_manifest:
                    failures.append(
                        f"expected skipped path is present: {unwanted}"
                    )

        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id,
            "description": scenario.description,
            "direction": scenario.direction,
            "skip_dir_entries": list(scenario.skip_dir_entries),
            "skip_dir_strict_match": scenario.strict,
            "single_directory": scenario.single_directory,
            "phase1_returncode": phase1_result.returncode,
            "phase2_returncode": phase2_result.returncode,
            "expected_present": list(scenario.expected_present),
            "expected_absent": list(scenario.expected_absent),
            "result_manifest": result_manifest,
            "failure_messages": failures,
        }
        self._write_metadata(metadata_file, details)

        return ScenarioResult(
            scenario_id=scenario.scenario_id,
            description=scenario.description,
            passed=not failures,
            failure_messages=failures,
            artifacts=artifacts,
            details=details,
        )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0012",
            ensure_refresh_token=True,
        )

        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        suffix = f"{context.run_id}_{os.getpid()}"

        scenarios = [
            scenario
            for scenario in self._build_scenarios(suffix)
            if context.should_run_scenario(
                self.case_id,
                scenario.scenario_id,
            )
        ]

        results: list[ScenarioResult] = []

        for scenario in scenarios:
            scenario_dir_name = (
                scenario.scenario_id.lower().replace("-", "")
            )

            results.append(
                self._run_scenario(
                    context,
                    scenario,
                    scenario_work_dir=(
                        case_work_dir / scenario_dir_name
                    ),
                    scenario_log_dir=(
                        case_log_dir / scenario_dir_name
                    ),
                    scenario_state_dir=(
                        state_dir / scenario_dir_name
                    ),
                )
            )

        all_artifacts: list[str] = []
        details: dict[str, object] = {
            "executed_scenario_ids": [
                result.scenario_id for result in results
            ],
        }
        failed_results: list[ScenarioResult] = []

        summary_lines: list[str] = []

        for result in results:
            all_artifacts.extend(result.artifacts)
            details[result.scenario_id] = result.details

            if result.passed:
                summary_lines.append(
                    f"{result.scenario_id} [PASS] {result.description}"
                )
            else:
                failed_results.append(result)
                summary_lines.append(
                    f"{result.scenario_id} [FAIL] {result.description} — "
                    + "; ".join(result.failure_messages)
                )

        summary_file = state_dir / "scenario_summary.txt"
        write_text_file(
            summary_file,
            "\n".join(summary_lines)
            + ("\n" if summary_lines else ""),
        )
        all_artifacts.append(str(summary_file))

        details["failed_scenario_ids"] = [
            result.scenario_id for result in failed_results
        ]

        metadata_file = state_dir / "metadata.txt"
        self._write_metadata(metadata_file, details)
        all_artifacts.append(str(metadata_file))

        deduped_artifacts: list[str] = []
        seen: set[str] = set()

        for artifact in all_artifacts:
            if artifact not in seen:
                deduped_artifacts.append(artifact)
                seen.add(artifact)

        if failed_results:
            failure_text = "; ".join(
                f"{result.scenario_id}: "
                + ", ".join(result.failure_messages)
                for result in failed_results
            )

            return self.fail_result(
                self.case_id,
                self.name,
                (
                    f"{len(failed_results)} of {len(results)} "
                    f"skip_dir scenarios failed — {failure_text}"
                ),
                deduped_artifacts,
                details,
            )

        return self.pass_result(
            self.case_id,
            self.name,
            deduped_artifacts,
            details,
        )
