"""账号注销：级联删除、密码二次校验、多用户隔离。

对应《个人信息保护法》第 47 条删除权的服务端落地：
业务表 → 同步幂等账本 → 设备 → AI 配置密文 → 账号本身。
"""
from __future__ import annotations

from tests.test_api import _auth, _register


def _workout_push(device_id: str = "dev-1") -> dict:
    return {
        "device_id": device_id,
        "platform": "android",
        "changes": [
            {
                "table": "workouts",
                "id": "w1",
                "op": "upsert",
                "base_version": 0,
                "updated_at": "2026-10-18T08:00:00Z",
                "data": {
                    "date": "2026-10-18",
                    "type": "力量",
                    "duration": 45,
                    "intensity": 3,
                    "exercises": "卧推",
                },
            }
        ],
    }


async def _pull(client, token: str) -> list:
    resp = await client.post(
        "/sync/pull", json={"device_id": "dev-9"}, headers=_auth(token)
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["changes"]


async def test_delete_account_removes_all_user_data(client):
    token = (await _register(client))["access_token"]
    resp = await client.post("/sync/push", json=_workout_push(), headers=_auth(token))
    assert resp.status_code == 200
    assert len(await _pull(client, token)) == 1

    # AI 配置也写一份，确认级联覆盖到 ai_settings
    resp = await client.put(
        "/ai-settings",
        json={"models": [{"id": "m1", "name": "test", "baseUrl": "https://x", "model": "m"}]},
        headers=_auth(token),
    )
    assert resp.status_code == 200, resp.text

    resp = await client.request(
        "DELETE",
        "/auth/account",
        json={"password": "secret123"},
        headers=_auth(token),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"deleted": True}

    # 账号本身已删除：/auth/me 与登录都失败
    assert (await client.get("/auth/me", headers=_auth(token))).status_code == 401
    assert (
        await client.post(
            "/auth/login", json={"email": "a@example.com", "password": "secret123"}
        )
    ).status_code == 401

    # 旧 token 仍可通过签名校验（最长 60 分钟），但读不到任何数据
    assert await _pull(client, token) == []
    resp = await client.get("/ai-settings", headers=_auth(token))
    assert resp.status_code == 200
    assert resp.json()["models"] == []


async def test_delete_account_wrong_password_keeps_data(client):
    token = (await _register(client))["access_token"]
    await client.post("/sync/push", json=_workout_push(), headers=_auth(token))

    resp = await client.request(
        "DELETE",
        "/auth/account",
        json={"password": "wrong-pass"},
        headers=_auth(token),
    )
    assert resp.status_code == 401
    assert len(await _pull(client, token)) == 1


async def test_delete_account_does_not_touch_other_users(client):
    token_a = (await _register(client, email="a@example.com"))["access_token"]
    token_b = (await _register(client, email="b@example.com"))["access_token"]
    await client.post("/sync/push", json=_workout_push(), headers=_auth(token_a))
    await client.post("/sync/push", json=_workout_push(), headers=_auth(token_b))

    resp = await client.request(
        "DELETE",
        "/auth/account",
        json={"password": "secret123"},
        headers=_auth(token_a),
    )
    assert resp.status_code == 200

    assert await _pull(client, token_a) == []
    assert len(await _pull(client, token_b)) == 1
    assert (await client.get("/auth/me", headers=_auth(token_b))).status_code == 200
