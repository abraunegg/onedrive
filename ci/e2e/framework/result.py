from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class TestResult:
    """
    Structured test result returned by each test case.
    """

    case_id: str
    name: str
    status: str
    reason: str = ""
    artifacts: list[str] = field(default_factory=list)
    details: dict = field(default_factory=dict)

    @staticmethod
    def pass_result(
        case_id: str,
        name: str,
        artifacts: list[str] | None = None,
        details: dict | None = None,
    ) -> "TestResult":
        return TestResult(
            case_id=case_id,
            name=name,
            status="pass",
            reason="",
            artifacts=artifacts or [],
            details=details or {},
        )

    @staticmethod
    def fail_result(
        case_id: str,
        name: str,
        reason: str,
        artifacts: list[str] | None = None,
        details: dict | None = None,
    ) -> "TestResult":
        return TestResult(
            case_id=case_id,
            name=name,
            status="fail",
            reason=reason,
            artifacts=artifacts or [],
            details=details or {},
        )