from __future__ import annotations

import json
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


FIXTURE_ROOT_NAME = "ZZ_E2E_SYNC_LIST"


@dataclass
class ParsedEvent:
    event_type: str
    raw_path: str
    normalised_path: str
    line: str


@dataclass
class SyncListScenario:
    scenario_id: str
    description: str
    sync_list: list[str]

    # Paths explicitly allowed for non-skip operations.
    allowed_exact: list[str] = field(default_factory=list)
    allowed_prefixes: list[str] = field(default_factory=list)

    # Paths explicitly forbidden for non-skip operations.
    forbidden_exact: list[str] = field(default_factory=list)
    forbidden_prefixes: list[str] = field(default_factory=list)

    # Evidence we require to prove the scenario really exercised the rule.
    required_processed: list[str] = field(default_factory=list)
    required_skipped: list[str] = field(default_factory=list)

    def expanded_allowed_exact(self) -> set[str]:
        """
        Return only the explicitly allowed exact paths.

        Do not automatically promote ancestor/container paths to required
        allowed paths, because sync_list processing may legitimately skip
        container directories while still including matching descendants.
        """
        expanded: set[str] = set()

        for item in self.allowed_exact:
            path = item.strip("/")
            if path:
                expanded.add(path)

        return expanded

    def path_matches_prefix(self, path: str, prefix: str) -> bool:
        prefix = prefix.strip("/")
        if not prefix:
            return False
        return path == prefix or path.startswith(prefix + "/")

    def is_forbidden(self, path: str) -> bool:
        if path in self.forbidden_exact:
            return True

        for prefix in self.forbidden_prefixes:
            if self.path_matches_prefix(path, prefix):
                return True

        return False

    def is_allowed_non_skip(self, path: str) -> bool:
        if self.is_forbidden(path):
            return False

        if path in self.expanded_allowed_exact():
            return True

        for prefix in self.allowed_prefixes:
            if self.path_matches_prefix(path, prefix):
                return True

        return False


