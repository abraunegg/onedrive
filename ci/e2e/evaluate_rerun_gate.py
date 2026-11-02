#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path
from typing import Any, Iterable, Mapping


def case_ids(results: Mapping[str, Any]) -> list[str]:
    entries = results.get("cases")
    if not isinstance(entries, list):
        raise ValueError("E2E results have no cases array")
    ids: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise ValueError("E2E case record missing ID")
        if entry.get("status") not in ("pass", "fail"):
            raise ValueError(f"E2E case {entry['id']} has invalid status")
        ids.append(entry["id"])
    if not ids or len(ids) != len(set(ids)):
        raise ValueError("E2E results have no cases, or duplicate case IDs")
    return ids


def verify_debug_recovery(
    primary_case: Mapping[str, Any], debug_case: Mapping[str, Any],
    *, debug_selected: Iterable[str] | None,
) -> tuple[bool, str]:
    """A case-level PASS is not evidence of targeted scenario execution."""
    if debug_case.get("status") != "pass":
        return False, "debug case did not pass"
    details = primary_case.get("details") or {}
    failures = details.get("failed_scenario_ids")
    if failures is not None and (not isinstance(failures, list) or not failures):
        return False, "primary scenario failure IDs absent/invalid"
    original_executed = details.get("executed_scenario_ids")
    if original_executed is None:
        original_executed = details.get("executed_scenarios")
    expected = set(failures) if failures else set(original_executed or [])
    if not expected:
        if debug_selected:
            return False, "debug run selected scenarios but primary did not identify them"
        return True, "whole-case recovery (no selectable scenario metadata)"
    result_details = debug_case.get("details") or {}
    actual = result_details.get("executed_scenario_ids")
    if actual is None:
        actual = result_details.get("executed_scenarios")
    if not isinstance(actual, list) or len(actual) != len(set(actual)):
        return False, f"debug execution {actual!r} is absent or duplicated"
    if not debug_selected:
        # Some cases and both shared-folder workflows intentionally rerun the
        # whole case, even if the primary failure has scenario-level metadata.
        # The full original set must re-execute, not merely the failed subset.
        if not original_executed or set(actual) != set(original_executed):
            return False, "whole-case debug rerun did not execute all primary scenarios"
        if not expected <= set(actual):
            return False, "whole-case debug rerun omitted primary failed scenario(s)"
    elif set(debug_selected or []) != expected or set(actual) != expected:
        return False, (f"debug selection {sorted(debug_selected or [])} and "
                       f"execution {actual} differ from required {sorted(expected)}")
    if set(result_details.get("not_applicable_scenario_ids") or []) & expected:
        return False, "selected scenario was not applicable in debug run"
    return True, "exact requested scenarios executed and passed"


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


def _is_non_rerunnable_failure(case: dict[str, Any]) -> bool:
    details = case.get("details") or {}
    # Authentication/initial cleanup (0000) and final permanent cleanup (9999)
    # are not test cases and must never become recoverable by a case debug rerun.
    return _case_key(case.get("id")) in ("0000", "9999") or details.get("non_rerunnable") is True


