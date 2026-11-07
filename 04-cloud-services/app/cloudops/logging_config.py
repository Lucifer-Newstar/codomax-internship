"""Structured logging.

In production we log one JSON object per line to stdout. That format is what CloudWatch Logs,
`docker logs` and `journalctl` handle best: every line is self-contained and searchable with
filters like `{ $.status >= 500 }` in CloudWatch Logs Insights.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime

# Fields added by `extra={...}` that we want to surface in the JSON output.
EXTRA_FIELDS = (
    "request_id",
    "method",
    "path",
    "status",
    "duration_ms",
    "remote_addr",
    "note_id",
)


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "time": datetime.fromtimestamp(record.created, tz=UTC).isoformat(
                timespec="milliseconds"
            ),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for key in EXTRA_FIELDS:
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


class TextFormatter(logging.Formatter):
    def __init__(self):
        super().__init__("%(asctime)s %(levelname)-7s %(name)s: %(message)s")

    def format(self, record: logging.LogRecord) -> str:
        base = super().format(record)
        extras = " ".join(f"{k}={getattr(record, k)}" for k in EXTRA_FIELDS if hasattr(record, k))
        return f"{base} {extras}".rstrip()


def configure_logging(level: str = "INFO", fmt: str = "json") -> None:
    root = logging.getLogger()
    root.handlers.clear()
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter() if fmt == "json" else TextFormatter())
    root.addHandler(handler)
    root.setLevel(level)
    # Werkzeug's own access log duplicates ours; keep only warnings from it.
    logging.getLogger("werkzeug").setLevel(logging.WARNING)
