"""修改密码：旧密码校验、新旧相同拒绝、新密码约束、改密后重新登录。"""
from __future__ import annotations

from tests.test_api import _auth, _register


async def test_change_password_success_and_relogin(client):
    token = (await _register(client))["access_token"]

    resp = await client.put(
        "/auth/password",
        json={"old_password": "secret123", "new_password": "newpass456"},
        headers=_auth(token),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"changed": True}

    # 旧密码不能再登录，新密码可以登录
    assert (
        await client.post(
            "/auth/login", json={"email": "a@example.com", "password": "secret123"}
        )
    ).status_code == 401
    ok = await client.post(
        "/auth/login", json={"email": "a@example.com", "password": "newpass456"}
    )
    assert ok.status_code == 200, ok.text


async def test_change_password_wrong_old_password(client):
    token = (await _register(client))["access_token"]
    resp = await client.put(
        "/auth/password",
        json={"old_password": "wrong-pass", "new_password": "newpass456"},
        headers=_auth(token),
    )
    assert resp.status_code == 401
    # 密码未变：旧密码仍可登录
    assert (
        await client.post(
            "/auth/login", json={"email": "a@example.com", "password": "secret123"}
        )
    ).status_code == 200


async def test_change_password_rejects_same_short_and_anonymous(client):
    token = (await _register(client))["access_token"]

    # 新旧相同
    resp = await client.put(
        "/auth/password",
        json={"old_password": "secret123", "new_password": "secret123"},
        headers=_auth(token),
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "same_password"

    # 新密码过短：pydantic 约束 422
    resp = await client.put(
        "/auth/password",
        json={"old_password": "secret123", "new_password": "123"},
        headers=_auth(token),
    )
    assert resp.status_code == 422

    # 未携带 token：401
    resp = await client.put(
        "/auth/password",
        json={"old_password": "secret123", "new_password": "newpass456"},
    )
    assert resp.status_code == 401
