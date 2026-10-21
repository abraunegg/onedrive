from __future__ import annotations

import os
import random
import re
import shutil
import zlib
from pathlib import Path


SESSION_UPLOAD_THRESHOLD_BYTES = 4 * 1024 * 1024
SMALL_PDF_IMAGE_WIDTH = 256
SMALL_PDF_IMAGE_HEIGHT = 256
LARGE_PDF_IMAGE_WIDTH = 2100
LARGE_PDF_IMAGE_HEIGHT = 2100
REVISION_0 = "E2E-PDF-REVISION-0000"
REVISION_1 = "E2E-PDF-REVISION-0001"
REVISION_2 = "E2E-PDF-REVISION-0002"


def _pdf_literal(value: str) -> bytes:
    """Encode a simple PDF literal string using deterministic ASCII escaping."""
    data = value.encode("ascii", errors="replace")
    return (
        data.replace(b"\\", b"\\\\")
        .replace(b"(", b"\\(")
        .replace(b")", b"\\)")
        .replace(b"\r", b"\\r")
        .replace(b"\n", b"\\n")
    )


def _stream_object(dictionary: bytes, payload: bytes) -> bytes:
    return (
        b"<< "
        + dictionary
        + b" /Length "
        + str(len(payload)).encode("ascii")
        + b" >>\nstream\n"
        + payload
        + b"\nendstream"
    )


def _build_pdf(objects: list[bytes], *, root_object: int, info_object: int) -> bytes:
    """Build a classic xref-table PDF from already encoded indirect objects."""
    document = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]

    for object_number, body in enumerate(objects, start=1):
        offsets.append(len(document))
        document.extend(f"{object_number} 0 obj\n".encode("ascii"))
        document.extend(body)
        document.extend(b"\nendobj\n")

    xref_offset = len(document)
    document.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    document.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        document.extend(f"{offset:010d} 00000 n \n".encode("ascii"))

    document.extend(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root {root_object} 0 R "
            f"/Info {info_object} 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n"
        ).encode("ascii")
    )
    return bytes(document)


def create_random_pdf(
    path: Path,
    seed: str,
    *,
    revision: str = REVISION_0,
    image_width: int = SMALL_PDF_IMAGE_WIDTH,
    image_height: int = SMALL_PDF_IMAGE_HEIGHT,
    title: str = "OneDrive E2E PDF",
) -> dict[str, object]:
    """
    Create a genuine, deterministic one-page PDF without external dependencies.

    The page contains a visible revision marker and a rendered grayscale image.
    The image data is pseudo-random and Flate-compressed, so large fixtures become
    large because of real PDF page content rather than bytes appended after %%EOF.
    """
    if image_width <= 0 or image_height <= 0:
        raise ValueError("PDF image dimensions must be positive")

    path.parent.mkdir(parents=True, exist_ok=True)

    rng = random.Random(seed)
    raw_image = rng.randbytes(image_width * image_height)
    compressed_image = zlib.compress(raw_image, level=6)

    revision_literal = _pdf_literal(revision)
    title_literal = _pdf_literal(title)
    visible_text = _pdf_literal(f"{title} - {revision}")

    content_stream = (
        b"q\n"
        b"540 0 0 540 36 144 cm\n"
        b"/Im1 Do\n"
        b"Q\n"
        b"BT\n"
        b"/F1 12 Tf\n"
        b"36 744 Td\n"
        b"("
        + visible_text
        + b") Tj\n"
        b"ET\n"
    )

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            b"/Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> "
            b"/Contents 4 0 R >>"
        ),
        _stream_object(b"", content_stream),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        _stream_object(
            (
                b"/Type /XObject /Subtype /Image "
                + f"/Width {image_width} /Height {image_height} ".encode("ascii")
                + b"/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode"
            ),
            compressed_image,
        ),
        (
            b"<< /Title ("
            + title_literal
            + b") /Creator (OneDrive E2E Harness) /Producer (OneDrive E2E Harness) "
            + b"/Subject ("
            + revision_literal
            + b") >>"
        ),
    ]

    path.write_bytes(_build_pdf(objects, root_object=1, info_object=7))

    validation_error = validate_pdf(path, revision)
    if validation_error:
        raise RuntimeError(validation_error)

    return {
        "seed": seed,
        "image_width": image_width,
        "image_height": image_height,
        "raw_image_bytes": len(raw_image),
        "compressed_image_bytes": len(compressed_image),
        "size_bytes": path.stat().st_size,
        "revision": revision,
    }


