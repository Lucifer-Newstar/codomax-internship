"""Integration tests — run only with TEST_DATABASE_URL (CI service container or local docker)."""


def test_roundtrip_in_postgres(pg_client):
    ready = pg_client.get("/health/ready").get_json()
    assert ready["database"]["backend"] == "postgres"
    t = pg_client.post("/api/tasks", json={"title": "pg", "description": "stored"}).get_json()
    assert (
        pg_client.patch(f"/api/tasks/{t['id']}", json={"status": "done"}).get_json()["status"]
        == "done"
    )
    stats = pg_client.get("/api/stats").get_json()
    assert stats["tasks"]["done"] == 1
    assert stats["last_deployment"] is None or "git_sha" in stats["last_deployment"]


def test_ready_is_503_when_db_down(monkeypatch, tmp_path):
    from cloudops_api import create_app
    from cloudops_api.config import load_settings

    for k, v in {
        "APP_ENV": "test",
        "LOG_FORMAT": "text",
        "TASK_STORE": "postgres",
        "DATABASE_URL": "postgresql://u:p@127.0.0.1:1/none",
    }.items():
        monkeypatch.setenv(k, v)
    c = create_app(load_settings(dotenv_path=tmp_path / ".env")).test_client()
    assert c.get("/health").status_code == 200
    assert c.get("/health/ready").status_code == 503
    assert c.get("/api/tasks").status_code == 503
