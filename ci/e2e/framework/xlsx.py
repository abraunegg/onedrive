from __future__ import annotations

import base64
import os
import random
import shutil
import zipfile
from pathlib import Path


DEFAULT_PAYLOAD_BYTES_PER_ROW = 24_000
SESSION_UPLOAD_THRESHOLD_BYTES = 4 * 1024 * 1024
SMALL_XLSX_PAYLOAD_ROWS = 32
LARGE_XLSX_PAYLOAD_ROWS = 220
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


def large_xlsx_path(path: Path) -> Path:
    """Return the deterministic large-workbook companion path for a small XLSX fixture."""
    return path.with_name(f"{path.stem}-large{path.suffix}")


def large_xlsx_relative(relative: str) -> str:
    relative_path = Path(relative)
    return large_xlsx_path(relative_path).as_posix()


def xlsx_pair_paths(path: Path) -> tuple[Path, Path]:
    return path, large_xlsx_path(path)


def create_random_xlsx_pair(
    path: Path,
    seed: str,
    *,
    revision: str = REVISION_0,
    payload_rows: int = SMALL_XLSX_PAYLOAD_ROWS,
    worksheet_name: str = "TimestampE2E",
    title: str = "OneDrive E2E workbook",
) -> dict[str, object]:
    """Create valid XLSX fixtures on both sides of the 4 MiB upload boundary."""
    large_path = large_xlsx_path(path)
    # Keep the existing small fixture definition unchanged; the large companion is additive.
    small = create_random_xlsx(
        path,
        seed,
        revision=revision,
        payload_rows=payload_rows,
        worksheet_name=worksheet_name,
        title=title,
    )
    large = create_random_xlsx(
        large_path,
        f"{seed}:large",
        revision=revision,
        payload_rows=LARGE_XLSX_PAYLOAD_ROWS,
        worksheet_name=worksheet_name,
        title=f"{title} (large)",
    )

    small_size = int(small["size_bytes"])
    large_size = int(large["size_bytes"])
    if small_size >= SESSION_UPLOAD_THRESHOLD_BYTES:
        raise RuntimeError(
            f"Small XLSX fixture unexpectedly reached the session-upload threshold: {small_size} bytes"
        )
    if large_size <= SESSION_UPLOAD_THRESHOLD_BYTES:
        raise RuntimeError(
            f"Large XLSX fixture did not exceed the session-upload threshold: {large_size} bytes"
        )

    result = dict(small)
    result["small"] = small
    result["large"] = large
    result["large_size_bytes"] = large_size
    return result


def validate_xlsx_pair(path: Path, expected_revision: str) -> str:
    errors: list[str] = []
    for label, candidate in zip(("small", "large"), xlsx_pair_paths(path)):
        error = validate_xlsx(candidate, expected_revision)
        if error:
            errors.append(f"{label}: {error}")
            continue

        size_bytes = candidate.stat().st_size
        if label == "small" and size_bytes >= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"small: workbook crossed the 4 MiB simple-upload boundary ({size_bytes} bytes)"
            )
        if label == "large" and size_bytes <= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"large: workbook did not remain above the 4 MiB session-upload boundary ({size_bytes} bytes)"
            )
    return "; ".join(errors)


def mutate_xlsx_pair_revision(path: Path, old_revision: str, new_revision: str) -> None:
    for candidate in xlsx_pair_paths(path):
        mutate_xlsx_revision(candidate, old_revision, new_revision)


def rename_xlsx_pair(source: Path, destination: Path) -> None:
    source.rename(destination)
    large_xlsx_path(source).rename(large_xlsx_path(destination))


def unlink_xlsx_pair(path: Path) -> None:
    for candidate in xlsx_pair_paths(path):
        if candidate.exists():
            candidate.unlink()


def copy_xlsx_pair(source: Path, destination: Path) -> None:
    for source_candidate, destination_candidate in zip(xlsx_pair_paths(source), xlsx_pair_paths(destination)):
        destination_candidate.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_candidate, destination_candidate)


def set_xlsx_pair_mtime(path: Path, times: tuple[float, float]) -> None:
    for candidate in xlsx_pair_paths(path):
        os.utime(candidate, times)


def xlsx_pair_backup_files(path: Path, finder) -> dict[str, list[Path]]:
    return {
        label: finder(candidate)
        for label, candidate in zip(("small", "large"), xlsx_pair_paths(path))
    }


def validate_xlsx_pair_backups(backups: dict[str, list[Path]], expected_revision: str) -> str:
    errors: list[str] = []
    for label in ("small", "large"):
        files = backups.get(label, [])
        if len(files) != 1:
            errors.append(f"{label}: expected exactly one XLSX safeBackup, found {len(files)}")
            continue
        error = validate_xlsx(files[0], expected_revision)
        if error:
            errors.append(f"{label}: {error}")
            continue

        size_bytes = files[0].stat().st_size
        if label == "small" and size_bytes >= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"small: safeBackup crossed the 4 MiB simple-upload boundary ({size_bytes} bytes)"
            )
        if label == "large" and size_bytes <= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"large: safeBackup did not remain above the 4 MiB session-upload boundary ({size_bytes} bytes)"
            )
    return "; ".join(errors)


def xlsx_pair_backup_hashes(backups: dict[str, list[Path]], hash_function) -> dict[str, str]:
    return {
        label: hash_function(files[0]) if len(files) == 1 else ""
        for label, files in backups.items()
    }


def xlsx_pair_hashes(path: Path, hash_function) -> dict[str, str]:
    return {
        label: hash_function(candidate) if candidate.is_file() else ""
        for label, candidate in zip(("small", "large"), xlsx_pair_paths(path))
    }


def xlsx_pair_sizes(path: Path) -> dict[str, int]:
    return {
        label: candidate.stat().st_size if candidate.is_file() else -1
        for label, candidate in zip(("small", "large"), xlsx_pair_paths(path))
    }


def xlsx_pair_mtimes(path: Path) -> dict[str, int]:
    return {
        label: int(candidate.stat().st_mtime) if candidate.is_file() else -1
        for label, candidate in zip(("small", "large"), xlsx_pair_paths(path))
    }


def xlsx_pair_any_exists(path: Path) -> bool:
    return any(candidate.exists() for candidate in xlsx_pair_paths(path))


def xlsx_pair_all_files(path: Path) -> bool:
    return all(candidate.is_file() for candidate in xlsx_pair_paths(path))


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