def large_pdf_path(path: Path) -> Path:
    """Return the deterministic large-PDF companion path for a small PDF fixture."""
    return path.with_name(f"{path.stem}-large{path.suffix}")


def large_pdf_relative(relative: str) -> str:
    relative_path = Path(relative)
    return large_pdf_path(relative_path).as_posix()


def pdf_pair_paths(path: Path) -> tuple[Path, Path]:
    return path, large_pdf_path(path)


def create_random_pdf_pair(
    path: Path,
    seed: str,
    *,
    revision: str = REVISION_0,
    title: str = "OneDrive E2E PDF",
) -> dict[str, object]:
    """Create valid PDF fixtures on both sides of the 4 MiB upload boundary."""
    large_path = large_pdf_path(path)

    small = create_random_pdf(
        path,
        seed,
        revision=revision,
        image_width=SMALL_PDF_IMAGE_WIDTH,
        image_height=SMALL_PDF_IMAGE_HEIGHT,
        title=title,
    )
    large = create_random_pdf(
        large_path,
        f"{seed}:large",
        revision=revision,
        image_width=LARGE_PDF_IMAGE_WIDTH,
        image_height=LARGE_PDF_IMAGE_HEIGHT,
        title=f"{title} (large)",
    )

    small_size = int(small["size_bytes"])
    large_size = int(large["size_bytes"])
    if small_size >= SESSION_UPLOAD_THRESHOLD_BYTES:
        raise RuntimeError(
            f"Small PDF fixture unexpectedly reached the session-upload threshold: {small_size} bytes"
        )
    if large_size <= SESSION_UPLOAD_THRESHOLD_BYTES:
        raise RuntimeError(
            f"Large PDF fixture did not exceed the session-upload threshold: {large_size} bytes"
        )

    result = dict(small)
    result["small_size_bytes"] = small_size
    result["small"] = small
    result["large"] = large
    result["large_size_bytes"] = large_size
    return result


def validate_pdf(path: Path, expected_revision: str) -> str:
    """Perform dependency-free structural checks for generated/downloaded PDF fixtures."""
    if not path.is_file():
        return f"PDF file does not exist: {path}"

    try:
        data = path.read_bytes()
    except OSError as exc:
        return f"Unable to read PDF file: {exc}"

    if not data.startswith(b"%PDF-1.7\n"):
        return "PDF does not contain the expected PDF 1.7 header"
    if not data.rstrip().endswith(b"%%EOF"):
        return "PDF does not contain a terminating %%EOF marker"
    if expected_revision.encode("ascii", errors="replace") not in data:
        return f"PDF does not contain expected revision marker: {expected_revision}"
    if b"/Type /Catalog" not in data or b"/Type /Page" not in data:
        return "PDF is missing required catalog/page objects"
    if b"/Subtype /Image" not in data or b"/FlateDecode" not in data:
        return "PDF is missing the rendered image XObject"

    startxref_match = re.search(rb"startxref\s+(\d+)\s+%%EOF\s*$", data)
    if startxref_match is None:
        return "PDF does not contain a valid startxref trailer"

    xref_offset = int(startxref_match.group(1))
    if xref_offset < 0 or xref_offset >= len(data) or not data[xref_offset:].startswith(b"xref\n"):
        return f"PDF startxref does not point to the xref table: {xref_offset}"

    return ""


def validate_pdf_pair(path: Path, expected_revision: str) -> str:
    errors: list[str] = []
    for label, candidate in zip(("small", "large"), pdf_pair_paths(path)):
        error = validate_pdf(candidate, expected_revision)
        if error:
            errors.append(f"{label}: {error}")
            continue

        size_bytes = candidate.stat().st_size
        if label == "small" and size_bytes >= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"small: PDF crossed the 4 MiB simple-upload boundary ({size_bytes} bytes)"
            )
        if label == "large" and size_bytes <= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"large: PDF did not remain above the 4 MiB session-upload boundary ({size_bytes} bytes)"
            )
    return "; ".join(errors)


