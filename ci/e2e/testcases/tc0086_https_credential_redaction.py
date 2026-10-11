from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from framework.base import E2ETestCase
from framework.context import E2EContext
from framework.utils import command_to_string, write_text_file
from framework.result import TestResult


class TestCase0086HTTPSCredentialRedaction(E2ETestCase):
    case_id = "0086"
    name = "HTTPS debug OAuth credential redaction"
    description = (
        "Ensure authenticated --debug-https output preserves HTTP diagnostics "
        "without revealing OAuth bearer, access, or refresh token values"
    )

    # Match credential-bearing fields irrespective of HTTP/1.1, HTTP/2,
    # URL-encoded form, or JSON presentation. Keep matches out of artifacts.
    SENSITIVE_FIELDS = re.compile(
        r'(?i)((?:proxy-)?authorization\s*:\s*)(?!bearer\s+\[REDACTED\]|\[REDACTED\])(?:bearer\s+)?([^\s\]\r\n]+)'
        r'|((?:access_token|refresh_token)(?:\s*=\s*|\s*"\s*:\s*"?))(?!\[REDACTED\])([^\s&"\],}\r\n]+)'
    )
    BEARER = re.compile(r'(?i)\bbearer\s+(?!\[REDACTED\])([A-Za-z0-9._~+/-]{12,})')

    def run(self, context: E2EContext) -> TestResult:
        layout = self.prepare_case_layout(context, case_dir_name="tc0086", ensure_refresh_token=True)
        root_name = f"ZZ_E2E_TC0086_{context.run_id}_{os.getpid()}"
        sync_root = layout.work_dir / "syncroot"
        conf_dir = layout.work_dir / "conf-main"
        stdout_file = layout.log_dir / "debug_https_stdout.log"
        stderr_file = layout.log_dir / "debug_https_stderr.log"
        metadata_file = layout.state_dir / "metadata.txt"
        artifacts = [str(stdout_file), str(stderr_file), str(metadata_file)]

        context.prepare_minimal_config_dir(
            conf_dir,
            f'# tc0086 authenticated HTTPS diagnostics\nsync_dir = "{sync_root}"\n'
            'bypass_data_preservation = "true"\n',
        )
        write_text_file(sync_root / root_name / "probe.txt", "TC0086 real authenticated request\n")

        command = [
            context.onedrive_bin, "--sync", "--verbose", "--verbose", "--debug-https",
            "--resync", "--resync-auth", "--single-directory", root_name,
            "--confdir", str(conf_dir),
        ]
        context.log(f"Executing Test Case {self.case_id}: {command_to_string(command)}")
        details: dict[str, object] = {"root_name": root_name}

        # Do not use run_command_logged: in the presence of a regression it
        # would persist the unredacted libcurl output before verification.
        try:
            result = subprocess.run(
                command, cwd=context.repo_root, capture_output=True, text=True,
                errors="replace", timeout=300, check=False,
            )
            raw_stdout, raw_stderr = result.stdout, result.stderr
            details["returncode"] = result.returncode
        except subprocess.TimeoutExpired:
            raw_stdout, raw_stderr = "", ""
            details["returncode"] = None
            details["timed_out"] = True

        # The bootstrap refresh token must also never appear verbatim in a
        # persisted artifact, even if a broken client prints it without a key.
        refresh_token_path = conf_dir / "refresh_token"
        refresh_token = (
            refresh_token_path.read_text(encoding="utf-8").strip()
            if refresh_token_path.is_file() else ""
        )
        raw_combined = raw_stdout + "\n" + raw_stderr
        leaked_field = bool(self.SENSITIVE_FIELDS.search(raw_combined))
        leaked_bearer = bool(self.BEARER.search(raw_combined))
        leaked_refresh = bool(refresh_token and len(refresh_token) >= 12 and refresh_token in raw_combined)

        def sanitize(value: str) -> str:
            value = self.SENSITIVE_FIELDS.sub(
                lambda match: (match.group(1) or match.group(3)) + "[REDACTED]", value,
            )
            value = self.BEARER.sub("Bearer [REDACTED]", value)
            if refresh_token and len(refresh_token) >= 12:
                value = value.replace(refresh_token, "[REDACTED]")
            return value

        # No raw process output reaches logs, metadata, or failure reasons.
        safe_stdout, safe_stderr = sanitize(raw_stdout), sanitize(raw_stderr)
        write_text_file(stdout_file, safe_stdout)
        write_text_file(stderr_file, safe_stderr)

        diagnostic_present = bool(re.search(
            r'(?im)(?:^\*\s+(?:Trying|Connected|SSL|ALPN|TLS)|^>\s*(?:GET|POST|PUT|HTTP/)|^<\s*HTTP/|HTTP Response Headers:)',
            raw_combined,
        ))
        authorization_redacted = bool(re.search(
            r'(?i)(?:proxy-)?authorization\s*:\s*\[REDACTED\]', raw_combined,
        ))
        details.update({
            "https_diagnostic_present": diagnostic_present,
            "authorization_redacted": authorization_redacted,
            "credential_field_leak": leaked_field,
            "bare_bearer_leak": leaked_bearer,
            "bootstrap_refresh_token_leak": leaked_refresh,
        })
        self.write_metadata(metadata_file, details)

        if leaked_field or leaked_bearer or leaked_refresh:
            return self.fail_result(reason="OAuth credential exposure detected in HTTPS debug output (output sanitized)", artifacts=artifacts, details=details)
        if details["returncode"] != 0:
            return self.fail_result(reason="Authenticated HTTPS diagnostic sync did not complete successfully", artifacts=artifacts, details=details)
        if not diagnostic_present:
            return self.fail_result(reason="No HTTPS request/response diagnostic output was observed", artifacts=artifacts, details=details)
        if not authorization_redacted:
            return self.fail_result(reason="No redacted Authorization header was observed in HTTPS debug output", artifacts=artifacts, details=details)
        if "Sync with Microsoft OneDrive is complete" not in raw_combined:
            return self.fail_result(reason="Authenticated sync completion was not demonstrated", artifacts=artifacts, details=details)
        return self.pass_result(artifacts=artifacts, details=details)
