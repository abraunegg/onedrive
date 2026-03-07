from __future__ import annotations

from abc import ABC, abstractmethod

from framework.context import E2EContext
from framework.result import TestResult


class E2ETestCase(ABC):
    """
    Base class for all E2E test cases.
    """

    case_id: str = ""
    name: str = ""
    description: str = ""

    @abstractmethod
    def run(self, context: E2EContext) -> TestResult:
        """
        Execute the test case and return a structured TestResult.
        """
        raise NotImplementedError