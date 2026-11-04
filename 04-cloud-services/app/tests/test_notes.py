def test_create_list_get_delete(client):
    r = client.post("/api/notes", json={"title": "Deploy to EC2", "body": "t3.micro"})
    assert r.status_code == 201
    note = r.get_json()
    assert note["title"] == "Deploy to EC2"

    r = client.get("/api/notes")
    assert r.status_code == 200
    assert [n["id"] for n in r.get_json()["notes"]] == [note["id"]]

    assert client.get(f"/api/notes/{note['id']}").status_code == 200
    assert client.delete(f"/api/notes/{note['id']}").status_code == 204
    assert client.get(f"/api/notes/{note['id']}").status_code == 404
    assert client.delete(f"/api/notes/{note['id']}").status_code == 404


def test_validation(client):
    assert client.post("/api/notes", json={"title": ""}).status_code == 400
    assert client.post("/api/notes", json={"title": "x" * 121}).status_code == 400
    assert client.post("/api/notes", json=["not", "an", "object"]).status_code == 400
    assert client.post("/api/notes", data="not json").status_code == 400
    assert client.get("/api/notes?limit=abc").status_code == 400


def test_newest_first(client):
    for i in range(3):
        client.post("/api/notes", json={"title": f"n{i}"})
    titles = [n["title"] for n in client.get("/api/notes").get_json()["notes"]]
    assert titles == ["n2", "n1", "n0"]


def test_unknown_api_route_is_json(client):
    r = client.get("/api/nope")
    assert r.status_code == 404
    assert r.get_json() == {"error": "not found"}
