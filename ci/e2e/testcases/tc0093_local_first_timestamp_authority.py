from __future__ import annotations

import os
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_manifest, diff_tree_snapshots, snapshot_tree
from framework.utils import compute_quickxor_hash_file, reset_directory, write_text_file
from testcases.safe_backup_case_base import SafeBackupCaseBase


class TestCase0093LocalFirstTimestampAuthority(SafeBackupCaseBase):
    case_id = "0093"
    name = "local-first timestamp-only authority validation"
    description = (
        "Validate that older and newer local mtimes are authoritative with --local-first, "
        "upload-only keeps the local tree immutable, default sync retains remote-first behaviour, "
        "and repeated syncs "
        "do not reapply timestamp metadata"
    )

    FILES = ("local-first-older.txt", "local-first-newer.txt", "default-older.txt")

    def run(self, context: E2EContext):
        layout = self.prepare_case_layout(context, case_dir_name="tc0093", ensure_refresh_token=True)
        work, logs, state = layout.work_dir, layout.log_dir, layout.state_dir
        root_name = f"ZZ_E2E_TC0093_{context.run_id}_{os.getpid()}"
        roots = {name: work / f"{name}-root" for name in ("seed", "subject", "verify")}
        configs = {name: work / f"conf-{name}" for name in roots}
        for name, root in roots.items():
            reset_directory(root)
            self._prepare_config(context, configs[name], root)

        artifacts: list[str] = []
        metadata = state / "metadata.txt"
        artifacts.append(str(metadata))
        details: dict[str, object] = {"root_name": root_name, "phases": {}}
        expected_content = {
            name: f"TC0093 {context.run_id} {name} unchanged content\n"
            for name in self.FILES
        }
        for name, content in expected_content.items():
            write_text_file(roots["seed"] / root_name / name, content)
        hashes = {
            name: compute_quickxor_hash_file(roots["seed"] / root_name / name)
            for name in self.FILES
        }

        def fail(reason: str):
            self.write_metadata(metadata, details)
            return self.fail_result(reason=reason, artifacts=artifacts, details=details)

        def phase(label: str, config_name: str, mode: str = "sync", *, resync: bool = False,
                  local_first: bool = False):
            stdout, stderr = logs / f"{label}_stdout.log", logs / f"{label}_stderr.log"
            artifacts.extend((str(stdout), str(stderr)))
            command = self._single_directory_command(
                context, root_name=root_name, config_dir=configs[config_name], mode=mode, resync=resync,
            )
            if local_first:
                command.insert(3, "--local-first")
            result = self._run_phase(context, label=label, command=command,
                                     stdout_file=stdout, stderr_file=stderr)
            output = result.stdout + "\n" + result.stderr
            details["phases"][label] = {
                "returncode": result.returncode,
                "timestamp_corrections": output.count("correcting online timestamp"),
                "content_upload_markers": self._unexpected_upload_activity(output),
            }
            return result.returncode, output

        def local_matches(root: Path, expected_times: dict[str, int]) -> str | None:
            for name in self.FILES:
                path = root / root_name / name
                if not path.is_file():
                    return f"missing {name}"
                if compute_quickxor_hash_file(path) != hashes[name]:
                    return f"content changed for {name}"
                if int(path.stat().st_mtime) != expected_times[name]:
                    return (f"{name} mtime {int(path.stat().st_mtime)} "
                            f"does not match expected {expected_times[name]}")
            if build_manifest(root) != [root_name, *(f"{root_name}/{name}" for name in sorted(self.FILES))]:
                return "unexpected file or safeBackup appeared in the sync root"
            return None

        def verify_remote(label: str, expected_times: dict[str, int]) -> str | None:
            # A fresh download-only database and filesystem independently observe Graph state.
            reset_directory(roots["verify"])
            self._prepare_config(context, configs["verify"], roots["verify"])
            code, _ = phase(label, "verify", "download-only", resync=True)
            if code != 0:
                return f"{label} independent download failed (status {code})"
            return local_matches(roots["verify"], expected_times)

        code, _ = phase("seed", "seed", "upload-only", resync=True)
        if code != 0:
            return fail(f"fixture upload failed (status {code})")
        # Subject starts with a genuine tracked online baseline; subsequent checks must
        # not use --resync, which would discard the historical comparison state.
        code, _ = phase("subject_baseline", "subject", "download-only", resync=True)
        if code != 0:
            return fail(f"subject baseline download failed (status {code})")
        baseline = {}
        for name in self.FILES:
            path = roots["subject"] / root_name / name
            if not path.is_file() or compute_quickxor_hash_file(path) != hashes[name]:
                return fail(f"subject baseline missing or altered {name}")
            baseline[name] = int(path.stat().st_mtime)
        details["baseline_mtimes"] = baseline

        expected = dict(baseline)
        expected["local-first-older.txt"] -= 2 * 86400
        expected["local-first-newer.txt"] += 120
        for name in ("local-first-older.txt", "local-first-newer.txt"):
            os.utime(roots["subject"] / root_name / name, (expected[name], expected[name]))
        code, output = phase("local_first", "subject", local_first=True)
        if code != 0:
            return fail(f"local-first sync failed (status {code})")
        if self._unexpected_upload_activity(output):
            return fail("local-first timestamp-only change uploaded file contents")
        mismatch = local_matches(roots["subject"], expected)
        if mismatch:
            return fail(f"local-first changed the local baseline: {mismatch}")
        mismatch = verify_remote("verify_local_first", expected)
        if mismatch:
            return fail(f"local-first remote timestamp authority failed: {mismatch}")

        code, output = phase("repeat_local_first", "subject", local_first=True)
        if code != 0 or "correcting online timestamp" in output or self._unexpected_upload_activity(output):
            return fail("repeat local-first sync performed redundant timestamp/content changes or failed")

        # With the normal remote-first policy an older timestamp must not replace online.
        default_local = roots["subject"] / root_name / "default-older.txt"
        os.utime(default_local, (baseline["default-older.txt"] - 86400,) * 2)
        code, output = phase("default_remote_first", "subject")
        if code != 0 or self._unexpected_upload_activity(output):
            return fail("default remote-first reconciliation failed or uploaded content")
        mismatch = local_matches(roots["subject"], expected)
        if mismatch:
            return fail(f"default remote-first timestamp reconciliation failed: {mismatch}")

        # Verify the same local timestamp authority in upload-only mode. The
        # filesystem must remain immutable (Issue #3666), including metadata.
        expected["local-first-older.txt"] -= 86400
        expected["local-first-newer.txt"] += 120
        for name in ("local-first-older.txt", "local-first-newer.txt"):
            os.utime(roots["subject"] / root_name / name, (expected[name], expected[name]))
        upload_only_before = snapshot_tree(roots["subject"])
        code, output = phase("upload_only_local_first", "subject", "upload-only", local_first=True)
        if code != 0 or self._unexpected_upload_activity(output):
            return fail("upload-only local-first timestamp correction failed or uploaded content")
        if diff_tree_snapshots(upload_only_before, snapshot_tree(roots["subject"])):
            return fail("upload-only local-first changed the local filesystem (Issue #3666)")
        mismatch = verify_remote("verify_upload_only_local_first", expected)
        if mismatch:
            return fail(f"upload-only local-first timestamp authority failed: {mismatch}")

        code, output = phase("repeat_upload_only_local_first", "subject", "upload-only", local_first=True)
        if code != 0 or "correcting online timestamp" in output or self._unexpected_upload_activity(output):
            return fail("repeat upload-only local-first sync performed redundant changes or failed")
        if diff_tree_snapshots(upload_only_before, snapshot_tree(roots["subject"])):
            return fail("repeat upload-only local-first changed the local filesystem (Issue #3666)")

        # Verify the final timestamps independently after upload-only correction.
        mismatch = verify_remote("verify_final", expected)
        if mismatch:
            return fail(f"final remote timestamps or contents incorrect: {mismatch}")
        self.write_metadata(metadata, details)
        return self.pass_result(artifacts=artifacts, details=details)
