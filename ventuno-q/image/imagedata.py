"""Decoding and type detection for the images sent to /inspect."""

import base64
import binascii

from errors import InspectError

DEFAULT_MAX_IMAGE = 10 * 1024 * 1024

# Image types the model reads, by their first bytes. WebP is checked
# separately because its signature is not a plain prefix.
SIGNATURES = (
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"\xff\xd8\xff", "image/jpeg"),
    (b"GIF87a", "image/gif"),
    (b"GIF89a", "image/gif"),
)


def media_type(data):
    """The image's type from its first bytes, or None when it is not an
    image the model reads (PNG, JPEG, GIF, WebP)."""
    for magic, kind in SIGNATURES:
        if data.startswith(magic):
            return kind
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def decode_image(value, max_bytes):
    """The image's bytes and type from base64 or a data: URL. Raises
    InspectError for anything that is not an image within max_bytes."""
    if not isinstance(value, str) or not value.strip():
        raise InspectError(400, "'image' (base64 or a data: URL) is required")
    text = value.strip()
    if text.startswith("data:"):
        header, sep, text = text.partition(",")
        if not sep or not header.endswith(";base64"):
            raise InspectError(400, "'image' data: URL must be base64")
    # Every 4 base64 characters decode to 3 bytes, so an oversized image is
    # refused before it is decoded.
    if len(text) // 4 * 3 > max_bytes + 3:
        raise InspectError(413, f"image over {max_bytes} bytes")
    try:
        data = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        raise InspectError(400, "'image' is not valid base64")
    if len(data) > max_bytes:
        raise InspectError(413, f"image over {max_bytes} bytes")
    kind = media_type(data)
    if kind is None:
        raise InspectError(415, "'image' must be a PNG, JPEG, GIF or WebP image")
    return data, kind
