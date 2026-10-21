from __future__ import annotations

import hashlib
import os
import random
import shutil
import struct
import zlib
from pathlib import Path


SESSION_UPLOAD_THRESHOLD_BYTES = 4 * 1024 * 1024

SMALL_IMAGE_WIDTH = 256
SMALL_IMAGE_HEIGHT = 256
LARGE_PNG_WIDTH = 1216
LARGE_PNG_HEIGHT = 1216
LARGE_JPEG_WIDTH = 2080
LARGE_JPEG_HEIGHT = 2080

REVISION_0 = "E2E-IMAGE-REVISION-0000"
REVISION_1 = "E2E-IMAGE-REVISION-0001"
REVISION_2 = "E2E-IMAGE-REVISION-0002"

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Standard baseline JPEG luminance Huffman tables. The JPEG generator below uses
# a grayscale scan and deliberately emits quantized DCT coefficients directly.
# This keeps the helper dependency-free while still producing a genuine image
# whose large-file size comes from encoded image data rather than padding or an
# oversized metadata segment.
_JPEG_DC_BITS = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
_JPEG_DC_VALUES = list(range(12))
_JPEG_AC_BITS = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
_JPEG_AC_VALUES = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
    0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
    0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
    0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
    0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
    0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
    0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
    0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
    0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
]
_JPEG_AC_TRANSLATION = bytes.maketrans(
    bytes(range(256)),
    bytes(0xB0 | (value & 0x0F) for value in range(256)),
)


def _png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(chunk_type)
    crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + chunk_type + payload + struct.pack(">I", crc)


def _png_text(keyword: str, value: str) -> bytes:
    if "\x00" in keyword or not (1 <= len(keyword.encode("latin-1")) <= 79):
        raise ValueError(f"Invalid PNG tEXt keyword: {keyword!r}")
    return keyword.encode("latin-1") + b"\x00" + value.encode("utf-8")


