# -*- coding: utf-8 -*-
"""P1 验收脚本：模拟客户端跑通全链路（13 项验收）。

用法（服务启动后）：
    python scripts/acceptance.py --base-url http://localhost:8000
    python scripts/acceptance.py --base-url https://你的域名.example.com

全部通过退出码 0，任一失败退出码 1。
"""

from __future__ import annotations

import argparse
import sys
import time
import uuid

import httpx

PASS, FAIL = "通过", "失败"
results: list[tuple[str, str, str]] = []


def record(name: str, ok: bool, note: str = "") -> bool:
    results.append((name, PASS if ok else FAIL, note))
    print(f"[{PASS if ok else FAIL}] {name}" + (f" — {note}" if note else ""))
    return ok


def push_results(r: httpx.Response) -> list[dict]:
    """安全取 push 响应的 results 列表（异常响应不致脚本崩溃）。"""
    try:
        data = r.json()
    except Exception:  # noqa: BLE001
        return []
    return data.get("results") or [] if isinstance(data, dict) else []


def main() -> int:
    parser = argparse.ArgumentParser(description="问道后端 P1 验收")
    parser.add_argument("--base-url", default="http://localhost:8000")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    client = httpx.Client(base_url=base, timeout=15.0)

    # 1. 健康检查
    try:
        r = client.get("/health")
        record("1. 健康检查 /health", r.status_code == 200 and r.json().get("db") == "ok", r.text[:80])
    except Exception as e:  # noqa: BLE001
        record("1. 健康检查 /health", False, f"连接失败: {e}")
        print("\n服务不可达，后续验收终止。")
        return 1

    # 2. 注册 / 登录 / me
    email = f"acceptance_{uuid.uuid4().hex[:8]}@example.com"
    r = client.post("/auth/register", json={"email": email, "password": "secret123", "display_name": "验收"})
    ok = r.status_code == 201 and r.json().get("access_token")
    record("2. 注册并获取 token", ok, f"status={r.status_code}")
    if not ok:
        print("\n注册失败，后续验收终止。")
        return 1
    token_a = r.json()["access_token"]
    auth_a = {"Authorization": f"Bearer {token_a}"}

    r = client.post("/auth/login", json={"email": email, "password": "secret123"})
    record("3. 登录", r.status_code == 200, f"status={r.status_code}")
    r = client.get("/auth/me", headers=auth_a)
    record("4. 鉴权访问 /auth/me", r.status_code == 200 and r.json().get("email") == email)

    # 5. push → pull 闭环
    change = {
        "table": "workouts",
        "id": "acc-w1",
        "op": "upsert",
        "base_version": 0,
        "updated_at": "2026-10-06T08:00:00Z",
        "data": {"date": "2026-10-06", "type": "力量", "duration": 45, "intensity": 3, "exercises": "卧推"},
    }
    r = client.post("/sync/push", json={"device_id": "acc-dev", "platform": "test", "changes": [change]}, headers=auth_a)
    got = push_results(r)
    ok = r.status_code == 200 and bool(got) and got[0].get("status") == "applied"
    record("5a. push 应用变更", ok, f"status={r.status_code}" + ("" if ok else f" {r.text[:100]}"))

    r = client.post("/sync/pull", json={"device_id": "acc-dev"}, headers=auth_a)
    pulled = [c for c in r.json().get("changes", []) if c["id"] == "acc-w1"]
    record("5b. pull 拉回同一变更", r.status_code == 200 and len(pulled) == 1 and pulled[0]["data"]["type"] == "力量")

    # 6. 幂等：重放同一变更
    r = client.post("/sync/push", json={"device_id": "acc-dev", "changes": [change]}, headers=auth_a)
    got = push_results(r)
    ok = r.status_code == 200 and bool(got) and got[0].get("server_version") == 1
    record("6. 幂等重放（server_version 不变）", ok, str(got[0] if got else r.text[:100]))

    # 7. 冲突：旧 base_version + 更旧逻辑时间 → 服务端胜
    stale = {
        "table": "workouts",
        "id": "acc-w1",
        "op": "upsert",
        "base_version": 0,
        "updated_at": "2026-10-01T00:00:00Z",
        "data": {"date": "2026-10-01", "type": "有氧", "duration": 20, "intensity": 1, "exercises": "跑步"},
    }
    r = client.post("/sync/push", json={"device_id": "acc-dev", "changes": [stale]}, headers=auth_a)
    got = push_results(r)
    res = got[0] if got else {}
    ok = res.get("status") == "conflict" and res.get("server_record") is not None
    record("7. 冲突检测（返回服务端快照）", ok, f"status={res.get('status', r.text[:100])}")

    # 8. 多用户隔离
    email_b = f"acceptance_b_{uuid.uuid4().hex[:8]}@example.com"
    r = client.post("/auth/register", json={"email": email_b, "password": "secret123"})
    auth_b = {"Authorization": f"Bearer {r.json()['access_token']}"}
    r = client.post("/sync/pull", json={"device_id": "acc-dev"}, headers=auth_b)
    ok = r.status_code == 200 and all(c["id"] != "acc-w1" for c in r.json().get("changes", []))
    record("8a. 多用户隔离（B 拉不到 A 的数据）", ok)

    # 9. REST CRUD + 软删除
    r = client.post("/data/finance_records", json={"date": "2026-10-06", "type": "支出", "category": "餐饮", "amount": 30.0, "note": "验收"}, headers=auth_a)
    ok = r.status_code == 201
    record("9a. REST 创建", ok, f"status={r.status_code}")
    if ok:
        row_id = r.json()["id"]
        r = client.delete(f"/data/finance_records/{row_id}", headers=auth_a)
        record("9b. REST 软删除", r.status_code == 200 and r.json().get("deleted") is True)
        r = client.get("/data/finance_records", headers=auth_a)
        record("9c. 删除后列表为空", r.json().get("count") == 0)

    # 10. 公共食物库
    r = client.get("/data/food-catalog")
    record("10. 公共食物库可读", r.status_code == 200, f"count={r.json().get('count')}")

    # 汇总
    failed = [n for n, s, _ in results if s == FAIL]
    print("\n" + "=" * 50)
    print(f"验收结果：{len(results) - len(failed)}/{len(results)} 通过")
    if failed:
        print("失败项：" + "、".join(failed))
        return 1
    print("P1 全部验收通过 ✔")
    return 0


if __name__ == "__main__":
    sys.exit(main())