def _failure_reasons(cases: dict[str, dict[str, Any]]) -> list[str]:
    reasons: list[str] = []
    for case_id, case in sorted(cases.items()):
        reason = str(case.get("reason") or "").strip()
        if reason:
            reasons.append(f"{case_id}: {reason}")
    return reasons


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def _build_effective_results(
    primary: dict[str, Any],
    debug_cases: dict[str, dict[str, Any]],
    recovered_case_ids: set[str],
) -> dict[str, Any]:
    effective = copy.deepcopy(primary)
    effective_cases: list[dict[str, Any]] = []

    for primary_case in primary.get("cases", []) or []:
        case_id = _case_key(primary_case.get("id"))
        if case_id in recovered_case_ids:
            recovered = copy.deepcopy(debug_cases[case_id])
            recovered["primary_status"] = "fail"
            recovered["primary_failure_reason"] = primary_case.get("reason", "")
            recovered["recovery_source"] = "debug_rerun"
            effective_cases.append(recovered)
        else:
            effective_cases.append(copy.deepcopy(primary_case))

    effective["cases"] = effective_cases
    return effective


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate final E2E gate status after optional debug rerun")
    parser.add_argument("--primary-results", default="ci/e2e/out/results.json")
    parser.add_argument("--debug-results", default="ci/e2e/out/debug-rerun/results.json")
    parser.add_argument("--gate-file", default="ci/e2e/out/gate.json")
    parser.add_argument("--cleanup-results", help="Required post-debug cleanup result JSON")
    args = parser.parse_args()

    primary_path = Path(args.primary_results)
    debug_path = Path(args.debug_results)
    gate_path = Path(args.gate_file)

    if args.cleanup_results:
        cleanup_path = Path(args.cleanup_results)
        try:
            cleanup = _load_json(cleanup_path)
        except (ValueError, OSError) as exc:
            cleanup = {"status": "fail", "reason": f"Invalid cleanup result: {exc}"}
        if not cleanup or cleanup.get("status") != "pass":
            reason = (cleanup or {}).get("reason") or "Missing post-debug cleanup result"
            payload = {
                "conclusion": "failure",
                "recovered_by_debug_rerun": False,
                "reason": f"Mandatory post-debug cleanup failed: {reason}",
                "primary_results": str(primary_path),
                "debug_results": str(debug_path),
                "cleanup_results": str(cleanup_path),
                "effective_results": str(primary_path),
                "primary_failed_case_ids": [], "debug_failed_case_ids": [],
                "recovered_case_ids": [], "unrecovered_case_ids": [],
            }
            _write_json(gate_path, payload)
            print(payload["reason"])
            return 1

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
            "primary_failed_case_ids": [],
            "debug_failed_case_ids": [],
            "recovered_case_ids": [],
            "unrecovered_case_ids": [],
        }
        _write_json(gate_path, payload)
        print(payload["reason"])
        return 1

    # Do not accept an empty, duplicated or incomplete primary result set.
    try:
        primary_ids = case_ids(primary)
        planned_ids = primary.get("executed_case_ids") or []
        actual_ids = [_case_key(value) for value in primary_ids]
        expected_ids = [_case_key(value) for value in planned_ids]
        if (not expected_ids or len(expected_ids) != len(set(expected_ids)) or
                len(actual_ids) != len(set(actual_ids)) or
                set(actual_ids) != set(expected_ids)):
            # Authentication / suite-cleanup sentinel cases still make a failed
            # run, never a valid success or recoverable test-case result.
            if not any(_case_key(item.get("id")) in ("0000", "9999")
                       for item in primary.get("cases", [])):
                raise ValueError("primary results do not match the executed-case plan")
    except (ValueError, TypeError) as exc:
        payload = {
            "conclusion": "failure", "recovered_by_debug_rerun": False,
            "reason": f"Invalid or incomplete primary E2E results: {exc}",
            "primary_results": str(primary_path), "debug_results": str(debug_path),
            "effective_results": str(primary_path),
            "primary_failed_case_ids": [], "debug_failed_case_ids": [],
            "recovered_case_ids": [], "unrecovered_case_ids": [],
        }
        _write_json(gate_path, payload)
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
            "recovered_case_ids": [],
            "unrecovered_case_ids": [],
        }
        _write_json(gate_path, payload)
        print(payload["reason"])
        return 0

    non_rerunnable_failures = {
        case_id: case
        for case_id, case in primary_failures.items()
        if _is_non_rerunnable_failure(case)
    }
    if non_rerunnable_failures:
        reason_lines = _failure_reasons(non_rerunnable_failures)
        payload = {
            "conclusion": "failure",
            "recovered_by_debug_rerun": False,
            "reason": "Primary E2E run failed during a non-rerunnable harness stage",
            "primary_results": str(primary_path),
            "debug_results": str(debug_path),
            "effective_results": str(primary_path),
            "primary_failed_case_ids": sorted(primary_failures),
            "debug_failed_case_ids": [],
            "recovered_case_ids": [],
            "unrecovered_case_ids": sorted(primary_failures),
            "non_rerunnable_case_ids": sorted(non_rerunnable_failures),
            "non_rerunnable_reasons": reason_lines,
        }
        _write_json(gate_path, payload)
        print(payload["reason"])
        for line in reason_lines:
            print(line)
        return 1

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
            "recovered_case_ids": [],
            "unrecovered_case_ids": sorted(primary_failures),
        }
        _write_json(gate_path, payload)
        print(payload["reason"])
        return 1

    try:
        debug_ids = case_ids(debug)
        expected_debug = set(primary_failures)
        observed_debug = {_case_key(value) for value in debug_ids}
        selected_debug = {_case_key(value) for value in (debug.get("selected_case_ids") or [])}
        if (len(debug_ids) != len(observed_debug) or
                observed_debug != expected_debug or selected_debug != expected_debug):
            raise ValueError(f"debug case coverage {sorted(observed_debug)} and selected "
                             f"{sorted(selected_debug)} do not match primary failures "
                             f"{sorted(expected_debug)}")
    except (ValueError, TypeError) as exc:
        payload = {
            "conclusion": "failure", "recovered_by_debug_rerun": False,
            "reason": f"Invalid debug rerun coverage: {exc}",
            "primary_results": str(primary_path), "debug_results": str(debug_path),
            "effective_results": str(primary_path),
            "primary_failed_case_ids": sorted(primary_failures),
            "debug_failed_case_ids": [], "recovered_case_ids": [],
            "unrecovered_case_ids": sorted(primary_failures),
        }
        _write_json(gate_path, payload)
        print(payload["reason"])
        return 1

    debug_cases = _case_map(debug)
    debug_failures = _failed_cases(debug)
    unrecovered: list[str] = []
    recovery_evidence: dict[str, str] = {}
    for case_id in sorted(primary_failures):
        debug_case = debug_cases.get(case_id)
        debug_selected = (debug.get("selected_scenarios") or {}).get(case_id, [])
        if not debug_case:
            unrecovered.append(case_id)
            recovery_evidence[case_id] = "debug case missing"
            continue
        recovered, explanation = verify_debug_recovery(
            primary_failures[case_id], debug_case, debug_selected=debug_selected,
        )
        recovery_evidence[case_id] = explanation
        if not recovered:
            unrecovered.append(case_id)

    recovered_case_ids = set(primary_failures) - set(unrecovered)
    effective_results_path = primary_path

    if recovered_case_ids:
        effective_path = gate_path.with_name("effective-results.json")
        effective_results = _build_effective_results(primary, debug_cases, recovered_case_ids)
        _write_json(effective_path, effective_results)
        effective_results_path = effective_path

    if unrecovered:
        payload = {
            "conclusion": "failure",
            "recovered_by_debug_rerun": False,
            "reason": "Primary E2E run failed and one or more failed cases did not pass during debug rerun",
            "primary_results": str(primary_path),
            "debug_results": str(debug_path),
            "effective_results": str(effective_results_path),
            "primary_failed_case_ids": sorted(primary_failures),
            "debug_failed_case_ids": sorted(debug_failures),
            "recovered_case_ids": sorted(recovered_case_ids),
            "unrecovered_case_ids": unrecovered,
        }
        _write_json(gate_path, payload)
        print(payload["reason"])
        if recovered_case_ids:
            print("Recovered case ids:", ",".join(sorted(recovered_case_ids)))
        print("Unrecovered case ids:", ",".join(unrecovered))
        return 1

    payload = {
        "conclusion": "success",
        "recovered_by_debug_rerun": True,
        "reason": "Primary E2E run failed, but all failed cases passed during debug rerun",
        "primary_results": str(primary_path),
        "debug_results": str(debug_path),
        "effective_results": str(effective_results_path),
        "primary_failed_case_ids": sorted(primary_failures),
        "debug_failed_case_ids": sorted(debug_failures),
        "recovered_case_ids": sorted(recovered_case_ids),
        "unrecovered_case_ids": [],
        "debug_recovery_evidence": recovery_evidence,
    }
    _write_json(gate_path, payload)
    print(payload["reason"])
    print("Recovered case ids:", ",".join(sorted(recovered_case_ids)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