def _parse_png(path: Path) -> tuple[dict[str, object], dict[str, str], bytes]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("PNG signature is missing")

    offset = len(PNG_SIGNATURE)
    metadata: dict[str, str] = {}
    info: dict[str, object] = {}
    idat_parts: list[bytes] = []
    saw_iend = False

    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("PNG contains a truncated chunk header")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        payload_start = offset + 8
        payload_end = payload_start + length
        crc_end = payload_end + 4
        if crc_end > len(data):
            raise ValueError(f"PNG chunk {chunk_type!r} is truncated")

        payload = data[payload_start:payload_end]
        expected_crc = struct.unpack(">I", data[payload_end:crc_end])[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(payload, actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValueError(f"PNG chunk {chunk_type.decode('latin-1')} has an invalid CRC")

        if chunk_type == b"IHDR":
            if length != 13:
                raise ValueError("PNG IHDR has an invalid length")
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            info.update(
                {
                    "width": width,
                    "height": height,
                    "bit_depth": bit_depth,
                    "color_type": color_type,
                    "compression": compression,
                    "filtering": filtering,
                    "interlace": interlace,
                }
            )
        elif chunk_type == b"tEXt":
            if b"\x00" not in payload:
                raise ValueError("PNG tEXt chunk is malformed")
            keyword, value = payload.split(b"\x00", 1)
            metadata[keyword.decode("latin-1")] = value.decode("utf-8")
        elif chunk_type == b"IDAT":
            idat_parts.append(payload)
        elif chunk_type == b"IEND":
            if length != 0:
                raise ValueError("PNG IEND has an invalid length")
            saw_iend = True
            offset = crc_end
            break

        offset = crc_end

    if not saw_iend:
        raise ValueError("PNG IEND chunk is missing")
    if offset != len(data):
        raise ValueError("PNG contains bytes after IEND")
    if not info:
        raise ValueError("PNG IHDR chunk is missing")
    if not idat_parts:
        raise ValueError("PNG IDAT data is missing")

    try:
        decoded = zlib.decompress(b"".join(idat_parts))
    except zlib.error as exc:
        raise ValueError(f"PNG IDAT data cannot be decompressed: {exc}") from exc

    return info, metadata, decoded


def create_random_png(
    path: Path,
    seed: str,
    *,
    revision: str = REVISION_0,
    width: int = SMALL_IMAGE_WIDTH,
    height: int = SMALL_IMAGE_HEIGHT,
    title: str = "OneDrive E2E PNG",
) -> dict[str, object]:
    """Create a deterministic genuine 24-bit RGB PNG without external dependencies."""
    if width <= 0 or height <= 0:
        raise ValueError("PNG dimensions must be positive")

    path.parent.mkdir(parents=True, exist_ok=True)
    rng = random.Random(f"{seed}:{revision}:png-pixels")

    raw = bytearray()
    row_bytes = width * 3
    for _ in range(height):
        raw.append(0)  # PNG filter type 0 (None)
        raw.extend(rng.randbytes(row_bytes))

    compressed = zlib.compress(bytes(raw), level=6)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    document = bytearray(PNG_SIGNATURE)
    document.extend(_png_chunk(b"IHDR", ihdr))
    document.extend(_png_chunk(b"tEXt", _png_text("E2ERevision", revision)))
    document.extend(_png_chunk(b"tEXt", _png_text("E2ESeed", seed)))
    document.extend(_png_chunk(b"tEXt", _png_text("Title", title)))
    document.extend(_png_chunk(b"IDAT", compressed))
    document.extend(_png_chunk(b"IEND", b""))
    path.write_bytes(document)

    validation_error = validate_png(path, revision)
    if validation_error:
        raise RuntimeError(validation_error)

    return {
        "format": "PNG",
        "seed": seed,
        "width": width,
        "height": height,
        "raw_pixel_bytes": width * height * 3,
        "compressed_image_bytes": len(compressed),
        "size_bytes": path.stat().st_size,
        "revision": revision,
        "title": title,
    }


def validate_png(path: Path, expected_revision: str) -> str:
    """Perform dependency-free structural and pixel-stream validation of a PNG fixture."""
    if not path.is_file():
        return f"PNG file does not exist: {path}"

    try:
        info, metadata, decoded = _parse_png(path)
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        return f"Unable to validate PNG file: {exc}"

    if info.get("bit_depth") != 8 or info.get("color_type") != 2:
        return "PNG is not the expected 8-bit truecolour RGB image"
    if info.get("compression") != 0 or info.get("filtering") != 0 or info.get("interlace") != 0:
        return "PNG uses unexpected compression/filter/interlace settings"

    width = int(info["width"])
    height = int(info["height"])
    expected_raw_size = height * (1 + width * 3)
    if len(decoded) != expected_raw_size:
        return f"PNG decoded pixel stream has unexpected size: {len(decoded)} != {expected_raw_size}"

    stride = 1 + width * 3
    if any(decoded[row * stride] != 0 for row in range(height)):
        return "PNG contains an unexpected scanline filter"

    if metadata.get("E2ERevision") != expected_revision:
        return (
            "PNG does not contain expected revision marker: "
            f"{expected_revision} (found {metadata.get('E2ERevision')!r})"
        )
    if not metadata.get("E2ESeed"):
        return "PNG does not contain the E2E seed metadata"

    return ""


def _jpeg_segment(marker: int, payload: bytes) -> bytes:
    if len(payload) > 65533:
        raise ValueError("JPEG segment payload is too large")
    return b"\xFF" + bytes([marker]) + struct.pack(">H", len(payload) + 2) + payload


def _jpeg_metadata_payload(seed: str, revision: str, title: str) -> bytes:
    return (
        f"E2ERevision={revision}\n"
        f"E2ESeed={seed}\n"
        f"Title={title}"
    ).encode("utf-8")


def _parse_jpeg(path: Path) -> tuple[dict[str, object], dict[str, str]]:
    data = path.read_bytes()
    if not data.startswith(b"\xFF\xD8"):
        raise ValueError("JPEG SOI marker is missing")
    if not data.endswith(b"\xFF\xD9"):
        raise ValueError("JPEG EOI marker is missing")

    offset = 2
    markers: set[int] = set()
    metadata: dict[str, str] = {}
    info: dict[str, object] = {}
    entropy_start = -1

    while offset < len(data) - 2:
        if data[offset] != 0xFF:
            raise ValueError(f"JPEG marker prefix is missing at offset {offset}")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            raise ValueError("JPEG ends while reading a marker")

        marker = data[offset]
        offset += 1
        markers.add(marker)
        if marker == 0xD9:
            break
        if marker in {0x01} or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            raise ValueError("JPEG segment length is truncated")

        length = struct.unpack(">H", data[offset : offset + 2])[0]
        if length < 2:
            raise ValueError(f"JPEG marker 0x{marker:02X} has an invalid length")
        payload_start = offset + 2
        payload_end = offset + length
        if payload_end > len(data):
            raise ValueError(f"JPEG marker 0x{marker:02X} is truncated")
        payload = data[payload_start:payload_end]

        if marker == 0xFE:
            try:
                for line in payload.decode("utf-8").splitlines():
                    if "=" in line:
                        key, value = line.split("=", 1)
                        metadata[key] = value
            except UnicodeDecodeError as exc:
                raise ValueError("JPEG E2E comment metadata is not UTF-8") from exc
        elif marker == 0xC0:
            if len(payload) < 6:
                raise ValueError("JPEG SOF0 payload is truncated")
            precision = payload[0]
            height, width = struct.unpack(">HH", payload[1:5])
            components = payload[5]
            info.update(
                {
                    "precision": precision,
                    "width": width,
                    "height": height,
                    "components": components,
                }
            )
        elif marker == 0xDA:
            entropy_start = payload_end
            offset = payload_end
            break

        offset = payload_end

    required_markers = {0xE0, 0xDB, 0xC0, 0xC4, 0xDA}
    missing = sorted(required_markers - markers)
    if missing:
        raise ValueError(
            "JPEG is missing required marker(s): "
            + ", ".join(f"0x{marker:02X}" for marker in missing)
        )
    if entropy_start < 0:
        raise ValueError("JPEG SOS/entropy-coded image data is missing")

    entropy_end = len(data) - 2
    if entropy_end <= entropy_start:
        raise ValueError("JPEG entropy-coded image data is empty")

    # Validate that any 0xFF byte in the entropy stream is either stuffed (FF00)
    # or a restart marker. The generator currently emits neither, but accepting
    # these forms keeps validation structurally correct for a normal baseline JPEG.
    index = entropy_start
    while index < entropy_end:
        if data[index] != 0xFF:
            index += 1
            continue
        if index + 1 >= entropy_end:
            raise ValueError("JPEG entropy stream ends with a bare 0xFF byte")
        follower = data[index + 1]
        if follower == 0x00 or 0xD0 <= follower <= 0xD7:
            index += 2
            continue
        raise ValueError(f"JPEG entropy stream contains unexpected marker 0xFF{follower:02X}")

    return info, metadata


def create_random_jpeg(
    path: Path,
    seed: str,
    *,
    revision: str = REVISION_0,
    width: int = SMALL_IMAGE_WIDTH,
    height: int = SMALL_IMAGE_HEIGHT,
    title: str = "OneDrive E2E JPEG",
) -> dict[str, object]:
    """
    Create a deterministic genuine baseline grayscale JPEG without dependencies.

    The entropy stream encodes real quantized DCT coefficients. Each block uses an
    alternating DC differential and 63 non-zero AC coefficients, so the large
    fixture's size is derived entirely from image content. No trailing padding or
    oversized metadata is used to cross the 4 MiB upload-session boundary.
    """
    if width <= 0 or height <= 0 or width > 65535 or height > 65535:
        raise ValueError("JPEG dimensions must be between 1 and 65535")

    path.parent.mkdir(parents=True, exist_ok=True)
    blocks_x = (width + 7) // 8
    blocks_y = (height + 7) // 8
    block_count = blocks_x * blocks_y

    rng = random.Random(f"{seed}:{revision}:jpeg-coefficients")
    random_ac = rng.randbytes(block_count * 63).translate(_JPEG_AC_TRANSLATION)
    entropy = bytearray(block_count * 64)
    src = 0
    dst = 0
    for block_index in range(block_count):
        # DC category 5: standard Huffman code 110 (3 bits) plus a 5-bit
        # amplitude. +16 encodes as 10000 and -16 as 01111, making exactly
        # one byte per block while keeping the reconstructed DC bounded.
        entropy[dst] = 0xD0 if block_index % 2 == 0 else 0xCF
        entropy[dst + 1 : dst + 64] = random_ac[src : src + 63]
        src += 63
        dst += 64

    # Quantization values are transmitted in zig-zag order. A uniform table is
    # sufficient for the deterministic E2E noise image and keeps the generator
    # simple while remaining standards-compliant.
    dqt_payload = bytes([0]) + bytes([16] * 64)
    sof0_payload = (
        bytes([8])
        + struct.pack(">HH", height, width)
        + bytes([1, 1, 0x11, 0])
    )
    dht_payload = (
        bytes([0x00])
        + bytes(_JPEG_DC_BITS)
        + bytes(_JPEG_DC_VALUES)
        + bytes([0x10])
        + bytes(_JPEG_AC_BITS)
        + bytes(_JPEG_AC_VALUES)
    )
    sos_payload = bytes([1, 1, 0x00, 0, 63, 0])

    document = bytearray(b"\xFF\xD8")
    document.extend(
        _jpeg_segment(0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00")
    )
    document.extend(_jpeg_segment(0xFE, _jpeg_metadata_payload(seed, revision, title)))
    document.extend(_jpeg_segment(0xDB, dqt_payload))
    document.extend(_jpeg_segment(0xC0, sof0_payload))
    document.extend(_jpeg_segment(0xC4, dht_payload))
    document.extend(_jpeg_segment(0xDA, sos_payload))
    document.extend(entropy)
    document.extend(b"\xFF\xD9")
    path.write_bytes(document)

    validation_error = validate_jpeg(path, revision)
    if validation_error:
        raise RuntimeError(validation_error)

    return {
        "format": "JPEG",
        "seed": seed,
        "width": width,
        "height": height,
        "block_count": block_count,
        "entropy_bytes": len(entropy),
        "size_bytes": path.stat().st_size,
        "revision": revision,
        "title": title,
    }


def validate_jpeg(path: Path, expected_revision: str) -> str:
    """Perform dependency-free structural validation of a baseline JPEG fixture."""
    if not path.is_file():
        return f"JPEG file does not exist: {path}"

    try:
        info, metadata = _parse_jpeg(path)
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        return f"Unable to validate JPEG file: {exc}"

    if info.get("precision") != 8 or info.get("components") != 1:
        return "JPEG is not the expected 8-bit baseline grayscale image"
    if int(info.get("width", 0)) <= 0 or int(info.get("height", 0)) <= 0:
        return "JPEG contains invalid image dimensions"
    if metadata.get("E2ERevision") != expected_revision:
        return (
            "JPEG does not contain expected revision marker: "
            f"{expected_revision} (found {metadata.get('E2ERevision')!r})"
        )
    if not metadata.get("E2ESeed"):
        return "JPEG does not contain the E2E seed metadata"

    return ""


def large_image_path(path: Path) -> Path:
    """Return the deterministic large companion path for a PNG or JPEG image."""
    return path.with_name(f"{path.stem}-large{path.suffix}")


def jpeg_image_path(png_path: Path) -> Path:
    """Return the JPEG peer path for the PNG base path used by an image set."""
    return png_path.with_suffix(".jpg")


def image_set_paths(path: Path) -> dict[str, Path]:
    """Return small/large PNG and JPEG paths for an image-set base PNG path."""
    if path.suffix.lower() != ".png":
        raise ValueError(f"Image-set base path must use .png: {path}")
    jpeg_path = jpeg_image_path(path)
    return {
        "png_small": path,
        "png_large": large_image_path(path),
        "jpeg_small": jpeg_path,
        "jpeg_large": large_image_path(jpeg_path),
    }


def image_set_relatives(relative: str) -> dict[str, str]:
    return {
        label: candidate.as_posix()
        for label, candidate in image_set_paths(Path(relative)).items()
    }


def create_random_image_set(
    path: Path,
    seed: str,
    *,
    revision: str = REVISION_0,
    title: str = "OneDrive E2E image",
) -> dict[str, object]:
    """Create genuine PNG and JPEG fixtures on both sides of the 4 MiB boundary."""
    paths = image_set_paths(path)

    png_small = create_random_png(
        paths["png_small"],
        f"{seed}:png-small",
        revision=revision,
        width=SMALL_IMAGE_WIDTH,
        height=SMALL_IMAGE_HEIGHT,
        title=f"{title} PNG",
    )
    png_large = create_random_png(
        paths["png_large"],
        f"{seed}:png-large",
        revision=revision,
        width=LARGE_PNG_WIDTH,
        height=LARGE_PNG_HEIGHT,
        title=f"{title} PNG (large)",
    )
    jpeg_small = create_random_jpeg(
        paths["jpeg_small"],
        f"{seed}:jpeg-small",
        revision=revision,
        width=SMALL_IMAGE_WIDTH,
        height=SMALL_IMAGE_HEIGHT,
        title=f"{title} JPEG",
    )
    jpeg_large = create_random_jpeg(
        paths["jpeg_large"],
        f"{seed}:jpeg-large",
        revision=revision,
        width=LARGE_JPEG_WIDTH,
        height=LARGE_JPEG_HEIGHT,
        title=f"{title} JPEG (large)",
    )

    result: dict[str, object] = {
        "seed": seed,
        "revision": revision,
        "png_small": png_small,
        "png_large": png_large,
        "jpeg_small": jpeg_small,
        "jpeg_large": jpeg_large,
    }

    for label, candidate in paths.items():
        size_bytes = candidate.stat().st_size
        result[f"{label}_size_bytes"] = size_bytes
        is_large = label.endswith("_large")
        if not is_large and size_bytes >= SESSION_UPLOAD_THRESHOLD_BYTES:
            raise RuntimeError(
                f"Small {label} image unexpectedly reached the session-upload threshold: {size_bytes} bytes"
            )
        if is_large and size_bytes <= SESSION_UPLOAD_THRESHOLD_BYTES:
            raise RuntimeError(
                f"Large {label} image did not exceed the session-upload threshold: {size_bytes} bytes"
            )

    validation_error = validate_image_set(path, revision)
    if validation_error:
        raise RuntimeError(validation_error)
    return result


def validate_image_set(path: Path, expected_revision: str) -> str:
    errors: list[str] = []
    for label, candidate in image_set_paths(path).items():
        if label.startswith("png_"):
            error = validate_png(candidate, expected_revision)
        else:
            error = validate_jpeg(candidate, expected_revision)
        if error:
            errors.append(f"{label}: {error}")
            continue

        size_bytes = candidate.stat().st_size
        if label.endswith("_small") and size_bytes >= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"{label}: image crossed the 4 MiB simple-upload boundary ({size_bytes} bytes)"
            )
        if label.endswith("_large") and size_bytes <= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"{label}: image did not remain above the 4 MiB session-upload boundary ({size_bytes} bytes)"
            )
    return "; ".join(errors)


def _png_fixture_metadata(path: Path) -> tuple[str, str, str, int, int]:
    info, metadata, _ = _parse_png(path)
    return (
        metadata.get("E2ESeed", ""),
        metadata.get("E2ERevision", ""),
        metadata.get("Title", "OneDrive E2E PNG"),
        int(info["width"]),
        int(info["height"]),
    )


def _jpeg_fixture_metadata(path: Path) -> tuple[str, str, str, int, int]:
    info, metadata = _parse_jpeg(path)
    return (
        metadata.get("E2ESeed", ""),
        metadata.get("E2ERevision", ""),
        metadata.get("Title", "OneDrive E2E JPEG"),
        int(info["width"]),
        int(info["height"]),
    )


def mutate_png_revision(path: Path, old_revision: str, new_revision: str) -> None:
    """Regenerate a PNG with the same geometry/seed and new metadata + pixel content."""
    seed, current_revision, title, width, height = _png_fixture_metadata(path)
    if current_revision != old_revision:
        raise RuntimeError(
            f"PNG revision mismatch before mutation: expected {old_revision}, found {current_revision}"
        )
    create_random_png(
        path,
        seed,
        revision=new_revision,
        width=width,
        height=height,
        title=title,
    )


def mutate_jpeg_revision(path: Path, old_revision: str, new_revision: str) -> None:
    """Regenerate a JPEG with the same geometry/seed and new metadata + DCT image content."""
    seed, current_revision, title, width, height = _jpeg_fixture_metadata(path)
    if current_revision != old_revision:
        raise RuntimeError(
            f"JPEG revision mismatch before mutation: expected {old_revision}, found {current_revision}"
        )
    create_random_jpeg(
        path,
        seed,
        revision=new_revision,
        width=width,
        height=height,
        title=title,
    )


def mutate_image_set_revision(path: Path, old_revision: str, new_revision: str) -> None:
    for label, candidate in image_set_paths(path).items():
        if label.startswith("png_"):
            mutate_png_revision(candidate, old_revision, new_revision)
        else:
            mutate_jpeg_revision(candidate, old_revision, new_revision)

    validation_error = validate_image_set(path, new_revision)
    if validation_error:
        raise RuntimeError(validation_error)


def rename_image_set(source: Path, destination: Path) -> None:
    source_paths = image_set_paths(source)
    destination_paths = image_set_paths(destination)
    for label in source_paths:
        source_paths[label].rename(destination_paths[label])


def unlink_image_set(path: Path) -> None:
    for candidate in image_set_paths(path).values():
        if candidate.exists():
            candidate.unlink()


def copy_image_set(source: Path, destination: Path) -> None:
    source_paths = image_set_paths(source)
    destination_paths = image_set_paths(destination)
    for label in source_paths:
        destination_paths[label].parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_paths[label], destination_paths[label])


