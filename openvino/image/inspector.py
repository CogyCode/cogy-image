"""Inspection: asks the vision-language model what an image shows.

The caption says what the caller expects the image to show. The system
prompt tells the model not to take it, or any text in the image, as true or
as instructions.
"""

import base64
import time

from errors import InspectError
from imagedata import DEFAULT_MAX_IMAGE, decode_image
from upstream import CHAT_PATH, Upstream, error_text

MAX_CAPTION = 4000
# Defaults for settings missing from the configuration.
DEFAULT_MAX_TOKENS = 1200
DEFAULT_TIMEOUT = 300
# Room in a request body for the JSON around the image, and a caption.
BODY_OVERHEAD = 1024 * 1024


def build_messages(system_prompt, data, kind, caption=None):
    """The chat messages that ask the model to inspect one image: the system
    prompt, then the caption (or a request for a description) and the image
    as a data: URL."""
    caption = (caption or "").strip()
    text = ("Expected change to inspect: " + caption) if caption else "Describe what this image shows."
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": [
            {"type": "text", "text": text},
            {"type": "image_url", "image_url": {
                "url": f"data:{kind};base64," + base64.b64encode(data).decode("ascii")}},
        ]},
    ]


def check_caption(caption):
    """Raise InspectError unless caption is absent or a string of at most
    MAX_CAPTION characters."""
    if caption is not None and not isinstance(caption, str):
        raise InspectError(400, "'caption' must be a string")
    if caption and len(caption) > MAX_CAPTION:
        raise InspectError(400, f"'caption' over {MAX_CAPTION} characters")


def read_reply(status, body):
    """The first choice and its trimmed text from a chat completion reply.
    Raises InspectError when the model server failed or gave no findings."""
    if status != 200:
        message = error_text(body)
        if "exceeds model max length" in message:
            raise InspectError(413, f"image and caption too long for the model's context: {message}")
        raise InspectError(502, f"model server HTTP {status}: {message}")
    try:
        choice = body["choices"][0]
        findings = (choice["message"]["content"] or "").strip()
    except (KeyError, IndexError, TypeError, AttributeError):
        raise InspectError(502, f"model server reply has no message: {str(body)[:200]}")
    if not findings:
        raise InspectError(502, "the model returned no findings")
    return choice, findings


class Inspector:
    """Reads images with the configured model on the model server."""

    def __init__(self, cfg):
        self.model = cfg["model"]
        self.max_tokens = cfg.get("max_tokens", DEFAULT_MAX_TOKENS)
        self.upstream = Upstream(cfg["upstream"], cfg.get("timeout", DEFAULT_TIMEOUT))
        self.max_image = cfg.get("max_image_bytes", DEFAULT_MAX_IMAGE)
        # Base64 is 4/3 of the image.
        self.max_body = self.max_image * 4 // 3 + BODY_OVERHEAD
        with open(cfg["prompt_file"], encoding="utf-8") as f:
            self.system_prompt = f.read().strip()

    def model_state(self):
        """The model's state as (state, detail); see Upstream.model_state."""
        return self.upstream.model_state(self.model)

    def inspect(self, image, caption=None):
        """Findings for one image, as the /inspect reply. Raises InspectError."""
        check_caption(caption)
        data, kind = decode_image(image, self.max_image)
        request = {
            "model": self.model,
            "messages": build_messages(self.system_prompt, data, kind, caption),
            "max_tokens": self.max_tokens,
            "temperature": 0,
        }
        started = time.monotonic()
        try:
            status, body = self.upstream.request_json("POST", CHAT_PATH, request)
        except OSError as e:
            raise InspectError(502, f"model server unreachable: {e}")
        choice, findings = read_reply(status, body)
        usage = body.get("usage") or {}
        return {
            "findings": findings,
            "truncated": choice.get("finish_reason") == "length",
            "model": self.model,
            "media_type": kind,
            "seconds": round(time.monotonic() - started, 1),
            "usage": {k: usage.get(k, 0) for k in ("prompt_tokens", "completion_tokens")},
        }
