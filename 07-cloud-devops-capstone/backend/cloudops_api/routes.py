"""REST API.

GET    /health            liveness (no DB)
GET    /health/ready      readiness (DB ping) — 503 when the database is unreachable
GET    /metrics           Prometheus text format
GET    /api/info          non-secret runtime info
GET    /api/stats         task counts + last recorded deployment
GET    /api/tasks[?status=todo|doing|done]
POST   /api/tasks         {"title", "description"?, "priority"?}
GET    /api/tasks/<id>
PATCH  /api/tasks/<id>    any of {"title", "description", "status", "priority"}
DELETE /api/tasks/<id>
"""

from __future__ import annotations

import logging
import socket
import time

from flask import Blueprint, Response, current_app, jsonify, request

from .db import DESC_MAX, STATUSES, TITLE_MAX, StoreUnavailable, TaskNotFound

bp = Blueprint("api", __name__)
log = logging.getLogger("cloudops.api")
START = time.time()


def _store():
    return current_app.extensions["task_store"]


def _settings():
    return current_app.extensions["settings"]


def _metrics():
    return current_app.extensions["metrics"]


# --- health & ops ------------------------------------------------------------------------
@bp.get("/health")
def health():
    return jsonify(status="ok", uptime_seconds=round(time.time() - START, 1))


@bp.get("/health/ready")
def ready():
    try:
        info = _store().ping()
    except StoreUnavailable as exc:
        log.error("readiness failed: %s", exc)
        return jsonify(status="unavailable", database={"ok": False, "error": str(exc)}), 503
    return jsonify(status="ok", database={"ok": True, **info})


@bp.get("/metrics")
def metrics():
    return Response(_metrics().render(), mimetype="text/plain; version=0.0.4")


@bp.get("/api/info")
def info():
    s = _settings()
    return jsonify(
        app="cloudops-api",
        hostname=socket.gethostname(),
        uptime_seconds=round(time.time() - START, 1),
        metrics=_metrics().totals(),
        **s.safe_dict(),
    )


@bp.get("/api/stats")
def stats():
    return jsonify(_store().stats())


# --- tasks ----------------------------------------------------------------------------------
def _clean(data, *, partial: bool) -> dict:
    if not isinstance(data, dict):
        raise ValueError("JSON body must be an object")
    out: dict = {}
    if "title" in data or not partial:
        title = str(data.get("title", "")).strip()
        if not title:
            raise ValueError("title is required")
        if len(title) > TITLE_MAX:
            raise ValueError(f"title must be at most {TITLE_MAX} characters")
        out["title"] = title
    if "description" in data or not partial:
        desc = str(data.get("description", "")).strip()
        if len(desc) > DESC_MAX:
            raise ValueError(f"description must be at most {DESC_MAX} characters")
        out["description"] = desc
    if "priority" in data or not partial:
        try:
            prio = int(data.get("priority", 2))
        except (TypeError, ValueError) as exc:
            raise ValueError("priority must be 1, 2 or 3") from exc
        if prio not in (1, 2, 3):
            raise ValueError("priority must be 1, 2 or 3")
        out["priority"] = prio
    if "status" in data:
        if data["status"] not in STATUSES:
            raise ValueError(f"status must be one of {', '.join(STATUSES)}")
        out["status"] = data["status"]
    if partial and not out:
        raise ValueError("nothing to update")
    return out


@bp.get("/api/tasks")
def list_tasks():
    status = request.args.get("status")
    if status and status not in STATUSES:
        return jsonify(error=f"status must be one of {', '.join(STATUSES)}"), 400
    return jsonify(tasks=_store().list(status=status))


@bp.post("/api/tasks")
def create_task():
    try:
        f = _clean(request.get_json(silent=True), partial=False)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    task = _store().create(f["title"], f["description"], f["priority"])
    log.info("task created", extra={"task_id": task["id"]})
    return jsonify(task), 201


@bp.get("/api/tasks/<int:task_id>")
def get_task(task_id: int):
    try:
        return jsonify(_store().get(task_id))
    except TaskNotFound:
        return jsonify(error="task not found"), 404


@bp.patch("/api/tasks/<int:task_id>")
def update_task(task_id: int):
    try:
        fields = _clean(request.get_json(silent=True), partial=True)
        task = _store().update(task_id, fields)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    except TaskNotFound:
        return jsonify(error="task not found"), 404
    log.info("task updated", extra={"task_id": task_id})
    return jsonify(task)


@bp.delete("/api/tasks/<int:task_id>")
def delete_task(task_id: int):
    try:
        _store().delete(task_id)
    except TaskNotFound:
        return jsonify(error="task not found"), 404
    log.info("task deleted", extra={"task_id": task_id})
    return "", 204


# --- errors -----------------------------------------------------------------------------------
@bp.app_errorhandler(StoreUnavailable)
def _unavailable(exc):
    log.error("store unavailable: %s", exc)
    return jsonify(error="database unavailable"), 503


@bp.app_errorhandler(404)
def _404(_):
    return jsonify(error="not found"), 404


@bp.app_errorhandler(405)
def _405(_):
    return jsonify(error="method not allowed"), 405
