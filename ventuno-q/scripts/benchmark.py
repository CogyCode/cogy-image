#!/usr/bin/env python3
"""Measures how fast Cogy Image reads screenshots, its generation speed and
the model server's memory.

    python3 scripts/benchmark.py [--trials 3] [--gen-tokens 256] [--base-url URL]

- Inspection: --trials POST /inspect calls with a generated 1920 x 1080
  screenshot. Each has different text. Reports the time per screenshot.
- Generation: streams a --gen-tokens completion and times the tokens after
  the first (time to first token reported too).
- Two at once: two inspections sent together. GenieX runs requests one after
  the other, so expect about twice the time of one.
- Memory: the model server's resident memory and the system's available
  memory. (The NPU shares the system's memory.)
"""

import argparse
import base64
import http.client
import json
import random
import statistics
import sys
import threading
import time
import urllib.parse
import uuid

import testimage
import verify

S = verify.S


def inspect_body():
    """An /inspect request with a fresh 1920 x 1080 test screenshot."""
    png = testimage.screenshot(f"Error {random.randint(0, 10**6)} payment failed",
                               f"Save {random.randint(0, 10**6)}", 1920, 1080)
    return {"image": base64.b64encode(png).decode(), "caption": "The form saved without errors"}


def inspect(base):
    """(seconds, tokens written) for one inspection."""
    started = time.monotonic()
    status, r = verify.http("POST", f"{base}/inspect", inspect_body())
    if status != 200:
        raise SystemExit(f"POST /inspect: HTTP {status}: {r}")
    return round(time.monotonic() - started, 1), r["usage"]["completion_tokens"]


def generation(base, model, tokens):
    """(tokens per second after the first, seconds to the first token)."""
    u = urllib.parse.urlsplit(base)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=600)
    body = {"model": model, "stream": True, "max_tokens": tokens, "temperature": 0, "enable_think": False,
            "stream_options": {"include_usage": True},
            "messages": [{"role": "user", "content": f"Run {uuid.uuid4()}. Describe a settings page in great detail."}]}
    started = time.monotonic()
    conn.request("POST", "/v1/chat/completions", body=json.dumps(body), headers={"Content-Type": "application/json"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise SystemExit(f"streaming: HTTP {resp.status}: {resp.read()[:300]}")
    first = last = None
    chunks = 0
    usage = None
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        # Server-sent events: "data:" then an optional space (GenieX sends none).
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            continue
        chunk = json.loads(data)
        if chunk.get("choices") and (chunk["choices"][0].get("delta") or {}).get("content"):
            now = time.monotonic() - started
            first = now if first is None else first
            last = now
            chunks += 1
        if chunk.get("usage"):
            usage = chunk["usage"]
    conn.close()
    count = (usage or {}).get("completion_tokens") or chunks
    if first is None or last is None or last <= first:
        return 0.0, first or 0.0
    return round((count - 1) / (last - first), 1), round(first, 2)


def memory():
    """(model server resident GB, system available GB); None where unknown."""
    pid = verify.main_pid(S["MODEL_SERVICE_NAME"])
    rss = None
    if pid:
        try:
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        rss = int(line.split()[1]) / 1024 / 1024
        except OSError:
            pass
    available = None
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    available = int(line.split()[1]) / 1024 / 1024
    except OSError:
        pass
    return rss, available


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--base-url")
    ap.add_argument("--trials", type=int, default=3)
    ap.add_argument("--gen-tokens", type=int, default=256)
    a = ap.parse_args(argv)
    if not a.base_url:
        ip = verify.private_ip()
        if not ip:
            raise SystemExit("This machine is not on the private network; pass --base-url")
        a.base_url = f"http://{ip}:{S['PORT']}"
    base, model = a.base_url, S["MODEL_NAME"]
    print(f"Server: {base}   Model: {model}")

    times = []
    for t in range(1, a.trials + 1):
        seconds, written = inspect(base)
        times.append(seconds)
        print(f"  inspection {t}: {seconds} s, {written} tokens written")

    speeds, ttfts = [], []
    for t in range(1, a.trials + 1):
        speed, ttft = generation(base, model, a.gen_tokens)
        speeds.append(speed)
        ttfts.append(ttft)
        print(f"  generation {t}: {speed} tok/s, first token after {ttft} s")

    results = []
    started = time.monotonic()
    threads = [threading.Thread(target=lambda: results.append(inspect(base))) for _ in range(2)]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    both = round(time.monotonic() - started, 1)
    print(f"  2 at once: {len(results)} of 2 succeeded in {both} s")

    rss, available = memory()
    print()
    print(f"Screenshot (1920 x 1080): {statistics.median(times)} s per inspection (median)")
    print(f"Generation:               {statistics.median(speeds)} tok/s (median, {a.gen_tokens} tokens)")
    print(f"Time to first token:      {statistics.median(ttfts)} s (median, text only)")
    print(f"2 inspections at once:    {both} s for both")
    if rss is not None and available is not None:
        print(f"Memory: model server {rss:.2f} GB resident; {available:.2f} GB available on the system")
    else:
        print("Memory: unavailable (run on the board, with the model server running)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
