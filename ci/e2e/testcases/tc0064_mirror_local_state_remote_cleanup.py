from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, reset_directory, run_command, write_onedrive_config, write_text_file


class TestCase0064MirrorLocalStateRemoteCleanup(E2ETestCase):
    case_id = "0064"
    name = "mirror local state remote cleanup"
    description = (
        "Validate that --mirror-local-state with local_first enabled treats the local tree "
        "as authoritative during a resync and deletes remote-only files and folders instead "
        "of downloading them"
    )

    def _write_config(self, config_path: Path, sync_dir: Path) -> None:
        content = (
            "# tc0064 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'local_first = "true"\n'
        )
        write_onedrive_config(config_path, content)

    def _run_phase(
        self,
        *,
        context: E2EContext,
        label: str,
        command: list[str],
        stdout_file: Path,
        stderr_file: Path,
    ):
        context.log(f"Executing Test Case {self.case_id} {label}: {command_to_string(command)}")
        result = run_command(command, cwd=context.repo_root)
        write_text_file(stdout_file, result.stdout)
        write_text_file(stderr_file, result.stderr)
        return result

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0064",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        sync_root = case_work_dir / "syncroot"
        verify_root = case_work_dir / "verifyroot"

        conf_main = case_work_dir / "conf-main"
        conf_verify = case_work_dir / "conf-verify"

        for path in [sync_root, verify_root]:
            reset_directory(path)

        root_name = f"ZZ_E2E_TC0064_{context.run_id}_{os.getpid()}"

        retained_files = {
            f"{root_name}/keep-root.txt": "TC0064 retained root file\n",
            f"{root_name}/keep-dir/keep-nested.txt": "TC0064 retained nested file\n",
        }
        removed_files = {
            f"{root_name}/remote-only-root-1.txt": "TC0064 remote-only root file 1\n",
            f"{root_name}/remote-only-root-2.txt": "TC0064 remote-only root file 2\n",
            f"{root_name}/remote-only-parent/remote-only-child-1.txt": "TC0064 remote-only child file 1\n",
            f"{root_name}/remote-only-parent/remote-only-child-2.txt": "TC0064 remote-only child file 2\n",
        }
        removed_directory = f"{root_name}/remote-only-parent"

        # Seed the local tree with everything, then upload it all.  This is the
        # only phase that intentionally uses --upload-only.  local_first is
        # enabled for the whole test via configuration.
        for relative_path, content in {**retained_files, **removed_files}.items():
            write_text_file(sync_root / relative_path, content)

        context.bootstrap_config_dir(conf_main)
        self._write_config(conf_main / "config", sync_root)
        context.bootstrap_config_dir(conf_verify)
        self._write_config(conf_verify / "config", verify_root)

        phase_files = {
            "seed": (case_log_dir / "phase1_seed_stdout.log", case_log_dir / "phase1_seed_stderr.log"),
            "local_delete": (case_log_dir / "phase2_local_delete_stdout.log", case_log_dir / "phase2_local_delete_stderr.log"),
            "mirror_cleanup": (case_log_dir / "phase3_mirror_cleanup_stdout.log", case_log_dir / "phase3_mirror_cleanup_stderr.log"),
            "verify": (case_log_dir / "phase4_verify_stdout.log", case_log_dir / "phase4_verify_stderr.log"),
        }

        local_manifest_after_delete_file = state_dir / "local_manifest_after_delete.txt"
        verify_manifest_file = state_dir / "remote_truth_manifest_after_cleanup.txt"
        metadata_file = state_dir / "metadata.txt"

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--upload-only",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        seed_result = self._run_phase(
            context=context,
            label="seed",
            command=seed_command,
            stdout_file=phase_files["seed"][0],
            stderr_file=phase_files["seed"][1],
        )

        local_delete_log: list[str] = []
        for relative_path in [
            f"{root_name}/remote-only-root-1.txt",
            f"{root_name}/remote-only-root-2.txt",
        ]:
            target = sync_root / relative_path
            if target.exists():
                target.unlink()
                local_delete_log.append(f"Deleted local file: {relative_path}")
            else:
                local_delete_log.append(f"Local file already missing: {relative_path}")

        removed_directory_path = sync_root / removed_directory
        if removed_directory_path.exists():
            shutil.rmtree(removed_directory_path)
            local_delete_log.append(f"Deleted local directory tree: {removed_directory}")
        else:
            local_delete_log.append(f"Local directory tree already missing: {removed_directory}")

        write_text_file(phase_files["local_delete"][0], "\n".join(local_delete_log) + "\n")
        write_text_file(phase_files["local_delete"][1], "")
        local_manifest_after_delete = build_manifest(sync_root)
        write_manifest(local_manifest_after_delete_file, local_manifest_after_delete)

        # This is the feature validation phase.  The local state is deliberately
        # missing files/folders that exist online.  The resync discards local DB
        # state, pulls the current online JSON state, then --mirror-local-state
        # must delete those remote-only items instead of downloading them.
        mirror_cleanup_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--mirror-local-state",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_main),
        ]
        mirror_cleanup_result = self._run_phase(
            context=context,
            label="mirror cleanup",
            command=mirror_cleanup_command,
            stdout_file=phase_files["mirror_cleanup"][0],
            stderr_file=phase_files["mirror_cleanup"][1],
        )

        # Verification also avoids --download-only.  A clean normal sync against
        # an empty verification sync_dir should download only the surviving
        # remote state after mirror cleanup has completed.
        verify_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--single-directory",
            root_name,
            "--confdir",
            str(conf_verify),
        ]
        verify_result = self._run_phase(
            context=context,
            label="verify",
            command=verify_command,
            stdout_file=phase_files["verify"][0],
            stderr_file=phase_files["verify"][1],
        )

        sync_manifest_after_cleanup = build_manifest(sync_root)
        verify_manifest = build_manifest(verify_root)
        sync_manifest_after_cleanup_file = state_dir / "local_manifest_after_mirror_cleanup.txt"
        write_manifest(sync_manifest_after_cleanup_file, sync_manifest_after_cleanup)
        write_manifest(verify_manifest_file, verify_manifest)

        cleanup_output = f"{mirror_cleanup_result.stdout}\n{mirror_cleanup_result.stderr}"

        expected_retained = sorted(retained_files)
        expected_removed = sorted(removed_files)
        unexpected_local_remote_only_after_delete = [path for path in expected_removed if path in local_manifest_after_delete]
        unexpected_local_remote_only_after_cleanup = [path for path in expected_removed if path in sync_manifest_after_cleanup]
        unexpected_verify_remote_only = [path for path in expected_removed if path in verify_manifest]
        missing_local_retained_after_delete = [path for path in expected_retained if path not in local_manifest_after_delete]
        missing_local_retained_after_cleanup = [path for path in expected_retained if path not in sync_manifest_after_cleanup]
        missing_verify_retained = [path for path in expected_retained if path not in verify_manifest]

        deletion_markers = [
            "--mirror-local-state",
            "mirror-local-state",
            "mirror_local_state",
            "Deleting online file from Microsoft OneDrive:",
            "Deleting online folder from Microsoft OneDrive:",
            "Number of items to remove from Microsoft OneDrive due to",
        ]
        observed_deletion_markers = [marker for marker in deletion_markers if marker in cleanup_output]

        disallowed_feature_phase_flags = ["--upload-only", "--download-only"]
        feature_commands = {
            "mirror_cleanup_command": command_to_string(mirror_cleanup_command),
            "verify_command": command_to_string(verify_command),
        }
        disallowed_flag_hits = {
            label: [flag for flag in disallowed_feature_phase_flags if flag in command]
            for label, command in feature_commands.items()
        }
        disallowed_flag_hits = {label: flags for label, flags in disallowed_flag_hits.items() if flags}

        details = {
            "root_name": root_name,
            "retained_files": expected_retained,
            "removed_files": expected_removed,
            "removed_directory": removed_directory,
            "seed_returncode": seed_result.returncode,
            "mirror_cleanup_returncode": mirror_cleanup_result.returncode,
            "verify_returncode": verify_result.returncode,
            "missing_local_retained_after_delete": missing_local_retained_after_delete,
            "missing_local_retained_after_cleanup": missing_local_retained_after_cleanup,
            "missing_verify_retained": missing_verify_retained,
            "unexpected_local_remote_only_after_delete": unexpected_local_remote_only_after_delete,
            "unexpected_local_remote_only_after_cleanup": unexpected_local_remote_only_after_cleanup,
            "unexpected_verify_remote_only": unexpected_verify_remote_only,
            "observed_deletion_markers": observed_deletion_markers,
            "disallowed_flag_hits": disallowed_flag_hits,
            "seed_command": command_to_string(seed_command),
            "mirror_cleanup_command": command_to_string(mirror_cleanup_command),
            "verify_command": command_to_string(verify_command),
        }

        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

        artifacts = [
            *(str(path) for pair in phase_files.values() for path in pair),
            str(local_manifest_after_delete_file),
            str(sync_manifest_after_cleanup_file),
            str(verify_manifest_file),
            str(metadata_file),
        ]

        for label, rc in [
            ("seed", seed_result.returncode),
            ("mirror cleanup", mirror_cleanup_result.returncode),
            ("verify", verify_result.returncode),
        ]:
            if rc != 0:
                return self.fail_result(
                    self.case_id,
                    self.name,
                    f"{label} phase failed with status {rc}",
                    artifacts,
                    details,
                )

        if disallowed_flag_hits:
            return self.fail_result(
                self.case_id,
                self.name,
                "Feature validation phases used --upload-only or --download-only",
                artifacts,
                details,
            )
        if missing_local_retained_after_delete:
            return self.fail_result(
                self.case_id,
                self.name,
                "Local source-of-truth preparation removed files that should be retained",
                artifacts,
                details,
            )
        if unexpected_local_remote_only_after_delete:
            return self.fail_result(
                self.case_id,
                self.name,
                "Local source-of-truth preparation did not remove all selected local content",
                artifacts,
                details,
            )
        if missing_local_retained_after_cleanup:
            return self.fail_result(
                self.case_id,
                self.name,
                "Mirror cleanup lost retained local source-of-truth files",
                artifacts,
                details,
            )
        if unexpected_local_remote_only_after_cleanup:
            return self.fail_result(
                self.case_id,
                self.name,
                "Mirror cleanup downloaded remote-only items instead of deleting them online",
                artifacts,
                details,
            )
        if missing_verify_retained:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote verification is missing retained files after mirror cleanup",
                artifacts,
                details,
            )
        if unexpected_verify_remote_only:
            return self.fail_result(
                self.case_id,
                self.name,
                "Remote verification still contains remote-only items after mirror cleanup",
                artifacts,
                details,
            )
        if not observed_deletion_markers:
            return self.fail_result(
                self.case_id,
                self.name,
                "Mirror cleanup output did not contain expected remote delete markers",
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
