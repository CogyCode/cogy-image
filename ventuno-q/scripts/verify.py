#!/usr/bin/env python3
"""Checks that the installed Cogy Image meets its requirements.

    sudo python3 scripts/verify.py [--test-restart] [--skip-context]
    sudo python3 scripts/verify.py --self-test      (install.sh's self-test)

- Services: running, start at boot, restart on failure, start in the right
  order (after the model server, the firewall rules and Tailscale)
- Network: the service listens on the private address only, the model server
  on 127.0.0.1 only
- Firewall: the API port is allowed from ALLOW_FROM only; the model server's
  port from this machine only
- API: /health, POST /inspect reads a generated screenshot, bad input is
  refused, model listed, chat passthrough with text and with an image, a
  passthrough image given as a file path or URL is refused
- Images: a 4K screenshot reads in about the time of a 1920 x 1080 one (every
  image is resized to the model's fixed input size)
- Two at once: both requests are answered (GenieX runs them one after the
  other)
- Context: a prompt just under the limit is served; one just over is refused
- Crash recovery (--test-restart): kills the image service and stops the
  model server's process, and waits for systemd to bring them back

Needs root (for the firewall and process checks). Output also goes to
/var/log/cogy-image/verify.log.
"""

import argparse
import base64
import ipaddress
import json
import os
import random
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

import testimage

HERE = os.path.dirname(os.path.abspath(__file__))
# Seconds the API checks wait for /health: the model may still be loading.
HEALTH_WAIT = 900


def load_settings(path=os.path.join(HERE, "..", "config", "settings.env")):
    """KEY=value lines of settings.env (quotes stripped, comments ignored)."""
    settings = {}
    pattern = re.compile(r"""^([A-Z_][A-Z0-9_]*)=(?:'([^']*)'|"([^"]*)"|(\S*))""")
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = pattern.match(line.strip())
            if m:
                settings[m.group(1)] = next(g for g in m.groups()[1:] if g is not None)
    return settings


S = load_settings()


def run(*cmd):
    """A command's stdout, or "" when it fails or is missing."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def private_ip():
    """This machine's address on Cogy Server's private network, or None when
    not joined."""
    network = ipaddress.ip_network(S["PRIVATE_RANGE"])
    for word in run("tailscale", "ip", "-4").split():
        try:
            if ipaddress.ip_address(word) in network:
                return word
        except ValueError:
            continue
    return None


def http(method, url, body=None, timeout=600):
    """(status, parsed JSON or text) for a request; never raises for HTTP errors."""
    data = json.dumps(body).encode() if body is not None and not isinstance(body, bytes) else body
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except OSError as e:
        return 0, str(e)
    try:
        return status, json.loads(raw.decode("utf-8"))
    except ValueError:
        return status, raw.decode("utf-8", "replace")


def data_url(png):
    return "data:image/png;base64," + base64.b64encode(png).decode()


def button_question(png):
    """Chat content asking for the text of the test screenshot's button."""
    return [{"type": "text", "text": "What is written on the blue button? Reply with the text only."},
            {"type": "image_url", "image_url": {"url": data_url(png)}}]


class Checker:
    """Prints and logs check results, and counts the failures."""

    def __init__(self, log_path=None):
        self.failures = 0
        self.log = open(log_path, "w", encoding="utf-8") if log_path else None

    def out(self, line):
        print(line, flush=True)
        if self.log:
            self.log.write(line + "\n")
            self.log.flush()

    def check(self, name, ok, detail=""):
        self.out(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}".rstrip())
        if not ok:
            self.failures += 1
        return ok


def chat(base, model, content, max_tokens):
    body = {"model": model, "max_tokens": max_tokens, "temperature": 0, "enable_think": False,
            "messages": [{"role": "user", "content": content}]}
    return http("POST", f"{base}/v1/chat/completions", body)


def answer(reply):
    """The text of a chat completion reply, or ""."""
    try:
        return (reply["choices"][0]["message"]["content"] or "").strip()
    except (KeyError, IndexError, TypeError):
        return ""


