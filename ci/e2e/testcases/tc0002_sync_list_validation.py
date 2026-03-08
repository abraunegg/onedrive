from __future__ import annotations

import json
import os
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

    # Evidence required to prove the scenario exercised the rule correctly.
    required_processed: list[str] = field(default_factory=list)
    required_skipped: list[str] = field(default_factory=list)

    def path_matches_prefix(self, path: str, prefix: str) -> bool:
        prefix = prefix.strip("/")
        if not prefix:
            return False
        return path == prefix or path.startswith(prefix + "/")

    def is_forbidden(self, path: str) -> bool:
        path = path.strip("/")

        if path in [item.strip("/") for item in self.forbidden_exact]:
            return True

        for prefix in self.forbidden_prefixes:
            if self.path_matches_prefix(path, prefix):
                return True

        return False

    def is_allowed_non_skip(self, path: str) -> bool:
        """
        Determine whether a path is explicitly allowed to appear in a non-skip
        event such as include/upload/create.
        """
        path = path.strip("/")

        if self.is_forbidden(path):
            return False

        if path in [item.strip("/") for item in self.allowed_exact]:
            return True

        for prefix in self.allowed_prefixes:
            if self.path_matches_prefix(path, prefix):
                return True

        return False

    def is_allowed_container(self, path: str) -> bool:
        """
        Allow container paths that may legitimately appear in logs even when the
        real rule target is a descendant path.

        Examples:
        - ZZ_E2E_SYNC_LIST
        - ZZ_E2E_SYNC_LIST/Documents
        """
        path = path.strip("/")

        if path == FIXTURE_ROOT_NAME:
            return True

        for item in self.allowed_exact:
            item = item.strip("/")
            if item.startswith(path + "/"):
                return True

        for prefix in self.allowed_prefixes:
            prefix = prefix.strip("/")
            if prefix.startswith(path + "/"):
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
        (
            "skip",
            re.compile(r"^(?:DEBUG:\s+)?Skipping path - excluded by sync_list config: (.+)$"),
        ),
        (
            "include_dir",
            re.compile(r"^(?:DEBUG:\s+)?Including path - included by sync_list config: (.+)$"),
        ),
        (
            "include_file",
            re.compile(r"^(?:DEBUG:\s+)?Including file - included by sync_list config: (.+)$"),
        ),
        (
            "upload_file",
            re.compile(r"^(?:DEBUG:\s+)?Uploading new file: (.+?) \.\.\."),
        ),
        (
            "create_remote_dir",
            re.compile(
                r"^(?:DEBUG:\s+)?OneDrive Client requested to create this directory online: (.+)$"
            ),
        ),
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
                continue

            if scenario.is_forbidden(path):
                diffs.append(
                    f"Forbidden path was processed by sync_list: {path} "
                    f"(line: {event.line})"
                )
                continue

            if not scenario.is_allowed_non_skip(path) and not scenario.is_allowed_container(path):
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

    def _safe_name_fragment(self, value: str) -> str:
        return re.sub(r"[^A-Za-z0-9]+", "_", value).strip("_").lower() or "root"

    def _dummy_filename_for_dir(self, rel_dir: str) -> str:
        """
        Generate a stable, unique filename for a directory.
        """
        fragment = self._safe_name_fragment(rel_dir.replace("/", "_"))
        extensions = [".bin", ".dat", ".cache", ".blob"]
        ext = extensions[len(fragment) % len(extensions)]
        return f"zz_e2e_{fragment}{ext}"

    def _write_random_file(self, path: Path, size_bytes: int = 50 * 1024) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(os.urandom(size_bytes))

    def _ensure_every_directory_has_direct_file(
        self,
        root: Path,
        dirs: list[str],
        existing_files: dict[str, str],
    ) -> None:
        """
        Ensure every created directory has at least one direct file inside it.

        If a directory already has a direct child file defined in existing_files,
        do nothing for that directory. Otherwise add a 50 KiB random dummy file.
        """
        dirs_set = {d.strip("/") for d in dirs}

        dirs_with_direct_files: set[str] = set()
        for rel_file in existing_files.keys():
            rel_file = rel_file.strip("/")
            parent = str(Path(rel_file).parent).replace("\\", "/")
            if parent == ".":
                parent = ""
            dirs_with_direct_files.add(parent)

        for rel_dir in sorted(dirs_set):
            if rel_dir in dirs_with_direct_files:
                continue

            dummy_name = self._dummy_filename_for_dir(rel_dir)
            dummy_path = root / rel_dir / dummy_name
            self._write_random_file(dummy_path)

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
            f"{FIXTURE_ROOT_NAME}/Programming",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build/intermediates",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx/tmp",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/build",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/.cxx",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build/assets",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/build",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv/bin",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv/bin",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules/pkg",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/libraries",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/caches",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/src",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/src",
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
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build/output.apk": "android app1 build\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build/intermediates/classes.dex": "classes dex\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx/tmp/native.o": "native object\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/src/main.kt": "fun main() {}\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/build/obj.o": "android app2 build\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/.cxx/state.bin": "android app2 cxx\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/src/app.kt": "class App\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build/bundle.js": "bundle\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build/assets/chunk.js": "chunk\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/src/index.ts": "console.log('site1');\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/build/app.js": "site2 build\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/src/app.ts": "console.log('site2');\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv/bin/python": "venv python\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv/bin/python": "venv python 2\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__/main.pyc": "pyc\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/src/main.py": "print('tool1')\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle/cache.bin": "gradle cache\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin/output.class": "class bytes\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/src/Main.java": "class Main {}\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules/pkg/index.js": "module.exports = {};\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/src/index.js": "console.log('node');\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next/cache.dat": "next cache\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/src/page.tsx": "export default function Page() {}\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/libraries/lib.xml": "<xml />\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/caches/cache.db": "cache db\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/src/App.kt": "class IdeaApp\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache/tool.cache": "misc cache\n",
            f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/src/readme.txt": "misc src\n",
        }

        for rel, content in files.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

        self._ensure_every_directory_has_direct_file(root, dirs, files)

    def _build_scenarios(self) -> list[SyncListScenario]:
        return [
            SyncListScenario(
                scenario_id="SL-0001",
                description="root directory include with trailing slash",
                sync_list=[
                    f"/{FIXTURE_ROOT_NAME}/Backup/",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                    f"{FIXTURE_ROOT_NAME}/Backup/root-backup.txt",
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
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Blender",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Blender",
                    f"{FIXTURE_ROOT_NAME}/Blender/scene.blend",
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
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                    f"{FIXTURE_ROOT_NAME}/Random/Backup",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                    f"{FIXTURE_ROOT_NAME}/Backup/root-backup.txt",
                    f"{FIXTURE_ROOT_NAME}/Random/Backup",
                    f"{FIXTURE_ROOT_NAME}/Random/Backup/nested-backup.txt",
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
                    f"{FIXTURE_ROOT_NAME}/Documents/latest_report.docx",
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes/keep.txt",
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
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectA/keep.txt",
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectB/latest_report.docx",
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
            SyncListScenario(
                scenario_id="SL-0007",
                description="rooted include of Programming tree",
                sync_list=[
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/src/main.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/src/index.ts",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/src/main.py",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Backup",
                    f"{FIXTURE_ROOT_NAME}/Documents",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0008",
                description="exclude Android recursive build output and include Programming",
                sync_list=[
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Android/**/build/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/build",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/src/main.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/src/app.kt",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/build",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0009",
                description="exclude Android recursive .cxx content and include Programming",
                sync_list=[
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Android/**/.cxx/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/.cxx",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/src/main.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/src/app.kt",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/.cxx",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0010",
                description="exclude Web recursive build output and include Programming",
                sync_list=[
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Web/**/build/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/build",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/src/index.ts",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/src/app.ts",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/build",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0011",
                description="exclude .gradle anywhere and include Programming",
                sync_list=[
                    "!.gradle/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/src/Main.java",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0012",
                description="exclude build/kotlin anywhere and include Programming",
                sync_list=[
                    "!build/kotlin/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/src/Main.java",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0013",
                description="exclude .venv and venv anywhere and include Programming",
                sync_list=[
                    "!.venv/*",
                    "!venv/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/src/main.py",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0014",
                description="exclude common cache and vendor directories and include Programming",
                sync_list=[
                    "!__pycache__/*",
                    "!node_modules/*",
                    "!.next/*",
                    "!.idea/libraries/*",
                    "!.idea/caches/*",
                    "!.cache/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/libraries",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/caches",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/src/main.py",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/src/index.js",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/src/page.tsx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/src/App.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/src/readme.txt",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/libraries",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/caches",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0015",
                description="cyb3rko style complex Programming ruleset",
                sync_list=[
                    "!build/kotlin/*",
                    "!.kotlin/*",
                    "!venv/*",
                    "!.venv/*",
                    "!.gradle/*",
                    "!.idea/libraries/*",
                    "!.idea/caches/*",
                    "!.cache/*",
                    "!__pycache__/*",
                    "!node_modules/*",
                    "!.next/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Android/**/build/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Android/**/.cxx/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Web/**/build/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/libraries",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/caches",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/src/main.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/src/app.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/src/index.ts",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/src/app.ts",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/src/main.py",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/src/Main.java",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/src/index.js",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/src/page.tsx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/src/App.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/src/readme.txt",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/libraries",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/caches",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0016",
                description="massive mixed rule set across Programming Documents and Work",
                sync_list=[
                    "!build/kotlin/*",
                    "!.gradle/*",
                    "!.cache/*",
                    "!__pycache__/*",
                    "!node_modules/*",
                    "!.next/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Android/**/build/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Android/**/.cxx/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Web/**/build/*",
                    f"!/{FIXTURE_ROOT_NAME}/Documents/Notes/.config/*",
                    f"!/{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                    f"/{FIXTURE_ROOT_NAME}/Documents/",
                    f"/{FIXTURE_ROOT_NAME}/Work/",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                    f"{FIXTURE_ROOT_NAME}/Documents",
                    f"{FIXTURE_ROOT_NAME}/Work",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes/.config",
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Documents/latest_report.docx",
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes/keep.txt",
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectA/keep.txt",
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectB/latest_report.docx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/src/main.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/src/index.ts",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/src/Main.java",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes/.config",
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
                ],
            ),
            SyncListScenario(
                scenario_id="SL-0017",
                description="stress test kitchen sink rule set with broad include and targeted file include",
                sync_list=[
                    "!build/kotlin/*",
                    "!.kotlin/*",
                    "!venv/*",
                    "!.venv/*",
                    "!.gradle/*",
                    "!.idea/libraries/*",
                    "!.idea/caches/*",
                    "!.cache/*",
                    "!__pycache__/*",
                    "!node_modules/*",
                    "!.next/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Android/**/build/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Android/**/.cxx/*",
                    f"!/{FIXTURE_ROOT_NAME}/Programming/Projects/Web/**/build/*",
                    f"!/{FIXTURE_ROOT_NAME}/Documents/Notes/.config/*",
                    f"!/{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle/*",
                    f"/{FIXTURE_ROOT_NAME}/Programming",
                    f"/{FIXTURE_ROOT_NAME}/Documents/",
                    f"/{FIXTURE_ROOT_NAME}/Work/",
                    f"/{FIXTURE_ROOT_NAME}/Backup/",
                    f"{FIXTURE_ROOT_NAME}/Blender/scene.blend",
                ],
                allowed_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming",
                    f"{FIXTURE_ROOT_NAME}/Documents",
                    f"{FIXTURE_ROOT_NAME}/Work",
                    f"{FIXTURE_ROOT_NAME}/Backup",
                ],
                allowed_exact=[
                    f"{FIXTURE_ROOT_NAME}/Blender/scene.blend",
                ],
                forbidden_prefixes=[
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App2/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site2/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/libraries",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/caches",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes/.config",
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Secret_data",
                ],
                required_processed=[
                    f"{FIXTURE_ROOT_NAME}/Backup/root-backup.txt",
                    f"{FIXTURE_ROOT_NAME}/Blender/scene.blend",
                    f"{FIXTURE_ROOT_NAME}/Documents/latest_report.docx",
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectB/latest_report.docx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/src/main.kt",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/src/index.ts",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/src/main.py",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/src/Main.java",
                ],
                required_skipped=[
                    f"{FIXTURE_ROOT_NAME}/Documents/Notes/.config",
                    f"{FIXTURE_ROOT_NAME}/Work/ProjectA/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Android/App1/.cxx",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Web/Site1/build",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/.venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/venv",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Python/Tool1/__pycache__",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/.gradle",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Java/Project1/build/kotlin",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Node/App1/node_modules",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Next/App1/.next",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/libraries",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Idea/App1/.idea/caches",
                    f"{FIXTURE_ROOT_NAME}/Programming/Projects/Misc/App1/.cache",
                    f"{FIXTURE_ROOT_NAME}/Secret_data",
                ],
            ),
        ]