def test_health_and_ready(client):
    assert client.get("/health").get_json()["status"] == "ok"
    r = client.get("/health/ready")
    assert r.status_code == 200 and r.get_json()["database"]["ok"] is True


def test_crud_flow(client):
    r = client.post("/api/tasks", json={"title": "Ship capstone", "priority": 1})
    assert r.status_code == 201
    t = r.get_json()
    assert t["status"] == "todo" and t["priority"] == 1

    r = client.patch(f"/api/tasks/{t['id']}", json={"status": "doing"})
    assert r.status_code == 200 and r.get_json()["status"] == "doing"

    assert client.get("/api/tasks?status=doing").get_json()["tasks"][0]["id"] == t["id"]
    assert client.get("/api/tasks?status=done").get_json()["tasks"] == []
    assert client.get("/api/stats").get_json()["tasks"] == {"todo": 0, "doing": 1, "done": 0}

    assert client.delete(f"/api/tasks/{t['id']}").status_code == 204
    assert client.get(f"/api/tasks/{t['id']}").status_code == 404
    assert client.patch(f"/api/tasks/{t['id']}", json={"status": "done"}).status_code == 404


def test_validation(client):
    bad = [
        {"title": ""},
        {"title": "x" * 141},
        {"title": "ok", "priority": 9},
        {"title": "ok", "priority": "high"},
        ["list"],
    ]
    for payload in bad:
        assert client.post("/api/tasks", json=payload).status_code == 400, payload
    tid = client.post("/api/tasks", json={"title": "t"}).get_json()["id"]
    assert client.patch(f"/api/tasks/{tid}", json={"status": "later"}).status_code == 400
    assert client.patch(f"/api/tasks/{tid}", json={}).status_code == 400
    assert client.get("/api/tasks?status=nope").status_code == 400
    assert client.get("/api/missing").status_code == 404
    assert client.put("/api/tasks").status_code == 405


def test_ordering(client):
    client.post("/api/tasks", json={"title": "low", "priority": 3})
    client.post("/api/tasks", json={"title": "high", "priority": 1})
    done = client.post("/api/tasks", json={"title": "finished"}).get_json()["id"]
    client.patch(f"/api/tasks/{done}", json={"status": "done"})
    titles = [t["title"] for t in client.get("/api/tasks").get_json()["tasks"]]
    assert titles == ["high", "low", "finished"]


def test_metrics_and_info(client):
    client.get("/api/tasks")
    client.get("/api/nope")
    body = client.get("/metrics").data.decode()
    assert 'cloudops_http_requests_total{method="GET",route="/api/tasks",status="200"} 1' in body
    assert 'route="unmatched",status="404"' in body
    assert "cloudops_http_request_duration_ms_bucket" in body
    info = client.get("/api/info").get_json()
    assert info["app"] == "cloudops-api" and info["metrics"]["requests"] >= 2
    assert "secret_key" not in info and "database_url" not in info


def test_request_id_header(client):
    r = client.get("/api/info", headers={"X-Request-ID": "trace-1"})
    assert r.headers["X-Request-ID"] == "trace-1"
    assert r.headers["X-Content-Type-Options"] == "nosniff"