def check_api(c, base, model):
    """The checks install.sh runs as its self-test."""
    deadline = time.monotonic() + HEALTH_WAIT
    status, health = 0, None
    while time.monotonic() < deadline:
        status, health = http("GET", f"{base}/health", timeout=10)
        if status == 200:
            break
        time.sleep(5)
    c.check("GET /health", status == 200, str(health.get("status") if isinstance(health, dict) else health))

    # No caption: the text must come from the image, not from the request.
    png = testimage.screenshot("Payment failed", "Save changes")
    status, r = http("POST", f"{base}/inspect", {"image": base64.b64encode(png).decode()})
    findings = r.get("findings", "") if isinstance(r, dict) else ""
    read = (status == 200 and re.search(r"payment\s+failed", findings, re.I) is not None
            and re.search(r"save\s+changes", findings, re.I) is not None)
    if c.check("POST /inspect reads the test screenshot", read,
               f"{r.get('seconds')} s" if status == 200 else f"HTTP {status}: {r}"):
        c.out(f"INFO  findings: {findings[:300]}")

    status, r = chat(base, model, "Reply with exactly: OK", 16)
    c.check("POST /v1/chat/completions (text)", status == 200 and bool(answer(r)), f"'{answer(r)}'" if status == 200 else f"HTTP {status}: {r}")
    return png


def check_services(c):
    for unit in (S["MODEL_SERVICE_NAME"], S["SERVICE_NAME"], S["FIREWALL_SERVICE_NAME"]):
        active = run("systemctl", "is-active", unit).strip()
        c.check(f"{unit} running", active == "active", active)
        enabled = run("systemctl", "is-enabled", unit).strip()
        c.check(f"{unit} starts at boot", enabled == "enabled", enabled)
    for unit in (S["MODEL_SERVICE_NAME"], S["SERVICE_NAME"]):
        restart = run("systemctl", "show", "-p", "Restart", "--value", unit).strip()
        c.check(f"{unit} restarts on failure", restart == "always", f"Restart={restart}")
    after = run("systemctl", "show", "-p", "After", "--value", S["SERVICE_NAME"]).split()
    needed = [S["MODEL_SERVICE_NAME"] + ".service", "tailscaled.service", S["FIREWALL_SERVICE_NAME"] + ".service"]
    c.check(f"{S['SERVICE_NAME']} starts after {', '.join(needed)}", all(n in after for n in needed), "")
    ts = run("systemctl", "is-enabled", "tailscaled").strip()
    c.check("Tailscale starts at boot", ts == "enabled", ts)


def listeners(port):
    """Local addresses listening on TCP port."""
    addrs = set()
    for line in run("ss", "-Hltn", f"sport = :{port}").splitlines():
        parts = line.split()
        if len(parts) >= 4:
            addrs.add(parts[3].rsplit(":", 1)[0].strip("[]"))
    return addrs


def check_network(c, ip):
    addrs = listeners(S["PORT"])
    c.check(f"{S['NAME']} listens on the private address only", addrs == {ip}, ", ".join(sorted(addrs)))
    addrs = listeners(S["MODEL_PORT"])
    c.check("Model server listens on 127.0.0.1 only", addrs == {"127.0.0.1"}, ", ".join(sorted(addrs)))


def check_firewall(c):
    table = run("nft", "-j", "list", "table", "inet", S["NFT_TABLE"])
    try:
        items = json.loads(table)["nftables"]
    except (ValueError, KeyError):
        c.check(f"Firewall table inet {S['NFT_TABLE']} loaded", False, "missing")
        return
    allowed = set()
    for item in items:
        for elem in (item.get("set") or {}).get("elem", []):
            if isinstance(elem, str):
                allowed.add(elem)
            elif isinstance(elem, dict) and "prefix" in elem:
                allowed.add(f"{elem['prefix']['addr']}/{elem['prefix']['len']}")
    want = set(S["ALLOW_FROM"].split())
    c.check(f"Firewall allows {', '.join(sorted(want))}", allowed == want, ", ".join(sorted(allowed)))
    text = run("nft", "list", "table", "inet", S["NFT_TABLE"])
    c.check("Firewall drops all other sources", re.search(rf"tcp dport {S['PORT']} counter packets \d+ bytes \d+ drop", text) is not None, "")
    c.check("Firewall drops the model server's port from other machines",
            re.search(rf'iifname != "lo" tcp dport {S["MODEL_PORT"]} counter packets \d+ bytes \d+ drop', text) is not None, "")


