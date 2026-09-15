from __future__ import annotations

import hashlib
import os
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape


DOCUMENT_MEMBER = "word/document.xml"
REQUIRED_MEMBERS = {
    "[Content_Types].xml",
    "_rels/.rels",
    DOCUMENT_MEMBER,
}


def validate_docx(path: Path, *, required_marker: str | None = None, forbidden_marker: str | None = None) -> str:
    if not path.is_file():
        return f"DOCX file does not exist: {path}"

    try:
        with zipfile.ZipFile(path, "r") as archive:
            names = set(archive.namelist())
            missing = sorted(REQUIRED_MEMBERS - names)
            if missing:
                return f"DOCX package is missing required members: {', '.join(missing)}"
            corrupt_member = archive.testzip()
            if corrupt_member is not None:
                return f"DOCX package contains corrupt ZIP member: {corrupt_member}"
            document_xml = archive.read(DOCUMENT_MEMBER)
    except (OSError, zipfile.BadZipFile) as exc:
        return f"Unable to validate DOCX package: {exc}"

    if required_marker is not None and required_marker.encode("utf-8") not in document_xml:
        return f"DOCX document.xml does not contain required marker: {required_marker}"
    if forbidden_marker is not None and forbidden_marker.encode("utf-8") in document_xml:
        return f"DOCX document.xml still contains forbidden marker: {forbidden_marker}"

    return ""


def docx_contains_marker(path: Path, marker: str) -> bool:
    if not path.is_file():
        return False
    try:
        with zipfile.ZipFile(path, "r") as archive:
            return marker.encode("utf-8") in archive.read(DOCUMENT_MEMBER)
    except (OSError, KeyError, zipfile.BadZipFile):
        return False


def docx_member_sha256(path: Path, member: str = DOCUMENT_MEMBER) -> str:
    with zipfile.ZipFile(path, "r") as archive:
        return hashlib.sha256(archive.read(member)).hexdigest()


def _rewrite_docx_member(path: Path, member: str, new_data: bytes) -> None:
    temp_path = path.with_name(path.name + ".rewriting")
    try:
        with zipfile.ZipFile(path, "r") as source, zipfile.ZipFile(temp_path, "w") as target:
            found = False
            for info in source.infolist():
                data = source.read(info.filename)
                if info.filename == member:
                    data = new_data
                    found = True
                target.writestr(info, data)
            if not found:
                raise RuntimeError(f"DOCX package does not contain required member: {member}")
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)


def append_docx_test_marker(path: Path, marker: str) -> None:
    """
    Append one deterministic visible paragraph to word/document.xml while retaining
    every other package member exactly as supplied by the Microsoft-settled DOCX.

    The marker is deliberately reversible without an external recovery file. If a
    CI runner is interrupted after the modified document reaches SharePoint, a later
    run can identify the marker and remove only the paragraph introduced here.
    """
    validation_error = validate_docx(path)
    if validation_error:
        raise RuntimeError(validation_error)

    marker_bytes = marker.encode("utf-8")
    with zipfile.ZipFile(path, "r") as archive:
        document_xml = archive.read(DOCUMENT_MEMBER)

    if marker_bytes in document_xml:
        raise RuntimeError(f"DOCX test marker already exists: {marker}")

    body_close = b"</w:body>"
    insert_at = document_xml.rfind(body_close)
    if insert_at < 0:
        raise RuntimeError("DOCX document.xml does not contain </w:body>")

    escaped_marker = escape(marker)
    paragraph = (
        f'<w:p><w:r><w:t xml:space="preserve">{escaped_marker}</w:t></w:r></w:p>'
    ).encode("utf-8")
    mutated_xml = document_xml[:insert_at] + paragraph + document_xml[insert_at:]
    _rewrite_docx_member(path, DOCUMENT_MEMBER, mutated_xml)

    validation_error = validate_docx(path, required_marker=marker)
    if validation_error:
        raise RuntimeError(validation_error)


def remove_docx_test_marker(path: Path, marker: str) -> bool:
    """
    Remove the paragraph containing the deterministic E2E marker.

    This first uses the exact paragraph form emitted by append_docx_test_marker().
    A conservative paragraph-boundary fallback is then used in case SharePoint has
    retained the marker but normalised surrounding XML formatting.
    """
    validation_error = validate_docx(path)
    if validation_error:
        raise RuntimeError(validation_error)

    marker_bytes = marker.encode("utf-8")
    with zipfile.ZipFile(path, "r") as archive:
        document_xml = archive.read(DOCUMENT_MEMBER)

    if marker_bytes not in document_xml:
        return False
    if document_xml.count(marker_bytes) != 1:
        raise RuntimeError(
            f"Expected exactly one DOCX test marker during rollback; found {document_xml.count(marker_bytes)}"
        )

    escaped_marker = escape(marker)
    exact_paragraph = (
        f'<w:p><w:r><w:t xml:space="preserve">{escaped_marker}</w:t></w:r></w:p>'
    ).encode("utf-8")

    if exact_paragraph in document_xml:
        restored_xml = document_xml.replace(exact_paragraph, b"", 1)
    else:
        marker_pos = document_xml.find(marker_bytes)
        paragraph_start = document_xml.rfind(b"<w:p", 0, marker_pos)
        paragraph_end = document_xml.find(b"</w:p>", marker_pos)
        if paragraph_start < 0 or paragraph_end < 0:
            raise RuntimeError(
                "Unable to locate the DOCX paragraph containing the stranded E2E marker"
            )
        paragraph_end += len(b"</w:p>")
        restored_xml = document_xml[:paragraph_start] + document_xml[paragraph_end:]

    _rewrite_docx_member(path, DOCUMENT_MEMBER, restored_xml)

    validation_error = validate_docx(path, forbidden_marker=marker)
    if validation_error:
        raise RuntimeError(validation_error)
    return True
