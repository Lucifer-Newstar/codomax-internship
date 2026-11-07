"""CloudOps Notes — a small Flask + PostgreSQL app used throughout modules 03–06.

Application factory pattern: `create_app()` builds a fresh app from the environment, which keeps
tests isolated and lets gunicorn import `wsgi:app`.
"""

from __future__ import annotations

import logging
import time
import uuid

from flask import Flask, g, request

from .config import Settings, load_settings
from .db import StoreUnavailable, make_store
from .logging_config import configure_logging

log = logging.getLogger("cloudops")


def create_app(settings: Settings | None = None) -> Flask:
    settings = settings or load_settings()
    configure_logging(settings.log_level, settings.log_format)

    app = Flask(__name__)
    app.config["SECRET_KEY"] = settings.secret_key
    app.config["JSON_SORT_KEYS"] = False
    app.config["MAX_CONTENT_LENGTH"] = 64 * 1024  # 64 KiB is plenty for a note

    store = make_store(settings)
    app.extensions["settings"] = settings
    app.extensions["notes_store"] = store

    # Create tables at startup. If the DB is down we log and continue: /health stays green
    # (process alive) while /health/ready reports the problem — that is what a load balancer
    # or orchestrator should see.
    try:
        store.init_schema()
    except StoreUnavailable as exc:
        log.error("schema init skipped, database unavailable: %s", exc)

    from .routes import bp

    app.register_blueprint(bp)

    # --- request logging with a request id --------------------------------------------
    @app.before_request
    def _start_timer():
        g.start = time.perf_counter()
        g.request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex[:12]

    @app.after_request
    def _log_request(response):
        duration_ms = round((time.perf_counter() - g.get("start", time.perf_counter())) * 1000, 2)
        response.headers["X-Request-ID"] = g.get("request_id", "-")
        # Security headers that cost nothing.
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "same-origin")
        if request.path not in ("/health", "/health/ready"):  # keep probes out of the log
            logging.getLogger("cloudops.access").info(
                "request",
                extra={
                    "request_id": g.get("request_id"),
                    "method": request.method,
                    "path": request.path,
                    "status": response.status_code,
                    "duration_ms": duration_ms,
                    "remote_addr": request.headers.get("X-Forwarded-For", request.remote_addr),
                },
            )
        return response

    log.info(
        "app started env=%s version=%s store=%s",
        settings.app_env,
        settings.version,
        settings.notes_store,
    )
    return app
