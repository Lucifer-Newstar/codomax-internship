"""Runs only with TEST_DATABASE_URL set (e.g. CI's postgres service or a local docker db)."""


def test_postgres_roundtrip(pg_app):
    client = pg_app.test_client()
    r = client.get("/health/ready")
    assert r.status_code == 200, r.get_json()
    assert r.get_json()["database"]["backend"] == "postgres"

    r = client.post("/api/notes", json={"title": "pg note", "body": "stored in PostgreSQL"})
    assert r.status_code == 201
    note_id = r.get_json()["id"]
    assert client.get(f"/api/notes/{note_id}").get_json()["body"] == "stored in PostgreSQL"
    assert pg_app.extensions["notes_store"].count() == 1


def test_readiness_reports_db_down(monkeypatch, tmp_path):
    """Point the app at a closed port: /health must stay 200, /health/ready must be 503."""
    import pytest

    from cloudops import create_app
    from cloudops.config import load_settings

    monkeypatch.setenv("APP_ENV", "test")
    monkeypatch.setenv("NOTES_STORE", "postgres")
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@127.0.0.1:1/none")
    monkeypatch.setenv("LOG_FORMAT", "text")
    try:
        import psycopg  # noqa: F401
    except ImportError:
        pytest.skip("psycopg not installed")
    app = create_app(load_settings(dotenv_path=tmp_path / ".env"))
    c = app.test_client()
    assert c.get("/health").status_code == 200
    r = c.get("/health/ready")
    assert r.status_code == 503
    assert r.get_json()["database"]["ok"] is False
    assert c.get("/api/notes").status_code == 503
