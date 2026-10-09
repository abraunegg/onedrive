from __future__ import annotations

import os
import shutil
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file


class TestCase0084RemoteBatchDeletionReconciliation(E2ETestCase):
    """Reconcile remotely deleted tracked objects using an authoritative full scan.

    This tests recovery from stale database/local entries described in #3775.
    It does not attempt to force Microsoft Graph to omit /delta tombstones.
    The observer must remain stopped while the independent mutator deletes the
    objects, and its reconciliation must not use --resync or --single-directory.
    """

    case_id = "0084"
    name = "authoritative remote batch deletion reconciliation"
    description = (
        "Validate that a forced /children full scan removes stale tracked files "
        "and directories after independent remote batch deletion, without resync "
        "or resurrection of deleted remote objects"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0084", ensure_refresh_token=True)
        work_dir = layout.work_dir
        log_dir = layout.log_dir
        state_dir = layout.state_dir

        mutator_root = work_dir / "mutator-root"
        subject_root = work_dir / "subject-root"
        before_verify_root = work_dir / "before-verify-root"
        after_verify_root = work_dir / "after-verify-root"
        conf_mutator = work_dir / "conf-mutator"
        conf_subject = work_dir / "conf-subject"
        conf_before_verify = work_dir / "conf-before-verify"
        conf_after_verify = work_dir / "conf-after-verify"
        root_name = f"ZZ_E2E_TC0084_{context.run_id}_{os.getpid()}"
        metadata_file = state_dir / "metadata.txt"

        # Deliberately large enough to cover several nested branches, but not
        # a stress workload against the shared CI OneDrive account.
        deleted_files = {
            f"{root_name}/Batch/Group{group:02d}/item{item:02d}.txt":
                f"TC0084 remotely deleted group={group} item={item}\n"
            for group in range(6) for item in range(6)
        }
        deleted_files[f"{root_name}/Singles/removed.txt"] = "TC0084 removed single file\n"
        keep_files = {
            f"{root_name}/anchor.txt": "TC0084 anchor survives remote batch deletion\n",
            f"{root_name}/Survivor/Nested/keep.txt": "TC0084 nested survivor\n",
        }
        removed_directories = [f"{root_name}/Batch", f"{root_name}/EmptyRemoved"]
        expected_final = sorted([
            f"{root_name}/", f"{root_name}/Survivor/", f"{root_name}/Survivor/Nested/",
            f"{root_name}/Singles/", *keep_files,
        ])
        phase_names = (
            "seed", "subject_initial", "remote_delete", "remote_before",
            "subject_reconcile", "subject_converge", "remote_after",
        )
        artifacts = [
            str(log_dir / f"{phase}_{stream}.log")
            for phase in phase_names for stream in ("stdout", "stderr")
        ]
        artifacts.extend(str(state_dir / name) for name in (
            "seed_manifest.txt", "subject_initial_manifest.txt", "remote_before_manifest.txt",
            "subject_final_manifest.txt", "remote_after_manifest.txt", "metadata.txt",
        ))
        details: dict[str, object] = {
            "root_name": root_name,
            "deleted_file_count": len(deleted_files),
            "deleted_directory_roots": removed_directories,
            "subject_force_children_scan": True,
        }

        context.prepare_minimal_config_dir(
            conf_mutator,
            f'# tc0084 independent remote mutator\nsync_dir = "{mutator_root}"\n'
            'bypass_data_preservation = "true"\n',
        )
        context.prepare_minimal_config_dir(
            conf_subject,
            f'# tc0084 tracked authoritative observer\nsync_dir = "{subject_root}"\n'
            'force_children_scan = "true"\n'
            'bypass_data_preservation = "false"\n',
        )
        # The observer uses sync_list instead of --single-directory. The latter
        # would select /children by itself and weaken this regression test.
        write_text_file(conf_subject / "sync_list", f"/{root_name}\n")
        for conf_dir, sync_root in (
            (conf_before_verify, before_verify_root),
            (conf_after_verify, after_verify_root),
        ):
            context.prepare_minimal_config_dir(
                conf_dir,
                f'# tc0084 independent remote verifier\nsync_dir = "{sync_root}"\n'
                'bypass_data_preservation = "true"\n',
            )

        for relative, content in {**deleted_files, **keep_files}.items():
            write_text_file(mutator_root / relative, content)
        (mutator_root / root_name / "EmptyRemoved").mkdir(parents=True, exist_ok=True)

        mutator_command = [
            context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
            "--verbose", "--single-directory", root_name,
            "--confdir", str(conf_mutator),
        ]
        subject_command = [
            context.onedrive_bin, "--display-running-config", "--sync",
            "--verbose", "--confdir", str(conf_subject),
        ]

        def fail(reason: str) -> TestResult:
            self.write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, reason, artifacts, details)

        def execute(phase: str, command: list[str]):
            context.log(f"Executing Test Case {self.case_id} {phase}: {command_to_string(command)}")
            result = run_command(command, cwd=context.repo_root)
            write_text_file(log_dir / f"{phase}_stdout.log", result.stdout)
            write_text_file(log_dir / f"{phase}_stderr.log", result.stderr)
            details[f"{phase}_returncode"] = result.returncode
            details[f"{phase}_command"] = command_to_string(command)
            return result

        seed = execute("seed", mutator_command + ["--resync", "--resync-auth"])
        if seed.returncode != 0 or not (conf_mutator / "items.sqlite3").is_file():
            return fail("mutator seed did not complete or establish an item database")
        seed_manifest = build_typed_manifest(mutator_root)
        write_manifest(state_dir / "seed_manifest.txt", seed_manifest)

        initial = execute("subject_initial", subject_command + ["--resync", "--resync-auth"])
        if initial.returncode != 0 or not (conf_subject / "items.sqlite3").is_file():
            return fail("initial tracked observer download did not establish an item database")
        initial_manifest = build_typed_manifest(subject_root)
        write_manifest(state_dir / "subject_initial_manifest.txt", initial_manifest)
        if initial_manifest != seed_manifest:
            return fail("observer did not acquire the complete tracked pre-deletion hierarchy")
        for relative, content in {**deleted_files, **keep_files}.items():
            if not (subject_root / relative).is_file() or (subject_root / relative).read_text(encoding="utf-8") != content:
                return fail(f"initial tracked observer content mismatch: {relative}")

        # Mutator owns the remote delete; the subject is stopped, with its
        # pre-deletion database and files untouched until authoritative scan.
        shutil.rmtree(mutator_root / removed_directories[0])
        (mutator_root / removed_directories[1]).rmdir()
        (mutator_root / f"{root_name}/Singles/removed.txt").unlink()
        deleted = execute("remote_delete", mutator_command)
        if deleted.returncode != 0:
            return fail("independent mutator batch remote deletion failed")

        before = execute("remote_before", [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
            "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_before_verify),
        ])
        if before.returncode != 0:
            return fail("fresh independent verifier failed before observer reconciliation")
        before_manifest = build_typed_manifest(before_verify_root)
        write_manifest(state_dir / "remote_before_manifest.txt", before_manifest)
        if before_manifest != expected_final:
            return fail("remote deletion not confirmed before observer reconciliation")
        # Explicitly establish that the subject really is stale: absent online,
        # still present locally, with its original database retained.
        if not all((subject_root / relative).is_file() for relative in deleted_files):
            return fail("observer lost tracked files before authoritative reconciliation")
        if not (subject_root / removed_directories[0]).is_dir():
            return fail("observer no longer contains stale directory before reconciliation")

        reconciled = execute("subject_reconcile", subject_command)
        if reconciled.returncode != 0:
            return fail("authoritative /children observer reconciliation failed")
        if "Forcing client to use /children API call rather than /delta API" not in reconciled.stdout:
            return fail("observer did not confirm forced /children traversal in application logs")
        for phase, outcome in (("subject_reconcile", reconciled),):
            if any(marker in outcome.stdout for marker in (
                "Uploading file:", "Successfully created the remote directory",
                "Successfully deleted the item from Microsoft OneDrive",
            )):
                return fail(f"unexpected remote upload/create/delete during {phase}")
        final_manifest = build_typed_manifest(subject_root)
        write_manifest(state_dir / "subject_final_manifest.txt", final_manifest)
        if final_manifest != expected_final:
            return fail("authoritative reconciliation did not remove stale tracked items")

        converged = execute("subject_converge", subject_command)
        if converged.returncode != 0 or build_typed_manifest(subject_root) != expected_final:
            return fail("observer did not converge to stable authoritative remote state")
        if any(marker in converged.stdout for marker in (
            "Uploading file:", "Successfully created the remote directory",
            "Successfully deleted the item from Microsoft OneDrive",
        )):
            return fail("unexpected remote mutation during observer convergence")

        after = execute("remote_after", [
            context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
            "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_after_verify),
        ])
        if after.returncode != 0:
            return fail("fresh independent remote verifier failed after reconciliation")
        after_manifest = build_typed_manifest(after_verify_root)
        write_manifest(state_dir / "remote_after_manifest.txt", after_manifest)
        if after_manifest != expected_final:
            return fail("remote paths were recreated or remote survivors changed")
        for root in (subject_root, before_verify_root, after_verify_root):
            for relative, content in keep_files.items():
                file_path = root / relative
                if not file_path.is_file() or file_path.read_text(encoding="utf-8") != content:
                    return fail(f"surviving content mismatch at {root.name}: {relative}")
            if any("safeBackup" in p.name or ".partial" in p.name for p in root.rglob("*")):
                return fail(f"unexpected backup or partial file at {root.name}")

        details["expected_final_manifest"] = expected_final
        details["subject_final_manifest"] = final_manifest
        details["remote_after_manifest"] = after_manifest
        self.write_metadata(metadata_file, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
