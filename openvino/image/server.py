"""The HTTP API of the image service.

    GET  /health             service and model status
    POST /inspect            {"image": "<base64 or data URL>", "caption": "..."}
                             -> {"findings": "...", "model", "seconds", "usage"}
    *    /v3/..., /v1/...    passed through to the model server (OpenAI API,
                             image_url content parts as data: URLs only)
"""

import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from errors import InspectError

# Paths passed through to the model server's OpenAI API.
PASSTHROUGH = ("/v3/", "/v1/")
# Passthrough paths whose requests may carry images.
CHAT = ("/v3/chat/", "/v1/chat/")
# The largest oversized body read and discarded so its 413 reaches the client.
MAX_DRAIN = 64 * 1024 * 1024
# Bytes read at a time from a request or the model server's reply.
CHUNK = 64 * 1024

log = logging.getLogger("image")


def check_passthrough(body):
    """Refuse a passthrough chat request whose image_url is not a data: URL.
    The model server would fetch URLs and read local file paths given there.
    Returns an error message, or None when the request may go through."""
    try:
        req = json.loads(body.decode("utf-8") or "{}")
    except ValueError:
        return "body is not JSON"
    if not isinstance(req, dict):
        return "body must be a JSON object"
    messages = req.get("messages")
    if not isinstance(messages, list):
        return None
    for msg in messages:
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        for part in content:
            if not isinstance(part, dict) or part.get("type") != "image_url":
                continue
            image_url = part.get("image_url")
            url = image_url.get("url") if isinstance(image_url, dict) else image_url
            if not isinstance(url, str) or not url.lstrip().lower().startswith("data:"):
                return "image_url must be a data: URL (base64); URLs and file paths are not accepted"
    return None


class Handler(BaseHTTPRequestHandler):
    """Serves one connection; the Inspector is on the server."""

    server_version = "CogyImage/1"

    @property
    def inspector(self):
        return self.server.inspector

    def log_message(self, fmt, *args):
        log.debug("%s %s", self.address_string(), fmt % args)

    def send_json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise InspectError(400, "bad Content-Length")
        if length < 0:
            raise InspectError(400, "bad Content-Length")
        if length > self.inspector.max_body:
            # Closing with the body unread resets the connection before the
            # client reads the 413, so a moderately oversized body is drained.
            if length <= MAX_DRAIN:
                while length > 0:
                    chunk = self.rfile.read(min(length, CHUNK))
                    if not chunk:
                        break
                    length -= len(chunk)
            raise InspectError(413, f"request body over {self.inspector.max_body} bytes")
        return self.rfile.read(length) if length else b""

    def upstream_path(self):
        """The model server path for a passthrough request, or None."""
        return self.path if self.path.startswith(PASSTHROUGH) else None

    def do_GET(self):
        path = self.upstream_path()
        if self.path == "/health":
            state, detail = self.inspector.model_state()
            self.send_json(200 if state == "ready" else 503,
                           {"service": "cogy-image", "status": state,
                            "model": self.inspector.model, "detail": detail})
        elif path:
            self.proxy("GET", path, b"")
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        try:
            body = self.read_body()
        except InspectError as e:
            # The body may be left unread, so the connection cannot be reused.
            self.close_connection = True
            return self.send_json(e.status, {"error": e.message})
        path = self.upstream_path()
        if self.path == "/inspect":
            self.handle_inspect(body)
        elif path:
            problem = check_passthrough(body) if path.startswith(CHAT) else None
            if problem:
                return self.send_json(400, {"error": problem})
            self.proxy("POST", path, body)
        else:
            self.send_json(404, {"error": "not found"})

    def handle_inspect(self, body):
        try:
            req = json.loads(body.decode("utf-8") or "{}")
        except ValueError:
            return self.send_json(400, {"error": "body is not JSON"})
        if not isinstance(req, dict):
            return self.send_json(400, {"error": "body must be a JSON object"})
        try:
            result = self.inspector.inspect(req.get("image"), req.get("caption"))
        except InspectError as e:
            log.warning("inspect failed (%d): %s", e.status, e.message)
            return self.send_json(e.status, {"error": e.message})
        log.info("inspect from %s: %s, %.1f s, %d+%d tokens%s", self.client_address[0],
                 result["media_type"], result["seconds"],
                 result["usage"]["prompt_tokens"], result["usage"]["completion_tokens"],
                 ", truncated" if result["truncated"] else "")
        self.send_json(200, result)

    def proxy(self, method, path, body):
        """Pass a request through to the model server, streaming the reply."""
        conn = self.inspector.upstream.connect()
        try:
            try:
                headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
                conn.request(method, path, body=body or None, headers=headers)
                resp = conn.getresponse()
            except OSError as e:
                return self.send_json(502, {"error": f"model server unreachable: {e}"})
            try:
                self.send_response(resp.status)
                for name in ("Content-Type", "Cache-Control"):
                    if resp.getheader(name):
                        self.send_header(name, resp.getheader(name))
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                while True:
                    chunk = resp.read1(CHUNK)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass  # the client closed the connection
        finally:
            conn.close()


def create_server(inspector, bind, port):
    """A threaded HTTP server on (bind, port) that answers with Handler,
    using inspector."""
    server = ThreadingHTTPServer((bind, port), Handler)
    server.daemon_threads = True
    server.inspector = inspector
    return server
