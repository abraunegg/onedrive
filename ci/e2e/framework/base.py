from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from framework.context import E2EContext
from framework.manifest import build_manifest, write_manifest
from framework.result import TestResult
from framework.utils import reset_directory, write_text_file


@dataclass(frozen=True)
class CaseLayout:
    """Standard per-case working layout inside the E2E harness."""

    case_id: str
    work_dir: Path
    log_dir: Path
    state_dir: Path


class E2ETestCase(ABC):
    """
    Base class for all E2E test cases.

    The class now provides a shared set of helper methods so every testcase can
    follow the same harness process for:
    - preparing per-case directories
    - writing metadata/artifacts
    - returning pass/fail results consistently
    - performing basic filesystem assertions
    """

    case_id: str = ""
    name: str = ""
    description: str = ""

    @abstractmethod
    def run(self, context: E2EContext) -> TestResult:
        """Execute the test case and return a structured TestResult."""
        raise NotImplementedError

    def prepare_case_layout(
        self,
        context: E2EContext,
        *,
        case_dir_name: str | None = None,
        ensure_refresh_token: bool = True,
        extra_reset_paths: Iterable[Path] | None = None,
    ) -> CaseLayout:
        """
        Reset the standard work/log/state directories for a testcase and return
        their paths in a single structured object.
        """
        directory_name = case_dir_name or f"tc{self.case_id}"
        layout = CaseLayout(
            case_id=self.case_id,
            work_dir=context.work_root / directory_name,
            log_dir=context.logs_dir / directory_name,
            state_dir=context.state_dir / directory_name,
        )

        reset_directory(layout.work_dir)
        reset_directory(layout.log_dir)
        reset_directory(layout.state_dir)

        if extra_reset_paths:
            for path in extra_reset_paths:
                reset_directory(path)

        if ensure_refresh_token:
            context.ensure_refresh_token_available()

        return layout

    def write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        write_text_file(
            metadata_file,
            "\n".join(f"{key}={value!r}" for key, value in sorted(details.items())) + "\n",
        )

    def _write_metadata(self, metadata_file: Path, details: dict[str, object]) -> None:
        """Backward-compatible alias used by existing testcase implementations."""
        self.write_metadata(metadata_file, details)

    def pass_result(self, *args, **kwargs) -> TestResult:
        if args or "case_id" in kwargs or "name" in kwargs:
            kwargs.setdefault("case_id", self.case_id)
            kwargs.setdefault("name", self.name)
            return TestResult.pass_result(*args, **kwargs)

        artifacts = kwargs.get("artifacts") if kwargs else None
        details = kwargs.get("details") if kwargs else None
        return TestResult.pass_result(
            case_id=self.case_id,
            name=self.name,
            artifacts=artifacts,
            details=details,
        )

    def fail_result(self, *args, **kwargs) -> TestResult:
        if args or "case_id" in kwargs or "name" in kwargs or "reason" in kwargs:
            kwargs.setdefault("case_id", self.case_id)
            kwargs.setdefault("name", self.name)
            return TestResult.fail_result(*args, **kwargs)

        reason = kwargs.get("reason", "") if kwargs else ""
        artifacts = kwargs.get("artifacts") if kwargs else None
        details = kwargs.get("details") if kwargs else None
        return TestResult.fail_result(
            case_id=self.case_id,
            name=self.name,
            reason=reason,
            artifacts=artifacts,
            details=details,
        )

    def write_manifest_artifact(self, root: Path, output_file: Path) -> list[str]:
        entries = build_manifest(root)
        write_manifest(output_file, entries)
        return entries

    def assert_exists(self, path: Path, message: str | None = None) -> None:
        if not path.exists():
            raise AssertionError(message or f"Expected path to exist: {path}")

    def assert_not_exists(self, path: Path, message: str | None = None) -> None:
        if path.exists():
            raise AssertionError(message or f"Expected path to be absent: {path}")

    def assert_is_file(self, path: Path, message: str | None = None) -> None:
        if not path.is_file():
            raise AssertionError(message or f"Expected file to exist: {path}")

    def assert_is_dir(self, path: Path, message: str | None = None) -> None:
        if not path.is_dir():
            raise AssertionError(message or f"Expected directory to exist: {path}")

    def assert_file_text_equals(self, path: Path, expected: str, message: str | None = None) -> None:
        self.assert_is_file(path, message)
        actual = path.read_text(encoding="utf-8", errors="replace")
        if actual != expected:
            raise AssertionError(
                message or f"Unexpected file content for {path}: expected {expected!r}, got {actual!r}"
            )

    def assert_manifest_contains(self, entries: list[str], relative_path: str, message: str | None = None) -> None:
        if relative_path not in entries:
            raise AssertionError(message or f"Expected manifest entry missing: {relative_path}")

    def assert_manifest_not_contains(self, entries: list[str], relative_path: str, message: str | None = None) -> None:
        if relative_path in entries:
            raise AssertionError(message or f"Unexpected manifest entry present: {relative_path}")
