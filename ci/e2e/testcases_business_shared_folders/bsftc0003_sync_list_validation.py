from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_text_file
from testcases_business_shared_folders.shared_folder_common import (
    REQUIRED_TYPED_MANIFEST_ENTRIES,
    case_sync_root,
    reset_local_sync_root,
)


CONFIG_FILE_NAME = "config"
SYNC_LIST_FILE_NAME = "sync_list"


@dataclass
class BusinessSharedFolderSyncListScenario:
    scenario_id: str
    description: str
    sync_list: list[str]
    expected_entries: list[str]
    required_present: list[str] = field(default_factory=list)
    required_absent: list[str] = field(default_factory=list)
    required_stdout_markers: list[str] = field(default_factory=list)


class BusinessSharedFolderTestCase0003SyncListValidation(E2ETestCase):
    case_id = "bsftc0003"
    name = "business shared folders sync_list validation"
    description = (
        "Validate sync_list include/exclude behaviour across preserved Business Account "
        "shared-folder shortcut topology without leaking unrelated account content"
    )

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

            diffs: list[str] = []
            if result.returncode != 0:
                diffs.append(f"onedrive exited with non-zero status {result.returncode}")
            if missing_stdout_markers:
                diffs.append(
                    "Expected Business shared-folder stdout markers were not present: "
                    + ", ".join(missing_stdout_markers)
                )
            if missing_entries:
                diffs.append(f"Missing expected local entries: {missing_entries[:20]!r}")
            if unexpected_entries:
                diffs.append(
                    "Unexpected local entries were created; possible sync_list leak: "
                    + repr(unexpected_entries[:20])
                )
            if missing_required_present:
                diffs.append(f"Required included entries were missing: {missing_required_present!r}")
            if unexpected_required_absent:
                diffs.append(f"Required excluded entries were present locally: {unexpected_required_absent!r}")

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
                f"{len(failures)} of {len(scenarios)} Business shared-folder sync_list scenarios failed: "
                + ", ".join(failure.split(":", 1)[0] for failure in failures),
                all_artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, all_artifacts, details)

    def _write_scenario_config(self, context: E2EContext, config_dir: Path, sync_root: Path) -> Path:
        config_path = context.prepare_minimal_config_dir(
            config_dir,
            "# bsftc0003 Business Shared Folder sync_list config\n"
            f'sync_dir = "{sync_root}"\n'
            'threads = "2"\n'
            'download_only = "true"\n'
            'sync_business_shared_items = "true"\n'
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
        return [entry for entry in parents if entry in REQUIRED_TYPED_MANIFEST_ENTRIES]

    def _entries_under(self, *prefixes: str) -> list[str]:
        normalised_prefixes = [prefix.strip("/") for prefix in prefixes]
        entries: list[str] = []
        for prefix in normalised_prefixes:
            entries.extend(self._parent_entries_for(prefix))
        for entry in REQUIRED_TYPED_MANIFEST_ENTRIES:
            clean_entry = entry.rstrip("/")
            for prefix in normalised_prefixes:
                if clean_entry == prefix or clean_entry.startswith(prefix + "/"):
                    entries.append(entry)
                    break
        return sorted(set(entries))

    def _entries_exact(self, *entries: str) -> list[str]:
        expected_set = set(REQUIRED_TYPED_MANIFEST_ENTRIES)
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
        return f"Syncing this OneDrive Business Shared Folder: {shared_folder_path.strip('/')}"

    def _build_scenarios(self) -> list[BusinessSharedFolderSyncListScenario]:
        core = "Documents/BSF_CORE"
        mixed = "Documents/BSF_MIXED_FILES"
        core_dataset_b = f"{core}/DATASET_B"
        core_files = f"{core_dataset_b}/files"
        core_nested = f"{core_dataset_b}/nested"
        core_keep = f"{core_nested}/keep"
        core_exclude = f"{core_nested}/exclude"
        core_deep_log = f"{core}/TOP_LEVEL/PROJECTS/2026/Week10/debug_output.log"
        mixed_dataset_a = f"{mixed}/DATASET_A"
        mixed_deep = f"{mixed}/DATASET_B/L1/L2/L3"

        core_without_exclude = self._exclude_entries(
            self._entries_under(core),
            core_exclude,
        )
        presentation_subset = self._entries_exact(
            f"{mixed_dataset_a}/Presentation1.pptx",
            f"{mixed_dataset_a}/Presentation2.pptx",
            f"{mixed_dataset_a}/Presentation3.pptx",
        )
        multi_tree = sorted(set(
            self._entries_under(core_keep)
            + self._entries_exact(f"{mixed_deep}/deepfile.txt")
            + self._entries_exact(core_deep_log)
        ))

        return [
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0001",
                description="rooted include of BSF_CORE shared folder tree with trailing slash",
                sync_list=[f"/{core}/"],
                expected_entries=self._entries_under(core),
                required_present=[f"{core}/DATASET_A/Document1.docx", f"{core_dataset_b}/README.txt"],
                required_absent=[f"{mixed_dataset_a}/Document2.docx", "Documents/BSF_FILTER_MATRIX/MINIMAL/single.txt"],
                required_stdout_markers=[self._marker(core)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0002",
                description="rooted include of BSF_MIXED_FILES shared folder tree without trailing slash",
                sync_list=[f"/{mixed}"],
                expected_entries=self._entries_under(mixed),
                required_present=[f"{mixed_dataset_a}/Document2.docx", f"{mixed_deep}/deepfile.txt"],
                required_absent=[f"{core_dataset_b}/README.txt", "Documents/BSF_FILTER_MATRIX/MINIMAL/single.txt"],
                required_stdout_markers=[self._marker(mixed)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0003",
                description="rooted include of deep path below a Business shared folder",
                sync_list=[f"/{mixed_deep}/"],
                expected_entries=self._entries_under(mixed_deep),
                required_present=[f"{mixed_deep}/deepfile.txt", f"{mixed_deep}/upload-target/"],
                required_absent=[f"{mixed_dataset_a}/Document2.docx", f"{core_dataset_b}/README.txt"],
                required_stdout_markers=[self._marker(mixed)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0004",
                description="include BSF_CORE shared folder tree with nested exclusion",
                sync_list=[
                    f"!/{core_exclude}/*",
                    f"/{core}/",
                ],
                expected_entries=core_without_exclude,
                required_present=[f"{core_keep}/keep.txt", f"{core_files}/data.txt"],
                required_absent=[f"{core_exclude}/exclude.txt", f"{mixed_dataset_a}/Document2.docx"],
                required_stdout_markers=[self._marker(core)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0005",
                description="file-specific include inside a Business shared folder",
                sync_list=[f"/{core_files}/data.txt"],
                expected_entries=self._entries_exact(f"{core_files}/data.txt"),
                required_present=[f"{core_files}/data.txt"],
                required_absent=[f"{core_files}/image0.png", f"{core_dataset_b}/README.txt", f"{mixed_dataset_a}/Document2.docx"],
                required_stdout_markers=[self._marker(core)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0006",
                description="multiple file-specific includes within one Business shared folder",
                sync_list=[
                    f"/{mixed_dataset_a}/Presentation1.pptx",
                    f"/{mixed_dataset_a}/Presentation2.pptx",
                    f"/{mixed_dataset_a}/Presentation3.pptx",
                ],
                expected_entries=presentation_subset,
                required_present=[f"{mixed_dataset_a}/Presentation1.pptx", f"{mixed_dataset_a}/Presentation3.pptx"],
                required_absent=[f"{mixed_dataset_a}/Presentation4.pptx", f"{mixed_dataset_a}/Document2.docx", f"{core_dataset_b}/README.txt"],
                required_stdout_markers=[self._marker(mixed)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0007",
                description="globbing include for one file below a Business shared-folder directory tree",
                sync_list=[f"/{core}/TOP_LEVEL/**/debug_output.log"],
                expected_entries=self._entries_exact(core_deep_log),
                required_present=[core_deep_log],
                required_absent=[f"{core_dataset_b}/README.txt", f"{mixed_deep}/deepfile.txt"],
                required_stdout_markers=[self._marker(core)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0008",
                description="mixed explicit includes across both Business shared folders",
                sync_list=[
                    f"/{core_keep}/",
                    f"/{mixed_deep}/deepfile.txt",
                    f"/{core_deep_log}",
                ],
                expected_entries=multi_tree,
                required_present=[f"{core_keep}/keep.txt", f"{mixed_deep}/deepfile.txt", core_deep_log],
                required_absent=[f"{core_exclude}/exclude.txt", f"{mixed_dataset_a}/Document2.docx"],
                required_stdout_markers=[self._marker(core), self._marker(mixed)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0009",
                description="wildcard include within a Business shared folder subtree",
                sync_list=[f"/{mixed_dataset_a}/Presentation*.pptx"],
                expected_entries=self._entries_exact(
                    f"{mixed_dataset_a}/Presentation1.pptx",
                    f"{mixed_dataset_a}/Presentation2.pptx",
                    f"{mixed_dataset_a}/Presentation3.pptx",
                    f"{mixed_dataset_a}/Presentation4.pptx",
                    f"{mixed_dataset_a}/Presentation5.pptx",
                ),
                required_present=[f"{mixed_dataset_a}/Presentation1.pptx", f"{mixed_dataset_a}/Presentation5.pptx"],
                required_absent=[f"{mixed_dataset_a}/Document2.docx", f"{core_dataset_b}/README.txt"],
                required_stdout_markers=[self._marker(mixed)],
            ),
            BusinessSharedFolderSyncListScenario(
                scenario_id="SL-0010",
                description="wildcard exclusion below an included Business shared folder subtree",
                sync_list=[
                    f"!/{core_files}/image*",
                    f"/{core_dataset_b}/",
                ],
                expected_entries=self._exclude_entries(
                    self._entries_under(core_dataset_b),
                    f"{core_files}/image0.png",
                    f"{core_files}/image1.png",
                ),
                required_present=[f"{core_dataset_b}/README.txt", f"{core_files}/data.txt", f"{core_keep}/keep.txt"],
                required_absent=[f"{core_files}/image0.png", f"{core_files}/image1.png", f"{mixed_dataset_a}/Document2.docx"],
                required_stdout_markers=[self._marker(core)],
            ),
        ]
