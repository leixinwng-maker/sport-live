"""AI 配置云端备份：加密落库、拉取回读、多用户隔离、越权与脏数据防御。"""
from __future__ import annotations

import pytest

from app.core.crypto import decrypt_settings, encrypt_settings
from tests.test_api import _auth, _register


async def test_encrypt_decrypt_roundtrip():
    ct = encrypt_settings('{"models":[]}', user_id="u1")
    assert ct.startswith("v1:")
    assert decrypt_settings(ct, user_id="u1") == '{"models":[]}'


async def test_decrypt_wrong_user_returns_none():
    ct = encrypt_settings('{"models":[]}', user_id="u1")
    assert decrypt_settings(ct, user_id="u2") is None


async def test_decrypt_tampered_returns_none():
    ct = encrypt_settings('{"models":[]}', user_id="u1")
    tampered = ct[:-4] + "AAAA"
    assert decrypt_settings(tampered, user_id="u1") is None


async def test_decrypt_garbage_returns_none():
    assert decrypt_settings("", user_id="u1") is None
    assert decrypt_settings("not-a-cipher", user_id="u1") is None


async def test_get_empty_when_never_backed_up(client):
    token = (await _register(client))["access_token"]
    resp = await client.get("/ai-settings", headers=_auth(token))
    assert resp.status_code == 200
    body = resp.json()
    assert body["models"] == []
    assert body["updatedAt"] is None


async def test_put_then_get_roundtrip(client):
    token = (await _register(client))["access_token"]
    payload = {
        "models": [
            {
                "id": "m1",
                "name": "通义千问",
                "baseUrl": "https://example.com",
                "model": "qwen-plus",
                "apiKey": "sk-secret-001",
                "supportsTools": True,
                "enabled": True,
            }
        ],
        "activeId": "m1",
        "vision": {
            "baseUrl": "https://vision.example.com",
            "model": "vl-7b",
            "apiKey": "sk-vision-001",
        },
    }
    resp = await client.put("/ai-settings", json=payload, headers=_auth(token))
    assert resp.status_code == 200
    assert resp.json()["count"] == 1

    got = await client.get("/ai-settings", headers=_auth(token))
    assert got.status_code == 200
    body = got.json()
    assert body["models"][0]["apiKey"] == "sk-secret-001"
    assert body["models"][0]["supportsTools"] is True
    assert body["activeId"] == "m1"
    assert body["vision"]["apiKey"] == "sk-vision-001"
    assert body["updatedAt"]


async def test_put_overwrites(client):
    token = (await _register(client))["access_token"]
    await client.put(
        "/ai-settings",
        json={"models": [{"id": "a", "apiKey": "k1"}], "activeId": "a"},
        headers=_auth(token),
    )
    await client.put(
        "/ai-settings",
        json={"models": [{"id": "b", "apiKey": "k2"}], "activeId": "b"},
        headers=_auth(token),
    )
    body = (await client.get("/ai-settings", headers=_auth(token))).json()
    assert len(body["models"]) == 1
    assert body["models"][0]["apiKey"] == "k2"


async def test_multi_user_isolation(client):
    t1 = (await _register(client, "u1@example.com"))["access_token"]
    t2 = (await _register(client, "u2@example.com"))["access_token"]
    await client.put(
        "/ai-settings",
        json={"models": [{"id": "a", "apiKey": "user1-key"}], "activeId": "a"},
        headers=_auth(t1),
    )
    b1 = (await client.get("/ai-settings", headers=_auth(t1))).json()
    b2 = (await client.get("/ai-settings", headers=_auth(t2))).json()
    assert b1["models"][0]["apiKey"] == "user1-key"
    assert b2["models"] == []


async def test_requires_auth(client):
    assert (await client.get("/ai-settings")).status_code == 401
    assert (await client.put("/ai-settings", json={"models": []})).status_code == 401


async def test_rejects_bad_models(client):
    token = (await _register(client))["access_token"]
    resp = await client.put(
        "/ai-settings", json={"models": "not-a-list"}, headers=_auth(token)
    )
    assert resp.status_code == 422
    resp = await client.put(
        "/ai-settings", json={"models": ["oops"]}, headers=_auth(token)
    )
    assert resp.status_code == 422


async def test_delete_clears_backup(client):
    token = (await _register(client))["access_token"]
    await client.put(
        "/ai-settings", json={"models": [{"id": "a"}], "activeId": "a"}, headers=_auth(token)
    )
    resp = await client.delete("/ai-settings", headers=_auth(token))
    assert resp.status_code == 200
    body = (await client.get("/ai-settings", headers=_auth(token))).json()
    assert body["models"] == []


@pytest.mark.parametrize("size", [1])
async def test_payload_size_limit(client, size):
    token = (await _register(client))["access_token"]
    huge = {"models": [{"id": f"m{i}", "apiKey": "k" * 4096} for i in range(200)]}
    resp = await client.put("/ai-settings", json=huge, headers=_auth(token))
    assert resp.status_code == 413
