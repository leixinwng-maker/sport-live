"""API 冒烟：鉴权、同步 push/pull、REST CRUD、多用户隔离。"""

from __future__ import annotations


async def _register(client, email="a@example.com", password="secret123"):
    resp = await client.post(
        "/auth/register",
        json={"email": email, "password": password, "display_name": "测试"},
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


async def test_register_login_me(client):
    data = await _register(client)
    assert data["access_token"] and data["user_id"]

    resp = await client.post(
        "/auth/login", json={"email": "a@example.com", "password": "secret123"}
    )
    assert resp.status_code == 200
    token = resp.json()["access_token"]

    resp = await client.get("/auth/me", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.json()["email"] == "a@example.com"


async def test_login_wrong_password(client):
    await _register(client)
    resp = await client.post(
        "/auth/login", json={"email": "a@example.com", "password": "wrong-pass"}
    )
    assert resp.status_code == 401


async def test_duplicate_register(client):
    await _register(client)
    resp = await client.post(
        "/auth/register", json={"email": "a@example.com", "password": "secret123"}
    )
    assert resp.status_code == 409


async def test_push_pull_roundtrip(client):
    token = (await _register(client))["access_token"]
    push = {
        "device_id": "dev-1",
        "platform": "android",
        "changes": [
            {
                "table": "workouts",
                "id": "w1",
                "op": "upsert",
                "base_version": 0,
                "updated_at": "2026-10-04T08:00:00Z",
                "data": {
                    "date": "2026-10-04",
                    "type": "力量",
                    "duration": 45,
                    "intensity": "中",
                    "exercises": "卧推",
                },
            }
        ],
    }
    resp = await client.post("/sync/push", json=push, headers=_auth(token))
    assert resp.status_code == 200, resp.text
    results = resp.json()["results"]
    assert results[0]["status"] == "applied"
    assert results[0]["server_version"] == 1

    resp = await client.post(
        "/sync/pull", json={"device_id": "dev-2"}, headers=_auth(token)
    )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["changes"]) == 1
    assert body["changes"][0]["id"] == "w1"
    assert body["changes"][0]["data"]["type"] == "力量"


async def test_push_requires_auth(client):
    resp = await client.post("/sync/push", json={"changes": []})
    assert resp.status_code == 401


async def test_rest_crud_and_isolation(client):
    tok_a = (await _register(client, "a@example.com"))["access_token"]
    tok_b = (await _register(client, "b@example.com"))["access_token"]

    resp = await client.post(
        "/data/finance_records",
        json={"date": "2026-10-04", "type": "支出", "category": "餐饮", "amount": 30.0, "note": "午饭"},
        headers=_auth(tok_a),
    )
    assert resp.status_code == 201, resp.text
    row_id = resp.json()["id"]

    resp = await client.get("/data/finance_records", headers=_auth(tok_a))
    assert resp.status_code == 200
    assert resp.json()["count"] == 1

    # 用户 B 看不到 A 的数据
    resp = await client.get("/data/finance_records", headers=_auth(tok_b))
    assert resp.json()["count"] == 0

    # 用户 B 也不能读/删 A 的单条
    resp = await client.get(f"/data/finance_records/{row_id}", headers=_auth(tok_b))
    assert resp.status_code == 404
    resp = await client.delete(f"/data/finance_records/{row_id}", headers=_auth(tok_b))
    assert resp.status_code == 404

    # 软删除
    resp = await client.delete(f"/data/finance_records/{row_id}", headers=_auth(tok_a))
    assert resp.status_code == 200
    resp = await client.get("/data/finance_records", headers=_auth(tok_a))
    assert resp.json()["count"] == 0


async def test_food_catalog_public(client):
    resp = await client.get("/data/food-catalog")
    assert resp.status_code == 200
    assert resp.json()["count"] >= 0  # 未 seed 时为 0，seed 后为 63


async def test_health(client):
    resp = await client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