def set_image_set_mtime(path: Path, times: tuple[float, float]) -> None:
    for candidate in image_set_paths(path).values():
        os.utime(candidate, times)


def image_set_backup_files(path: Path, finder) -> dict[str, list[Path]]:
    paths = image_set_paths(path)

    png_large = finder(paths["png_large"])
    png_large_set = set(png_large)
    png_small = [candidate for candidate in finder(paths["png_small"]) if candidate not in png_large_set]

    jpeg_large = finder(paths["jpeg_large"])
    jpeg_large_set = set(jpeg_large)
    jpeg_small = [candidate for candidate in finder(paths["jpeg_small"]) if candidate not in jpeg_large_set]

    return {
        "png_small": png_small,
        "png_large": png_large,
        "jpeg_small": jpeg_small,
        "jpeg_large": jpeg_large,
    }


def validate_image_set_backups(backups: dict[str, list[Path]], expected_revision: str) -> str:
    errors: list[str] = []
    for label in ("png_small", "png_large", "jpeg_small", "jpeg_large"):
        files = backups.get(label, [])
        if len(files) != 1:
            errors.append(f"{label}: expected exactly one image safeBackup, found {len(files)}")
            continue
        candidate = files[0]
        error = (
            validate_png(candidate, expected_revision)
            if label.startswith("png_")
            else validate_jpeg(candidate, expected_revision)
        )
        if error:
            errors.append(f"{label}: {error}")
            continue

        size_bytes = candidate.stat().st_size
        if label.endswith("_small") and size_bytes >= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"{label}: image safeBackup crossed the 4 MiB simple-upload boundary ({size_bytes} bytes)"
            )
        if label.endswith("_large") and size_bytes <= SESSION_UPLOAD_THRESHOLD_BYTES:
            errors.append(
                f"{label}: image safeBackup did not remain above the 4 MiB session-upload boundary ({size_bytes} bytes)"
            )
    return "; ".join(errors)