def check_more_api(c, base, model, png):
    status, _ = http("POST", f"{base}/inspect", {})
    c.check("POST /inspect without an image is refused", status == 400, f"HTTP {status}")
    status, _ = http("POST", f"{base}/inspect", {"image": base64.b64encode(b"%PDF-1.7 not an image").decode()})
    c.check("POST /inspect with a non-image is refused", status == 415, f"HTTP {status}")
    status, r = http("GET", f"{base}/v1/models", timeout=10)
    ids = [m.get("id", "") for m in r.get("data", [])] if isinstance(r, dict) else []
    c.check("GET /v1/models", any(i.split(":")[0].lower() == model.lower() for i in ids), ", ".join(ids))
    status, r = chat(base, model, "Is 17 a prime number? Answer yes or no.", 64)
    c.check("POST /v1/chat/completions (text)", status == 200 and bool(answer(r)), f"'{answer(r)}'")
    status, r = chat(base, model, button_question(png), 32)
    c.check("POST /v1/chat/completions (image)", status == 200 and re.search(r"save\s+changes", answer(r), re.I) is not None,
            f"'{answer(r)}'" if status == 200 else f"HTTP {status}: {r}")
    content = [{"type": "text", "text": "What is this?"}, {"type": "image_url", "image_url": {"url": "/etc/hostname"}}]
    status, _ = chat(base, model, content, 8)
    c.check("Passthrough refuses an image given as a file path", status == 400, f"HTTP {status}")


def read_time(base, model, width, height):
    """Seconds to read the button of a width x height test screenshot."""
    png = testimage.screenshot(f"Run {random.randint(0, 10**6)}", "Save changes", width, height)
    started = time.monotonic()
    chat(base, model, button_question(png), 8)
    return time.monotonic() - started


def check_image_size(c, base, model):
    # Every image is resized to the model's fixed IMAGE_SIZE square, so a 4K
    # screenshot costs the same image tokens as a 1920 x 1080 one.
    hd = read_time(base, model, 1920, 1080)
    uhd = read_time(base, model, 3840, 2160)
    c.check("4K screenshot read in at most 1.6 x the time of 1920 x 1080", uhd <= max(1.6 * hd, hd + 1),
            f"{uhd:.1f} s for 4K, {hd:.1f} s for 1920 x 1080")


def check_two_at_once(c, base, model):
    results = []

    def one():
        status, r = chat(base, model, f"Count upwards from {random.randint(0, 10**6)}.", 100)
        results.append(status == 200 and bool(answer(r)))
    threads = [threading.Thread(target=one) for _ in range(2)]
    started = time.monotonic()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    c.check("2 requests at once are both answered", results.count(True) == 2,
            f"{results.count(True)} of 2 in {time.monotonic() - started:.1f} s (run one after the other)")


def check_context(c, base, model):
    limit = int(S["CONTEXT_LENGTH"])
    words = "button form field label error banner window panel menu table list icon link page title".split()
    rng = random.Random()

    def text(n):
        return " ".join(rng.choice(words) for _ in range(n))
    status, r = chat(base, model, text(500), 1)
    per_word = (r.get("usage") or {}).get("prompt_tokens", 0) / 500 if status == 200 and isinstance(r, dict) else 0
    if not per_word:
        c.out(f"INFO  context check skipped: the model server reports no prompt token count (HTTP {status})")
        return
    ok_words = int((limit - 300) / per_word)
    status, r = chat(base, model, text(ok_words), 16)
    used = (r.get("usage") or {}).get("prompt_tokens", 0) if isinstance(r, dict) else 0
    c.check(f"Serves a {used}-token prompt (limit {limit})", status == 200 and used > limit - 600, f"HTTP {status}")
    too_long = int((limit + 300) / per_word)
    status, r = chat(base, model, text(too_long), 16)
    c.check(f"Refuses a ~{int(too_long * per_word)}-token prompt (limit {limit})", status in (400, 413), f"HTTP {status}")


