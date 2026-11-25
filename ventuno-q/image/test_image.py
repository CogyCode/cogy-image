"""Unit tests for the image service against a fake model server (GenieX).
Standard library only. Run from the build folder:

    python3 -m unittest discover -s image -v
"""

import base64
import http.client
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import imagedata
import inspector
import server
import upstream
from errors import InspectError

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR = os.path.join(HERE, "..", "config")
MODEL = "qualcomm/test-vision-model"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
WEBP = b"RIFF\x00\x00\x00\x00WEBPVP8 " + b"\x00" * 64


def b64(data):
    return base64.b64encode(data).decode()


class FakeGenieX:
    """Answers /v1/chat/completions with queued replies; records requests and
    paths. /status reports the model in self.state (None: not loaded)."""

    def __init__(self, state="idle"):
        self.replies = []
        self.requests = []
        self.paths = []
        self.state = state
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, status, obj):
                data = json.dumps(obj).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                outer.paths.append(self.path)
                if self.path == "/status":
                    models = [] if outer.state is None else [
                        {"id": MODEL + ":w4a16", "type": "vlm", "state": outer.state}]
                    self.reply(200, {"alive": True, "models": models})
                elif self.path == "/v1/models":
                    self.reply(200, {"data": [{"id": MODEL + ":w4a16"}]})
                else:
                    self.reply(404, {"error": "nope"})

            def do_POST(self):
                outer.paths.append(self.path)
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append(body)
                msgs = body.get("messages") or []
                if not msgs or (len(msgs) == 1 and msgs[0].get("role") == "system"):
                    # GenieX's warm-up: load the model, generate nothing.
                    outer.state = "idle"
                    return self.reply(200, None)
                if body.get("stream"):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for word in ("a", "b"):
                        self.wfile.write(f"data: {json.dumps({'choices': [{'delta': {'content': word}}]})}\n\n".encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                    return
                status, obj = outer.replies.pop(0)
                self.reply(status, obj)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def queue_content(self, content, finish="stop"):
        self.replies.append((200, {"choices": [{"message": {"content": content}, "finish_reason": finish}],
                                   "usage": {"prompt_tokens": 900, "completion_tokens": 40}}))

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class TestImages(unittest.TestCase):
    def test_media_type(self):
        self.assertEqual(imagedata.media_type(PNG), "image/png")
        self.assertEqual(imagedata.media_type(JPEG), "image/jpeg")
        self.assertEqual(imagedata.media_type(b"GIF89a..."), "image/gif")
        self.assertEqual(imagedata.media_type(WEBP), "image/webp")
        self.assertIsNone(imagedata.media_type(b"%PDF-1.7"))
        self.assertIsNone(imagedata.media_type(b""))

    def test_decode_base64_and_data_url(self):
        self.assertEqual(imagedata.decode_image(b64(PNG), 1000), (PNG, "image/png"))
        self.assertEqual(imagedata.decode_image("data:image/jpeg;base64," + b64(JPEG), 1000), (JPEG, "image/jpeg"))

    def test_decode_refuses(self):
        cases = [(None, 400), ("  ", 400), ("not base64!", 400), (b64(b"%PDF-1.7 x"), 415),
                 ("data:image/png," + b64(PNG), 400), (b64(PNG), 413)]
        for value, status in cases:
            with self.subTest(value=value):
                with self.assertRaises(InspectError) as e:
                    imagedata.decode_image(value, 1000 if status != 413 else 10)
                self.assertEqual(e.exception.status, status)

    def test_build_messages(self):
        m = inspector.build_messages("sys", PNG, "image/png", "  The Save button is blue  ")
        self.assertEqual(m[0], {"role": "system", "content": "sys"})
        text, picture = m[1]["content"]
        self.assertEqual(text, {"type": "text", "text": "Expected change to inspect: The Save button is blue"})
        self.assertEqual(picture["image_url"]["url"], "data:image/png;base64," + b64(PNG))
        self.assertEqual(inspector.build_messages("sys", PNG, "image/png")[1]["content"][0]["text"],
                         "Describe what this image shows.")

    def test_error_text(self):
        self.assertEqual(upstream.error_text({"error": "boom"}), "boom")
        self.assertEqual(upstream.error_text({"error": {"message": "too long", "code": "context_length_exceeded"}}),
                         "too long context_length_exceeded")
        self.assertEqual(upstream.error_text("plain"), "plain")

    def test_check_passthrough(self):
        def chat(url):
            return json.dumps({"messages": [{"role": "user", "content": [
                {"type": "text", "text": "hi"}, {"type": "image_url", "image_url": {"url": url}}]}]}).encode()
        self.assertIsNone(server.check_passthrough(chat("data:image/png;base64," + b64(PNG))))
        self.assertIsNone(server.check_passthrough(b'{"messages": [{"role": "user", "content": "hi"}]}'))
        for url in ("/etc/shadow", "file:///etc/passwd", "http://169.254.169.254/", "HTTPS://x/y.png", "C:/x.png"):
            with self.subTest(url=url):
                self.assertIn("data: URL", server.check_passthrough(chat(url)))
        self.assertIsNotNone(server.check_passthrough(b"{oops"))
        self.assertIsNotNone(server.check_passthrough(b"[1]"))

    def test_same_model(self):
        self.assertTrue(upstream.same_model(MODEL + ":w4a16", MODEL))
        self.assertTrue(upstream.same_model(MODEL, MODEL + ":w4a16"))
        self.assertFalse(upstream.same_model("qualcomm/other:w4a16", MODEL))


class TestService(unittest.TestCase):
    def setUp(self):
        self.fake = FakeGenieX()
        cfg = {"upstream": f"http://127.0.0.1:{self.fake.port}", "model": MODEL, "max_tokens": 1200,
               "max_image_bytes": 4096, "prompt_file": os.path.join(CONFIG_DIR, "inspect-prompt.txt")}
        self.inspector = inspector.Inspector(cfg)
        self.httpd = server.create_server(self.inspector, "127.0.0.1", 0)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.port = self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.fake.close()

    def call(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
        conn.request(method, path, body=data, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        raw = resp.read().decode()
        conn.close()
        return resp.status, raw

    def inspect(self, body):
        status, raw = self.call("POST", "/inspect", body)
        return status, json.loads(raw)

    def test_inspect_returns_findings(self):
        self.fake.queue_content("  A dialog with a red error banner.  ")
        status, r = self.inspect({"image": b64(PNG), "caption": "Shows the error"})
        self.assertEqual(status, 200)
        self.assertEqual(r["findings"], "A dialog with a red error banner.")
        self.assertEqual((r["model"], r["media_type"], r["truncated"]), (MODEL, "image/png", False))
        self.assertEqual(r["usage"], {"prompt_tokens": 900, "completion_tokens": 40})
        self.assertEqual(self.fake.paths[-1], "/v1/chat/completions")
        sent = self.fake.requests[0]
        self.assertEqual((sent["model"], sent["temperature"], sent["max_tokens"], sent["enable_think"]),
                         (MODEL, 0, 1200, False))
        self.assertIn("untrusted", sent["messages"][0]["content"])
        self.assertEqual(sent["messages"][1]["content"][1]["image_url"]["url"], "data:image/png;base64," + b64(PNG))

    def test_truncated_reply_is_returned_and_flagged(self):
        self.fake.queue_content("A long description", finish="length")
        status, r = self.inspect({"image": b64(WEBP)})
        self.assertEqual((status, r["truncated"], r["media_type"]), (200, True, "image/webp"))

    def test_empty_reply_is_an_error(self):
        self.fake.queue_content("   ")
        self.assertEqual(self.inspect({"image": b64(PNG)})[0], 502)

    def test_context_too_long(self):
        self.fake.replies.append((400, {"error": {"message": "prompt is longer than the model's context window",
                                                  "type": "invalid_request_error",
                                                  "code": "context_length_exceeded"}}))
        self.assertEqual(self.inspect({"image": b64(PNG)})[0], 413)

    def test_image_the_model_cannot_load(self):
        self.fake.replies.append((400, {"error": "failed to load image", "code": "VLM_IMAGE_LOAD"}))
        self.assertEqual(self.inspect({"image": b64(PNG)})[0], 415)

    def test_model_server_error(self):
        self.fake.replies.append((500, {"error": "boom"}))
        status, r = self.inspect({"image": b64(PNG)})
        self.assertEqual(status, 502)
        self.assertIn("boom", r["error"])

    def test_bad_input(self):
        self.assertEqual(self.inspect({})[0], 400)
        self.assertEqual(self.inspect({"image": b64(PNG), "caption": 3})[0], 400)
        self.assertEqual(self.inspect({"image": b64(PNG), "caption": "x" * 5000})[0], 400)
        self.assertEqual(self.inspect({"image": b64(b"plain text, not an image")})[0], 415)
        self.assertEqual(self.inspect({"image": b64(PNG + b"\x00" * 5000)})[0], 413)
        self.assertEqual(self.call("POST", "/inspect", b"{oops")[0], 400)
        self.assertEqual(self.call("POST", "/inspect", b"[1]")[0], 400)
        self.assertEqual(self.fake.requests, [])

    def test_body_over_limit_is_refused(self):
        self.assertEqual(self.call("POST", "/inspect", b"x" * (self.inspector.max_body + 1))[0], 413)

    def test_health(self):
        status, raw = self.call("GET", "/health")
        self.assertEqual((status, json.loads(raw)["status"]), (200, "ready"))
        self.fake.state = "active"
        self.assertEqual(self.call("GET", "/health")[0], 200)
        self.fake.state = "loading"
        status, raw = self.call("GET", "/health")
        self.assertEqual((status, json.loads(raw)["status"]), (503, "loading"))
        self.fake.state = None
        status, raw = self.call("GET", "/health")
        self.assertEqual((status, json.loads(raw)["status"]), (503, "unloaded"))
        self.assertEqual(self.call("GET", "/nope")[0], 404)

    def test_health_when_model_server_down(self):
        self.fake.close()
        status, raw = self.call("GET", "/health")
        self.assertEqual((status, json.loads(raw)["status"]), (503, "down"))
        self.fake = FakeGenieX()  # a fresh server for tearDown to close

    def test_warm_up_loads_the_model(self):
        self.fake.state = None
        url = f"http://127.0.0.1:{self.fake.port}"
        self.assertEqual(upstream.warm_up(url, MODEL, wait=10), 0)
        self.assertEqual(self.fake.state, "idle")
        self.assertEqual(self.fake.requests[-1], {"model": MODEL, "messages": [{"role": "system", "content": "warm-up"}]})

    def test_warm_up_gives_up_on_a_missing_model(self):
        self.fake.close()
        missing = FakeGenieX(state=None)
        try:
            # A 404 (model not in the store) ends the warm-up at once.
            url = f"http://127.0.0.1:{missing.port}"
            missing.httpd.RequestHandlerClass.do_POST = lambda h: h.reply(404, {"error": "model not found"})
            self.assertEqual(upstream.warm_up(url, MODEL, wait=10), 1)
        finally:
            missing.close()
            self.fake = FakeGenieX()  # a fresh server for tearDown to close

    def test_passthrough(self):
        status, raw = self.call("GET", "/v1/models")
        self.assertEqual((status, json.loads(raw)["data"][0]["id"]), (200, MODEL + ":w4a16"))
        status, raw = self.call("POST", "/v1/chat/completions",
                                {"model": MODEL, "stream": True, "messages": [{"role": "user", "content": "hi"}]})
        self.assertEqual(status, 200)
        self.assertIn("data: [DONE]", raw)
        self.assertEqual(raw.count("data: "), 3)

    def test_v3_is_an_alias_of_v1(self):
        self.assertEqual(self.call("GET", "/v3/models")[0], 200)
        self.assertEqual(self.fake.paths[-1], "/v1/models")

    def test_passthrough_refuses_image_urls_and_paths(self):
        for url in ("/etc/shadow", "http://example.com/admin.png"):
            with self.subTest(url=url):
                body = {"model": MODEL, "messages": [{"role": "user", "content": [
                    {"type": "image_url", "image_url": {"url": url}}]}]}
                status, raw = self.call("POST", "/v1/chat/completions", body)
                self.assertEqual(status, 400)
                self.assertIn("data: URL", json.loads(raw)["error"])
        self.assertEqual(self.fake.requests, [])


if __name__ == "__main__":
    unittest.main()
