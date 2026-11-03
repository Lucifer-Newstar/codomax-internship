"""HTTP routes.

GET  /               the web page
GET  /health         liveness: process is up (never touches the DB)
GET  /health/ready   readiness: can we reach the database? 503 if not
GET  /api/info       non-secret runtime info (version, env, host)
GET  /api/notes      list notes
POST /api/notes      create a note  {"title": "...", "body": "..."}
GET  /api/notes/<id> one note
DELETE /api/notes/<id>
"""

from __future__ import annotations

import logging
import socket
import time

from flask import Blueprint, current_app, jsonify, render_template, request

from .db import BODY_MAX, TITLE_MAX, NoteNotFound, StoreUnavailable

bp = Blueprint("cloudops", __name__)
log = logging.getLogger("cloudops.api")

START_TIME = time.time()


def _store():
    return current_app.extensions["notes_store"]


def _settings():
    return current_app.extensions["settings"]


# --- pages -------------------------------------------------------------------------------
@bp.get("/")
def index():
    s = _settings()
    return render_template(
        "index.html",
        version=s.version,
        app_env=s.app_env,
        asset_base_url=s.asset_base_url,
    )


# --- health -------------------------------------------------------------------------------
@bp.get("/health")
def health():
    return jsonify(status="ok", uptime_seconds=round(time.time() - START_TIME, 1))


@bp.get("/health/ready")
def ready():
    try:
        db_info = _store().ping()
    except StoreUnavailable as exc:
        log.error("readiness check failed: %s", exc)
        return jsonify(status="unavailable", database={"ok": False, "error": str(exc)}), 503
    return jsonify(status="ok", database={"ok": True, **db_info})


@bp.get("/api/info")
def info():
    s = _settings()
    return jsonify(
        app="cloudops-notes",
        hostname=socket.gethostname(),
        uptime_seconds=round(time.time() - START_TIME, 1),
        **s.safe_dict(),
    )


# --- notes API ----------------------------------------------------------------------------
def _validate_note_payload(data) -> tuple[str, str]:
    if not isinstance(data, dict):
        raise ValueError("JSON body must be an object")
    title = str(data.get("title", "")).strip()
    body = str(data.get("body", "")).strip()
    if not title:
        raise ValueError("title is required")
    if len(title) > TITLE_MAX:
        raise ValueError(f"title must be at most {TITLE_MAX} characters")
    if len(body) > BODY_MAX:
        raise ValueError(f"body must be at most {BODY_MAX} characters")
    return title, body


@bp.get("/api/notes")
def list_notes():
    try:
        limit = min(max(int(request.args.get("limit", 100)), 1), 500)
    except ValueError:
        return jsonify(error="limit must be an integer"), 400
    return jsonify(notes=_store().list(limit=limit))


@bp.post("/api/notes")
def create_note():
    try:
        title, body = _validate_note_payload(request.get_json(silent=True))
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    note = _store().create(title, body)
    log.info("note created", extra={"note_id": note["id"]})
    return jsonify(note), 201


@bp.get("/api/notes/<int:note_id>")
def get_note(note_id: int):
    try:
        return jsonify(_store().get(note_id))
    except NoteNotFound:
        return jsonify(error="note not found"), 404


@bp.delete("/api/notes/<int:note_id>")
def delete_note(note_id: int):
    try:
        _store().delete(note_id)
    except NoteNotFound:
        return jsonify(error="note not found"), 404
    log.info("note deleted", extra={"note_id": note_id})
    return "", 204


# --- error handlers -----------------------------------------------------------------------
@bp.app_errorhandler(StoreUnavailable)
def handle_store_unavailable(exc):
    log.error("store unavailable: %s", exc)
    return jsonify(error="database unavailable"), 503


@bp.app_errorhandler(404)
def handle_404(_exc):
    if request.path.startswith("/api/"):
        return jsonify(error="not found"), 404
    return render_template(
        "index.html",
        version=_settings().version,
        app_env=_settings().app_env,
        asset_base_url=_settings().asset_base_url,
    ), 404
