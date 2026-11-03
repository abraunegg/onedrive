from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file


class TestCase0082SingleDirectoryDeleteReconciliation(E2ETestCase):
    case_id = "0082"
    name = "single-directory tracked deletion reconciliation"
    description = (
        "Validate that a scoped sync propagates tracked file and nested-directory "
        "deletions without restoring removed paths or changing surviving content"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0082", ensure_refresh_token=True)
        work_dir = layout.work_dir
        log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = work_dir / "syncroot"
        verify_root = work_dir / "verifyroot"
        conf_main = work_dir / "conf-main"
        conf_verify = work_dir / "conf-verify"
        root_name = f"ZZ_E2E_TC0082_{context.run_id}_{os.getpid()}"

        # These paths are all below the test-owned --single-directory scope.
        keep_files = {
            f"{root_name}/anchor.txt": "TC0082 anchor remains present\n",
            f"{root_name}/Survivor/Nested/keep.txt": "TC0082 nested survivor remains present\n",
        }
        deleted_files = {
            f"{root_name}/delete-top.txt": "TC0082 tracked top-level deletion\n",
            f"{root_name}/Survivor/delete-inside.txt": "TC0082 tracked nested deletion\n",
            f"{root_name}/RemoveTree/Deep/child.txt": "TC0082 tracked subtree deletion\n",
        }
        deleted_directories = [
            f"{root_name}/RemoveTree",
            f"{root_name}/EmptyToRemove",
        ]
        expected_final = sorted([
            f"{root_name}/",
            f"{root_name}/anchor.txt",
            f"{root_name}/Survivor/",
            f"{root_name}/Survivor/Nested/",
            f"{root_name}/Survivor/Nested/keep.txt",
        ])
        forbidden = list(deleted_files) + deleted_directories

        context.prepare_minimal_config_dir(
            conf_main,
            f'# tc0082 subject config\nsync_dir = "{sync_root}"\n'
            'bypass_data_preservation = "true"\n',
        )
        context.prepare_minimal_config_dir(
            conf_verify,
            f'# tc0082 verifier config\nsync_dir = "{verify_root}"\n'
            'bypass_data_preservation = "true"\n',
        )

        for relative, contents in {**keep_files, **deleted_files}.items():
            write_text_file(sync_root / relative, contents)
        (sync_root / root_name / "EmptyToRemove").mkdir(parents=True, exist_ok=True)

        phase_names = ("seed", "delete", "convergence", "verify")
        artifacts = [str(log_dir / f"{phase}_{stream}.log")
                     for phase in phase_names for stream in ("stdout", "stderr")]
        artifacts.extend(str(state_dir / name) for name in (
            "seed_manifest.txt", "mutated_manifest.txt", "final_manifest.txt",
            "remote_manifest.txt", "metadata.txt",
        ))
        details: dict[str, object] = {"root_name": root_name, "deleted_paths": forbidden}
        metadata_file = state_dir / "metadata.txt"

        subject_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--single-directory", root_name, "--confdir", str(conf_main),
        ]
        verify_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
            "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_verify),
        ]

        # Use the same run_command + captured stdout/stderr pattern as TC0040.
        # The subject deliberately retains its database between all three syncs.
        for phase in phase_names:
            if phase == "delete":
                for relative in deleted_files:
                    (sync_root / relative).unlink()
                shutil.rmtree(sync_root / deleted_directories[0])
                (sync_root / deleted_directories[1]).rmdir()
                write_manifest(state_dir / "mutated_manifest.txt", build_typed_manifest(sync_root))
            if phase == "convergence":
                write_manifest(state_dir / "final_manifest.txt", build_typed_manifest(sync_root))

            command = verify_command if phase == "verify" else subject_command
            context.log(f"Executing Test Case {self.case_id} {phase}: {command_to_string(command)}")
            result = run_command(command, cwd=context.repo_root)
            write_text_file(log_dir / f"{phase}_stdout.log", result.stdout)
            write_text_file(log_dir / f"{phase}_stderr.log", result.stderr)
            details[f"{phase}_returncode"] = result.returncode
            details[f"{phase}_command"] = command_to_string(command)
            if phase == "seed":
                write_manifest(state_dir / "seed_manifest.txt", build_typed_manifest(sync_root))
            if phase == "verify":
                write_manifest(state_dir / "remote_manifest.txt", build_typed_manifest(verify_root))

            if result.returncode != 0:
                write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
                return self.fail_result(self.case_id, self.name, f"{phase} sync failed with status {result.returncode}", artifacts, details)

            observed_root = verify_root if phase == "verify" else sync_root
            observed = build_typed_manifest(observed_root)
            details[f"{phase}_manifest"] = observed
            if phase == "seed":
                expected_seed = sorted(expected_final + [
                    f"{root_name}/delete-top.txt", f"{root_name}/Survivor/delete-inside.txt",
                    f"{root_name}/RemoveTree/", f"{root_name}/RemoveTree/Deep/",
                    f"{root_name}/RemoveTree/Deep/child.txt", f"{root_name}/EmptyToRemove/",
                ])
                if observed != expected_seed:
                    write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
                    return self.fail_result(self.case_id, self.name, "seed tree did not establish the expected tracked local state", artifacts, details)
                if not (conf_main / "items.sqlite3").is_file():
                    self.write_metadata(metadata_file, details)
                    return self.fail_result(self.case_id, self.name, "seed did not create the subject item database", artifacts, details)
            else:
                if observed != expected_final:
                    write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
                    return self.fail_result(self.case_id, self.name, f"{phase}: deleted paths were restored or surviving tree differs from expected state", artifacts, details)
                for relative, contents in keep_files.items():
                    path = observed_root / relative
                    if not path.is_file() or path.read_text(encoding="utf-8") != contents:
                        return self.fail_result(self.case_id, self.name, f"{phase}: surviving file changed: {relative}", artifacts, details)

        # A fresh independent remote enumeration has confirmed the deletions.
        # A repeated subject sync must also have converged without resurrecting them.
        write_text_file(metadata_file, "\n".join(f"{k}={v!r}" for k, v in sorted(details.items())) + "\n")
        return self.pass_result(self.case_id, self.name, artifacts, details)
