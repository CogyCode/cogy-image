"""Cogy Image: reads screenshots and images for the Cogy system.

Entry point of the image service, an HTTP service in front of the model
server (GenieX on localhost), which runs a vision-language model on the NPU.
Standard library only, so it runs on the system Python 3. The HTTP API is
described in server.py.

    python3 image.py --config image.json [--warm-up]
"""

import argparse
import json
import logging
import logging.handlers
import sys

from inspector import Inspector
from server import create_server
from upstream import warm_up

LOG_FORMAT = "%(asctime)s %(levelname)s %(message)s"
LOG_MAX_BYTES = 5_000_000
LOG_BACKUPS = 3

log = logging.getLogger("image")


def parse_args(argv=None):
    """The command line options."""
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", required=True, help="image.json written by install.sh")
    ap.add_argument("--warm-up", action="store_true",
                    help="load the model into the model server, wait until it is ready, and exit")
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
    """Serve the HTTP API until stopped, or with --warm-up load the model.
    Returns the exit code."""
    args = parse_args(argv)
    cfg = load_config(args.config)
    if args.warm_up:
        return warm_up(cfg["upstream"], cfg["model"])
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
