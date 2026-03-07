from __future__ import annotations

import shutil
from dataclasses import dataclass
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, compare_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file


@dataclass
class SyncListScenario:
    scenario_id: str
    description: str
    sync_list: list[str]
    expected_present: list[str]
    expected_absent: list[str]


class TestCase0002SyncListValidation(E2ETestCase):
    """
    Test Case 0002: sync_list validation

    This test case runs multiple isolated sync_list scenarios against a fixed
    test fixture and reports a single overall pass/fail result back to the E2E
    harness.
    """

    case_id = "0002"
    name = "sync_list validation"
    description = "Validate sync_list behaviour across a scenario matrix"

    def run(self, context: E2EContext) -> TestResult:
        case_work_dir = context.work_root / f"tc{self.case_id}"
        case_log_dir = context.logs_dir / f"tc{self.case_id}"
        state_dir = context.state_dir / f"tc{self.case_id}"

        reset_directory(case_work_dir)
        reset_directory(case_log_dir)
        reset_directory(state_dir)

        fixture_root = case_work_dir / "fixture"
        sync_root = case_work_dir / "syncroot"

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

            # Seed the local sync directory from the canonical fixture.
            shutil.copytree(fixture_root, sync_root, dirs_exist_ok=True)

            sync_list_path = config_dir / "sync_list"
            stdout_file = scenario_log_dir / "stdout.log"
            stderr_file = scenario_log_dir / "stderr.log"
            actual_manifest_file = scenario_dir / "actual_manifest.txt"
            diff_file = scenario_dir / "diff.txt"
            metadata_file = scenario_dir / "metadata.txt"

            write_text_file(sync_list_path, "\n".join(scenario.sync_list) + "\n")

            command = [
                context.onedrive_bin,
                "--sync",
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
            ]
            write_text_file(metadata_file, "\n".join(metadata_lines) + "\n")

            all_artifacts.extend(
                [
                    str(sync_list_path),
                    str(stdout_file),
                    str(stderr_file),
                    str(metadata_file),
                    str(copied_refresh_token),
                ]
            )
            
            context.log(
                f"Scenario {scenario.scenario_id} bootstrapped config dir: {config_dir}"
            )

            if result.returncode != 0:
                failures.append(
                    f"{scenario.scenario_id}: onedrive exited with non-zero status {result.returncode}"
                )
                continue

            actual_manifest = build_manifest(sync_root)
            write_manifest(actual_manifest_file, actual_manifest)
            all_artifacts.append(str(actual_manifest_file))

            diffs = compare_manifest(
                actual_entries=actual_manifest,
                expected_present=scenario.expected_present,
                expected_absent=scenario.expected_absent,
            )

            if diffs:
                write_text_file(diff_file, "\n".join(diffs) + "\n")
                all_artifacts.append(str(diff_file))
                failures.append(f"{scenario.scenario_id}: " + "; ".join(diffs))

        details = {
            "scenario_count": len(scenarios),
            "failed_scenarios": len(failures),
        }

        if failures:
            reason = f"{len(failures)} of {len(scenarios)} sync_list scenarios failed: " + ", ".join(
                failure.split(":")[0] for failure in failures
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

    def _create_fixture_tree(self, root: Path) -> None:
        reset_directory(root)

        dirs = [
            "Backup",
            "Blender",
            "Documents",
            "Documents/Notes",
            "Documents/Notes/.config",
            "Documents/Notes/temp123",
            "Work",
            "Work/ProjectA",
            "Work/ProjectA/.gradle",
            "Work/ProjectB",
            "Secret_data",
            "Random",
            "Random/Backup",
        ]

        for rel in dirs:
            (root / rel).mkdir(parents=True, exist_ok=True)

        files = {
            "Backup/root-backup.txt": "backup-root\n",
            "Blender/scene.blend": "blend-scene\n",
            "Documents/latest_report.docx": "latest report\n",
            "Documents/report.pdf": "report pdf\n",
            "Documents/Notes/keep.txt": "keep\n",
            "Documents/Notes/.config/app.json": '{"ok": true}\n',
            "Documents/Notes/temp123/ignored.txt": "ignored\n",
            "Work/ProjectA/keep.txt": "project a\n",
            "Work/ProjectA/.gradle/state.bin": "gradle\n",
            "Work/ProjectB/latest_report.docx": "project b report\n",
            "Secret_data/secret.txt": "secret\n",
            "Random/Backup/nested-backup.txt": "nested backup\n",
        }

        for rel, content in files.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def _build_scenarios(self) -> list[SyncListScenario]:
        """
        First-cut scenario matrix.

        These focus on download-side validation only.
        """
        return [
            SyncListScenario(
                scenario_id="SL-0001",
                description="root directory include with trailing slash",
                sync_list=[
                    "/Backup/",
                ],
                expected_present=[
                    "Backup",
                    "Backup/root-backup.txt",
                ],
                expected_absent=[
                    "Blender",
                    "Blender/scene.blend",
                    "Documents",
                    "Work",
                    "Secret_data",
                    "Random",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0002",
                description="root include without trailing slash",
                sync_list=[
                    "/Blender",
                ],
                expected_present=[
                    "Blender",
                    "Blender/scene.blend",
                ],
                expected_absent=[
                    "Backup",
                    "Documents",
                    "Work",
                    "Secret_data",
                    "Random",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0003",
                description="non-root include by name",
                sync_list=[
                    "Backup",
                ],
                expected_present=[
                    "Backup",
                    "Backup/root-backup.txt",
                    "Random/Backup",
                    "Random/Backup/nested-backup.txt",
                ],
                expected_absent=[
                    "Blender",
                    "Documents",
                    "Work",
                    "Secret_data",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0004",
                description="include tree with nested exclusion",
                sync_list=[
                    "/Documents/",
                    "!/Documents/Notes/.config/*",
                ],
                expected_present=[
                    "Documents",
                    "Documents/latest_report.docx",
                    "Documents/report.pdf",
                    "Documents/Notes",
                    "Documents/Notes/keep.txt",
                    "Documents/Notes/temp123",
                    "Documents/Notes/temp123/ignored.txt",
                ],
                expected_absent=[
                    "Documents/Notes/.config",
                    "Documents/Notes/.config/app.json",
                    "Backup",
                    "Blender",
                    "Work",
                    "Secret_data",
                    "Random",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0005",
                description="included tree with hidden directory excluded",
                sync_list=[
                    "/Work/",
                    "!.gradle/*",
                ],
                expected_present=[
                    "Work",
                    "Work/ProjectA",
                    "Work/ProjectA/keep.txt",
                    "Work/ProjectB",
                    "Work/ProjectB/latest_report.docx",
                ],
                expected_absent=[
                    "Work/ProjectA/.gradle",
                    "Work/ProjectA/.gradle/state.bin",
                    "Backup",
                    "Blender",
                    "Documents",
                    "Secret_data",
                    "Random",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0006",
                description="file-specific include inside named directory",
                sync_list=[
                    "Documents/latest_report.docx",
                ],
                expected_present=[
                    "Documents",
                    "Documents/latest_report.docx",
                ],
                expected_absent=[
                    "Documents/report.pdf",
                    "Documents/Notes",
                    "Backup",
                    "Blender",
                    "Work",
                    "Secret_data",
                    "Random",
                ],
            ),
        ]