from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

from framework.context import E2EContext
from framework.manifest import build_typed_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_text_file
from testcases.monitor_case_base import MonitorModeTestCaseBase


class TestCase0087ResyncMonitorWorkingDirectoryBoundary(MonitorModeTestCaseBase):
    """Issue #3901: resync/monitor must not create relative paths outside sync_dir.

    Use a synthetic HOME and an existing tracked sync_list database, not the
    runner's actual HOME. An independent inotify mutator preserves remote item
    identity when moving a populated directory outside the selected subtree.
    """

    case_id = "0087"
    name = "resync monitor working directory boundary validation"
    description = (
        "Validate filesystem boundaries and runtime sync_dir resolution across "
        "resync-to-monitor transitions, a tracked remote move, tilde and relative "
        "paths, controlled HOME/SHELL/USER/PWD variants, and different launch cwd values"
    )

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0087", ensure_refresh_token=True)
        work_dir, log_dir, state_dir = layout.work_dir, layout.log_dir, layout.state_dir
        home = work_dir / "home"
        subject_root = home / "OneDrive"
        mutator_root = work_dir / "mutator-root"
        verifier_root = work_dir / "verify-root"
        subject_conf = work_dir / "conf-subject"
        mutator_conf = work_dir / "conf-mutator"
        verifier_conf = work_dir / "conf-verifier"
        root_name = f"ZZ_E2E_TC0087_{context.run_id}_{os.getpid()}"
        selected = f"{root_name}/Documents"
        remote_move_source = f"{selected}/Vault"
        remote_move_destination = f"{root_name}/Outside/Vault"
        forbidden = home / root_name
        subject_env = {
            "HOME": str(home),
            "PWD": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
        }
        home.mkdir(parents=True, exist_ok=True)
        subject_root.mkdir(parents=True, exist_ok=True)
        metadata_file = state_dir / "metadata.txt"
        details: dict[str, object] = {"root_name": root_name, "configured_sync_dir": str(subject_root),
                                      "external_cwd": str(home), "selected_scope": selected}
        phase_names = ("seed", "initial", "resync_external", "converge_external",
                       "verify_move", "resync_after_move", "converge_after_move",
                       "tilde_initial", "tilde_resync")
        artifacts = [str(log_dir / f"{phase}_{stream}.log") for phase in phase_names
                     for stream in ("stdout", "stderr")]
        artifacts += [str(log_dir / f"{phase}_{stream}.log")
                      for phase in ("monitor_external", "mutator_monitor", "monitor_after_move", "monitor_control", "monitor_tilde")
                      for stream in ("stdout", "stderr")]
        artifacts += [str(log_dir / f"{phase}_{stream}.log")
                      for phase in ("relative_initial", "relative_resync", "absolute_other_home",
                                    "headless_initial", "headless_resync", "tilde_alt_resync",
                                    "resync_cwd_transition", "root_like_initial", "no_home_resync",
                                    "root_like_resync", "home_switch_resync") for stream in ("stdout", "stderr")]
        artifacts += [str(log_dir / f"{phase}_{stream}.log")
                      for phase in ("monitor_tilde_alt", "monitor_relative",
                                    "monitor_absolute_other_home", "monitor_headless",
                                    "monitor_cwd_transition", "monitor_root_like", "monitor_no_home",
                                    "monitor_home_switch") for stream in ("stdout", "stderr")]
        artifacts += [str(state_dir / "metadata.txt"), str(state_dir / "subject_initial.txt"),
                      str(state_dir / "subject_final.txt"), str(state_dir / "remote_final.txt")]

        def fail(message: str) -> TestResult:
            self.write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, message, artifacts, details)

        def execute(phase: str, command: list[str], *, cwd: Path, env: dict[str, str | None] | None = None):
            context.log(f"Executing Test Case {self.case_id} {phase}: {command_to_string(command)} (cwd={cwd})")
            process_env = dict(os.environ)
            if env is not None:
                for name, value in env.items():
                    if value is None:
                        process_env.pop(name, None)
                    else:
                        process_env[name] = value
            result = run_command(command, cwd=cwd, env=process_env)
            if env is not None:
                details[f"{phase}_environment"] = dict(env)
            write_text_file(log_dir / f"{phase}_stdout.log", result.stdout)
            write_text_file(log_dir / f"{phase}_stderr.log", result.stderr)
            details[f"{phase}_returncode"] = result.returncode
            details[f"{phase}_cwd"] = str(cwd)
            return result

        def outside_sync_snapshot(controlled_home: Path, sync_root: Path) -> list[str]:
            # Exact filesystem enumeration: ignore only the configured sync tree
            # and the expected per-user XDG config tree. These are the only
            # intentionally writable paths beneath the synthetic home.
            entries: list[str] = []
            if not controlled_home.exists():
                return entries
            for path in sorted(controlled_home.rglob("*")):
                if path == sync_root or sync_root in path.parents:
                    continue
                xdg = controlled_home / ".config"
                if path == xdg or xdg in path.parents:
                    continue
                relative = path.relative_to(controlled_home).as_posix()
                entries.append(relative + ("/" if path.is_dir() else ""))
            return entries

        home_boundary_baseline = outside_sync_snapshot(home, subject_root)

        def boundary_ok() -> bool:
            return (not forbidden.exists()
                    and not (home / "Documents").exists()
                    and outside_sync_snapshot(home, subject_root) == home_boundary_baseline)


        def launch(phase: str, command: list[str], cwd: Path, env: dict[str, str | None] | None = None):
            stdout = log_dir / f"{phase}_stdout.log"
            stderr = log_dir / f"{phase}_stderr.log"
            out_fp = stdout.open("w", encoding="utf-8")
            err_fp = stderr.open("w", encoding="utf-8")
            try:
                process_env = dict(os.environ)
                if env is not None:
                    for name, value in env.items():
                        if value is None:
                            process_env.pop(name, None)
                        else:
                            process_env[name] = value
                    details[f"{phase}_environment"] = dict(env)
                process = subprocess.Popen(command, cwd=str(cwd), env=process_env, stdout=out_fp,
                                           stderr=err_fp, text=True)
            except BaseException:
                out_fp.close()
                err_fp.close()
                raise
            process._tc_stdout_fp = out_fp  # type: ignore[attr-defined]
            process._tc_stderr_fp = err_fp  # type: ignore[attr-defined]
            details[f"{phase}_cwd"] = str(cwd)
            details[f"{phase}_pid"] = process.pid
            proc_cwd = Path(f"/proc/{process.pid}/cwd")
            if proc_cwd.exists():
                try:
                    details[f"{phase}_proc_cwd"] = str(proc_cwd.resolve())
                except OSError:
                    pass
            return process, stdout

        fixture = {
            f"{remote_move_source}/Notes/.obsidian/plugins/plugin.txt": "TC0087 obsidian content\n",
            f"{remote_move_source}/Notes/.obsidian/themes/theme.txt": "TC0087 theme content\n",
            f"{remote_move_source}/Development/Project/src/main.txt": "TC0087 source\n",
            f"{remote_move_source}/Reference/Level1/Level2/reference.txt": "TC0087 nested\n",
            f"{selected}/anchor.txt": "TC0087 survivor\n",
            f"{root_name}/Outside/anchor.txt": "TC0087 outside selected scope\n",
        }
        for relative, content in fixture.items():
            write_text_file(mutator_root / relative, content)
        (mutator_root / remote_move_source / "EmptyChild").mkdir(parents=True, exist_ok=True)
        context.prepare_minimal_config_dir(
            mutator_conf, f'sync_dir = "{mutator_root}"\nbypass_data_preservation = "true"\n'
        )
        context.prepare_minimal_config_dir(
            subject_conf, f'sync_dir = "{subject_root}"\nbypass_data_preservation = "true"\n'
            'monitor_interval = "300"\nmonitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n'
        )
        # Include ONLY the testcase's Documents branch. The sibling Outside
        # subtree belongs to the independent mutator, not the subject.
        write_text_file(subject_conf / "sync_list", f"/{selected}\n")
        context.prepare_minimal_config_dir(
            verifier_conf, f'sync_dir = "{verifier_root}"\nbypass_data_preservation = "true"\n'
        )
        mutator_seed = [context.onedrive_bin, "--display-running-config", "--sync", "--upload-only",
                        "--verbose", "--resync", "--resync-auth", "--single-directory",
                        root_name, "--confdir", str(mutator_conf)]
        subject_sync = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--verbose",
                        "--confdir", str(subject_conf)]
        subject_monitor = [context.onedrive_bin, "--display-running-config", "--monitor",
                           "--verbose", "--verbose", "--confdir", str(subject_conf)]
        mutator_monitor = [context.onedrive_bin, "--display-running-config", "--monitor",
                           "--upload-only", "--verbose", "--verbose", "--single-directory",
                           root_name, "--confdir", str(mutator_conf)]
        remote_verify = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only",
                         "--resync", "--resync-auth", "--single-directory", root_name,
                         "--confdir", str(verifier_conf)]

        if execute("seed", mutator_seed, cwd=context.repo_root).returncode != 0:
            return fail("independent mutator failed to establish remote fixture")
        if execute("initial", subject_sync + ["--resync", "--resync-auth"], cwd=home, env=subject_env).returncode != 0:
            return fail("subject failed to acquire initial tracked state")
        if not (subject_conf / "items.sqlite3").is_file():
            return fail("subject has no tracked item database")
        initial_output = (log_dir / "initial_stdout.log").read_text(encoding="utf-8", errors="replace")
        if ("sync_dir: runtimeSyncDirectory set to: " + str(subject_root)) not in initial_output:
            return fail("debug output does not confirm expected absolute runtime sync_dir")
        original_manifest = build_typed_manifest(subject_root)
        write_manifest(state_dir / "subject_initial.txt", original_manifest)
        for relative, content in fixture.items():
            if relative.startswith(selected + "/"):
                p = subject_root / relative
                if not p.is_file() or p.read_text(encoding="utf-8") != content:
                    return fail(f"initial subject missing selected content: {relative}")
        if not boundary_ok():
            return fail("subject wrote a directory outside sync_dir during initial resync")

        if execute("resync_external", subject_sync + ["--resync", "--resync-auth"], cwd=home, env=subject_env).returncode != 0:
            return fail("external-cwd resync failed")
        if build_typed_manifest(subject_root) != original_manifest or not boundary_ok():
            return fail("external-cwd resync changed expected tree or violated sync_dir boundary")

        # S02: run normal monitor initial sync from outside sync_dir, then watch
        # for delayed directory creation after the completion marker.
        process, stdout = launch("monitor_external", subject_monitor, home, subject_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_external_stderr.log", timeout_seconds=300) != "complete":
                return fail("external-cwd monitor did not complete its initial sync")
            until = time.monotonic() + 110
            while time.monotonic() < until:
                if not boundary_ok():
                    return fail("external-cwd monitor created a directory outside sync_dir")
                if process.poll() is not None:
                    return fail("external-cwd monitor unexpectedly exited during observation")
                time.sleep(1)
        finally:
            self._shutdown_monitor_process(process, details)
        if not boundary_ok():
            return fail("external-cwd monitor created directories outside sync_dir at shutdown")
        if build_typed_manifest(subject_root) != original_manifest:
            return fail("external-cwd monitor disturbed tracked tree")

        # S03: tracked remote move out of the subject's selected subtree. Use
        # TC0065's established mutator --monitor --upload-only/inotify pattern.
        mutator_process, mutator_stdout = launch("mutator_monitor", mutator_monitor, context.repo_root)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    mutator_process, mutator_stdout, log_dir / "mutator_monitor_stderr.log",
                    timeout_seconds=300) != "complete":
                return fail("remote move mutator monitor did not complete initial sync")
            offset = self._prepare_monitor_for_local_mutation(mutator_process, mutator_stdout,
                                                               details, timeout_seconds=40)
            if not details.get("monitor_ready_after_initial_sync"):
                return fail("remote move mutator never reached idle state")
            source = mutator_root / remote_move_source
            destination = mutator_root / remote_move_destination
            destination.parent.mkdir(parents=True, exist_ok=True)
            source.rename(destination)
            expected_patterns = [
                f"[M] Local item moved: ./{remote_move_source} -> ./{remote_move_destination}",
                f"Moving ./{remote_move_source} to ./{remote_move_destination}",
                '"Vault", "", dir,',
            ]
            if not self._wait_for_monitor_patterns(mutator_stdout, expected_patterns,
                                                   timeout_seconds=180, start_offset=offset):
                return fail("independent mutator did not prove an existing-identity remote move")
        finally:
            self._shutdown_monitor_process(mutator_process, details)

        # Reproduce the reporter moving orphaned local content out of sync_dir
        # after a genuine remote move. This occurs while the subject is stopped,
        # so no local inotify deletion is sent back to OneDrive.
        old_local = subject_root / remote_move_source
        holding = work_dir / "orphan-holding"
        holding.mkdir(parents=True, exist_ok=True)
        if not old_local.is_dir():
            return fail("remote move precondition missing tracked local directory")
        old_local.rename(holding / "Vault")
        details["orphan_holding_path"] = str(holding / "Vault")

        if execute("resync_after_move", subject_sync + ["--resync", "--resync-auth"], cwd=home, env=subject_env).returncode != 0:
            return fail("external-cwd resync after remote move failed")
        if not boundary_ok():
            return fail("external-cwd post-move resync created outside-sync directory")
        if (subject_root / remote_move_source).exists():
            return fail("resync recreated moved directory inside excluded selected scope")

        # The actual issue reproduction is a fresh monitor starting from HOME
        # after the remote-move/resync sequence, not the sync_dir control below.
        process, stdout = launch("monitor_after_move", subject_monitor, home, subject_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_after_move_stderr.log", timeout_seconds=300) != "complete":
                return fail("external-cwd post-move monitor did not complete initial sync")
            until = time.monotonic() + 110
            while time.monotonic() < until:
                if not boundary_ok():
                    return fail("post-move external-cwd monitor created outside-sync directories")
                if process.poll() is not None:
                    return fail("post-move external-cwd monitor unexpectedly exited")
                time.sleep(1)
        finally:
            self._shutdown_monitor_process(process, details)

        # Diagnostic control: launch from the configured sync_dir instead.
        process, stdout = launch("monitor_control", subject_monitor, subject_root,
                                 dict(subject_env, PWD=str(home)))
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_control_stderr.log", timeout_seconds=300) != "complete":
                return fail("sync_dir-cwd control monitor did not complete its initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("sync_dir-cwd control monitor did not become idle")
            if not boundary_ok():
                return fail("control monitor violated sync_dir boundary")
        finally:
            self._shutdown_monitor_process(process, details)

        verify_result = execute("verify_move", remote_verify, cwd=context.repo_root)
        if verify_result.returncode != 0:
            return fail("independent remote verification failed")
        remote_manifest = build_typed_manifest(verifier_root)
        write_manifest(state_dir / "remote_final.txt", remote_manifest)
        if not (verifier_root / remote_move_destination / "Development/Project/src/main.txt").is_file():
            return fail("fresh remote verifier did not observe moved directory at destination")
        if (verifier_root / remote_move_source).exists():
            return fail("fresh remote verifier still sees original directory")
        if not boundary_ok():
            return fail("out-of-sync directory was created outside sync_dir")
        # S05: separately validate the reporter's literal ~/OneDrive configuration
        # with a real synthetic HOME, rather than merely naming a directory home.
        tilde_home = work_dir / "tilde-home"
        tilde_root = tilde_home / "OneDrive"
        tilde_conf = work_dir / "conf-tilde"
        tilde_home.mkdir(parents=True, exist_ok=True)
        tilde_env = {
            "HOME": str(tilde_home),
            "PWD": str(tilde_home),
            "XDG_CONFIG_HOME": str(tilde_home / ".config"),
        }
        context.prepare_minimal_config_dir(
            tilde_conf,
            'sync_dir = "~/OneDrive"\n'
            'bypass_data_preservation = "true"\n'
            'monitor_interval = "300"\n'
            'monitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n',
        )
        write_text_file(tilde_conf / "sync_list", f"/{selected}\n")
        tilde_sync = [context.onedrive_bin, "--display-running-config", "--sync",
                      "--verbose", "--verbose", "--confdir", str(tilde_conf)]
        tilde_monitor = [context.onedrive_bin, "--display-running-config", "--monitor",
                         "--verbose", "--verbose", "--confdir", str(tilde_conf)]
        if execute("tilde_initial", tilde_sync + ["--resync", "--resync-auth"],
                   cwd=tilde_home, env=tilde_env).returncode != 0:
            return fail("literal tilde sync_dir initial sync failed")
        if not (tilde_conf / "items.sqlite3").is_file():
            return fail("literal tilde scenario did not create tracked database")
        tilde_output = (log_dir / "tilde_initial_stdout.log").read_text(
            encoding="utf-8", errors="replace")
        if "sync_dir: runtimeSyncDirectory set to: " + str(tilde_root) not in tilde_output:
            return fail("literal tilde expansion did not resolve to synthetic HOME/OneDrive")
        if execute("tilde_resync", tilde_sync + ["--resync", "--resync-auth"],
                   cwd=tilde_home, env=tilde_env).returncode != 0:
            return fail("literal tilde sync_dir resync failed")
        if (tilde_home / root_name).exists() or (tilde_home / "Documents").exists():
            return fail("literal tilde resync created out-of-sync_dir hierarchy")
        process, stdout = launch("monitor_tilde", tilde_monitor, tilde_home, tilde_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_tilde_stderr.log", timeout_seconds=300) != "complete":
                return fail("literal tilde external-cwd monitor failed initial sync")
            until = time.monotonic() + 110
            while time.monotonic() < until:
                if (tilde_home / root_name).exists() or (tilde_home / "Documents").exists():
                    return fail("literal tilde monitor created directory outside sync_dir")
                if process.poll() is not None:
                    return fail("literal tilde monitor unexpectedly exited during observation")
                time.sleep(1)
        finally:
            self._shutdown_monitor_process(process, details)
        if (tilde_home / root_name).exists() or (tilde_home / "Documents").exists():
            return fail("literal tilde monitor created an out-of-sync_dir hierarchy")
        if build_typed_manifest(tilde_root) != build_typed_manifest(subject_root):
            return fail("literal tilde and absolute-path subject trees did not converge")

        # S06: keep the same literal ~/OneDrive client state, but resync from a
        # different cwd and launch its monitor from another external cwd.
        alternate_cwd = work_dir / "alternate-launch-cwd"
        alternate_cwd.mkdir(parents=True, exist_ok=True)
        tilde_before = build_typed_manifest(tilde_root)
        tilde_baseline = outside_sync_snapshot(tilde_home, tilde_root)
        if execute("tilde_alt_resync", tilde_sync + ["--resync", "--resync-auth"],
                   cwd=alternate_cwd, env=dict(tilde_env, PWD=str(tilde_home))).returncode != 0:
            return fail("S06 tilde resync from alternate cwd failed")
        if build_typed_manifest(tilde_root) != tilde_before:
            return fail("S06 alternate-cwd resync changed tracked tree")
        if "sync_dir: runtimeSyncDirectory set to: " + str(tilde_root) not in (
                log_dir / "tilde_alt_resync_stdout.log").read_text(encoding="utf-8", errors="replace"):
            return fail("S06 alternate-cwd tilde resync resolved the wrong sync_dir")
        if outside_sync_snapshot(tilde_home, tilde_root) != tilde_baseline:
            return fail("S06 alternate-cwd resync wrote outside configured sync_dir")
        process, stdout = launch("monitor_tilde_alt", tilde_monitor, alternate_cwd,
                                 dict(tilde_env, PWD=str(tilde_home)))
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_tilde_alt_stderr.log", timeout_seconds=300) != "complete":
                return fail("S06 alternate-cwd tilde monitor did not complete initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("S06 alternate-cwd tilde monitor did not settle")
            if outside_sync_snapshot(tilde_home, tilde_root) != tilde_baseline:
                return fail("S06 alternate-cwd tilde monitor wrote outside sync_dir")
            if outside_sync_snapshot(alternate_cwd, tilde_root):
                return fail("S06 alternate cwd received synchronised content")
        finally:
            self._shutdown_monitor_process(process, details)

        # S07--S09: each variant gets an independent database, HOME and local
        # tree. All use the existing scoped remote fixture, so unrelated CI
        # account content is never eligible for download or upload.
        relative_home = work_dir / "relative-home"
        relative_root = relative_home / "OneDrive"
        relative_conf = work_dir / "conf-relative"
        relative_home.mkdir(parents=True, exist_ok=True)
        relative_env = {"HOME": str(relative_home), "PWD": str(relative_home),
                        "XDG_CONFIG_HOME": str(relative_home / ".config")}
        context.prepare_minimal_config_dir(
            relative_conf, 'sync_dir = "OneDrive"\n'
            'bypass_data_preservation = "true"\n'
            'monitor_interval = "300"\nmonitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n')
        write_text_file(relative_conf / "sync_list", f"/{selected}\n")
        relative_sync = [context.onedrive_bin, "--display-running-config", "--sync",
                         "--verbose", "--verbose", "--confdir", str(relative_conf)]
        relative_monitor = [context.onedrive_bin, "--display-running-config", "--monitor",
                            "--verbose", "--verbose", "--confdir", str(relative_conf)]
        if execute("relative_initial", relative_sync + ["--resync", "--resync-auth"],
                   cwd=relative_home, env=relative_env).returncode != 0:
            return fail("S07 relative sync_dir initial sync failed")
        if "sync_dir: runtimeSyncDirectory set to: " + str(relative_root) not in (
                log_dir / "relative_initial_stdout.log").read_text(encoding="utf-8", errors="replace"):
            return fail("S07 relative sync_dir did not resolve to HOME/OneDrive")
        if not (relative_conf / "items.sqlite3").is_file():
            return fail("S07 relative sync_dir did not establish a tracked database")
        relative_before = build_typed_manifest(relative_root)
        if relative_before != build_typed_manifest(subject_root):
            return fail("S07 relative sync_dir did not acquire expected scoped tree")
        relative_boundary = outside_sync_snapshot(relative_home, relative_root)
        if execute("relative_resync", relative_sync + ["--resync", "--resync-auth"],
                   cwd=alternate_cwd, env=relative_env).returncode != 0:
            return fail("S07 relative sync_dir resync failed from alternate cwd")
        if "sync_dir: runtimeSyncDirectory set to: " + str(relative_root) not in (
                log_dir / "relative_resync_stdout.log").read_text(encoding="utf-8", errors="replace"):
            return fail("S07 alternate-cwd relative resync resolved the wrong sync_dir")
        process, stdout = launch("monitor_relative", relative_monitor, alternate_cwd, relative_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_relative_stderr.log", timeout_seconds=300) != "complete":
                return fail("S07 relative sync_dir monitor did not complete initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("S07 relative sync_dir monitor did not settle")
            if outside_sync_snapshot(relative_home, relative_root) != relative_boundary:
                return fail("S07 relative sync_dir wrote outside HOME/OneDrive")
            if outside_sync_snapshot(alternate_cwd, relative_root):
                return fail("S07 relative sync_dir wrote into process cwd")
        finally:
            self._shutdown_monitor_process(process, details)
        if build_typed_manifest(relative_root) != relative_before:
            return fail("S07 relative sync_dir tracked tree changed unexpectedly")

        # S08: absolute sync_dir must remain authoritative when HOME points to
        # another location and PWD disagrees with the actual cwd.
        other_home = work_dir / "other-home"
        absolute_root = work_dir / "absolute-sync-root"
        absolute_conf = work_dir / "conf-absolute-other-home"
        other_home.mkdir(parents=True, exist_ok=True)
        absolute_root.mkdir(parents=True, exist_ok=True)
        other_env = {"HOME": str(other_home), "PWD": str(home),
                     "XDG_CONFIG_HOME": str(other_home / ".config")}
        context.prepare_minimal_config_dir(
            absolute_conf, f'sync_dir = "{absolute_root}"\n'
            'bypass_data_preservation = "true"\n'
            'monitor_interval = "300"\nmonitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n')
        write_text_file(absolute_conf / "sync_list", f"/{selected}\n")
        absolute_sync = [context.onedrive_bin, "--display-running-config", "--sync",
                         "--verbose", "--verbose", "--confdir", str(absolute_conf)]
        absolute_monitor = [context.onedrive_bin, "--display-running-config", "--monitor",
                            "--verbose", "--verbose", "--confdir", str(absolute_conf)]
        if execute("absolute_other_home", absolute_sync + ["--resync", "--resync-auth"],
                   cwd=other_home, env=other_env).returncode != 0:
            return fail("S08 absolute sync_dir under divergent HOME failed")
        if "sync_dir: runtimeSyncDirectory set to: " + str(absolute_root) not in (
                log_dir / "absolute_other_home_stdout.log").read_text(encoding="utf-8", errors="replace"):
            return fail("S08 absolute sync_dir did not remain authoritative")
        absolute_expected = build_typed_manifest(absolute_root)
        if absolute_expected != build_typed_manifest(subject_root):
            return fail("S08 absolute sync_dir content differs from tracked subject")
        other_boundary = outside_sync_snapshot(other_home, absolute_root)
        process, stdout = launch("monitor_absolute_other_home", absolute_monitor,
                                 other_home, other_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_absolute_other_home_stderr.log", timeout_seconds=300) != "complete":
                return fail("S08 divergent HOME monitor did not complete initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("S08 divergent HOME monitor did not settle")
            if outside_sync_snapshot(other_home, absolute_root) != other_boundary:
                return fail("S08 divergent HOME caused writes outside absolute sync_dir")
        finally:
            self._shutdown_monitor_process(process, details)
        if build_typed_manifest(absolute_root) != absolute_expected:
            return fail("S08 divergent HOME changed tracked content")

        # S09: HOME remains defined but SHELL and USER are genuinely removed
        # from the child environment; the ordinary helper normally inherits
        # those values from GitHub Actions otherwise.
        headless_home = work_dir / "headless-home"
        headless_root = headless_home / "OneDrive"
        headless_conf = work_dir / "conf-headless"
        headless_home.mkdir(parents=True, exist_ok=True)
        headless_env: dict[str, str | None] = {
            "HOME": str(headless_home), "PWD": str(headless_home),
            "XDG_CONFIG_HOME": str(headless_home / ".config"),
            "SHELL": None, "USER": None,
        }
        context.prepare_minimal_config_dir(
            headless_conf, 'sync_dir = "~/OneDrive"\n'
            'bypass_data_preservation = "true"\n'
            'monitor_interval = "300"\nmonitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n')
        write_text_file(headless_conf / "sync_list", f"/{selected}\n")
        headless_sync = [context.onedrive_bin, "--display-running-config", "--sync",
                         "--verbose", "--verbose", "--confdir", str(headless_conf)]
        headless_monitor = [context.onedrive_bin, "--display-running-config", "--monitor",
                            "--verbose", "--verbose", "--confdir", str(headless_conf)]
        if execute("headless_initial", headless_sync + ["--resync", "--resync-auth"],
                   cwd=headless_home, env=headless_env).returncode != 0:
            return fail("S09 no-SHELL/no-USER initial sync failed")
        output = (log_dir / "headless_initial_stdout.log").read_text(encoding="utf-8", errors="replace")
        if "sync_dir: runtimeSyncDirectory set to: " + str(headless_root) not in output:
            return fail("S09 no-SHELL/no-USER path expansion did not use HOME")
        if "runtime_environment: HOME environment variable detected" not in output:
            return fail("S09 no-SHELL/no-USER did not exercise HOME-present branch")
        headless_before = build_typed_manifest(headless_root)
        if headless_before != build_typed_manifest(subject_root):
            return fail("S09 HOME-present environment produced unexpected content")
        headless_boundary = outside_sync_snapshot(headless_home, headless_root)
        if execute("headless_resync", headless_sync + ["--resync", "--resync-auth"],
                   cwd=alternate_cwd, env=headless_env).returncode != 0:
            return fail("S09 headless-style resync failed from alternate cwd")
        if "sync_dir: runtimeSyncDirectory set to: " + str(headless_root) not in (
                log_dir / "headless_resync_stdout.log").read_text(encoding="utf-8", errors="replace"):
            return fail("S09 headless-style resync resolved the wrong sync_dir")
        process, stdout = launch("monitor_headless", headless_monitor, alternate_cwd, headless_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_headless_stderr.log", timeout_seconds=300) != "complete":
                return fail("S09 headless-style monitor did not complete initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("S09 headless-style monitor did not settle")
            if outside_sync_snapshot(headless_home, headless_root) != headless_boundary:
                return fail("S09 headless-style environment wrote outside sync_dir")
        finally:
            self._shutdown_monitor_process(process, details)
        if build_typed_manifest(headless_root) != headless_before:
            return fail("S09 headless-style client changed tracked content")

        # S10: resync from HOME, then start the *same* tracked client from the
        # sync directory. This explicitly reverses its launch cwd while keeping
        # database and configuration unchanged.
        if execute("resync_cwd_transition", subject_sync + ["--resync", "--resync-auth"],
                   cwd=home, env=subject_env).returncode != 0:
            return fail("S10 resync from HOME before cwd transition failed")
        process, stdout = launch("monitor_cwd_transition", subject_monitor,
                                 subject_root, dict(subject_env, PWD=str(home)))
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_cwd_transition_stderr.log", timeout_seconds=300) != "complete":
                return fail("S10 post-resync cwd-transition monitor did not complete initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("S10 cwd-transition monitor did not settle")
            if not boundary_ok():
                return fail("S10 cwd-transition monitor violated sync_dir boundary")
        finally:
            self._shutdown_monitor_process(process, details)
        if build_typed_manifest(subject_root) != build_typed_manifest(tilde_root):
            return fail("S10 cwd-transition monitor changed established tracked content")
        # S11-S13: reproduce root/chroot-like inherited environments without
        # escalating privileges or touching the host's actual /root. The test
        # always uses an explicit absolute sync root, so environment changes
        # must not alter where synchronised directories are created.
        root_like_home = work_dir / "root-like-home"
        root_like_home.mkdir(parents=True, exist_ok=True)
        root_like_sync = work_dir / "root-like-sync"
        root_like_conf = work_dir / "conf-root-like"
        root_like_env: dict[str, str | None] = {
            "HOME": str(root_like_home), "PWD": str(root_like_home),
            "XDG_CONFIG_HOME": str(root_like_home / ".config"),
            "SHELL": "/bin/bash", "USER": "root",
        }
        context.prepare_minimal_config_dir(
            root_like_conf, f'sync_dir = "{root_like_sync}"\n'
            'bypass_data_preservation = "true"\n'
            'monitor_interval = "300"\nmonitor_fullscan_frequency = "0"\n'
            'disable_websocket_support = "true"\n')
        write_text_file(root_like_conf / "sync_list", f"/{selected}\n")
        root_like_sync_cmd = [context.onedrive_bin, "--display-running-config", "--sync",
                              "--verbose", "--verbose", "--confdir", str(root_like_conf)]
        root_like_monitor_cmd = [context.onedrive_bin, "--display-running-config", "--monitor",
                                 "--verbose", "--verbose", "--confdir", str(root_like_conf)]

        # S11: root-like HOME/USER/SHELL with an absolute sync root. This is
        # deliberately NOT a privilege or chroot test.
        root_before = outside_sync_snapshot(root_like_home, root_like_sync)
        result = execute("root_like_initial", root_like_sync_cmd + ["--resync", "--resync-auth"],
                         cwd=root_like_home, env=root_like_env)
        if result.returncode != 0:
            return fail("S11 root-like environment initial sync failed")
        if "sync_dir: runtimeSyncDirectory set to: " + str(root_like_sync) not in result.stdout:
            return fail("S11 root-like environment changed absolute runtime sync_dir")
        root_manifest = build_typed_manifest(root_like_sync)
        if root_manifest != build_typed_manifest(subject_root):
            return fail("S11 root-like environment did not acquire expected tracked content")
        if outside_sync_snapshot(root_like_home, root_like_sync) != root_before:
            return fail("S11 root-like initial resync created content under HOME")
        process, stdout = launch("monitor_root_like", root_like_monitor_cmd,
                                 root_like_home, root_like_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_root_like_stderr.log", timeout_seconds=300) != "complete":
                return fail("S11 root-like monitor did not complete initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("S11 root-like monitor did not settle")
            if outside_sync_snapshot(root_like_home, root_like_sync) != root_before:
                return fail("S11 root-like monitor created content under HOME")
        finally:
            self._shutdown_monitor_process(process, details)
        if build_typed_manifest(root_like_sync) != root_manifest:
            return fail("S11 root-like monitor unexpectedly changed tracked content")

        # S12: no HOME, SHELL or USER. config.d intentionally selects /root
        # for defaultHomePath; that branch is checked explicitly, but /root
        # must never be a write target for synchronised content. Keep config,
        # cwd, XDG and sync_dir within the testcase's controlled work tree.
        no_home_env: dict[str, str | None] = {
            "HOME": None, "SHELL": None, "USER": None,
            "PWD": str(root_like_home),
            "XDG_CONFIG_HOME": str(root_like_home / ".config"),
        }
        result = execute("no_home_resync", root_like_sync_cmd + ["--resync", "--resync-auth"],
                         cwd=root_like_home, env=no_home_env)
        if result.returncode != 0:
            return fail("S12 HOME/SHELL/USER-absent resync failed")
        if "runtime_environment: Calculated defaultHomePath: /root" not in result.stdout:
            return fail("S12 did not execute config.d's /root fallback branch")
        if "sync_dir: runtimeSyncDirectory set to: " + str(root_like_sync) not in result.stdout:
            return fail("S12 /root fallback incorrectly changed absolute sync_dir")
        if outside_sync_snapshot(root_like_home, root_like_sync) != root_before:
            return fail("S12 /root fallback created unexpected content under synthetic home")
        if build_typed_manifest(root_like_sync) != root_manifest:
            return fail("S12 /root fallback changed tracked content")
        process, stdout = launch("monitor_no_home", root_like_monitor_cmd,
                                 root_like_home, no_home_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_no_home_stderr.log", timeout_seconds=300) != "complete":
                return fail("S12 no-HOME monitor did not complete initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("S12 no-HOME monitor did not settle")
            if outside_sync_snapshot(root_like_home, root_like_sync) != root_before:
                return fail("S12 no-HOME monitor created unexpected content under synthetic home")
        finally:
            self._shutdown_monitor_process(process, details)
        if build_typed_manifest(root_like_sync) != root_manifest:
            return fail("S12 no-HOME monitor changed tracked content")

        # S13: the same configuration/database transitions from a root-like
        # resync environment to the ordinary user-like environment on monitor
        # restart. The initial working directories also differ.
        result = execute("root_like_resync", root_like_sync_cmd + ["--resync", "--resync-auth"],
                         cwd=root_like_home, env=root_like_env)
        if result.returncode != 0:
            return fail("S13 root-like precursor resync failed")
        switched_home = work_dir / "user-like-home"
        switched_home.mkdir(parents=True, exist_ok=True)
        switched_env: dict[str, str | None] = {
            "HOME": str(switched_home), "PWD": str(switched_home),
            "XDG_CONFIG_HOME": str(switched_home / ".config"),
            "USER": None, "SHELL": None,
        }
        switched_before = outside_sync_snapshot(switched_home, root_like_sync)
        result = execute("home_switch_resync", root_like_sync_cmd + ["--resync", "--resync-auth"],
                         cwd=switched_home, env=switched_env)
        if result.returncode != 0:
            return fail("S13 user-like HOME switch resync failed")
        if "sync_dir: runtimeSyncDirectory set to: " + str(root_like_sync) not in result.stdout:
            return fail("S13 HOME switch modified absolute runtime sync_dir")
        if outside_sync_snapshot(root_like_home, root_like_sync) != root_before or \
                outside_sync_snapshot(switched_home, root_like_sync) != switched_before:
            return fail("S13 environment switch resync created outside-sync content")
        process, stdout = launch("monitor_home_switch", root_like_monitor_cmd,
                                 switched_home, switched_env)
        try:
            if self._wait_for_initial_sync_complete_or_transient_failure(
                    process, stdout, log_dir / "monitor_home_switch_stderr.log", timeout_seconds=300) != "complete":
                return fail("S13 switched-HOME monitor did not complete initial sync")
            if not self._wait_for_monitor_stdout_quiet(process, stdout, timeout_seconds=40):
                return fail("S13 switched-HOME monitor did not settle")
            if outside_sync_snapshot(root_like_home, root_like_sync) != root_before or \
                    outside_sync_snapshot(switched_home, root_like_sync) != switched_before:
                return fail("S13 changed HOME created synchronised content outside sync_dir")
        finally:
            self._shutdown_monitor_process(process, details)
        if build_typed_manifest(root_like_sync) != root_manifest:
            return fail("S13 resync-to-monitor HOME transition changed tracked content")
        details["environment_scenarios_completed"] = [f"S{i:02d}" for i in range(1, 14)]

        final_manifest = build_typed_manifest(subject_root)
        write_manifest(state_dir / "subject_final.txt", final_manifest)
        details["subject_final_manifest"] = final_manifest
        self.write_metadata(metadata_file, details)
        return self.pass_result(self.case_id, self.name, artifacts, details)