def main_pid(unit):
    """The main process ID of a systemd unit, or 0."""
    try:
        return int(run("systemctl", "show", "-p", "MainPID", "--value", unit).strip() or 0)
    except ValueError:
        return 0


def wait_ready(base, minutes=5):
    """True once /health is 200, False when not within minutes."""
    deadline = time.monotonic() + minutes * 60
    while time.monotonic() < deadline:
        time.sleep(3)
        if http("GET", f"{base}/health", timeout=3)[0] == 200:
            return True
    return False


def check_restart(c, base):
    # A PID of 0 would signal this script's own process group, so a unit with
    # no main process fails the check and is not signalled.
    unit = S["SERVICE_NAME"]
    pid = main_pid(unit)
    if not c.check(f"{unit} has a main process", pid > 0, f"pid {pid}"):
        return
    os.kill(pid, signal.SIGKILL)
    c.out(f"INFO  killed image.py (pid {pid}); waiting for {unit} to restart it")
    back = wait_ready(base)
    pid2 = main_pid(unit)
    c.check(f"{S['NAME']} restarts after a crash", back and pid2 not in (0, pid), f"new pid {pid2}")

    # The model server is stopped with SIGTERM, not SIGKILL: GenieX releases
    # the NPU's buffers on SIGTERM, and a SIGKILL would leave them reserved
    # until reboot. systemd restarts it after any exit (Restart=always).
    unit = S["MODEL_SERVICE_NAME"]
    pid = main_pid(unit)
    if not c.check(f"{unit} has a main process", pid > 0, f"pid {pid}"):
        return
    os.kill(pid, signal.SIGTERM)
    c.out(f"INFO  stopped geniex (pid {pid}) with SIGTERM; waiting for {unit} to restart it and reload the model")
    back = wait_ready(base, minutes=15)
    pid2 = main_pid(unit)
    c.check("Model server restarts after it exits", back and pid2 not in (0, pid), f"new pid {pid2}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true", help="only the API checks install.sh runs")
    ap.add_argument("--test-restart", action="store_true", help="also kill the services and check they come back")
    ap.add_argument("--skip-context", action="store_true", help="skip the context length checks")
    ap.add_argument("--base-url", help="default: this machine's private address and PORT")
    a = ap.parse_args(argv)

    if not a.self_test and hasattr(os, "geteuid") and os.geteuid() != 0:
        print("Root rights needed; re-running with sudo...")
        os.execvp("sudo", ["sudo", sys.executable] + [os.path.abspath(__file__)] + sys.argv[1:])

    log = None if a.self_test else os.path.join(S["LOG_DIR"], "verify.log")
    c = Checker(log if log and os.path.isdir(S["LOG_DIR"]) else None)
    ip = private_ip()
    if not a.base_url:
        c.check("Private address", bool(ip), ip or "not on the private network")
        if not ip:
            return 1
    base = a.base_url or f"http://{ip}:{S['PORT']}"
    model = S["MODEL_NAME"]
    try:
        png = check_api(c, base, model)
        if not a.self_test:
            check_services(c)
            check_network(c, ip)
            check_firewall(c)
            check_more_api(c, base, model, png)
            check_image_size(c, base, model)
            check_two_at_once(c, base, model)
            if not a.skip_context:
                check_context(c, base, model)
            if a.test_restart:
                check_restart(c, base)
    except Exception as e:  # an unexpected error counts as a failed check
        c.check("error", False, repr(e))
    c.out(f"Result: {f'{c.failures} check(s) failed' if c.failures else 'all checks passed'}")
    return 1 if c.failures else 0


if __name__ == "__main__":
    sys.exit(main())