def mutate_pdf_revision(path: Path, old_revision: str, new_revision: str) -> None:
    """Change only the fixed-width revision marker in an existing PDF."""
    if len(old_revision.encode("ascii", errors="replace")) != len(new_revision.encode("ascii", errors="replace")):
        raise ValueError("PDF revision markers must have equal encoded length")

    data = path.read_bytes()
    old_marker = old_revision.encode("ascii", errors="replace")
    new_marker = new_revision.encode("ascii", errors="replace")
    replacement_count = data.count(old_marker)
    if replacement_count < 1:
        raise RuntimeError(
            f"Expected at least one PDF revision marker before mutation; found {replacement_count}"
        )

    temp_path = path.with_name(path.name + ".mutating")
    try:
        # The generated document carries the revision in both visible page content
        # and document metadata. Keep those representations consistent.
        temp_path.write_bytes(data.replace(old_marker, new_marker))
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)

    validation_error = validate_pdf(path, new_revision)
    if validation_error:
        raise RuntimeError(validation_error)


def mutate_pdf_pair_revision(path: Path, old_revision: str, new_revision: str) -> None:
    for candidate in pdf_pair_paths(path):
        mutate_pdf_revision(candidate, old_revision, new_revision)


def rename_pdf_pair(source: Path, destination: Path) -> None:
    source.rename(destination)
    large_pdf_path(source).rename(large_pdf_path(destination))


def unlink_pdf_pair(path: Path) -> None:
    for candidate in pdf_pair_paths(path):
        if candidate.exists():
            candidate.unlink()


def copy_pdf_pair(source: Path, destination: Path) -> None:
    for source_candidate, destination_candidate in zip(pdf_pair_paths(source), pdf_pair_paths(destination)):
        destination_candidate.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_candidate, destination_candidate)


def set_pdf_pair_mtime(path: Path, times: tuple[float, float]) -> None:
    for candidate in pdf_pair_paths(path):
        os.utime(candidate, times)


def pdf_pair_backup_files(path: Path, finder) -> dict[str, list[Path]]:
    small_path, large_path = pdf_pair_paths(path)
    large_backups = finder(large_path)
    large_backup_set = set(large_backups)
    small_backups = [
        candidate
        for candidate in finder(small_path)
        if candidate not in large_backup_set
    ]
    return {
        "small": small_backups,
        "large": large_backups,
    }


def validate_pdf_pair_backups(backups: dict[str, list[Path]], expected_revision: str) -> str:
    errors: list[str] = []
    for label in ("small", "large"):
        files = backups.get(label, [])
        if len(files) != 1:
            errors.append(f"{label}: expected exactly one PDF safeBackup, found {len(files)}")
            continue
        error = validate_pdf(files[0], expected_revision)
        if error:
            errors.append(f"{label}: {error}")
            continue

        size_bytes = files[0].stat().st_size
        if label == "small" and size_bytes >= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"small: PDF safeBackup crossed the 4 MiB simple-upload boundary ({size_bytes} bytes)"
            )
        if label == "large" and size_bytes <= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"large: PDF safeBackup did not remain above the 4 MiB session-upload boundary ({size_bytes} bytes)"
            )
    return "; ".join(errors)


def pdf_pair_backup_hashes(backups: dict[str, list[Path]], hash_function) -> dict[str, str]:
    return {
        label: hash_function(files[0]) if len(files) == 1 else ""
        for label, files in backups.items()
    }


def pdf_pair_hashes(path: Path, hash_function) -> dict[str, str]:
    return {
        label: hash_function(candidate) if candidate.is_file() else ""
        for label, candidate in zip(("small", "large"), pdf_pair_paths(path))
    }


def pdf_pair_sizes(path: Path) -> dict[str, int]:
    return {
        label: candidate.stat().st_size if candidate.is_file() else -1
        for label, candidate in zip(("small", "large"), pdf_pair_paths(path))
    }


def pdf_pair_mtimes(path: Path) -> dict[str, int]:
    return {
        label: int(candidate.stat().st_mtime) if candidate.is_file() else -1
        for label, candidate in zip(("small", "large"), pdf_pair_paths(path))
    }


def pdf_pair_any_exists(path: Path) -> bool:
    return any(candidate.exists() for candidate in pdf_pair_paths(path))


def pdf_pair_all_files(path: Path) -> bool:
    return all(candidate.is_file() for candidate in pdf_pair_paths(path))

