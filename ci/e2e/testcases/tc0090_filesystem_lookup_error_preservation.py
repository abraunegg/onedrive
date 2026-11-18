from __future__ import annotations

import errno
import os
import shutil
import subprocess
import sys
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file
from testcases.remote_move_identity import snapshot_remote_identities


class TestCase0090FilesystemLookupErrorPreservation(E2ETestCase):
    """Issue #3958: an inaccessible DB-known item is not a local deletion.

    The independent download-only verifiers establish actual Graph identities;
    the subject DB is inspected only after the client has exited. EBADMSG is injected into lstat() in the subject process, never by damaging
    CI storage. When privileged runners bypass chmod 000, EACCES is injected too.
    """

    case_id = "0090"
    name = "filesystem lookup errors must not delete remote items"
    description = (
        "Validate fatal EACCES/EBADMSG on tracked files and directories, original "
        "Graph identity preservation through recovery, monitor failure handling, "
        "and a genuine local-delete control"
    )

    SCENARIOS = (
        ("FS-0001", "sync", "EACCES", "file"),
        ("FS-0002", "sync", "EACCES", "directory"),
        ("FS-0003", "sync", "EBADMSG", "file"),
        ("FS-0004", "sync", "EBADMSG", "directory"),
        ("FS-0005", "monitor", "EACCES", "file"),
        ("FS-0006", "sync", "DELETE", "file"),
    )

    @staticmethod
    def _execute(
        context: E2EContext,
        command: list[str],
        log_dir: Path,
        phase: str,
        details: dict[str, object],
        *,
        env: dict[str, str] | None = None,
    ):
        context.log(f"Executing Test Case 0090 {phase}: {command_to_string(command)}")
        # The bounded monitor-error phase cannot use run_command: a regression
        # could otherwise leave a long-running monitor hanging the entire CI.
        if "--monitor" in command:
            try:
                completed = subprocess.run(
                    command, cwd=context.repo_root, env=dict(os.environ, **(env or {})),
                    capture_output=True, text=True, errors="replace", check=False,
                    timeout=240,
                )
                returncode, stdout, stderr = completed.returncode, completed.stdout, completed.stderr
            except subprocess.TimeoutExpired as error:
                returncode = None
                stdout = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
                stderr = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
                details[f"{phase}_timed_out"] = True
        else:
            result = run_command(command, cwd=context.repo_root, env=env)
            returncode, stdout, stderr = result.returncode, result.stdout, result.stderr
        write_text_file(log_dir / f"{phase}_stdout.log", stdout)
        write_text_file(log_dir / f"{phase}_stderr.log", stderr)
        details[f"{phase}_returncode"] = returncode
        details[f"{phase}_command"] = command_to_string(command)
        return returncode, stdout + "\n" + stderr

    @staticmethod
    def _build_lstat_injector(context: E2EContext, work_dir: Path, log_dir: Path) -> Path:
        source = context.repo_root / "ci/e2e/testcases/fixtures/tc0090_lstat_error.c"
        if not source.is_file():
            raise RuntimeError(f"TC0090 lstat fault-injection fixture missing: {source}")
        compiler = shutil.which("cc")
        if not compiler:
            raise RuntimeError("TC0090 requires a C compiler for isolated EACCES/EBADMSG injection")
        library = work_dir / "tc0090_lstat_error.so"
        command = [compiler, "-shared", "-fPIC", "-O2", "-o", str(library), str(source), "-ldl"]
        context.log("Compiling TC0090 isolated lstat injector: " + command_to_string(command))
        result = subprocess.run(command, capture_output=True, text=True, errors="replace", check=False)
        write_text_file(log_dir / "injector_build_stdout.log", result.stdout)
        write_text_file(log_dir / "injector_build_stderr.log", result.stderr)
        if result.returncode != 0 or not library.is_file():
            raise RuntimeError(f"TC0090 fault injector build failed with status {result.returncode}")
        return library

    @staticmethod
    def _verify_injected_errno(
        library: Path, local_target: Path, root_relative: str,
        log_dir: Path, env: dict[str, str], expected_errno: int,
    ) -> None:
        # Probe both glibc symbols. D Phobos can use lstat64 rather than
        # lstat, so probing lstat alone cannot prove the client will see the
        # injected error. A nonfunctional preload must never go green.
        program = (
            "import ctypes,sys; "
            "c=ctypes.CDLL(None,use_errno=True); "
            "path=sys.argv[1].encode(); "
            "\nfor symbol in ('lstat','lstat64'):\n"
            " f=getattr(c,symbol); "
            "f.argtypes=[ctypes.c_char_p,ctypes.c_void_p]; "
            "f.restype=ctypes.c_int; "
            "buf=ctypes.create_string_buffer(1024); "
            "ctypes.set_errno(0); "
            "rc=f(path,buf); "
            "print(f'{symbol}: rc={rc} errno={ctypes.get_errno()}')"
        )
        result = subprocess.run(
            [sys.executable, "-c", program, str(local_target)],
            capture_output=True, text=True, errors="replace", check=False,
            env=dict(os.environ, **env),
        )
        write_text_file(log_dir / "injector_probe_stdout.log", result.stdout)
        write_text_file(log_dir / "injector_probe_stderr.log", result.stderr)
        expected = [f"{symbol}: rc=-1 errno={expected_errno}"
                    for symbol in ("lstat", "lstat64")]
        if result.returncode != 0 or any(line not in result.stdout.splitlines() for line in expected):
            raise RuntimeError(
                f"TC0090 lstat/lstat64 injector did not return errno {expected_errno} "
                f"for {root_relative}: status={result.returncode}; "
                f"output={result.stdout.strip()!r}"
            )

    def _run_scenario(
        self, context: E2EContext, layout, scenario_id: str,
        mode: str, condition: str, target_type: str,
        artifacts: list[str], details: dict[str, object], injector: Path | None,
    ) -> str | None:
        scenario_work = layout.work_dir / scenario_id
        scenario_logs = layout.log_dir / scenario_id
        scenario_state = layout.state_dir / scenario_id
        scenario_work.mkdir(parents=True)
        scenario_logs.mkdir(parents=True)
        scenario_state.mkdir(parents=True)

        root_name = f"ZZ_E2E_TC0090_{context.run_id}_{os.getpid()}_{scenario_id.replace('-', '')}"
        sync_root = scenario_work / "subject-root"
        conf_subject = scenario_work / "conf-subject"
        relative_guard = f"{root_name}/Guarded"
        relative_target = (
            f"{relative_guard}/nested" if target_type == "directory"
            else f"{relative_guard}/a.txt"
        )
        anchor = f"{root_name}/anchor.txt"
        if target_type == "directory":
            files = {
                anchor: "TC0090 untouched control\n",
                f"{relative_guard}/nested/a.txt": "TC0090 nested file a\n",
                f"{relative_guard}/nested/b.txt": "TC0090 nested file b\n",
                f"{relative_guard}/nested/c.txt": "TC0090 nested file c\n",
            }
        else:
            files = {
                anchor: "TC0090 untouched control\n",
                f"{relative_guard}/a.txt": "TC0090 guarded file a\n",
                f"{relative_guard}/b.txt": "TC0090 guarded file b\n",
                f"{relative_guard}/c.txt": "TC0090 guarded file c\n",
            }
        # For DELETE, also check that a genuinely deleted tracked directory
        # is still removed online, while surviving tracked identities remain.
        if condition == "DELETE":
            files[f"{root_name}/DeleteMe/sub/child.txt"] = "TC0090 removed tree\n"
        for relative, content in files.items():
            write_text_file(sync_root / relative, content)

        context.prepare_minimal_config_dir(
            conf_subject,
            f'# tc0090 subject {scenario_id}\nsync_dir = "{sync_root}"\n'
            'bypass_data_preservation = "false"\n'
            'monitor_max_loop = "1"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n',
        )
        subject_cmd = [
            context.onedrive_bin, "--display-running-config", "--sync", "--verbose",
            "--single-directory", root_name, "--confdir", str(conf_subject),
        ]

        scenario_details: dict[str, object] = {
            "scenario_id": scenario_id, "mode": mode, "condition": condition,
            "target_type": target_type, "root_name": root_name,
            "target_path": relative_target,
        }
        details[scenario_id] = scenario_details
        phases = ("seed", "before", "failure", "after")
        if condition != "DELETE":
            phases += ("recover", "final")
        for phase in phases:
            for stream in ("stdout", "stderr"):
                artifacts.append(str(scenario_logs / f"{phase}_{stream}.log"))
        for name in ("seed_manifest.txt", "after_manifest.txt", "metadata.txt"):
            artifacts.append(str(scenario_state / name))

        def fail(message: str) -> str:
            self.write_metadata(scenario_state / "metadata.txt", scenario_details)
            return f"{scenario_id}: {message}"

        def verify_remote(phase: str) -> dict[str, tuple[str, str]] | None:
            verify_root = scenario_work / f"verifier-{phase}"
            verify_conf = scenario_work / f"conf-verifier-{phase}"
            context.prepare_minimal_config_dir(
                verify_conf, f'# tc0090 independent remote {phase}\nsync_dir = "{verify_root}"\n',
            )
            command = [
                context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
                "--verbose", "--resync", "--resync-auth", "--single-directory", root_name,
                "--confdir", str(verify_conf),
            ]
            code, _output = self._execute(context, command, scenario_logs, phase, scenario_details)
            if code != 0:
                return None
            try:
                identities = snapshot_remote_identities(verify_conf / "items.sqlite3", root_name)
            except (RuntimeError, OSError) as error:
                scenario_details[f"{phase}_identity_error"] = str(error)
                return None
            for relative in files:
                if relative not in identities:
                    continue  # DELETE control may intentionally remove it.
                local = verify_root / relative
                if not local.is_file() or local.read_text(encoding="utf-8") != files[relative]:
                    scenario_details[f"{phase}_content_error"] = relative
                    return None
            scenario_details[f"{phase}_identities"] = identities
            return identities

        seeded, _ = self._execute(context, subject_cmd, scenario_logs, "seed", scenario_details)
        if seeded != 0:
            return fail("seed sync failed")
        if not (conf_subject / "items.sqlite3").is_file():
            return fail("seed sync did not create a tracked item database")
        write_manifest(scenario_state / "seed_manifest.txt", build_typed_manifest(sync_root))
        try:
            original = snapshot_remote_identities(conf_subject / "items.sqlite3", root_name)
        except (RuntimeError, OSError) as error:
            return fail(f"seed database identities unavailable: {error}")
        expected_paths = {root_name, f"{root_name}/Guarded", *files}
        if target_type == "directory":
            expected_paths.add(relative_target)
        if condition == "DELETE":
            expected_paths.update({f"{root_name}/DeleteMe", f"{root_name}/DeleteMe/sub"})
        if set(original) != expected_paths:
            return fail(f"seed database hierarchy mismatch: expected={sorted(expected_paths)} actual={sorted(original)}")
        independent_before = verify_remote("before")
        if independent_before is None or independent_before != original:
            return fail("independent pre-failure Graph identities differ from seeded subject database")
        scenario_details["original_graph_ids_verified"] = True

        if condition == "DELETE":
            (sync_root / f"{relative_guard}/a.txt").unlink()
            shutil.rmtree(sync_root / root_name / "DeleteMe")
            successful, output = self._execute(context, subject_cmd, scenario_logs, "failure", scenario_details)
            if successful != 0 or "Sync with Microsoft OneDrive is complete" not in output:
                return fail("genuine local deletion was not successfully reconciled")
            remaining = expected_paths - {f"{relative_guard}/a.txt", f"{root_name}/DeleteMe", f"{root_name}/DeleteMe/sub", f"{root_name}/DeleteMe/sub/child.txt"}
            after = verify_remote("after")
            if after is None or set(after) != remaining:
                return fail("independent Graph verifier did not confirm legitimate file and directory deletion")
            if any(after[path] != original[path] for path in remaining):
                return fail("surviving remote items changed identities during legitimate deletion")
            scenario_details["verified_remote_deletion_count"] = len(expected_paths - remaining)
            self.write_metadata(scenario_state / "metadata.txt", scenario_details)
            return None

        test_env: dict[str, str] | None = None
        blocked_dir = sync_root / relative_guard
        blocked_target = sync_root / relative_target
        previous_mode: int | None = None
        try:
            if condition == "EACCES":
                previous_mode = blocked_dir.stat().st_mode & 0o777
                blocked_dir.chmod(0)
                try:
                    blocked_target.lstat()
                except OSError as error:
                    scenario_details["precondition_errno"] = error.errno
                    if error.errno != errno.EACCES:
                        return fail(f"chmod precondition raised wrong errno: {error.errno}")
                    scenario_details["lookup_failure_method"] = "chmod_000"
                else:
                    # Privileged CI runners can traverse chmod 000 directories.
                    # Restore permissions and inject the same lstat errno only
                    # in the subject client, rather than skipping the test.
                    blocked_dir.chmod(previous_mode)
                    previous_mode = None
                    if injector is None:
                        return fail("EACCES injector was not built")
                    test_env = {
                        "LD_PRELOAD": f"{injector}:{os.environ.get('LD_PRELOAD', '')}".rstrip(":"),
                        "E2E_TC0090_LSTAT_PATH": relative_target,
                        "E2E_TC0090_LSTAT_ERRNO": "EACCES",
                    }
                    self._verify_injected_errno(
                        injector, blocked_target, relative_target,
                        scenario_logs, test_env, errno.EACCES,
                    )
                    artifacts.extend((str(scenario_logs / "injector_probe_stdout.log"),
                                      str(scenario_logs / "injector_probe_stderr.log")))
                    scenario_details["precondition_errno"] = errno.EACCES
                    scenario_details["lookup_failure_method"] = "injected_lstat_eacces"
            else:
                if injector is None:
                    return fail("EBADMSG injector was not built")
                test_env = {
                    "LD_PRELOAD": f"{injector}:{os.environ.get('LD_PRELOAD', '')}".rstrip(":"),
                    "E2E_TC0090_LSTAT_PATH": relative_target,
                    "E2E_TC0090_LSTAT_ERRNO": "EBADMSG",
                }
                self._verify_injected_errno(
                    injector, blocked_target, relative_target,
                    scenario_logs, test_env, errno.EBADMSG,
                )
                artifacts.extend((str(scenario_logs / "injector_probe_stdout.log"),
                                  str(scenario_logs / "injector_probe_stderr.log")))
                scenario_details["precondition_errno"] = errno.EBADMSG
                scenario_details["lookup_failure_method"] = "injected_lstat_ebadmsg"

            command = subject_cmd if mode == "sync" else [
                context.onedrive_bin, "--display-running-config", "--monitor", "--verbose",
                "--single-directory", root_name, "--confdir", str(conf_subject),
            ]
            code, output = self._execute(context, command, scenario_logs, "failure", scenario_details, env=test_env)
        finally:
            if previous_mode is not None:
                blocked_dir.chmod(previous_mode)

        if code != 1:
            return fail(f"filesystem failure did not stop client with EXIT_FAILURE (1): status={code}")
        permission_error_seen = ("Permission denied" in output) or (
            mode == "monitor" and "Failed to stat file" in output
        )
        if "FATAL" not in output or (condition == "EACCES" and not permission_error_seen) or (
            condition == "EBADMSG" and "Bad message" not in output
        ):
            return fail("client did not report fatal lookup failure with the expected filesystem error")
        if "Performing a database consistency and integrity check" not in output and mode == "sync":
            return fail("subject failed before database consistency checking; cannot validate regression")
        if mode == "sync" and (
            "FATAL: The local file system returned an error with the following details:" not in output
            or "Calling Function:  syncEngine.localPathExistsForConsistency" not in output
        ):
            return fail("the targeted database-consistency lookup safeguard was not exercised")
        if (relative_target if mode == "sync" else relative_guard) not in output:
            return fail("fatal filesystem diagnostics did not identify the protected test path")
        if "Deleting item from Microsoft OneDrive:" in output or "Successfully deleted item from Microsoft OneDrive:" in output:
            return fail("remote delete was dispatched during an inaccessible-path sync")
        if "Sync with Microsoft OneDrive is complete" in output:
            return fail("client reported successful completion after fatal filesystem error")

        # The subject has terminated; opening its SQLite DB is now safe.
        try:
            after_subject = snapshot_remote_identities(conf_subject / "items.sqlite3", root_name)
        except (RuntimeError, OSError) as error:
            return fail(f"subject database was damaged by failed consistency pass: {error}")
        if after_subject != original:
            return fail("failed consistency pass altered the subject tracked item identities")
        write_manifest(scenario_state / "after_manifest.txt", build_typed_manifest(sync_root))

        # A separate client with no shared DB or local tree must show the
        # original remote IDs, not just same-name re-uploaded replacements.
        independent_after = verify_remote("after")
        if independent_after is None or independent_after != independent_before:
            return fail("online files/Graph identities changed during a filesystem lookup error")
        scenario_details["remote_ids_survived_failure"] = True

        # Recover normal filesystem access and ensure the same original item
        # identities persist after another normal bidirectional sync.
        recovered, recovery_output = self._execute(context, subject_cmd, scenario_logs, "recover", scenario_details)
        if recovered != 0 or "Sync with Microsoft OneDrive is complete" not in recovery_output:
            return fail("subject did not recover with a successful normal sync")
        final_remote = verify_remote("final")
        if final_remote is None or final_remote != independent_before:
            return fail("recovery recreated or removed remote items instead of preserving their IDs")
        scenario_details["remote_ids_survived_recovery"] = True
        self.write_metadata(scenario_state / "metadata.txt", scenario_details)
        return None

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0090", ensure_refresh_token=True)
        details: dict[str, object] = {"executed_scenario_ids": []}
        artifacts: list[str] = [str(layout.state_dir / "metadata.txt")]
        injector: Path | None = None

        for scenario_id, mode, condition, target_type in self.SCENARIOS:
            if not context.should_run_scenario(self.case_id, scenario_id):
                continue
            details["executed_scenario_ids"].append(scenario_id)
            try:
                if condition in ("EACCES", "EBADMSG") and injector is None:
                    injector = self._build_lstat_injector(context, layout.work_dir, layout.log_dir)
                    artifacts.extend((str(layout.log_dir / "injector_build_stdout.log"),
                                      str(layout.log_dir / "injector_build_stderr.log")))
                error = self._run_scenario(
                    context, layout, scenario_id, mode, condition, target_type,
                    artifacts, details, injector,
                )
                if error:
                    self.write_metadata(layout.state_dir / "metadata.txt", details)
                    return self.fail_result(reason=error, artifacts=artifacts, details=details)
            except Exception as error:
                self.write_metadata(layout.state_dir / "metadata.txt", details)
                return self.fail_result(
                    reason=f"{scenario_id}: unexpected harness failure: {type(error).__name__}: {error}",
                    artifacts=artifacts, details=details,
                )

        if not details["executed_scenario_ids"]:
            return self.fail_result(reason="No TC0090 scenarios selected/executed", artifacts=artifacts, details=details)
        self.write_metadata(layout.state_dir / "metadata.txt", details)
        return self.pass_result(artifacts=artifacts, details=details)
