def test_liveness(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_readiness_memory_store(client):
    r = client.get("/health/ready")
    assert r.status_code == 200
    assert r.get_json()["database"]["ok"] is True


def test_info_has_no_secrets(client):
    r = client.get("/api/info")
    body = r.get_json()
    assert r.status_code == 200
    assert body["app"] == "cloudops-notes"
    assert body["app_env"] == "test"
    # Make sure we never leak connection details.
    assert "database_url" not in body
    assert "secret_key" not in body


def test_request_id_and_security_headers(client):
    r = client.get("/api/info", headers={"X-Request-ID": "abc123"})
    assert r.headers["X-Request-ID"] == "abc123"
    assert r.headers["X-Content-Type-Options"] == "nosniff"


def test_index_page(client):
    r = client.get("/")
    assert r.status_code == 200
    assert b"CloudOps Notes" in r.data