class TestCase0002SyncListValidation(E2ETestCase):
    """
    Test Case 0002: sync_list validation

    This validates sync_list as a policy-conformance test.

    The test is considered successful when all observed sync operations
    involving the fixture tree match the active sync_list rules.
    """

    case_id = "0002"
    name = "sync_list validation"
    description = "Validate sync_list behaviour across a scenario matrix"

    EVENT_PATTERNS = [
        ("skip", re.compile(r"^Skipping path - excluded by sync_list config: (.+)$")),
        ("include_dir", re.compile(r"^Including path - included by sync_list config: (.+)$")),
        ("include_file", re.compile(r"^Including file - included by sync_list config: (.+)$")),
        ("upload_file", re.compile(r"^Uploading new file: (.+?) \.\.\.")),
        ("create_remote_dir", re.compile(r"^OneDrive Client requested to create this directory online: (.+)$")),
    ]

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / f"tc{self.case_id}"
        case_log_dir = context.logs_dir / f"tc{self.case_id}"
        state_dir = context.state_dir / f"tc{self.case_id}"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)

        fixture_root = case_work_dir / "fixture"
        sync_root = case_work_dir / "syncroot"

        context.ensure_refresh_token_available()
        self._create_fixture_tree(fixture_root)

        scenarios = self._build_scenarios()

        failures: list[str] = []
        all_artifacts: list[str] = []

        for scenario in scenarios:
            context.log(
                f"Running Test Case {self.case_id} scenario {scenario.scenario_id}: "
                f"{scenario.description}"
            )

            scenario_dir = state_dir / scenario.scenario_id
            scenario_log_dir = case_log_dir / scenario.scenario_id
            config_dir = case_work_dir / f"config-{scenario.scenario_id}"

            reset_directory(scenario_dir)
            reset_directory(scenario_log_dir)
            reset_directory(config_dir)
            reset_directory(sync_root)

            copied_refresh_token = context.bootstrap_config_dir(config_dir)
            context.log(
                f"Scenario {scenario.scenario_id} bootstrapped config dir: {config_dir}"
            )

            # Seed the local sync directory from the canonical fixture.
            shutil.copytree(fixture_root, sync_root, dirs_exist_ok=True)

            sync_list_path = config_dir / "sync_list"
            stdout_file = scenario_log_dir / "stdout.log"
            stderr_file = scenario_log_dir / "stderr.log"
            metadata_file = scenario_dir / "metadata.txt"
            events_file = scenario_dir / "events.json"
            actual_manifest_file = scenario_dir / "actual_manifest.txt"
            diff_file = scenario_dir / "diff.txt"

            write_text_file(sync_list_path, "\n".join(scenario.sync_list) + "\n")

            command = [
                context.onedrive_bin,
                "--sync",
                "--verbose",
                "--verbose",
                "--resync",
                "--resync-auth",
                "--syncdir",
                str(sync_root),
                "--confdir",
                str(config_dir),
            ]

            result = run_command(command, cwd=context.repo_root)

            write_text_file(stdout_file, result.stdout)
            write_text_file(stderr_file, result.stderr)

            metadata_lines = [
                f"scenario_id={scenario.scenario_id}",
                f"description={scenario.description}",
                f"command={command_to_string(command)}",
                f"returncode={result.returncode}",
                f"config_dir={config_dir}",
                f"refresh_token_path={copied_refresh_token}",
            ]
            write_text_file(metadata_file, "\n".join(metadata_lines) + "\n")

            all_artifacts.extend(
                [
                    str(sync_list_path),
                    str(stdout_file),
                    str(stderr_file),
                    str(metadata_file),
                ]
            )

            if result.returncode != 0:
                failure_message = (
                    f"{scenario.scenario_id}: onedrive exited with non-zero status "
                    f"{result.returncode}"
                )
                failures.append(failure_message)
                context.log(f"Scenario {scenario.scenario_id} FAILED: {failure_message}")
                continue

            events = self._parse_events(result.stdout)
            fixture_events = [
                event for event in events if self._is_fixture_path(event.normalised_path)
            ]

            write_text_file(
                events_file,
                json.dumps(
                    [
                        {
                            "event_type": event.event_type,
                            "raw_path": event.raw_path,
                            "normalised_path": event.normalised_path,
                            "line": event.line,
                        }
                        for event in fixture_events
                    ],
                    indent=2,
                )
                + "\n",
            )
            all_artifacts.append(str(events_file))

            actual_manifest = build_manifest(sync_root)
            write_manifest(actual_manifest_file, actual_manifest)
            all_artifacts.append(str(actual_manifest_file))

            diffs = self._validate_scenario(scenario, fixture_events)

            if diffs:
                write_text_file(diff_file, "\n".join(diffs) + "\n")
                all_artifacts.append(str(diff_file))

                failure_message = f"{scenario.scenario_id}: " + "; ".join(diffs)
                failures.append(failure_message)
                context.log(f"Scenario {scenario.scenario_id} FAILED: {failure_message}")
            else:
                context.log(f"Scenario {scenario.scenario_id} PASSED")

        details = {
            "scenario_count": len(scenarios),
            "failed_scenarios": len(failures),
        }

        if failures:
            reason = (
                f"{len(failures)} of {len(scenarios)} sync_list scenarios failed: "
                + ", ".join(failure.split(":")[0] for failure in failures)
            )
            details["failures"] = failures
            return TestResult.fail_result(
                case_id=self.case_id,
                name=self.name,
                reason=reason,
                artifacts=all_artifacts,
                details=details,
            )

        return TestResult.pass_result(
            case_id=self.case_id,
            name=self.name,
            artifacts=all_artifacts,
            details=details,
        )

    def _normalise_log_path(self, raw_path: str) -> str:
        path = raw_path.strip()
        if path.startswith("./"):
            path = path[2:]
        path = path.rstrip("/")
        return path

    def _parse_events(self, stdout: str) -> list[ParsedEvent]:
        events: list[ParsedEvent] = []

        for line in stdout.splitlines():
            stripped = line.strip()

            for event_type, pattern in self.EVENT_PATTERNS:
                match = pattern.match(stripped)
                if not match:
                    continue

                raw_path = match.group(1).strip()
                normalised_path = self._normalise_log_path(raw_path)

                events.append(
                    ParsedEvent(
                        event_type=event_type,
                        raw_path=raw_path,
                        normalised_path=normalised_path,
                        line=stripped,
                    )
                )
                break

        return events

    def _is_fixture_path(self, path: str) -> bool:
        return path == FIXTURE_ROOT_NAME or path.startswith(FIXTURE_ROOT_NAME + "/")

    def _path_matches(self, path: str, prefix: str) -> bool:
        prefix = prefix.strip("/")
        if not prefix:
            return False
        return path == prefix or path.startswith(prefix + "/")

    def _find_matching_events(
        self,
        events: list[ParsedEvent],
        wanted_path: str,
        event_type: str | None = None,
        non_skip_only: bool = False,
    ) -> list[ParsedEvent]:
        matches: list[ParsedEvent] = []

        for event in events:
            if event_type and event.event_type != event_type:
                continue
            if non_skip_only and event.event_type == "skip":
                continue
            if self._path_matches(event.normalised_path, wanted_path):
                matches.append(event)

        return matches

    def _validate_scenario(
        self,
        scenario: SyncListScenario,
        events: list[ParsedEvent],
    ) -> list[str]:
        diffs: list[str] = []

        if not events:
            diffs.append("No fixture-related sync_list events were captured")
            return diffs

        for event in events:
            path = event.normalised_path

            if event.event_type == "skip":
                if scenario.is_allowed_non_skip(path):
                    diffs.append(
                        f"Allowed path was skipped by sync_list: {path} "
                        f"(line: {event.line})"
                    )
                continue

            # Non-skip operation
            if scenario.is_forbidden(path):
                diffs.append(
                    f"Forbidden path was processed by sync_list: {path} "
                    f"(line: {event.line})"
                )
                continue

            if not scenario.is_allowed_non_skip(path):
                diffs.append(
                    f"Unexpected path was processed by sync_list: {path} "
                    f"(line: {event.line})"
                )

        for required in scenario.required_processed:
            matches = self._find_matching_events(events, required, non_skip_only=True)
            if not matches:
                diffs.append(
                    f"Expected allowed processing was not observed for: {required}"
                )

        for required in scenario.required_skipped:
            matches = self._find_matching_events(events, required, event_type="skip")
            if not matches:
                diffs.append(
                    f"Expected excluded skip was not observed for: {required}"
                )

        return diffs

    def _create_fixture_tree(self, root: Path) -> None:
        reset_directory(root)

        dirs = [
            FIXTURE_ROOT_NAME,
            f"{FIXTURE_ROOT_NAME}/Backup",
            f"{FIXTURE_ROOT_NAME}/Blender",
            f"{FIXTURE_ROOT_NAME}/Documents",
            f"{FIXTURE_ROOT_NAME}/Documents/Notes",
            f"{FIXTURE_ROOT_NAME}/Documents/Notes/.config",
            f"{FIXTURE_ROOT_NAME}/Documents/Notes/temp123",
            f"{FIXTURE_ROOT_NAME}/Work",
            f"{FIXTURE_ROOT_NAME}/Work/ProjectA",
            f"{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle",
            f"{FIXTURE_ROOT_NAME}/Work/ProjectB",
            f"{FIXTURE_ROOT_NAME}/Secret_data",
            f"{FIXTURE_ROOT_NAME}/Random",
            f"{FIXTURE_ROOT_NAME}/Random/Backup",
        ]

        for rel in dirs:
            (root / rel).mkdir(parents=True, exist_ok=True)

        files = {
            f"{FIXTURE_ROOT_NAME}/Backup/root-backup.txt": "backup-root\n",
            f"{FIXTURE_ROOT_NAME}/Blender/scene.blend": "blend-scene\n",
            f"{FIXTURE_ROOT_NAME}/Documents/latest_report.docx": "latest report\n",
            f"{FIXTURE_ROOT_NAME}/Documents/report.pdf": "report pdf\n",
            f"{FIXTURE_ROOT_NAME}/Documents/Notes/keep.txt": "keep\n",
            f"{FIXTURE_ROOT_NAME}/Documents/Notes/.config/app.json": '{"ok": true}\n',
            f"{FIXTURE_ROOT_NAME}/Documents/Notes/temp123/ignored.txt": "ignored\n",
            f"{FIXTURE_ROOT_NAME}/Work/ProjectA/keep.txt": "project a\n",
            f"{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle/state.bin": "gradle\n",
            f"{FIXTURE_ROOT_NAME}/Work/ProjectB/latest_report.docx": "project b report\n",
            f"{FIXTURE_ROOT_NAME}/Secret_data/secret.txt": "secret\n",
            f"{FIXTURE_ROOT_NAME}/Random/Backup/nested-backup.txt": "nested backup\n",
        }

        for rel, content in files.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def _build_scenarios(self) -> list[SyncListScenario]:
        return [
            SyncListScenario(
                scenario_id="SL-0001",
                description="root directory include with trailing slash",
                sync_list=[
                    f"/{FIXTURE_ROOT_NAME}/Backup/",
                ],
                allowed_exact=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                    f"{FIXTURE_ROOT_NAME}/Backup/root-backup.txt",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Blender",
                    f"{FIXTURE_ROOT_NAME}/Documents",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0002",
                description="root include without trailing slash",
                sync_list=[
                    f"/{FIXTURE_ROOT_NAME}/Blender",
                ],
                allowed_exact=[
                    f"{FIXTURE_ROOT_NAME}/Blender",
                    f"{FIXTURE_ROOT_NAME}/Blender/scene.blend",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Blender",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                    f"{FIXTURE_ROOT_NAME}/Documents",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0003",
                description="non-root include by name",
                sync_list=[
                    "Backup",
                ],
                allowed_exact=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                    f"{FIXTURE_ROOT_NAME}/Backup/root-backup.txt",
                    f"{FIXTURE_ROOT_NAME}/Random/Backup",
                    f"{FIXTURE_ROOT_NAME}/Random/Backup/nested-backup.txt",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                    f"{FIXTURE_ROOT_NAME}/Random/Backup",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Blender",
                    f"{FIXTURE_ROOT_NAME}/Documents",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0004",
                description="include tree with nested exclusion",
                sync_list=[
                    f"!/{FIXTURE_ROOT_NAME}/Documents/Notes/.config/*",
                    f"/{FIXTURE_ROOT_NAME}/Documents/",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Documents",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes/.config",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Documents",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes/.config",
                    f"{FIXTURE_ROOT_NAME}/Backup",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0005",
                description="included tree with hidden directory excluded",
                sync_list=[
                    "!.gradle/*",
                    f"/{FIXTURE_ROOT_NAME}/Work/",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Work",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Work",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Backup",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0006",
                description="file-specific include inside named directory",
                sync_list=[
                    f"{FIXTURE_ROOT_NAME}/Documents/latest_report.docx",
                ],
                allowed_exact=[
                    f"{FIXTURE_ROOT_NAME}/Documents/latest_report.docx",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Documents/latest_report.docx",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes",
                    f"{FIXTURE_ROOT_NAME}/Backup",
                ],
            ),
        ]