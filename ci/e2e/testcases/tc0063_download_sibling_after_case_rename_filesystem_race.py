from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import (
    command_to_string,
    compute_quickxor_hash_file,
    reset_directory,
    run_command,
    write_onedrive_config,
    write_text_file,
)


class TestCase0063DownloadSiblingAfterCaseRenameFilesystemRace(E2ETestCase):
    case_id = "0063"
    name = "download sibling after case-only folder rename filesystem race"
    description = (
        "Reproduce the user-reported shape where Documents/divers/Notes is reconciled "
        "and a sibling file Documents/divers/jeux intéressants.odt is downloaded, while "
        "forcing the post-download permission update to fail with ENOENT."
    )

    def _write_config(self, config_dir: Path, sync_dir: Path) -> None:
        config_path = config_dir / "config"
        backup_path = config_dir / ".config.backup"
        hash_path = config_dir / ".config.hash"

        config_text = (
            "# tc0063 config\n"
            f'sync_dir = "{sync_dir}"\n'
            'bypass_data_preservation = "true"\n'
            'disable_permission_set = "false"\n'
            'local_first = "true"\n'
        )

        write_onedrive_config(config_path, config_text)
        write_onedrive_config(backup_path, config_text)
        hash_path.write_text(compute_quickxor_hash_file(config_path), encoding="utf-8")
        os.chmod(config_path, 0o600)
        os.chmod(backup_path, 0o600)
        os.chmod(hash_path, 0o600)

    def _write_preload_source(self, source_path: Path) -> None:
        write_text_file(
            source_path,
            r'''#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>

static int triggered = 0;

typedef int (*chmod_fn_t)(const char *, mode_t);
typedef int (*fchmodat_fn_t)(int, const char *, mode_t, int);
typedef long (*syscall_fn_t)(long number, ...);

static int string_ends_with(const char *value, const char *suffix) {
    if (value == NULL || suffix == NULL) return 0;
    size_t value_len = strlen(value);
    size_t suffix_len = strlen(suffix);
    if (suffix_len == 0 || suffix_len > value_len) return 0;
    return strcmp(value + value_len - suffix_len, suffix) == 0;
}

static int should_fail_path(const char *path) {
    const char *target = getenv("TC0063_FAIL_PATH");
    const char *suffix = getenv("TC0063_FAIL_SUFFIX");
    if (path == NULL || triggered) return 0;
    if (target != NULL && target[0] != '\0' && strcmp(path, target) == 0) return 1;
    if (suffix != NULL && suffix[0] != '\0' && string_ends_with(path, suffix)) return 1;
    return 0;
}

static void remove_target(const char *path) {
    const char *target = getenv("TC0063_FAIL_PATH");
    triggered = 1;
    if (target != NULL && target[0] != '\0') unlink(target);
    if (path != NULL && path[0] == '/') unlink(path);
}

static int force_enoent_int(const char *function_name, const char *path) {
    fprintf(stderr, "TC0063_PRELOAD: forcing %s ENOENT for %s\n", function_name, path ? path : "(null)");
    remove_target(path);
    errno = ENOENT;
    return -1;
}

static long force_enoent_long(const char *function_name, const char *path) {
    fprintf(stderr, "TC0063_PRELOAD: forcing %s ENOENT for %s\n", function_name, path ? path : "(null)");
    remove_target(path);
    errno = ENOENT;
    return -1;
}

int chmod(const char *path, mode_t mode) {
    static chmod_fn_t real_chmod = NULL;
    if (real_chmod == NULL) real_chmod = (chmod_fn_t)dlsym(RTLD_NEXT, "chmod");
    if (should_fail_path(path)) return force_enoent_int("chmod", path);
    return real_chmod(path, mode);
}

int __chmod(const char *path, mode_t mode) {
    static chmod_fn_t real___chmod = NULL;
    if (real___chmod == NULL) real___chmod = (chmod_fn_t)dlsym(RTLD_NEXT, "__chmod");
    if (should_fail_path(path)) return force_enoent_int("__chmod", path);
    if (real___chmod != NULL) return real___chmod(path, mode);
    return chmod(path, mode);
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags) {
    static fchmodat_fn_t real_fchmodat = NULL;
    if (real_fchmodat == NULL) real_fchmodat = (fchmodat_fn_t)dlsym(RTLD_NEXT, "fchmodat");
    if (should_fail_path(path)) return force_enoent_int("fchmodat", path);
    return real_fchmodat(dirfd, path, mode, flags);
}

int __fchmodat(int dirfd, const char *path, mode_t mode, int flags) {
    static fchmodat_fn_t real___fchmodat = NULL;
    if (real___fchmodat == NULL) real___fchmodat = (fchmodat_fn_t)dlsym(RTLD_NEXT, "__fchmodat");
    if (should_fail_path(path)) return force_enoent_int("__fchmodat", path);
    if (real___fchmodat != NULL) return real___fchmodat(dirfd, path, mode, flags);
    return fchmodat(dirfd, path, mode, flags);
}

long syscall(long number, ...) {
    static syscall_fn_t real_syscall = NULL;
    if (real_syscall == NULL) real_syscall = (syscall_fn_t)dlsym(RTLD_NEXT, "syscall");

    va_list ap;
    va_start(ap, number);

#ifdef SYS_chmod
    if (number == SYS_chmod) {
        const char *path = va_arg(ap, const char *);
        mode_t mode = va_arg(ap, mode_t);
        va_end(ap);
        if (should_fail_path(path)) return force_enoent_long("syscall(SYS_chmod)", path);
        return real_syscall(number, path, mode);
    }
#endif

#ifdef SYS_fchmodat
    if (number == SYS_fchmodat) {
        int dirfd = va_arg(ap, int);
        const char *path = va_arg(ap, const char *);
        mode_t mode = va_arg(ap, mode_t);
        int flags = va_arg(ap, int);
        va_end(ap);
        if (should_fail_path(path)) return force_enoent_long("syscall(SYS_fchmodat)", path);
        return real_syscall(number, dirfd, path, mode, flags);
    }
#endif

#ifdef SYS_fchmodat2
    if (number == SYS_fchmodat2) {
        int dirfd = va_arg(ap, int);
        const char *path = va_arg(ap, const char *);
        mode_t mode = va_arg(ap, mode_t);
        int flags = va_arg(ap, int);
        va_end(ap);
        if (should_fail_path(path)) return force_enoent_long("syscall(SYS_fchmodat2)", path);
        return real_syscall(number, dirfd, path, mode, flags);
    }
#endif

    /* Forward the common six-argument syscall shape. Extra arguments are harmless for shorter syscalls. */
    long a1 = va_arg(ap, long);
    long a2 = va_arg(ap, long);
    long a3 = va_arg(ap, long);
    long a4 = va_arg(ap, long);
    long a5 = va_arg(ap, long);
    long a6 = va_arg(ap, long);
    va_end(ap);
    return real_syscall(number, a1, a2, a3, a4, a5, a6);
}
''',
        )

    def _build_preload_library(self, work_dir: Path, log_dir: Path) -> tuple[Path | None, str]:
        source_path = work_dir / "tc0063_filesystem_race.c"
        library_path = work_dir / "tc0063_filesystem_race.so"
        build_log = log_dir / "preload_build.log"
        self._write_preload_source(source_path)
        command = ["gcc", "-shared", "-fPIC", "-Wall", "-Wextra", "-O2", "-o", str(library_path), str(source_path), "-ldl"]
        completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", check=False)
        write_text_file(build_log, "command=" + command_to_string(command) + "\nreturncode=" + str(completed.returncode) + "\n\nSTDOUT:\n" + completed.stdout + "\n\nSTDERR:\n" + completed.stderr + "\n")
        if completed.returncode != 0 or not library_path.exists():
            return None, f"Failed to build tc0063 LD_PRELOAD helper; see {build_log}"
        return library_path, ""

    def _sanity_check_preload_library(self, library_path: Path, work_dir: Path, log_dir: Path) -> tuple[bool, str]:
        sanity_file = work_dir / "tc0063_preload_sanity_target.txt"
        sanity_log = log_dir / "preload_sanity.log"
        write_text_file(sanity_file, "tc0063 preload sanity check\n")
        command = ["/bin/chmod", "0600", str(sanity_file)]
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
            env=dict(os.environ, LD_PRELOAD=str(library_path), TC0063_FAIL_PATH=str(sanity_file), TC0063_FAIL_SUFFIX=sanity_file.name),
        )
        combined_output = completed.stdout + "\n" + completed.stderr
        write_text_file(
            sanity_log,
            "command=" + command_to_string(command) + "\nreturncode=" + str(completed.returncode) + "\ntarget=" + str(sanity_file) + "\ntarget_exists_after=" + str(sanity_file.exists()) + "\n\nSTDOUT:\n" + completed.stdout + "\n\nSTDERR:\n" + completed.stderr + "\n",
        )
        if "TC0063_PRELOAD: forcing" not in combined_output:
            return False, f"tc0063 LD_PRELOAD helper sanity check failed; see {sanity_log}"
        return True, ""

    def _combined_contains_bad_api_status_zero(self, output: str) -> list[str]:
        markers = [
            "ERROR: Microsoft OneDrive API returned an error",
            "HTTP request returned status code 0",
            "There was a file system error during OneDrive request",
        ]
        return [marker for marker in markers if marker in output]

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0063", ensure_refresh_token=True)
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        seed_root = case_work_dir / "seedroot"
        stale_root = case_work_dir / "staleroot"
        verify_root = case_work_dir / "verifyroot"
        conf_seed = case_work_dir / "conf-seed"
        conf_stale = case_work_dir / "conf-stale"
        conf_verify = case_work_dir / "conf-verify"
        reset_directory(seed_root)
        reset_directory(verify_root)
        context.prepare_minimal_config_dir(conf_seed, "")
        context.prepare_minimal_config_dir(conf_verify, "")
        self._write_config(conf_seed, seed_root)
        self._write_config(conf_verify, verify_root)

        root_name = f"ZZ_E2E_TC0063_{context.run_id}_{os.getpid()}"
        notes_lower = f"{root_name}/Documents/divers/notes"
        notes_upper = f"{root_name}/Documents/divers/Notes"
        sibling_relative = f"{root_name}/Documents/divers/jeux intéressants.odt"
        sibling_absolute = stale_root / sibling_relative

        seed_stdout = case_log_dir / "phase1_seed_stdout.log"
        seed_stderr = case_log_dir / "phase1_seed_stderr.log"
        remote_change_stdout = case_log_dir / "phase2_remote_change_stdout.log"
        remote_change_stderr = case_log_dir / "phase2_remote_change_stderr.log"
        stale_stdout = case_log_dir / "phase3_stale_reconcile_stdout.log"
        stale_stderr = case_log_dir / "phase3_stale_reconcile_stderr.log"
        verify_stdout = case_log_dir / "verify_stdout.log"
        verify_stderr = case_log_dir / "verify_stderr.log"
        stale_manifest_file = state_dir / "stale_manifest.txt"
        verify_manifest_file = state_dir / "verify_manifest.txt"
        metadata_file = state_dir / "metadata.txt"
        artifacts = [
            str(case_log_dir / "preload_build.log"), str(case_log_dir / "preload_sanity.log"),
            str(seed_stdout), str(seed_stderr), str(remote_change_stdout), str(remote_change_stderr),
            str(stale_stdout), str(stale_stderr), str(verify_stdout), str(verify_stderr),
            str(stale_manifest_file), str(verify_manifest_file), str(metadata_file),
        ]
        details: dict[str, object] = {
            "root_name": root_name,
            "notes_lower": notes_lower,
            "notes_upper": notes_upper,
            "sibling_relative": sibling_relative,
            "sibling_absolute": str(sibling_absolute),
        }

        preload_library, preload_error = self._build_preload_library(case_work_dir, case_log_dir)
        details["preload_library"] = str(preload_library) if preload_library else ""
        if preload_library is None:
            details["preload_error"] = preload_error
            self.write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, preload_error, artifacts, details)
        sanity_ok, sanity_error = self._sanity_check_preload_library(preload_library, case_work_dir, case_log_dir)
        details["preload_sanity_ok"] = sanity_ok
        if not sanity_ok:
            details["preload_sanity_error"] = sanity_error
            self.write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, sanity_error, artifacts, details)

        # Phase 1: seed a layout matching the user's report. Start with lowercase notes,
        # then later change only the folder case and the sibling file content remotely.
        write_text_file(seed_root / notes_lower / "note-anchor.txt", "initial notes anchor\n")
        write_text_file(seed_root / sibling_relative, "initial sibling content\n")
        seed_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--single-directory", root_name, "--confdir", str(conf_seed)]
        context.log(f"Executing Test Case {self.case_id} phase1 seed: {command_to_string(seed_command)}")
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_returncode"] = seed_result.returncode
        if seed_result.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"seed phase failed with status {seed_result.returncode}", artifacts, details)

        # Snapshot a stale client before the remote case-only rename and sibling update.
        if conf_stale.exists(): shutil.rmtree(conf_stale)
        if stale_root.exists(): shutil.rmtree(stale_root)
        shutil.copytree(conf_seed, conf_stale)
        shutil.copytree(seed_root, stale_root)
        self._write_config(conf_stale, stale_root)
        details["stale_sibling_exists_before_reconcile"] = sibling_absolute.is_file()

        # Phase 2: remote-side case-only folder rename plus sibling modification.
        # This approximates the user clue: Documents/divers/Notes was the folder involved,
        # while Documents/divers/jeux intéressants.odt was the sibling file that failed.
        (seed_root / notes_lower).rename(seed_root / notes_upper)
        write_text_file(seed_root / sibling_relative, "updated sibling content to force download\n")
        remote_change_command = [context.onedrive_bin, "--display-running-config", "--sync", "--verbose", "--single-directory", root_name, "--confdir", str(conf_seed)]
        context.log(f"Executing Test Case {self.case_id} phase2 remote change: {command_to_string(remote_change_command)}")
        remote_change_result = run_command(remote_change_command, cwd=context.repo_root)
        write_text_file(remote_change_stdout, remote_change_result.stdout)
        write_text_file(remote_change_stderr, remote_change_result.stderr)
        details["remote_change_returncode"] = remote_change_result.returncode
        if remote_change_result.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, f"remote-change phase failed with status {remote_change_result.returncode}", artifacts, details)

        # Phase 3: stale client reconciles the case-only folder rename and downloads the sibling update.
        # LD_PRELOAD removes the sibling at the post-download chmod/setAttributes point to force the race.
        stale_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose", "--single-directory", root_name, "--confdir", str(conf_stale)]
        preload_env = {"LD_PRELOAD": str(preload_library), "TC0063_FAIL_PATH": str(sibling_absolute), "TC0063_FAIL_SUFFIX": sibling_relative}
        context.log(f"Executing Test Case {self.case_id} phase3 stale reconcile: {command_to_string(stale_command)}")
        stale_result = run_command(stale_command, cwd=context.repo_root, env=preload_env)
        write_text_file(stale_stdout, stale_result.stdout)
        write_text_file(stale_stderr, stale_result.stderr)
        stale_manifest = build_manifest(stale_root)
        write_manifest(stale_manifest_file, stale_manifest)

        combined_output = stale_result.stdout + "\n" + stale_result.stderr
        details.update({
            "stale_returncode": stale_result.returncode,
            "preload_marker_seen": "TC0063_PRELOAD: forcing" in combined_output,
            "filesystem_error_seen": "ERROR: The local file system returned an error" in combined_output,
            "api_status_zero_seen": "HTTP request returned status code 0" in combined_output,
            "api_error_seen": "ERROR: Microsoft OneDrive API returned an error" in combined_output,
            "sibling_exists_after_reconcile": sibling_absolute.exists(),
            "stale_manifest_contains_notes_upper": any(entry.startswith(notes_upper) for entry in stale_manifest),
            "stale_manifest_contains_notes_lower": any(entry.startswith(notes_lower) for entry in stale_manifest),
        })

        verify_command = [context.onedrive_bin, "--display-running-config", "--sync", "--download-only", "--verbose", "--single-directory", root_name, "--confdir", str(conf_verify)]
        verify_result = run_command(verify_command, cwd=context.repo_root)
        write_text_file(verify_stdout, verify_result.stdout)
        write_text_file(verify_stderr, verify_result.stderr)
        verify_manifest = build_manifest(verify_root)
        write_manifest(verify_manifest_file, verify_manifest)
        details["verify_returncode"] = verify_result.returncode
        self.write_metadata(metadata_file, details)

        if "TC0063_PRELOAD: forcing" not in combined_output:
            return self.fail_result(
                self.case_id,
                self.name,
                "tc0063 did not force the sibling post-download chmod/setAttributes filesystem race; LD_PRELOAD helper was not triggered",
                artifacts,
                details,
            )
        if "ERROR: The local file system returned an error" not in combined_output:
            return self.fail_result(self.case_id, self.name, "Expected local filesystem error was not reported", artifacts, details)
        present_misleading_markers = self._combined_contains_bad_api_status_zero(combined_output)
        if present_misleading_markers:
            return self.fail_result(
                self.case_id,
                self.name,
                "Local filesystem race was misreported as a Microsoft OneDrive API / HTTP status 0 error: " + ", ".join(present_misleading_markers),
                artifacts,
                details,
            )
        return self.pass_result(self.case_id, self.name, artifacts, details)
