"""CloudOps API — capstone backend. Evolution of the module 03 app (04-cloud-services/app):
tasks instead of notes, PATCH, /metrics, /api/stats, deployment recording.
"""

from __future__ import annotations

import logging
import socket
import time
import uuid

from flask import Flask, g, request

from .config import Settings, load_settings
from .db import StoreUnavailable, make_store
from .logging_config import configure_logging
from .metrics import Metrics

log = logging.getLogger("cloudops")


def create_app(settings: Settings | None = None) -> Flask:
    settings = settings or load_settings()
    configure_logging(settings.log_level, settings.log_format)

    app = Flask(__name__)
    app.config["SECRET_KEY"] = settings.secret_key
    app.config["MAX_CONTENT_LENGTH"] = 64 * 1024

    store = make_store(settings)
    metrics = Metrics()
    app.extensions.update(settings=settings, task_store=store, metrics=metrics)

    try:
        store.init_schema()
        if settings.app_env != "test":
            store.record_deployment(
                settings.version, settings.git_sha, settings.app_env, socket.gethostname()
            )
    except StoreUnavailable as exc:
        log.error("database unavailable at start-up: %s", exc)

    from .routes import bp

    app.register_blueprint(bp)

    @app.before_request
    def _start():
        g.start = time.perf_counter()
        g.request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex[:12]

    @app.after_request
    def _finish(response):
        duration_ms = round((time.perf_counter() - g.get("start", time.perf_counter())) * 1000, 2)
        response.headers["X-Request-ID"] = g.get("request_id", "-")
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Cache-Control", "no-store")
        route = request.url_rule.rule if request.url_rule else "unmatched"
        if request.path not in ("/health", "/health/ready", "/metrics"):
            metrics.observe(request.method, route, response.status_code, duration_ms)
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
        "app started env=%s version=%s sha=%s store=%s",
        settings.app_env,
        settings.version,
        settings.git_sha,
        settings.task_store,
    )
    return app
