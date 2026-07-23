from __future__ import annotations

import shutil
import traceback
from pathlib import Path

from framework.context import E2EContext
from framework.result import TestResult
from framework.utils import command_to_string, ensure_directory, run_command_logged, write_text_file

AUTH_PREFLIGHT_CASE_ID = "0000"
AUTH_PREFLIGHT_NAME = "auth preflight"


_ACCOUNT_LABEL_BY_TARGET = {
    "business": "Business",
    "sharepoint": "SharePoint",
    "personal": "Personal",
    "business-shared-folders": "Business Shared Folder",
    "personal-shared-folders": "Personal Shared Folder",
}


def account_label_for_context(context: E2EContext) -> str:
    """Return the human-facing account label used in fail-fast auth messages."""
    if context.account_label:
        return context.account_label
    return _ACCOUNT_LABEL_BY_TARGET.get(context.e2e_target, context.e2e_target or "unknown")


def _auth_failure_reason(account_label: str, suffix: str) -> str:
    return (
        f"E2E auth preflight failed for {account_label}: {suffix}. "
        f"Re-authenticate the {account_label} account/configuration before rerunning this workflow."
    )


def run_auth_preflight(context: E2EContext) -> TestResult:
    """
    Validate that the selected E2E account can authenticate before any suite
    cleanup or testcase execution is allowed to run.

    The preflight uses an isolated config/sync root and the non-mutating
    --display-sync-status path so expired refresh tokens fail immediately and
    clearly, without deleting or synchronising account content.
    """
    account_label = account_label_for_context(context)
    preflight_root = context.work_root / "auth-preflight"
    config_dir = preflight_root / "conf"
    sync_dir = preflight_root / "syncroot"
    log_dir = context.logs_dir / "_auth_preflight"

    stdout_file = log_dir / "auth_preflight_stdout.log"
    stderr_file = log_dir / "auth_preflight_stderr.log"
    command_file = log_dir / "auth_preflight_command.txt"
    exception_file = log_dir / "auth_preflight_exception.log"

    artifacts = [
        str(stdout_file),
        str(stderr_file),
        str(command_file),
    ]

    details: dict[str, object] = {
        "failure_stage": "auth_preflight",
        "non_rerunnable": True,
        "account_label": account_label,
        "target": context.e2e_target,
        "run_label": context.run_label,
        "preflight_sync_dir": str(sync_dir),
        "preflight_config_dir": str(config_dir),
    }

    try:
        if preflight_root.exists():
            shutil.rmtree(preflight_root)
        ensure_directory(sync_dir)
        ensure_directory(log_dir)

        context.prepare_minimal_config_dir(
            config_dir,
            (
                "# E2E auth preflight\n"
                f'sync_dir = "{sync_dir}"\n'
                'bypass_data_preservation = "true"\n'
            ),
        )

        command = [
            context.onedrive_bin,
            "--display-running-config",
            "--display-sync-status",
            "--verbose",
            "--syncdir",
            str(sync_dir),
            "--confdir",
            str(config_dir),
        ]
        write_text_file(command_file, command_to_string(command) + "\n")
        details["command"] = command_to_string(command)

        context.log(f"Running E2E auth preflight for {account_label}: {command_to_string(command)}")
        result = run_command_logged(
            command,
            stdout_file=stdout_file,
            stderr_file=stderr_file,
            cwd=context.repo_root,
        )
        details["returncode"] = result.returncode

        if result.returncode == 0:
            return TestResult.pass_result(
                case_id=AUTH_PREFLIGHT_CASE_ID,
                name=AUTH_PREFLIGHT_NAME,
                artifacts=artifacts,
                details={**details, "non_rerunnable": False},
            )

        return TestResult.fail_result(
            case_id=AUTH_PREFLIGHT_CASE_ID,
            name=AUTH_PREFLIGHT_NAME,
            reason=_auth_failure_reason(account_label, f"OneDrive startup/auth validation returned status {result.returncode}"),
            artifacts=artifacts,
            details=details,
        )

    except Exception as exc:
        tb = traceback.format_exc()
        write_text_file(exception_file, tb)
        artifacts.append(str(exception_file))
        details["exception_type"] = type(exc).__name__
        details["exception_message"] = str(exc)

        return TestResult.fail_result(
            case_id=AUTH_PREFLIGHT_CASE_ID,
            name=AUTH_PREFLIGHT_NAME,
            reason=_auth_failure_reason(account_label, str(exc)),
            artifacts=artifacts,
            details=details,
        )
