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
class LiteralSkipRuleScenario:
    scenario_id: str
    description: str
    direction: str
    files: tuple[tuple[str, str], ...]
    root_name: str
    skip_dir_entries: tuple[str, ...] = ()
    skip_file_entries: tuple[str, ...] = ()
    strict: bool = False
    sync_list: tuple[str, ...] = ()
    expected_present: tuple[str, ...] = ()
    expected_absent: tuple[str, ...] = ()
    expected_shadowed_rules: tuple[str, ...] = ()
    expected_shadowing_option: str | None = None


@dataclass
class ScenarioResult:
    scenario_id: str
    description: str
    passed: bool
    failure_messages: list[str]
    artifacts: list[str]
    details: dict[str, object]


class TestCase0088SkipRuleLiteralCharacterValidation(E2ETestCase):
    """
    Test Case 0088: skip_file and skip_dir literal character validation

    'skip_file' and 'skip_dir' only support the '*' and '?' wildcards and the
    '|' rule separator. The characters '[', ']', '{', '}', '^' and '$' are
    valid in OneDrive file and folder names and must be matched literally.

    Before this was fixed, these characters were passed through to the regex
    engine, so:
      - 'Photos [2023]' became a character class matching 'Photos 2' but not
        the intended 'Photos [2023]' directory
      - 'Backup{1}.txt' became a repetition quantifier matching 'Backup.txt'
      - '^' and '$' became anchors
      - an unbalanced '[' or '{' threw a RegexException during start-up
      - 'sync_list' shadowing validation reported unrelated include rules as
        shadowed, and missed genuinely shadowed include rules

    Each scenario uses unique test data, performs real local or remote
    mutations, runs the client with the rule set under test, validates the
    resulting state on both sides and removes its test data online again.
    """

    case_id = "0088"
    name = "skip_file and skip_dir literal character validation"
    description = (
        "Validate that '[', ']', '{', '}', '^' and '$' in skip_file and skip_dir rules are matched literally "
        "across local and remote processing, strict and non-strict skip_dir matching, unbalanced brackets and "
        "braces, multiple rules, existing wildcards and sync_list shadowing validation"
    )

    LOCAL_TO_REMOTE = "local_to_remote"
    REMOTE_TO_LOCAL = "remote_to_local"
    STARTUP_VALIDATION = "startup_validation"

    def _write_config(
        self,
        config_path: Path,
        *,
        skip_dir_entries: tuple[str, ...] = (),
        skip_file_entries: tuple[str, ...] = (),
        strict: bool = False,
        label: str,
    ) -> None:
        lines = [
            f"# tc0088 {label} config",
            'bypass_data_preservation = "true"',
        ]

        for entry in skip_dir_entries:
            lines.append(f'skip_dir = "{entry}"')

        if skip_dir_entries:
            lines.append(
                f'skip_dir_strict_match = "{"true" if strict else "false"}"'
            )

        for entry in skip_file_entries:
            lines.append(f'skip_file = "{entry}"')

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

    def _build_scenarios(self, suffix: str) -> list[LiteralSkipRuleScenario]:
        def root(scenario_number: str) -> str:
            return f"ZZ_E2E_TC0088_LS{scenario_number}_{suffix}"

        # Shared fixture for the non-strict 'skip_dir' bracket scenarios.
        def bracket_dir_files(r: str) -> tuple[tuple[str, str], ...]:
            return (
                (f"{r}/Photos [2023]/skip-top.txt", "skip literal bracket directory\n"),
                (f"{r}/Nested/Photos [2023]/skip-nested.txt", "skip nested literal bracket directory\n"),
                (f"{r}/Photos 2/keep-2.txt", "keep, matched by the old character class\n"),
                (f"{r}/Photos 3/keep-3.txt", "keep, matched by the old character class\n"),
                (f"{r}/Photos [2024]/keep-2024.txt", "keep, different literal bracket directory\n"),
                (f"{r}/Keep/ok.txt", "keep\n"),
            )

        def bracket_dir_present(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Photos 2/keep-2.txt",
                f"{r}/Photos 3/keep-3.txt",
                f"{r}/Photos [2024]/keep-2024.txt",
                f"{r}/Keep/ok.txt",
            )

        def bracket_dir_absent(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Photos [2023]/skip-top.txt",
                f"{r}/Nested/Photos [2023]/skip-nested.txt",
            )

        # Shared fixture for the strict 'skip_dir' bracket scenarios.
        def strict_dir_files(r: str) -> tuple[tuple[str, str], ...]:
            return (
                (f"{r}/Albums/Photos [2023]/skip-strict.txt", "skip strict full path\n"),
                (f"{r}/Photos [2023]/keep-top.txt", "keep, same name outside the strict path\n"),
                (f"{r}/Albums/Photos 2/keep-2.txt", "keep, matched by the old character class\n"),
                (f"{r}/Albums/keep.txt", "keep\n"),
            )

        def strict_dir_present(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Photos [2023]/keep-top.txt",
                f"{r}/Albums/Photos 2/keep-2.txt",
                f"{r}/Albums/keep.txt",
            )

        # Shared fixture for the 'skip_file' scenarios: literal '{}', '^' and '$',
        # multiple '|' separated rules, and the existing '*' and '?' wildcards.
        skip_file_rules = ("Backup{1}.txt|Report^Final.txt|Price$*|*.tmp|Draft?.txt",)

        def skip_file_files(r: str) -> tuple[tuple[str, str], ...]:
            return (
                (f"{r}/Backup{{1}}.txt", "skip literal braces\n"),
                (f"{r}/Backup.txt", "keep, matched by the old repetition quantifier\n"),
                (f"{r}/Report^Final.txt", "skip literal caret\n"),
                (f"{r}/ReportFinal.txt", "keep\n"),
                (f"{r}/Price$100.txt", "skip literal dollar with wildcard\n"),
                (f"{r}/Price", "keep, matched by the old end anchor\n"),
                (f"{r}/Docs/scratch.tmp", "skip existing '*' wildcard\n"),
                (f"{r}/Docs/Draft1.txt", "skip existing '?' wildcard\n"),
                (f"{r}/Docs/Draft10.txt", "keep, '?' matches exactly one character\n"),
                (f"{r}/Docs/notes.txt", "keep\n"),
            )

        def skip_file_present(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Backup.txt",
                f"{r}/ReportFinal.txt",
                f"{r}/Price",
                f"{r}/Docs/Draft10.txt",
                f"{r}/Docs/notes.txt",
            )

        def skip_file_absent(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Backup{{1}}.txt",
                f"{r}/Report^Final.txt",
                f"{r}/Price$100.txt",
                f"{r}/Docs/scratch.tmp",
                f"{r}/Docs/Draft1.txt",
            )

        # Shared fixture for the unbalanced bracket and brace scenarios.
        unbalanced_skip_dir = ("Draft [old",)
        unbalanced_skip_file = ("Notes {draft.txt|Closing ]bracket}.txt",)

        def unbalanced_files(r: str) -> tuple[tuple[str, str], ...]:
            return (
                (f"{r}/Draft [old/skip.txt", "skip unbalanced bracket directory\n"),
                (f"{r}/Draft old/keep.txt", "keep\n"),
                (f"{r}/Notes {{draft.txt", "skip unbalanced brace file\n"),
                (f"{r}/Notes draft.txt", "keep\n"),
                (f"{r}/Closing ]bracket}}.txt", "skip unbalanced closing bracket and brace file\n"),
                (f"{r}/Closing bracket.txt", "keep\n"),
            )

        def unbalanced_present(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Draft old/keep.txt",
                f"{r}/Notes draft.txt",
                f"{r}/Closing bracket.txt",
            )

        def unbalanced_absent(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Draft [old/skip.txt",
                f"{r}/Notes {{draft.txt",
                f"{r}/Closing ]bracket}}.txt",
            )

        # Shared fixture for the 'sync_list' interaction scenarios. The include rules
        # '/<root>/Photos 2' and '/<root>/Backup.txt' were previously reported as
        # shadowed by 'skip_dir = "Photos [2023]"' and 'skip_file = "Backup{1}.txt"'.
        def sync_list_rules(r: str) -> tuple[str, ...]:
            return (
                f"/{r}/Photos 2",
                f"/{r}/Albums",
                f"/{r}/Backup.txt",
            )

        def sync_list_files(r: str) -> tuple[tuple[str, str], ...]:
            return (
                (f"{r}/Photos 2/keep-2.txt", "keep, included by sync_list\n"),
                (f"{r}/Albums/Photos [2023]/skip.txt", "skip, excluded by skip_dir inside an included path\n"),
                (f"{r}/Albums/Photos 3/keep-3.txt", "keep, included by sync_list\n"),
                (f"{r}/Albums/Backup{{1}}.txt", "skip, excluded by skip_file inside an included path\n"),
                (f"{r}/Albums/keep.txt", "keep, included by sync_list\n"),
                (f"{r}/Backup.txt", "keep, included by sync_list\n"),
                (f"{r}/Outside/excluded.txt", "skip, not included by sync_list\n"),
            )

        def sync_list_present(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Photos 2/keep-2.txt",
                f"{r}/Albums/Photos 3/keep-3.txt",
                f"{r}/Albums/keep.txt",
                f"{r}/Backup.txt",
            )

        def sync_list_absent(r: str) -> tuple[str, ...]:
            return (
                f"{r}/Albums/Photos [2023]/skip.txt",
                f"{r}/Albums/Backup{{1}}.txt",
                f"{r}/Outside/excluded.txt",
            )

        r1, r2, r3, r4, r5, r6 = root("0001"), root("0002"), root("0003"), root("0004"), root("0005"), root("0006")
        r7, r8, r9, r10, r11, r12 = root("0007"), root("0008"), root("0009"), root("0010"), root("0011"), root("0012")

        return [
            LiteralSkipRuleScenario(
                scenario_id="LS-0001",
                description="skip_dir with literal square brackets, non-strict, local to remote",
                direction=self.LOCAL_TO_REMOTE,
                root_name=r1,
                skip_dir_entries=("Photos [2023]",),
                strict=False,
                files=bracket_dir_files(r1),
                expected_present=bracket_dir_present(r1),
                expected_absent=bracket_dir_absent(r1),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0002",
                description="skip_dir with literal square brackets, non-strict, remote to local",
                direction=self.REMOTE_TO_LOCAL,
                root_name=r2,
                skip_dir_entries=("Photos [2023]",),
                strict=False,
                files=bracket_dir_files(r2),
                expected_present=bracket_dir_present(r2),
                expected_absent=bracket_dir_absent(r2),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0003",
                description="skip_dir full path with literal square brackets, strict, local to remote",
                direction=self.LOCAL_TO_REMOTE,
                root_name=r3,
                skip_dir_entries=(f"{r3}/Albums/Photos [2023]",),
                strict=True,
                files=strict_dir_files(r3),
                expected_present=strict_dir_present(r3),
                expected_absent=(f"{r3}/Albums/Photos [2023]/skip-strict.txt",),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0004",
                description="skip_dir full path with literal square brackets, strict, remote to local",
                direction=self.REMOTE_TO_LOCAL,
                root_name=r4,
                skip_dir_entries=(f"{r4}/Albums/Photos [2023]",),
                strict=True,
                files=strict_dir_files(r4),
                expected_present=strict_dir_present(r4),
                expected_absent=(f"{r4}/Albums/Photos [2023]/skip-strict.txt",),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0005",
                description="skip_file with literal braces, caret and dollar plus '*', '?' and '|', local to remote",
                direction=self.LOCAL_TO_REMOTE,
                root_name=r5,
                skip_file_entries=skip_file_rules,
                files=skip_file_files(r5),
                expected_present=skip_file_present(r5),
                expected_absent=skip_file_absent(r5),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0006",
                description="skip_file with literal braces, caret and dollar plus '*', '?' and '|', remote to local",
                direction=self.REMOTE_TO_LOCAL,
                root_name=r6,
                skip_file_entries=skip_file_rules,
                files=skip_file_files(r6),
                expected_present=skip_file_present(r6),
                expected_absent=skip_file_absent(r6),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0007",
                description="unbalanced brackets and braces in skip_dir and skip_file, local to remote",
                direction=self.LOCAL_TO_REMOTE,
                root_name=r7,
                skip_dir_entries=unbalanced_skip_dir,
                skip_file_entries=unbalanced_skip_file,
                files=unbalanced_files(r7),
                expected_present=unbalanced_present(r7),
                expected_absent=unbalanced_absent(r7),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0008",
                description="unbalanced brackets and braces in skip_dir and skip_file, remote to local",
                direction=self.REMOTE_TO_LOCAL,
                root_name=r8,
                skip_dir_entries=unbalanced_skip_dir,
                skip_file_entries=unbalanced_skip_file,
                files=unbalanced_files(r8),
                expected_present=unbalanced_present(r8),
                expected_absent=unbalanced_absent(r8),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0009",
                description="sync_list includes not shadowed by literal skip_dir and skip_file rules, local to remote",
                direction=self.LOCAL_TO_REMOTE,
                root_name=r9,
                skip_dir_entries=("Photos [2023]",),
                skip_file_entries=("Backup{1}.txt",),
                sync_list=sync_list_rules(r9),
                files=sync_list_files(r9),
                expected_present=sync_list_present(r9),
                expected_absent=sync_list_absent(r9),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0010",
                description="sync_list includes not shadowed by literal skip_dir and skip_file rules, remote to local",
                direction=self.REMOTE_TO_LOCAL,
                root_name=r10,
                skip_dir_entries=("Photos [2023]",),
                skip_file_entries=("Backup{1}.txt",),
                sync_list=sync_list_rules(r10),
                files=sync_list_files(r10),
                expected_present=sync_list_present(r10),
                expected_absent=sync_list_absent(r10),
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0011",
                description="sync_list include shadowed by a skip_dir rule containing literal square brackets",
                direction=self.STARTUP_VALIDATION,
                root_name=r11,
                skip_dir_entries=("Photos [2023]",),
                sync_list=(f"/{r11}/Photos [2023]",),
                files=((f"{r11}/Photos [2023]/never-uploaded.txt", "configuration must be rejected\n"),),
                expected_shadowed_rules=(f"/{r11}/Photos [2023]",),
                expected_shadowing_option="skip_dir",
            ),
            LiteralSkipRuleScenario(
                scenario_id="LS-0012",
                description="sync_list include shadowed by a skip_file rule containing literal braces",
                direction=self.STARTUP_VALIDATION,
                root_name=r12,
                skip_file_entries=("Backup{1}.txt",),
                sync_list=(f"/{r12}/Backup{{1}}.txt",),
                files=((f"{r12}/Backup{{1}}.txt", "configuration must be rejected\n"),),
                expected_shadowed_rules=(f"/{r12}/Backup{{1}}.txt",),
                expected_shadowing_option="skip_file",
            ),
        ]

    def _run_phase(
        self,
        context: E2EContext,
        scenario: LiteralSkipRuleScenario,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
    ):
        context.log(
            f"Executing Test Case {self.case_id} {scenario.scenario_id} "
            f"{label}: {command_to_string(command)}"
        )
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def _sync_command(
        self,
        context: E2EContext,
        *,
        mode: str,
        sync_root: Path,
        conf_dir: Path,
        single_directory: str | None,
    ) -> list[str]:
        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            mode,
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(sync_root),
            "--confdir",
            str(conf_dir),
        ]
        # A client with 'sync_list' configured deliberately runs without --single-directory,
        # so that 'sync_list' itself selects the testcase tree.
        if single_directory:
            command.extend(["--single-directory", single_directory])
        return command

    def _run_scenario(
        self,
        context: E2EContext,
        scenario: LiteralSkipRuleScenario,
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
        verify_root = scenario_work_dir / "verify-syncroot"
        verify_conf = scenario_work_dir / "conf-verify"

        reset_directory(subject_root)
        reset_directory(other_root)
        reset_directory(verify_root)

        if scenario.direction in (self.LOCAL_TO_REMOTE, self.STARTUP_VALIDATION):
            source_root = subject_root
        elif scenario.direction == self.REMOTE_TO_LOCAL:
            source_root = other_root
        else:
            raise ValueError(f"Unknown TC0088 scenario direction: {scenario.direction}")

        for relative_path, file_content in scenario.files:
            write_text_file(source_root / relative_path, file_content)

        context.bootstrap_config_dir(subject_conf)
        self._write_config(
            subject_conf / "config",
            skip_dir_entries=scenario.skip_dir_entries,
            skip_file_entries=scenario.skip_file_entries,
            strict=scenario.strict,
            label=f"{scenario.scenario_id} subject",
        )
        if scenario.sync_list:
            write_text_file(subject_conf / "sync_list", "\n".join(scenario.sync_list) + "\n")

        context.bootstrap_config_dir(other_conf)
        self._write_config(other_conf / "config", label=f"{scenario.scenario_id} unfiltered")

        context.bootstrap_config_dir(verify_conf)
        self._write_config(verify_conf / "config", label=f"{scenario.scenario_id} verify")

        subject_scope = None if scenario.sync_list else scenario.root_name

        result_manifest_file = scenario_state_dir / "result_manifest.txt"
        local_manifest_file = scenario_state_dir / "local_source_manifest.txt"
        remote_manifest_file = scenario_state_dir / "remote_verify_manifest.txt"
        metadata_file = scenario_state_dir / "metadata.txt"
        artifacts: list[str] = [str(metadata_file)]

        failures: list[str] = []
        details: dict[str, object] = {
            "scenario_id": scenario.scenario_id,
            "description": scenario.description,
            "direction": scenario.direction,
            "root_name": scenario.root_name,
            "skip_dir_entries": list(scenario.skip_dir_entries),
            "skip_file_entries": list(scenario.skip_file_entries),
            "skip_dir_strict_match": scenario.strict,
            "sync_list": list(scenario.sync_list),
            "expected_present": list(scenario.expected_present),
            "expected_absent": list(scenario.expected_absent),
            "expected_shadowed_rules": list(scenario.expected_shadowed_rules),
        }

        def phase_logs(name: str) -> tuple[Path, Path]:
            stdout_file = scenario_log_dir / f"{name}_stdout.log"
            stderr_file = scenario_log_dir / f"{name}_stderr.log"
            artifacts.extend([str(stdout_file), str(stderr_file)])
            return stdout_file, stderr_file

        def check_no_regex_exception(label: str, result) -> None:
            if "RegexException" in result.stdout or "RegexException" in result.stderr:
                failures.append(f"{label} raised a RegexException while loading the client side filtering rules")

        remote_root_exists = False

        if scenario.direction == self.STARTUP_VALIDATION:
            # The configuration must be rejected before any synchronisation takes place.
            stdout_file, stderr_file = phase_logs("phase1_subject")
            phase1_result = self._run_phase(
                context,
                scenario,
                "phase 1 (subject)",
                self._sync_command(
                    context,
                    mode="--upload-only",
                    sync_root=subject_root,
                    conf_dir=subject_conf,
                    single_directory=None,
                ),
                stdout_file,
                stderr_file,
            )
            details["phase1_returncode"] = phase1_result.returncode
            check_no_regex_exception("phase 1", phase1_result)
            output = phase1_result.stdout + phase1_result.stderr

            if phase1_result.returncode == 0:
                failures.append("client accepted a configuration where a sync_list include rule is shadowed")
                # The client synchronised the test data, it must be removed again below
                remote_root_exists = True

            expected_heading = f"inclusion rules are shadowed by '{scenario.expected_shadowing_option}'"
            if expected_heading not in output:
                failures.append(f"expected shadowing error not reported: {expected_heading}")

            for rule in scenario.expected_shadowed_rules:
                expected_line = f"Shadowed 'sync_list' rule: {rule}"
                if expected_line not in output:
                    failures.append(f"expected shadowed rule not reported: {rule}")
        else:
            if scenario.direction == self.LOCAL_TO_REMOTE:
                # Phase 1: the filtered subject client uploads the local test data
                phase1_root, phase1_conf, phase1_scope = subject_root, subject_conf, subject_scope
                # Phase 2: a fresh unfiltered client observes what was placed online
                phase2_root, phase2_conf, phase2_scope = other_root, other_conf, scenario.root_name
            else:
                # Phase 1: an unfiltered client seeds the test data online
                phase1_root, phase1_conf, phase1_scope = other_root, other_conf, scenario.root_name
                # Phase 2: the filtered subject client downloads the remote test data
                phase2_root, phase2_conf, phase2_scope = subject_root, subject_conf, subject_scope

            stdout_file, stderr_file = phase_logs("phase1_source")
            phase1_result = self._run_phase(
                context,
                scenario,
                "phase 1 (upload)",
                self._sync_command(
                    context,
                    mode="--upload-only",
                    sync_root=phase1_root,
                    conf_dir=phase1_conf,
                    single_directory=phase1_scope,
                ),
                stdout_file,
                stderr_file,
            )
            details["phase1_returncode"] = phase1_result.returncode
            check_no_regex_exception("phase 1", phase1_result)
            if phase1_result.returncode != 0:
                failures.append(f"upload phase failed with status {phase1_result.returncode}")

            if scenario.direction == self.REMOTE_TO_LOCAL and phase1_result.returncode == 0:
                remote_root_exists = True

            if phase1_result.returncode == 0:
                stdout_file, stderr_file = phase_logs("phase2_result")
                phase2_result = self._run_phase(
                    context,
                    scenario,
                    "phase 2 (download)",
                    self._sync_command(
                        context,
                        mode="--download-only",
                        sync_root=phase2_root,
                        conf_dir=phase2_conf,
                        single_directory=phase2_scope,
                    ),
                    stdout_file,
                    stderr_file,
                )
                details["phase2_returncode"] = phase2_result.returncode
                check_no_regex_exception("phase 2", phase2_result)
                if phase2_result.returncode != 0:
                    failures.append(f"download phase failed with status {phase2_result.returncode}")

                result_manifest = build_manifest(phase2_root)
                write_manifest(result_manifest_file, result_manifest)
                artifacts.append(str(result_manifest_file))
                details["result_manifest"] = result_manifest

                if scenario.direction == self.LOCAL_TO_REMOTE and scenario.root_name in result_manifest:
                    remote_root_exists = True

                if phase2_result.returncode == 0:
                    for expected in scenario.expected_present:
                        if expected not in result_manifest:
                            failures.append(f"expected included path is missing: {expected}")
                    for unwanted in scenario.expected_absent:
                        if unwanted in result_manifest:
                            failures.append(f"expected skipped path is present: {unwanted}")

                if scenario.direction == self.LOCAL_TO_REMOTE:
                    # Local side: skipped data must remain untouched on the local filesystem
                    local_manifest = build_manifest(subject_root)
                    write_manifest(local_manifest_file, local_manifest)
                    artifacts.append(str(local_manifest_file))
                    for relative_path, _ in scenario.files:
                        if relative_path not in local_manifest:
                            failures.append(f"local source path was removed: {relative_path}")
                elif phase2_result.returncode == 0:
                    # Remote side: skipped data must remain online, verified by a fresh unfiltered client
                    stdout_file, stderr_file = phase_logs("phase3_remote_verify")
                    phase3_result = self._run_phase(
                        context,
                        scenario,
                        "phase 3 (remote verify)",
                        self._sync_command(
                            context,
                            mode="--download-only",
                            sync_root=verify_root,
                            conf_dir=verify_conf,
                            single_directory=scenario.root_name,
                        ),
                        stdout_file,
                        stderr_file,
                    )
                    details["phase3_returncode"] = phase3_result.returncode
                    if phase3_result.returncode != 0:
                        failures.append(f"remote verification failed with status {phase3_result.returncode}")
                    else:
                        remote_manifest = build_manifest(verify_root)
                        write_manifest(remote_manifest_file, remote_manifest)
                        artifacts.append(str(remote_manifest_file))
                        for relative_path, _ in scenario.files:
                            if relative_path not in remote_manifest:
                                failures.append(f"remote source path was removed: {relative_path}")

        # Cleanup: remove this scenario's test data online again
        details["remote_root_exists"] = remote_root_exists
        if remote_root_exists:
            stdout_file, stderr_file = phase_logs("cleanup_remove_directory")
            cleanup_command = [
                context.onedrive_bin,
                "--verbose",
                "--remove-directory",
                scenario.root_name,
                "--syncdir",
                str(other_root),
                "--confdir",
                str(other_conf),
            ]
            cleanup_result = self._run_phase(
                context,
                scenario,
                "cleanup",
                cleanup_command,
                stdout_file,
                stderr_file,
            )
            details["cleanup_returncode"] = cleanup_result.returncode
            if cleanup_result.returncode != 0:
                failures.append(f"cleanup of remote test data failed with status {cleanup_result.returncode}")

        details["failure_messages"] = failures
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
            case_dir_name="tc0088",
            ensure_refresh_token=True,
        )

        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        suffix = f"{context.run_id}_{os.getpid()}"

        scenarios = [
            scenario
            for scenario in self._build_scenarios(suffix)
            if context.should_run_scenario(self.case_id, scenario.scenario_id)
        ]

        results: list[ScenarioResult] = []

        for scenario in scenarios:
            scenario_dir_name = scenario.scenario_id.lower().replace("-", "")
            results.append(
                self._run_scenario(
                    context,
                    scenario,
                    scenario_work_dir=case_work_dir / scenario_dir_name,
                    scenario_log_dir=case_log_dir / scenario_dir_name,
                    scenario_state_dir=state_dir / scenario_dir_name,
                )
            )

        all_artifacts: list[str] = []
        details: dict[str, object] = {
            "executed_scenario_ids": [result.scenario_id for result in results],
        }
        failed_results: list[ScenarioResult] = []
        summary_lines: list[str] = []

        for result in results:
            all_artifacts.extend(result.artifacts)
            details[result.scenario_id] = result.details

            if result.passed:
                summary_lines.append(f"{result.scenario_id} [PASS] {result.description}")
            else:
                failed_results.append(result)
                summary_lines.append(
                    f"{result.scenario_id} [FAIL] {result.description} — "
                    + "; ".join(result.failure_messages)
                )

        summary_file = state_dir / "scenario_summary.txt"
        write_text_file(summary_file, "\n".join(summary_lines) + ("\n" if summary_lines else ""))
        all_artifacts.append(str(summary_file))

        details["failed_scenario_ids"] = [result.scenario_id for result in failed_results]

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
                f"{result.scenario_id}: " + ", ".join(result.failure_messages)
                for result in failed_results
            )
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failed_results)} of {len(results)} literal skip rule scenarios failed — {failure_text}",
                deduped_artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, deduped_artifacts, details)
