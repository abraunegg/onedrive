#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def _load_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _case_key(value: Any) -> str:
    text = str(value or "").strip().lower()
    if text.startswith("tc") and text[2:].isdigit():
        return text[2:].zfill(4)
    if text.startswith("bsftc") and text[5:].isdigit():
        return f"bsftc{text[5:].zfill(4)}"
    if text.startswith("sfptc") and text[5:].isdigit():
        return f"sfptc{text[5:].zfill(4)}"
    if text.startswith("bsf") and text[3:].isdigit():
        return f"bsftc{text[3:].zfill(4)}"
    if text.startswith("sfp") and text[3:].isdigit():
        return f"sfptc{text[3:].zfill(4)}"
    if text.isdigit() and len(text) <= 4:
        return text.zfill(4)
    return text


def _case_map(results: dict[str, Any] | None) -> dict[str, dict[str, Any]]:
    if not results:
        return {}
    mapped: dict[str, dict[str, Any]] = {}
    for case in results.get("cases", []) or []:
        key = _case_key(case.get("id"))
        if key:
            mapped[key] = case
    return mapped


def _failed_cases(results: dict[str, Any] | None) -> dict[str, dict[str, Any]]:
    return {
        key: case
        for key, case in _case_map(results).items()
        if str(case.get("status", "")).lower() != "pass"
    }


def _write_gate(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate final E2E gate status after optional debug rerun")
    parser.add_argument("--primary-results", default="ci/e2e/out/results.json")
    parser.add_argument("--debug-results", default="ci/e2e/out/debug-rerun/results.json")
    parser.add_argument("--gate-file", default="ci/e2e/out/gate.json")
    args = parser.parse_args()

    primary_path = Path(args.primary_results)
    debug_path = Path(args.debug_results)
    gate_path = Path(args.gate_file)

    primary = _load_json(primary_path)
    debug = _load_json(debug_path)

    if primary is None:
        payload = {
            "conclusion": "failure",
            "recovered_by_debug_rerun": False,
            "reason": f"Primary results file not found: {primary_path}",
            "primary_results": str(primary_path),
            "debug_results": str(debug_path),
            "effective_results": None,
        }
        _write_gate(gate_path, payload)
        print(payload["reason"])
        return 1

    primary_failures = _failed_cases(primary)
    if not primary_failures:
        payload = {
            "conclusion": "success",
            "recovered_by_debug_rerun": False,
            "reason": "Primary E2E run passed without debug recovery",
            "primary_results": str(primary_path),
            "debug_results": str(debug_path),
            "effective_results": str(primary_path),
            "primary_failed_case_ids": [],
            "debug_failed_case_ids": [],
            "unrecovered_case_ids": [],
        }
        _write_gate(gate_path, payload)
        print(payload["reason"])
        return 0

    if debug is None:
        payload = {
            "conclusion": "failure",
            "recovered_by_debug_rerun": False,
            "reason": f"Primary E2E run failed and debug rerun results file was not found: {debug_path}",
            "primary_results": str(primary_path),
            "debug_results": str(debug_path),
            "effective_results": str(primary_path),
            "primary_failed_case_ids": sorted(primary_failures),
            "debug_failed_case_ids": [],
            "unrecovered_case_ids": sorted(primary_failures),
        }
        _write_gate(gate_path, payload)
        print(payload["reason"])
        return 1

    debug_cases = _case_map(debug)
    debug_failures = _failed_cases(debug)
    unrecovered: list[str] = []
    for case_id in sorted(primary_failures):
        debug_case = debug_cases.get(case_id)
        if not debug_case or str(debug_case.get("status", "")).lower() != "pass":
            unrecovered.append(case_id)

    if unrecovered:
        payload = {
            "conclusion": "failure",
            "recovered_by_debug_rerun": False,
            "reason": "Primary E2E run failed and one or more failed cases did not pass during debug rerun",
            "primary_results": str(primary_path),
            "debug_results": str(debug_path),
            "effective_results": str(primary_path),
            "primary_failed_case_ids": sorted(primary_failures),
            "debug_failed_case_ids": sorted(debug_failures),
            "unrecovered_case_ids": unrecovered,
        }
        _write_gate(gate_path, payload)
        print(payload["reason"])
        print("Unrecovered case ids:", ",".join(unrecovered))
        return 1

    payload = {
        "conclusion": "success",
        "recovered_by_debug_rerun": True,
        "reason": "Primary E2E run failed, but all failed cases passed during debug rerun",
        "primary_results": str(primary_path),
        "debug_results": str(debug_path),
        "effective_results": str(debug_path),
        "primary_failed_case_ids": sorted(primary_failures),
        "debug_failed_case_ids": sorted(debug_failures),
        "unrecovered_case_ids": [],
    }
    _write_gate(gate_path, payload)
    print(payload["reason"])
    print("Recovered case ids:", ",".join(sorted(primary_failures)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
