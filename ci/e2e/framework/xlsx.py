from __future__ import annotations

import base64
import os
import random
import zipfile
from pathlib import Path


DEFAULT_PAYLOAD_BYTES_PER_ROW = 24_000
REVISION_0 = "E2E-REVISION-0000"
REVISION_1 = "E2E-REVISION-0001"
REVISION_2 = "E2E-REVISION-0002"


def create_random_xlsx(
    path: Path,
    seed: str,
    *,
    revision: str = REVISION_0,
    payload_rows: int,
    payload_bytes_per_row: int = DEFAULT_PAYLOAD_BYTES_PER_ROW,
    worksheet_name: str = "TimestampE2E",
    title: str = "OneDrive timestamp E2E workbook",
) -> dict[str, object]:
    """Create a valid XLSX package without external Python dependencies."""
    path.parent.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)

    content_types = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
'''
    package_rels = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
'''
    workbook = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\n'
        f'  <sheets><sheet name="{worksheet_name}" sheetId="1" r:id="rId1"/></sheets>\n'
        '</workbook>\n'
    ).encode("utf-8")
    workbook_rels = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>
'''
    core_props = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        f'  <dc:title>{title}</dc:title>\n'
        '  <dc:creator>OneDrive E2E Harness</dc:creator>\n'
        '</cp:coreProperties>\n'
    ).encode("utf-8")
    app_props = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>OneDrive E2E Harness</Application>
</Properties>
'''

    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("_rels/.rels", package_rels)
        archive.writestr("xl/workbook.xml", workbook)
        archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        archive.writestr("docProps/core.xml", core_props)
        archive.writestr("docProps/app.xml", app_props)

        with archive.open("xl/worksheets/sheet1.xml", "w") as sheet:
            sheet.write(
                b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
                b'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\n'
                b'<sheetData>\n'
            )
            sheet.write(
                (
                    '<row r="1"><c r="A1" t="inlineStr"><is><t>'
                    f'{revision}'
                    '</t></is></c></row>\n'
                ).encode("utf-8")
            )

            for row_index in range(2, payload_rows + 2):
                payload = base64.b64encode(rng.randbytes(payload_bytes_per_row)).decode("ascii")
                sheet.write(
                    (
                        f'<row r="{row_index}"><c r="A{row_index}" t="inlineStr">'
                        f'<is><t>{payload}</t></is></c></row>\n'
                    ).encode("ascii")
                )

            sheet.write(b'</sheetData>\n</worksheet>\n')

    validation_error = validate_xlsx(path, revision)
    if validation_error:
        raise RuntimeError(validation_error)

    return {
        "seed": seed,
        "payload_rows": payload_rows,
        "payload_bytes_per_row": payload_bytes_per_row,
        "size_bytes": path.stat().st_size,
        "revision": revision,
    }


def validate_xlsx(path: Path, expected_revision: str) -> str:
    required_members = {
        "[Content_Types].xml",
        "_rels/.rels",
        "xl/workbook.xml",
        "xl/_rels/workbook.xml.rels",
        "xl/worksheets/sheet1.xml",
    }

    if not path.is_file():
        return f"XLSX file does not exist: {path}"

    try:
        with zipfile.ZipFile(path, "r") as archive:
            names = set(archive.namelist())
            missing = sorted(required_members - names)
            if missing:
                return f"XLSX package is missing required members: {', '.join(missing)}"
            corrupt_member = archive.testzip()
            if corrupt_member is not None:
                return f"XLSX package contains corrupt ZIP member: {corrupt_member}"
            sheet_xml = archive.read("xl/worksheets/sheet1.xml")
    except (OSError, zipfile.BadZipFile) as exc:
        return f"Unable to validate XLSX package: {exc}"

    if expected_revision.encode("utf-8") not in sheet_xml:
        return f"XLSX worksheet does not contain expected revision marker: {expected_revision}"

    return ""


def mutate_xlsx_revision(path: Path, old_revision: str, new_revision: str) -> None:
    """
    Change the worksheet revision marker while retaining every other XLSX member.

    This intentionally preserves any package members or metadata Microsoft may have
    added after the initial upload so follow-up tests continue from the real file
    returned by the service rather than reconstructing a synthetic replacement.
    """
    if len(old_revision) != len(new_revision):
        raise ValueError("XLSX revision markers must have equal length")

    temp_path = path.with_name(path.name + ".mutating")
    old_marker = old_revision.encode("utf-8")
    new_marker = new_revision.encode("utf-8")
    replacement_count = 0

    try:
        with zipfile.ZipFile(path, "r") as source, zipfile.ZipFile(temp_path, "w") as target:
            for info in source.infolist():
                data = source.read(info.filename)
                if info.filename == "xl/worksheets/sheet1.xml":
                    replacement_count = data.count(old_marker)
                    data = data.replace(old_marker, new_marker, 1)
                target.writestr(info, data)

        if replacement_count != 1:
            raise RuntimeError(
                f"Expected exactly one XLSX revision marker before mutation; found {replacement_count}"
            )

        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)

    validation_error = validate_xlsx(path, new_revision)
    if validation_error:
        raise RuntimeError(validation_error)
