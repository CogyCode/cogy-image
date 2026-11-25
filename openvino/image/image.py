"""Cogy Image: reads screenshots and images for the Cogy system.

Entry point of the image service, an HTTP service in front of the model
server (OpenVINO Model Server on localhost), which runs a vision-language
model on the GPU. Standard library only, so it runs on the embeddable Python
that install.ps1 puts next to it. The HTTP API is described in server.py.

    python image.py --config image.json
"""

import argparse
import json
import logging
import logging.handlers
import os
import sys

# The embeddable Python's ._pth file keeps the script's directory off sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inspector import Inspector  # noqa: E402
from server import create_server  # noqa: E402

LOG_FORMAT = "%(asctime)s %(levelname)s %(message)s"
LOG_MAX_BYTES = 5_000_000
LOG_BACKUPS = 3

log = logging.getLogger("image")


def parse_args(argv=None):
    """The command line options."""
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", required=True, help="image.json written by install.ps1")
    return ap.parse_args(argv)


def load_config(path):
    """The service configuration from image.json."""
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def setup_logging(log_file=None):
    """Log to log_file, rotated, when one is configured, else to stdout."""
    if log_file:
        handler = logging.handlers.RotatingFileHandler(log_file, maxBytes=LOG_MAX_BYTES,
                                                       backupCount=LOG_BACKUPS, encoding="utf-8")
    else:
        handler = logging.StreamHandler(sys.stdout)
    logging.basicConfig(level=logging.INFO, handlers=[handler], format=LOG_FORMAT)


def main(argv=None):
    """Serve the HTTP API until stopped. Returns the exit code."""
    args = parse_args(argv)
    cfg = load_config(args.config)
    setup_logging(cfg.get("log_file"))
    server = create_server(Inspector(cfg), cfg["bind"], cfg["port"])
    log.info("Cogy Image listening on http://%s:%d, model %s via %s",
             cfg["bind"], cfg["port"], cfg["model"], cfg["upstream"])
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
