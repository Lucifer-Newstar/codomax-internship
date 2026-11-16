import os

import pytest

from cloudops_api import create_app
from cloudops_api.config import load_settings


def _settings(monkeypatch, tmp_path, **env):
    base = {"APP_ENV": "test", "LOG_FORMAT": "text", "TASK_STORE": "memory"}
    base.update(env)
    for k, v in base.items():
        monkeypatch.setenv(k, v)
    monkeypatch.delenv("DATABASE_URL", raising=False) if "DATABASE_URL" not in env else None
    return load_settings(dotenv_path=tmp_path / ".env")


@pytest.fixture()
def client(monkeypatch, tmp_path):
    return create_app(_settings(monkeypatch, tmp_path)).test_client()


@pytest.fixture()
def pg_client(monkeypatch, tmp_path):
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL not set")
    app = create_app(_settings(monkeypatch, tmp_path, TASK_STORE="postgres", DATABASE_URL=url))
    yield app.test_client()
    store = app.extensions["task_store"]
    for t in store.list(limit=1000):
        store.delete(t["id"])
