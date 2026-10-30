#!/usr/bin/env python3
"""Mandatory final cleanup after the targeted E2E debug-recovery phase.

This runs independently of test execution and preserves all diagnostic output.
"""
from __future__ import annotations

import argparse
import json
import traceback
from pathlib import Path

from framework.context import E2EContext
from framework.utils import perform_full_account_cleanup


def main() -> int:
    parser = argparse.ArgumentParser(description="Clean remote E2E fixtures after debug recovery")
    parser.add_argument("--result", default="ci/e2e/out/post-debug-cleanup.json")
    args = parser.parse_args()
    result_path = Path(args.result)
    result_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"status": "fail", "reason": "Cleanup did not complete", "artifacts": [], "details": {}}
    try:
        context = E2EContext.from_environment()
        context.prepare_runtime()
        # A separate config/database prevents interference with captured debug evidence.
        context.bootstrap_suite_cleanup_config_dir()
        print("Starting mandatory post-debug account cleanup", flush=True)
        ok, reason, artifacts, details = perform_full_account_cleanup(
            onedrive_bin=context.real_onedrive_bin,
            repo_root=context.repo_root,
            config_dir=context.suite_cleanup_config_dir,
            sync_dir=context.default_sync_dir,
            log_dir=context.logs_dir / "_post_debug_cleanup",
        )
        payload = {"status": "pass" if ok else "fail", "reason": reason,
                   "artifacts": artifacts, "details": details}
    except Exception as exc:
        payload["reason"] = f"Post-debug cleanup exception: {exc}"
        payload["details"] = {"traceback": traceback.format_exc()}
    finally:
        result_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"Post-debug cleanup: {payload['status']} {payload['reason']}", flush=True)
    return 0 if payload["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
