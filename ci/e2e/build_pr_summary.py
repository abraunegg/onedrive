#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
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


def _display_case_id(value: Any) -> str:
    key = _case_key(value)
    if key.isdigit() and len(key) == 4:
        return f"TC{key}"
    if key.startswith("bsftc") or key.startswith("sfptc"):
        return key.upper()
    return str(value or "????")


def _target_title(target: str) -> str:
    normalized = target.strip().lower()
    if normalized == "sharepoint":
        return "SharePoint"
    return target.title()


def _case_counts(results: dict[str, Any]) -> tuple[int, int, int]:
    cases = results.get("cases", []) or []
    passed = sum(1 for case in cases if str(case.get("status", "")).lower() == "pass")
    failed = sum(1 for case in cases if str(case.get("status", "")).lower() == "fail")
    return len(cases), passed, failed


def _primary_failure_lines(results: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    for case in results.get("cases", []) or []:
        if str(case.get("status", "")).lower() != "fail":
            continue
        case_id = _display_case_id(case.get("id"))
        name = str(case.get("name") or "unnamed test case").strip()
        reason = str(case.get("reason") or "no reason provided").strip()
        lines.append(f"- Test Case {case_id}: {name} — {reason}")
    return lines


def _effective_results_path(artifact_dir: Path, gate: dict[str, Any] | None, primary_path: Path) -> Path:
    if not gate:
        return primary_path
    raw = str(gate.get("effective_results") or "").strip()
    if not raw:
        return primary_path
    prefix = "ci/e2e/out/"
    relative = raw[len(prefix):] if raw.startswith(prefix) else Path(raw).name
    candidate = artifact_dir / relative
    return candidate if candidate.is_file() else primary_path


def _find_primary_results(artifact_dir: Path) -> Path | None:
    direct = artifact_dir / "results.json"
    if direct.is_file():
        return direct
    for candidate in sorted(artifact_dir.rglob("results.json")):
        if "debug-rerun" not in candidate.parts:
            return candidate
    return None


def build_summary(artifact_dir: Path, default_target: str, heading: str | None = None) -> str:
    primary_path = _find_primary_results(artifact_dir)
    if primary_path is None:
        return "⚠️ E2E ran but results.json was not found."

    primary = _load_json(primary_path)
    if primary is None:
        return "⚠️ E2E ran but results.json could not be read."

    gate_path = artifact_dir / "gate.json"
    gate = _load_json(gate_path)
    effective_path = _effective_results_path(artifact_dir, gate, primary_path)
    effective = _load_json(effective_path) or primary

    target = str(primary.get("target") or default_target).strip()
    title = heading or f"{_target_title(target)} Account Testing"

    primary_total, primary_passed, primary_failed = _case_counts(primary)
    effective_total, effective_passed, effective_failed = _case_counts(effective)
    primary_failures = _primary_failure_lines(primary)

    gate_conclusion = str((gate or {}).get("conclusion") or ("success" if primary_failed == 0 else "failure")).lower()
    primary_failed_ids = [str(value) for value in (gate or {}).get("primary_failed_case_ids", []) or []]
    recovered_ids = [str(value) for value in (gate or {}).get("recovered_case_ids", []) or []]
    unrecovered_ids = [str(value) for value in (gate or {}).get("unrecovered_case_ids", []) or []]

    # Backward compatibility for gate.json files created before recovered_case_ids
    # was emitted explicitly. A fully recovered historical gate has all primary
    # failures absent from unrecovered_case_ids.
    if not recovered_ids and primary_failed_ids:
        unrecovered_set = {_case_key(value) for value in unrecovered_ids}
        if bool((gate or {}).get("recovered_by_debug_rerun")) or unrecovered_ids:
            recovered_ids = [
                value for value in primary_failed_ids if _case_key(value) not in unrecovered_set
            ]

    lines = [
        f"## {title}",
        "",
        "### Primary Run",
        f"**{primary_total}** Test Cases Run  ",
        f"**{primary_passed}** Test Cases Passed  ",
        f"**{primary_failed}** Test Cases Failed",
        "",
    ]

    if primary_failed == 0:
        lines.extend([
            "✅ Primary run passed without debug recovery.",
            "",
        ])
    else:
        lines.append("### Primary Failures")
        if primary_failures:
            lines.extend(primary_failures)
        else:
            lines.append("- Primary failure details were not present in results.json")
        lines.append("")

        lines.append("### Debug Recovery")
        if recovered_ids:
            for case_id in recovered_ids:
                lines.append(f"- Test Case {_display_case_id(case_id)}: **PASS** during debug rerun")
        if unrecovered_ids:
            for case_id in unrecovered_ids:
                lines.append(f"- Test Case {_display_case_id(case_id)}: **FAIL / NOT RECOVERED** during debug rerun")
        if not recovered_ids and not unrecovered_ids:
            lines.append("- No debug recovery result was recorded.")
        lines.append("")

        if recovered_ids and not unrecovered_ids:
            lines.append(
                f"⚠️ **{len(recovered_ids)}** primary failure(s) were recovered by targeted debug rerun(s)."
            )
            lines.append("")
        elif recovered_ids and unrecovered_ids:
            lines.append(
                f"⚠️ **{len(recovered_ids)}** primary failure(s) recovered; "
                f"**{len(unrecovered_ids)}** remained unrecovered."
            )
            lines.append("")

        lines.extend([
            "### Effective Result",
            f"**{effective_total}** Test Cases Run  ",
            f"**{effective_passed}** Test Cases Passed  ",
            f"**{effective_failed}** Test Cases Failed",
            "",
        ])

    gate_label = "PASS" if gate_conclusion == "success" else "FAIL"
    gate_icon = "✅" if gate_conclusion == "success" else "❌"
    lines.append(f"{gate_icon} **Workflow gate: {gate_label}**")

    return "\n".join(lines).rstrip() + "\n"


def _write_github_output(path: Path, markdown: str) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write("md<<EOF\n")
        handle.write(markdown)
        if not markdown.endswith("\n"):
            handle.write("\n")
        handle.write("EOF\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Build E2E PR summary with primary/debug/effective results")
    parser.add_argument("--artifact-dir", required=True)
    parser.add_argument("--default-target", required=True)
    parser.add_argument("--heading")
    parser.add_argument("--github-output")
    args = parser.parse_args()

    markdown = build_summary(Path(args.artifact_dir), args.default_target, args.heading)
    if args.github_output:
        _write_github_output(Path(args.github_output), markdown)
    else:
        print(markdown, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
