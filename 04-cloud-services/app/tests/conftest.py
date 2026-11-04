"""Shared fixtures.

Unit tests run against the in-memory store (no database needed).
Integration tests run only when TEST_DATABASE_URL is set (CI starts a PostgreSQL service for this).
"""

import os

import pytest

from cloudops import create_app
from cloudops.config import load_settings


@pytest.fixture()
def app(monkeypatch, tmp_path):
    monkeypatch.setenv("APP_ENV", "test")
    monkeypatch.setenv("NOTES_STORE", "memory")
    monkeypatch.setenv("LOG_FORMAT", "text")
    monkeypatch.delenv("DATABASE_URL", raising=False)
    # Point dotenv at an empty dir so a developer's local .env can't leak into tests.
    settings = load_settings(dotenv_path=tmp_path / ".env")
    return create_app(settings)


@pytest.fixture()
def client(app):
    return app.test_client()


@pytest.fixture()
def pg_app(monkeypatch, tmp_path):
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL not set; skipping PostgreSQL integration test")
    monkeypatch.setenv("APP_ENV", "test")
    monkeypatch.setenv("NOTES_STORE", "postgres")
    monkeypatch.setenv("DATABASE_URL", url)
    monkeypatch.setenv("LOG_FORMAT", "text")
    settings = load_settings(dotenv_path=tmp_path / ".env")
    app = create_app(settings)
    yield app
    # Clean up what the test created so runs stay independent.
    store = app.extensions["notes_store"]
    for note in store.list(limit=500):
        store.delete(note["id"])
