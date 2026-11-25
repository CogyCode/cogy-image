"""HTTP client for the model server (OpenVINO Model Server on localhost)."""

import http.client
import json
import urllib.parse

# The model server's chat completion endpoint (OpenAI API).
CHAT_PATH = "/v3/chat/completions"
# Seconds to wait for the model server's state.
STATE_TIMEOUT = 5


class Upstream:
    """Connections to the model server at a base URL."""

    def __init__(self, url, timeout):
        u = urllib.parse.urlsplit(url)
        self.host, self.port, self.timeout = u.hostname, u.port or 80, timeout

    def connect(self, timeout=None):
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout or self.timeout)

    def request_json(self, method, path, body=None, timeout=None):
        """Send body as JSON and return (status, decoded reply). A reply that
        is not JSON comes back as {"error": <its text>}."""
        conn = self.connect(timeout)
        try:
            data = json.dumps(body).encode() if body is not None else None
            conn.request(method, path, body=data, headers={"Content-Type": "application/json"})
            resp = conn.getresponse()
            raw = resp.read()
            try:
                return resp.status, json.loads(raw.decode("utf-8"))
            except ValueError:
                return resp.status, {"error": raw.decode("utf-8", "replace")}
        finally:
            conn.close()

    def model_state(self, model):
        """The model's state as (state, detail): "ready", "loading" or "down".
        OVMS lists each model's versions and their states in /v1/config."""
        try:
            status, body = self.request_json("GET", "/v1/config", timeout=STATE_TIMEOUT)
        except OSError as e:
            return "down", str(e)
        if status != 200 or not isinstance(body, dict):
            return "down", f"model server HTTP {status}"
        entry = body.get(model)
        versions = entry.get("model_version_status") if isinstance(entry, dict) else None
        states = [v.get("state") for v in versions or [] if isinstance(v, dict)]
        return ("ready", None) if "AVAILABLE" in states else ("loading", ",".join(map(str, states)))


def error_text(body):
    """The message of a model server error body: {"error": "..."} or
    {"error": {"message": "...", "code": "..."}}."""
    if not isinstance(body, dict):
        return str(body)
    err = body.get("error", body)
    if isinstance(err, dict):
        return " ".join(str(err[k]) for k in ("message", "code") if err.get(k)) or json.dumps(err)
    return str(err)
