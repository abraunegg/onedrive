from __future__ import annotations

import os
import subprocess
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import command_to_string, run_command, write_onedrive_config, write_text_file


class TestCase0063DownloadPostChmodRaceReporting(E2ETestCase):
    case_id = "0063"
    name = "download post-permission filesystem race reporting"
    description = (
        "Force a local filesystem race during post-download permission application "
        "and validate it is reported as a filesystem error, not a Microsoft API/HTTP status 0 error"
    )

    def _write_config(self, config_path: Path) -> None:
        write_onedrive_config(
            config_path,
            "# tc0063 config\n"
            "bypass_data_preservation = \"true\"\n"
            "disable_permission_set = \"false\"\n",
        )

    def _write_preload_source(self, source_path: Path) -> None:
        write_text_file(
            source_path,
            r'''#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static int triggered = 0;

typedef int (*chmod_fn_t)(const char *, mode_t);
typedef int (*fchmodat_fn_t)(int, const char *, mode_t, int);

static int should_fail_path(const char *path) {
    const char *target = getenv("TC0063_FAIL_CHMOD_PATH");
    if (path == NULL || target == NULL || target[0] == '\0' || triggered) {
        return 0;
    }
    return strcmp(path, target) == 0;
}

static void remove_target(const char *path) {
    triggered = 1;
    unlink(path);
}

int chmod(const char *path, mode_t mode) {
    static chmod_fn_t real_chmod = NULL;
    if (real_chmod == NULL) {
        real_chmod = (chmod_fn_t)dlsym(RTLD_NEXT, "chmod");
    }

    if (should_fail_path(path)) {
        fprintf(stderr, "TC0063_PRELOAD: forcing chmod ENOENT for %s\n", path);
        remove_target(path);
        errno = ENOENT;
        return -1;
    }

    return real_chmod(path, mode);
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags) {
    static fchmodat_fn_t real_fchmodat = NULL;
    if (real_fchmodat == NULL) {
        real_fchmodat = (fchmodat_fn_t)dlsym(RTLD_NEXT, "fchmodat");
    }

    if (path != NULL && path[0] == '/' && should_fail_path(path)) {
        fprintf(stderr, "TC0063_PRELOAD: forcing fchmodat ENOENT for %s\n", path);
        remove_target(path);
        errno = ENOENT;
        return -1;
    }

    return real_fchmodat(dirfd, path, mode, flags);
}
''',
        )

    def _build_preload_library(self, work_dir: Path, log_dir: Path) -> tuple[Path | None, str]:
        source_path = work_dir / "tc0063_chmod_race.c"
        library_path = work_dir / "tc0063_chmod_race.so"
        build_log = log_dir / "preload_build.log"
        self._write_preload_source(source_path)

        command = [
            "gcc",
            "-shared",
            "-fPIC",
            "-Wall",
            "-Wextra",
            "-O2",
            "-o",
            str(library_path),
            str(source_path),
            "-ldl",
        ]
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        write_text_file(
            build_log,
            "command=" + command_to_string(command) + "\n"
            "returncode=" + str(completed.returncode) + "\n\n"
            "STDOUT:\n" + completed.stdout + "\n\n"
            "STDERR:\n" + completed.stderr + "\n",
        )

        if completed.returncode != 0 or not library_path.exists():
            return None, f"Failed to build tc0063 LD_PRELOAD helper; see {build_log}"
        return library_path, ""

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(
            context,
            case_dir_name="tc0063",
            ensure_refresh_token=True,
        )
        case_work_dir = layout.work_dir
        case_log_dir = layout.log_dir
        state_dir = layout.state_dir

        seed_root = case_work_dir / "seedroot"
        seed_conf = case_work_dir / "conf-seed"
        download_root = case_work_dir / "downloadroot"
        download_conf = case_work_dir / "conf-download"
        root_name = f"ZZ_E2E_TC0063_{context.run_id}_{os.getpid()}"
        target_relative = f"{root_name}/race-target.txt"
        target_absolute = download_root / root_name / "race-target.txt"

        context.bootstrap_config_dir(seed_conf)
        self._write_config(seed_conf / "config")
        context.bootstrap_config_dir(download_conf)
        self._write_config(download_conf / "config")

        write_text_file(seed_root / root_name / "race-target.txt", "TC0063 post-download chmod race target\n")

        preload_library, preload_error = self._build_preload_library(case_work_dir, case_log_dir)

        seed_stdout = case_log_dir / "seed_stdout.log"
        seed_stderr = case_log_dir / "seed_stderr.log"
        download_stdout = case_log_dir / "download_stdout.log"
        download_stderr = case_log_dir / "download_stderr.log"
        download_manifest_file = state_dir / "download_manifest.txt"
        metadata_file = state_dir / "metadata.txt"

        artifacts = [
            str(case_log_dir / "preload_build.log"),
            str(seed_stdout),
            str(seed_stderr),
            str(download_stdout),
            str(download_stderr),
            str(download_manifest_file),
            str(metadata_file),
        ]

        details: dict[str, object] = {
            "root_name": root_name,
            "target_relative": target_relative,
            "target_absolute": str(target_absolute),
            "preload_library": str(preload_library) if preload_library else "",
        }

        if preload_library is None:
            details["preload_error"] = preload_error
            self.write_metadata(metadata_file, details)
            return self.fail_result(self.case_id, self.name, preload_error, artifacts, details)

        seed_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(seed_root),
            "--confdir",
            str(seed_conf),
        ]
        seed_result = run_command(seed_command, cwd=context.repo_root)
        write_text_file(seed_stdout, seed_result.stdout)
        write_text_file(seed_stderr, seed_result.stderr)
        details["seed_command"] = command_to_string(seed_command)
        details["seed_returncode"] = seed_result.returncode

        if seed_result.returncode != 0:
            self.write_metadata(metadata_file, details)
            return self.fail_result(
                self.case_id,
                self.name,
                f"Remote seed failed with status {seed_result.returncode}",
                artifacts,
                details,
            )

        download_command = [
            context.onedrive_bin,
            "--display-running-config",
            "--sync",
            "--verbose",
            "--download-only",
            "--resync",
            "--resync-auth",
            "--syncdir",
            str(download_root),
            "--confdir",
            str(download_conf),
        ]
        preload_env = {
            "LD_PRELOAD": str(preload_library),
            "TC0063_FAIL_CHMOD_PATH": str(target_absolute),
        }
        download_result = run_command(download_command, cwd=context.repo_root, env=preload_env)
        write_text_file(download_stdout, download_result.stdout)
        write_text_file(download_stderr, download_result.stderr)

        download_manifest = build_manifest(download_root)
        write_manifest(download_manifest_file, download_manifest)

        combined_output = download_result.stdout + "\n" + download_result.stderr
        details.update(
            {
                "download_command": command_to_string(download_command),
                "download_returncode": download_result.returncode,
                "preload_marker_seen": "TC0063_PRELOAD: forcing" in combined_output,
                "filesystem_error_seen": "ERROR: The local file system returned an error" in combined_output,
                "api_status_zero_seen": "HTTP request returned status code 0" in combined_output,
                "api_error_seen": "ERROR: Microsoft OneDrive API returned an error" in combined_output,
                "target_exists_after_download": target_absolute.exists(),
            }
        )
        self.write_metadata(metadata_file, details)

        if "TC0063_PRELOAD: forcing" not in combined_output:
            return self.fail_result(
                self.case_id,
                self.name,
                "tc0063 did not force the post-download chmod/setAttributes race; LD_PRELOAD helper was not triggered",
                artifacts,
                details,
            )

        if "ERROR: The local file system returned an error" not in combined_output:
            return self.fail_result(
                self.case_id,
                self.name,
                "Expected local filesystem error was not reported",
                artifacts,
                details,
            )

        misleading_markers = [
            "ERROR: Microsoft OneDrive API returned an error",
            "HTTP request returned status code 0",
            "There was a file system error during OneDrive request",
        ]
        present_misleading_markers = [marker for marker in misleading_markers if marker in combined_output]
        if present_misleading_markers:
            return self.fail_result(
                self.case_id,
                self.name,
                "Local filesystem race was misreported as a Microsoft OneDrive API / HTTP status 0 error: "
                + ", ".join(present_misleading_markers),
                artifacts,
                details,
            )

        return self.pass_result(self.case_id, self.name, artifacts, details)
