from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases_personal_shared_folders.shared_folder_common import (
    EXPECTED_TYPED_MANIFEST,
    case_sync_root,
    reset_local_sync_root,
)


CONFIG_FILE_NAME = "config"
SYNC_LIST_FILE_NAME = "sync_list"


@dataclass
class SharedFolderMutationCheck:
    parent_relative_path: str
    directory_name: str
    file_name: str
    content: str


@dataclass
class SharedFolderSyncListScenario:
    scenario_id: str
    description: str
    sync_list: list[str]
    expected_entries: list[str]
    required_present: list[str] = field(default_factory=list)
    required_absent: list[str] = field(default_factory=list)
    required_stdout_markers: list[str] = field(default_factory=list)
    mutation_checks: list[SharedFolderMutationCheck] = field(default_factory=list)


class SharedFolderPersonalTestCase0003SyncListValidation(E2ETestCase):
    case_id = "sfptc0003"
    name = "personal shared folders sync_list validation"
    description = "Validate sync_list include/exclude behaviour across preserved Personal Account shared-folder topology without ghost folders"

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name=self.case_id,
            ensure_refresh_token=True,
        )

        sync_root = case_sync_root(self.case_id)
        reset_local_sync_root(sync_root)

        scenarios = [
            scenario for scenario in self._build_scenarios()
            if context.should_run_scenario(self.case_id, scenario.scenario_id)
        ]

        failures: list[str] = []
        all_artifacts: list[str] = []

        for scenario in scenarios:
            context.log(
                f"Running Test Case {self.case_id} scenario {scenario.scenario_id}: "
                f"{scenario.description}"
            )

            scenario_sync_root = sync_root / scenario.scenario_id
            scenario_dir = layout.state_dir / scenario.scenario_id
            scenario_log_dir = layout.log_dir / scenario.scenario_id
            confdir = layout.work_dir / f"conf-{scenario.scenario_id}"

            reset_local_sync_root(scenario_sync_root)
            reset_directory(scenario_dir)
            reset_directory(scenario_log_dir)
            reset_directory(confdir)

            config_path = self._write_scenario_config(context, confdir, scenario_sync_root)
            sync_list_path = confdir / SYNC_LIST_FILE_NAME
            self._write_sync_list(sync_list_path, scenario.sync_list)

            stdout_file = scenario_log_dir / "stdout.log"
            stderr_file = scenario_log_dir / "stderr.log"
            actual_manifest_file = scenario_dir / "actual_typed_manifest.txt"
            expected_manifest_file = scenario_dir / "expected_typed_manifest.txt"
            missing_manifest_file = scenario_dir / "missing_expected_entries.txt"
            unexpected_manifest_file = scenario_dir / "unexpected_extra_entries.txt"
            required_present_file = scenario_dir / "missing_required_present_entries.txt"
            required_absent_file = scenario_dir / "unexpected_required_absent_entries.txt"
            metadata_file = scenario_dir / "metadata.txt"
            diff_file = scenario_dir / "diff.txt"

            command = [
                context.onedrive_bin,
                "--sync",
                "--verbose",
                "--download-only",
                "--resync",
                "--resync-auth",
                "--confdir",
                str(confdir),
            ]

            context.log(f"Executing {self.case_id} {scenario.scenario_id}: {command_to_string(command)}")
            result = run_command(command, cwd=context.repo_root)

            write_text_file(stdout_file, result.stdout)
            write_text_file(stderr_file, result.stderr)

            actual_manifest = build_typed_manifest(scenario_sync_root)
            expected_manifest = sorted(set(scenario.expected_entries))
            write_manifest(actual_manifest_file, actual_manifest)
            write_manifest(expected_manifest_file, expected_manifest)

            actual_set = set(actual_manifest)
            expected_set = set(expected_manifest)
            missing_entries = sorted(expected_set - actual_set)
            unexpected_entries = sorted(actual_set - expected_set)
            missing_required_present = sorted(
                entry for entry in scenario.required_present if entry not in actual_set
            )
            unexpected_required_absent = sorted(
                entry for entry in scenario.required_absent if entry in actual_set
            )
            missing_stdout_markers = [
                marker for marker in scenario.required_stdout_markers if marker not in result.stdout
            ]

            write_manifest(missing_manifest_file, missing_entries)
            write_manifest(unexpected_manifest_file, unexpected_entries)
            write_manifest(required_present_file, missing_required_present)
            write_manifest(required_absent_file, unexpected_required_absent)

            mutation_failures: list[str] = []
            mutation_artifacts: list[str] = []
            if scenario.mutation_checks:
                if result.returncode != 0 or missing_entries or unexpected_entries or missing_required_present or unexpected_required_absent:
                    mutation_failures.append(
                        "Skipping mutation validation because initial immutable baseline validation failed"
                    )
                else:
                    mutation_failures.extend(
                        self._run_mutation_checks(
                            context=context,
                            confdir=confdir,
                            sync_root=scenario_sync_root,
                            scenario_log_dir=scenario_log_dir,
                            scenario=scenario,
                            artifacts=mutation_artifacts,
                        )
                    )

            diffs: list[str] = []
            if result.returncode != 0:
                diffs.append(f"onedrive exited with non-zero status {result.returncode}")
            if missing_stdout_markers:
                diffs.append(
                    "Expected shared-folder stdout markers were not present: "
                    + ", ".join(missing_stdout_markers)
                )
            if missing_entries:
                diffs.append(f"Missing expected local entries: {missing_entries[:20]!r}")
            if unexpected_entries:
                diffs.append(
                    "Unexpected local entries were created; possible ghost folder or sync_list leak: "
                    + repr(unexpected_entries[:20])
                )
            if missing_required_present:
                diffs.append(f"Required included entries were missing: {missing_required_present!r}")
            if unexpected_required_absent:
                diffs.append(f"Required excluded entries were present locally: {unexpected_required_absent!r}")
            if mutation_failures:
                diffs.append("Mutation validation failed: " + "; ".join(mutation_failures))

            metadata_lines = [
                f"case_id={self.case_id}",
                f"scenario_id={scenario.scenario_id}",
                f"description={scenario.description}",
                f"command={command_to_string(command)}",
                f"returncode={result.returncode}",
                f"sync_root={scenario_sync_root}",
                f"config_dir={confdir}",
                f"config_path={config_path}",
                f"sync_list_path={sync_list_path}",
                f"expected_entries={len(expected_manifest)}",
                f"actual_entries={len(actual_manifest)}",
                f"missing_entries={len(missing_entries)}",
                f"unexpected_entries={len(unexpected_entries)}",
                f"missing_required_present={missing_required_present!r}",
                f"unexpected_required_absent={unexpected_required_absent!r}",
                f"missing_stdout_markers={missing_stdout_markers!r}",
                f"mutation_checks={len(scenario.mutation_checks)}",
                f"mutation_failures={mutation_failures!r}",
            ]
            write_text_file(metadata_file, "\n".join(metadata_lines) + "\n")

            scenario_artifacts = [
                str(config_path),
                str(sync_list_path),
                str(stdout_file),
                str(stderr_file),
                str(actual_manifest_file),
                str(expected_manifest_file),
                str(missing_manifest_file),
                str(unexpected_manifest_file),
                str(required_present_file),
                str(required_absent_file),
                str(metadata_file),
            ]
            scenario_artifacts.extend(mutation_artifacts)
            all_artifacts.extend(scenario_artifacts)

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
            "executed_scenario_ids": [scenario.scenario_id for scenario in scenarios],
            "failed_scenarios": len(failures),
            "failed_scenario_ids": [failure.split(":", 1)[0] for failure in failures],
        }

        if failures:
            details["failures"] = failures
            return self.fail_result(
                self.case_id,
                self.name,
                f"{len(failures)} of {len(scenarios)} shared-folder sync_list scenarios failed: "
                + ", ".join(failure.split(":", 1)[0] for failure in failures),
                all_artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, all_artifacts, details)

    def _run_mutation_checks(
        self,
        context: E2EContext,
        confdir: Path,
        sync_root: Path,
        scenario_log_dir: Path,
        scenario: SharedFolderSyncListScenario,
        artifacts: list[str],
    ) -> list[str]:
        failures: list[str] = []

        for index, mutation_check in enumerate(scenario.mutation_checks, start=1):
            parent_relative_path = mutation_check.parent_relative_path.strip("/")
            local_parent_path = sync_root / parent_relative_path
            local_test_dir = local_parent_path / mutation_check.directory_name
            local_test_file = local_test_dir / mutation_check.file_name

            upload_stdout_file = scenario_log_dir / f"mutation-upload-{index:02d}-stdout.log"
            upload_stderr_file = scenario_log_dir / f"mutation-upload-{index:02d}-stderr.log"
            cleanup_stdout_file = scenario_log_dir / f"mutation-cleanup-{index:02d}-stdout.log"
            cleanup_stderr_file = scenario_log_dir / f"mutation-cleanup-{index:02d}-stderr.log"
            verify_stdout_file = scenario_log_dir / f"mutation-cleanup-verify-{index:02d}-stdout.log"
            verify_stderr_file = scenario_log_dir / f"mutation-cleanup-verify-{index:02d}-stderr.log"
            baseline_manifest_file = scenario_log_dir / f"mutation-baseline-{index:02d}-manifest.txt"
            verify_manifest_file = scenario_log_dir / f"mutation-verify-{index:02d}-manifest.txt"
            mutation_diff_file = scenario_log_dir / f"mutation-diff-{index:02d}.txt"

            artifacts.extend([
                str(upload_stdout_file),
                str(upload_stderr_file),
                str(cleanup_stdout_file),
                str(cleanup_stderr_file),
                str(verify_stdout_file),
                str(verify_stderr_file),
                str(baseline_manifest_file),
                str(verify_manifest_file),
                str(mutation_diff_file),
            ])

            if "/" in mutation_check.directory_name or mutation_check.directory_name in {"", ".", ".."}:
                failures.append(
                    f"{parent_relative_path}: refusing mutation because tracked directory "
                    f"name is unsafe: {mutation_check.directory_name!r}"
                )
                continue

            if "/" in mutation_check.file_name or mutation_check.file_name in {"", ".", ".."}:
                failures.append(
                    f"{parent_relative_path}: refusing mutation because tracked file "
                    f"name is unsafe: {mutation_check.file_name!r}"
                )
                continue

            if not mutation_check.directory_name.startswith("sfptc0003-"):
                failures.append(
                    f"{parent_relative_path}: refusing mutation because tracked directory "
                    "does not use the sfptc0003- safety prefix"
                )
                continue

            if not mutation_check.file_name.startswith("sfptc0003-"):
                failures.append(
                    f"{parent_relative_path}: refusing mutation because tracked file "
                    "does not use the sfptc0003- safety prefix"
                )
                continue

            if not local_parent_path.is_dir():
                failures.append(
                    f"{parent_relative_path}: refusing mutation because parent directory "
                    f"does not already exist locally: {local_parent_path}"
                )
                continue

            if local_test_dir.exists():
                failures.append(
                    f"{parent_relative_path}: refusing mutation because tracked test "
                    f"directory already exists: {local_test_dir}"
                )
                continue

            if local_test_file.exists():
                failures.append(
                    f"{parent_relative_path}: refusing mutation because tracked test "
                    f"file already exists: {local_test_file}"
                )
                continue

            immutable_before_manifest = build_typed_manifest(sync_root)
            write_manifest(baseline_manifest_file, immutable_before_manifest)

            # Safety rule for shared-folder mutation testing:
            # - parent path must already exist from the initial download-only sync
            # - never create shared-folder parent paths
            # - create only one exact tracked child directory below that parent
            # - delete only the exact tracked file and directory created here
            local_test_dir.mkdir()
            write_text_file(local_test_file, mutation_check.content)

            upload_command = [
                context.onedrive_bin,
                "--sync",
                "--verbose",
                "--confdir",
                str(confdir),
            ]
            context.log(
                f"Executing {self.case_id} {scenario.scenario_id} mutation upload "
                f"for {local_test_file.relative_to(sync_root)}: {command_to_string(upload_command)}"
            )
            upload_result = run_command(upload_command, cwd=context.repo_root)
            write_text_file(upload_stdout_file, upload_result.stdout)
            write_text_file(upload_stderr_file, upload_result.stderr)

            if upload_result.returncode != 0:
                failures.append(
                    f"{local_test_file.relative_to(sync_root)}: upload sync exited with "
                    f"non-zero status {upload_result.returncode}"
                )

            if not local_test_file.exists():
                failures.append(
                    f"{local_test_file.relative_to(sync_root)}: tracked test file "
                    "disappeared unexpectedly after upload sync"
                )

            if local_test_file.exists():
                local_test_file.unlink()

            if local_test_dir.exists():
                try:
                    local_test_dir.rmdir()
                except OSError as exc:
                    failures.append(
                        f"{local_test_dir.relative_to(sync_root)}: unable to remove exact "
                        f"tracked test directory after deleting tracked test file: {exc}"
                    )

            cleanup_command = [
                context.onedrive_bin,
                "--sync",
                "--verbose",
                "--confdir",
                str(confdir),
            ]
            context.log(
                f"Executing {self.case_id} {scenario.scenario_id} mutation cleanup "
                f"for {parent_relative_path}/{mutation_check.directory_name}: "
                f"{command_to_string(cleanup_command)}"
            )
            cleanup_result = run_command(cleanup_command, cwd=context.repo_root)
            write_text_file(cleanup_stdout_file, cleanup_result.stdout)
            write_text_file(cleanup_stderr_file, cleanup_result.stderr)

            if cleanup_result.returncode != 0:
                failures.append(
                    f"{parent_relative_path}/{mutation_check.directory_name}: cleanup "
                    f"sync exited with non-zero status {cleanup_result.returncode}"
                )

            verify_command = [
                context.onedrive_bin,
                "--sync",
                "--verbose",
                "--download-only",
                "--resync",
                "--resync-auth",
                "--confdir",
                str(confdir),
            ]
            context.log(
                f"Executing {self.case_id} {scenario.scenario_id} mutation cleanup "
                f"verification for {parent_relative_path}/{mutation_check.directory_name}: "
                f"{command_to_string(verify_command)}"
            )
            verify_result = run_command(verify_command, cwd=context.repo_root)
            write_text_file(verify_stdout_file, verify_result.stdout)
            write_text_file(verify_stderr_file, verify_result.stderr)

            if verify_result.returncode != 0:
                failures.append(
                    f"{parent_relative_path}/{mutation_check.directory_name}: cleanup "
                    f"verification sync exited with non-zero status {verify_result.returncode}"
                )

            immutable_after_manifest = build_typed_manifest(sync_root)
            write_manifest(verify_manifest_file, immutable_after_manifest)

            before_set = set(immutable_before_manifest)
            after_set = set(immutable_after_manifest)
            missing_after = sorted(before_set - after_set)
            unexpected_after = sorted(after_set - before_set)

            mutation_diff_lines: list[str] = []
            if missing_after:
                mutation_diff_lines.append(
                    "Immutable baseline entries disappeared after tracked mutation cleanup: "
                    + repr(missing_after[:50])
                )
            if unexpected_after:
                mutation_diff_lines.append(
                    "Unexpected entries remain after tracked mutation cleanup: "
                    + repr(unexpected_after[:50])
                )
            write_text_file(mutation_diff_file, "\n".join(mutation_diff_lines) + ("\n" if mutation_diff_lines else ""))

            if missing_after:
                failures.append(
                    f"{parent_relative_path}/{mutation_check.directory_name}: immutable "
                    f"baseline changed; missing entries after cleanup: {missing_after[:20]!r}"
                )
            if unexpected_after:
                failures.append(
                    f"{parent_relative_path}/{mutation_check.directory_name}: immutable "
                    f"baseline changed; unexpected entries after cleanup: {unexpected_after[:20]!r}"
                )

            if local_test_file.exists():
                failures.append(
                    f"{local_test_file.relative_to(sync_root)}: tracked test file still "
                    "exists after cleanup verification; remote cleanup may have failed"
                )
                local_test_file.unlink()

            if local_test_dir.exists():
                failures.append(
                    f"{local_test_dir.relative_to(sync_root)}: tracked test directory still "
                    "exists after cleanup verification; remote cleanup may have failed"
                )
                try:
                    local_test_dir.rmdir()
                except OSError:
                    pass

        return failures

    def _write_scenario_config(self, context: E2EContext, config_dir: Path, sync_root: Path) -> Path:
        config_path = context.prepare_minimal_config_dir(
            config_dir,
            "# sfptc0003 Personal Shared Folder sync_list config\n"
            f'sync_dir = "{sync_root}"\n'
            'threads = "2"\n'
            'download_only = "true"\n'
            'cleanup_local_files = "false"\n'
            'bypass_data_preservation = "true"\n',
        )
        return config_path

    def _write_sync_list(self, sync_list_path: Path, sync_list: list[str]) -> None:
        write_text_file(sync_list_path, "\n".join(sync_list) + "\n")

    def _parent_entries_for(self, path: str) -> list[str]:
        parts = path.strip("/").split("/")
        parents: list[str] = []
        for index in range(1, len(parts)):
            parents.append("/".join(parts[:index]) + "/")
        return [entry for entry in parents if entry in EXPECTED_TYPED_MANIFEST]

    def _entries_under(self, *prefixes: str) -> list[str]:
        normalised_prefixes = [prefix.strip("/") for prefix in prefixes]
        entries: list[str] = []
        for prefix in normalised_prefixes:
            entries.extend(self._parent_entries_for(prefix))
        for entry in EXPECTED_TYPED_MANIFEST:
            clean_entry = entry.rstrip("/")
            for prefix in normalised_prefixes:
                if clean_entry == prefix or clean_entry.startswith(prefix + "/"):
                    entries.append(entry)
                    break
        return sorted(set(entries))

    def _entries_exact(self, *entries: str) -> list[str]:
        expected_set = set(EXPECTED_TYPED_MANIFEST)
        selected: list[str] = []
        for entry in entries:
            clean_entry = entry.strip("/")
            selected.extend(self._parent_entries_for(clean_entry))
            if entry in expected_set:
                selected.append(entry)
            elif entry + "/" in expected_set:
                selected.append(entry + "/")
            elif clean_entry in expected_set:
                selected.append(clean_entry)
            elif clean_entry + "/" in expected_set:
                selected.append(clean_entry + "/")
            else:
                selected.append(entry)
        return sorted(set(selected))

    def _exclude_entries(self, entries: list[str], *prefixes: str) -> list[str]:
        normalised_prefixes = [prefix.strip("/") for prefix in prefixes]
        filtered: list[str] = []
        for entry in entries:
            clean_entry = entry.rstrip("/")
            excluded = any(
                clean_entry == prefix or clean_entry.startswith(prefix + "/")
                for prefix in normalised_prefixes
            )
            if not excluded:
                filtered.append(entry)
        return sorted(set(filtered))

    def _marker(self, shared_folder_path: str) -> str:
        return f"Syncing this OneDrive Personal Shared Folder: ./{shared_folder_path.strip('/')}"

    def _build_scenarios(self) -> list[SharedFolderSyncListScenario]:
        core = "SHARED_FOLDERS/SUB_FOLDER_1/CORE"
        core15 = "SHARED_FOLDERS/SUB_FOLDER_1/CORE_15"
        deep = "SHARED_FOLDERS/SUB_FOLDER_1/DEEP_SOURCE"
        tree = "SHARED_FOLDERS/SUB_FOLDER_2/TREE"
        wide = "SHARED_FOLDERS/SUB_FOLDER_2/WIDE_SET"
        renamed = "SHARED_FOLDERS_RENAMED/RENAMED_SHARED_FOLDER"
        minimal = "MINIMAL"
        annas = "Family pictures/Annas pictures"
        bens = "Family pictures/Bens pictures"

        core_without_exclude = self._exclude_entries(
            self._entries_under(core),
            f"{core}/nested/exclude",
        )
        wide_subset = self._entries_exact(
            "SHARED_FOLDERS/SUB_FOLDER_2/",
            f"{wide}/",
            f"{wide}/file00.txt",
            f"{wide}/file01.txt",
            f"{wide}/file02.txt",
        )
        multi_tree = sorted(set(
            self._entries_under(minimal)
            + self._entries_under(renamed)
            + self._entries_exact(f"{deep}/L1/L2/L3/deepfile.txt")
        ))

        return [
            SharedFolderSyncListScenario(
                scenario_id="SL-0001",
                description="rooted include of one shared folder tree with trailing slash",
                sync_list=[f"/{core}/"],
                expected_entries=self._entries_under(core),
                required_present=[f"{core}/README.txt"],
                required_absent=[f"{core15}/README.txt", f"{deep}/L1/L2/L3/deepfile.txt"],
                required_stdout_markers=[self._marker(core)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0002",
                description="rooted include of one shared folder tree without trailing slash",
                sync_list=[f"/{core15}"],
                expected_entries=self._entries_under(core15),
                required_present=[f"{core15}/README.txt"],
                required_absent=[f"{core}/README.txt", f"{deep}/L1/L2/L3/deepfile.txt"],
                required_stdout_markers=[self._marker(core15)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0003",
                description="rooted include of deep shared folder path",
                sync_list=[f"/{deep}/"],
                expected_entries=self._entries_under(deep),
                required_present=[f"{deep}/L1/L2/L3/deepfile.txt"],
                required_absent=[f"{core}/README.txt", f"{tree}/A/B/C/tree.txt"],
                required_stdout_markers=[self._marker(deep)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0004",
                description="include shared folder tree with nested exclusion",
                sync_list=[
                    f"!/{core}/nested/exclude/*",
                    f"/{core}/",
                ],
                expected_entries=core_without_exclude,
                required_present=[f"{core}/nested/keep/keep.txt"],
                required_absent=[f"{core}/nested/exclude/exclude.txt"],
                required_stdout_markers=[self._marker(core)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0005",
                description="file-specific include inside a shared folder",
                sync_list=[f"/{core}/files/data.txt"],
                expected_entries=self._entries_exact(
                    "SHARED_FOLDERS/",
                    "SHARED_FOLDERS/SUB_FOLDER_1/",
                    f"{core}/",
                    f"{core}/files/",
                    f"{core}/files/data.txt",
                ),
                required_present=[f"{core}/files/data.txt"],
                required_absent=[f"{core}/files/image0.png", f"{core}/README.txt"],
                required_stdout_markers=[self._marker(core)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0006",
                description="multiple file-specific includes within one shared folder",
                sync_list=[
                    f"/{wide}/file00.txt",
                    f"/{wide}/file01.txt",
                    f"/{wide}/file02.txt",
                ],
                expected_entries=wide_subset,
                required_present=[f"{wide}/file00.txt", f"{wide}/file02.txt"],
                required_absent=[f"{wide}/file03.txt", f"{wide}/file49.txt"],
                required_stdout_markers=[self._marker(wide)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0007",
                description="include nested tree shared folder and exclude sibling shared folder trees",
                sync_list=[f"/{tree}/"],
                expected_entries=self._entries_under(tree),
                required_present=[f"{tree}/A/B/C/tree.txt"],
                required_absent=[f"{wide}/file00.txt", f"{core}/README.txt"],
                required_stdout_markers=[self._marker(tree)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0008",
                description="mixed includes across minimal renamed and deep shared folders",
                sync_list=[
                    f"/{minimal}/",
                    f"/{renamed}/",
                    f"/{deep}/L1/L2/L3/deepfile.txt",
                ],
                expected_entries=multi_tree,
                required_present=[
                    f"{minimal}/single.txt",
                    f"{renamed}/original.txt",
                    f"{deep}/L1/L2/L3/deepfile.txt",
                ],
                required_absent=[f"{core}/README.txt", f"{wide}/file00.txt"],
                required_stdout_markers=[self._marker(minimal), self._marker(renamed), self._marker(deep)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0009",
                description="include shared folder path containing spaces",
                sync_list=[f"/{annas}/"],
                expected_entries=self._entries_under(annas),
                required_present=[f"{annas}/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image0.png"],
                required_absent=["Family pictures/Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image0.png"],
                required_stdout_markers=[self._marker(annas)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0010",
                description="multiple explicit shared-folder shortcut includes only",
                sync_list=[
                    f"/{core}/",
                    f"/{deep}/",
                    f"/{tree}/",
                ],
                expected_entries=sorted(
                    set(
                        self._entries_under(core)
                        + self._entries_under(deep)
                        + self._entries_under(tree)
                    )
                ),
                required_present=[f"{core}/README.txt", f"{deep}/L1/L2/L3/deepfile.txt", f"{tree}/A/B/C/tree.txt"],
                required_absent=[f"{core15}/README.txt", f"{wide}/file00.txt"],
                required_stdout_markers=[self._marker(core), self._marker(deep), self._marker(tree)],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0011",
                description="safe tracked mutation inside an existing shared-folder directory",
                sync_list=[f"/{tree}/A/B/C/"],
                expected_entries=self._entries_under(f"{tree}/A/B/C"),
                required_present=[f"{tree}/A/B/C/tree.txt"],
                required_absent=[f"{core}/README.txt", f"{wide}/file00.txt"],
                required_stdout_markers=[self._marker(tree)],
                mutation_checks=[
                    SharedFolderMutationCheck(
                        parent_relative_path=f"{tree}/A/B/C",
                        directory_name="sfptc0003-tracked-mutation",
                        file_name="sfptc0003-upload-tree.txt",
                        content="sfptc0003 tracked mutation validation for TREE/A/B/C\n",
                    ),
                ],
            ),
            SharedFolderSyncListScenario(
                scenario_id="SL-0012",
                description="issue 3643 explicit Family pictures shared-folder includes only",
                sync_list=[
                    f"/{annas}/",
                    f"/{bens}/",
                ],
                expected_entries=sorted(
                    set(
                        self._entries_under(annas)
                        + self._entries_under(bens)
                    )
                ),
                required_present=[
                    f"{annas}/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image0.png",
                    f"{bens}/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image0.png",
                ],
                required_absent=[
                    "Annas pictures/",
                    "Bens pictures/",
                    "Annas pictures/4DiNZfTkCOlazjoQlDIVDh4VglcbENhA/image0.png",
                    "Bens pictures/7X2tH5TX0aiCXuNs8SBOk4lZqDS2qfEA/image0.png",
                ],
                required_stdout_markers=[self._marker(annas), self._marker(bens)],
            ),
        ]