def image_set_backup_hashes(backups: dict[str, list[Path]], hash_function) -> dict[str, str]:
    return {
        label: hash_function(files[0]) if len(files) == 1 else ""
        for label, files in backups.items()
    }


def image_set_hashes(path: Path, hash_function) -> dict[str, str]:
    return {
        label: hash_function(candidate) if candidate.is_file() else ""
        for label, candidate in image_set_paths(path).items()
    }


def image_set_sha256(path: Path) -> dict[str, str]:
    return {
        label: hashlib.sha256(candidate.read_bytes()).hexdigest() if candidate.is_file() else ""
        for label, candidate in image_set_paths(path).items()
    }


def image_set_sizes(path: Path) -> dict[str, int]:
    return {
        label: candidate.stat().st_size if candidate.is_file() else -1
        for label, candidate in image_set_paths(path).items()
    }


def image_set_mtimes(path: Path) -> dict[str, int]:
    return {
        label: int(candidate.stat().st_mtime) if candidate.is_file() else -1
        for label, candidate in image_set_paths(path).items()
    }


def image_set_any_exists(path: Path) -> bool:
    return any(candidate.exists() for candidate in image_set_paths(path).values())


def image_set_all_files(path: Path) -> bool:
    return all(candidate.is_file() for candidate in image_set_paths(path).values())
