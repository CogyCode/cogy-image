"""HTTP client for the model server (GenieX on localhost), and its warm-up."""

import http.client
import json
import time
import urllib.parse

# The model server's chat completion endpoint (OpenAI API).
CHAT_PATH = "/v1/chat/completions"
# Seconds to wait for the model server's state.
STATE_TIMEOUT = 5
# Seconds the warm-up waits for the model, and between its attempts.
WARM_UP_WAIT = 900
WARM_UP_RETRY = 2


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
        """The model's state as (state, detail): "ready", "loading", "unloaded"
        or "down". GenieX's own /health is 200 while no model is loaded, so
        this reads /status."""
        try:
            status, body = self.request_json("GET", "/status", timeout=STATE_TIMEOUT)
        except OSError as e:
            return "down", str(e)
        if status != 200 or not isinstance(body, dict):
            return "down", f"model server HTTP {status}"
        for m in body.get("models") or []:
            if isinstance(m, dict) and same_model(str(m.get("id", "")), model):
                state = m.get("state")
                if state in ("active", "idle"):
                    return "ready", None
                return ("loading" if state == "loading" else "unloaded"), str(state)
        return "unloaded", "the model is not loaded"


def error_text(body):
    """The message of a model server error body: {"error": "..."} or
    {"error": {"message": "...", "code": "..."}}."""
    if not isinstance(body, dict):
        return str(body)
    err = body.get("error", body)
    if isinstance(err, dict):
        return " ".join(str(err[k]) for k in ("message", "code") if err.get(k)) or json.dumps(err)
    return str(err)


def same_model(status_id, model):
    """GenieX may report a loaded model as name or name:precision."""
    return status_id == model or status_id.split(":")[0] == model.split(":")[0]


def warm_up(url, model, wait=WARM_UP_WAIT):
    """Load model into the model server at url and wait until it is ready.

    GenieX loads a model on its first request, so the model service runs this
    after it starts and the first inspection does not wait for the load. A
    request with only a system message loads the model and generates nothing.
    Returns 0 when ready, 1 when not ready within wait seconds."""
    upstream = Upstream(url, timeout=wait)
    deadline = time.monotonic() + wait
    request = {"model": model, "messages": [{"role": "system", "content": "warm-up"}]}
    while time.monotonic() < deadline:
        try:
            status, body = upstream.request_json("POST", CHAT_PATH, request)
            if status == 200:
                break
            print(f"warm-up: model server HTTP {status}: {error_text(body)}", flush=True)
            if status in (400, 404):
                return 1  # the model is missing or was refused: retrying will not help
        except OSError as e:
            print(f"warm-up: waiting for the model server ({e})", flush=True)
        time.sleep(WARM_UP_RETRY)
    # model_state uses its own short timeout, not the load request's.
    while time.monotonic() < deadline:
        state, _ = upstream.model_state(model)
        if state == "ready":
            print(f"warm-up: {model} loaded", flush=True)
            return 0
        time.sleep(WARM_UP_RETRY)
    print(f"warm-up: {model} not ready within {wait} s", flush=True)
    return 1
