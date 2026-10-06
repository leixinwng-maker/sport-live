"""同步引擎单测：无冲突、冲突（双方向）、幂等、软删除、批量超限。"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.core.errors import AppError
from app.core.sync_engine import ChangeItem, merge_changes, pull_changes

USER = "u1"
NOW = datetime(2026, 10, 4, 8, 0, 0, tzinfo=timezone.utc)


def _item(row_id="r1", op="upsert", base=0, minutes=0, data=None, table="workouts"):
    return ChangeItem(
        table=table,
        id=row_id,
        op=op,
        base_version=base,
        updated_at=NOW + timedelta(minutes=minutes),
        data=data
        or {
            "date": "2026-10-04",
            "type": "力量",
            "duration": 45,
            "intensity": "中",
            "exercises": "卧推",
        },
    )


async def test_upsert_without_conflict(session):
    results = await merge_changes(session, USER, [_item()])
    await session.commit()
    assert results[0].status == "applied"
    assert results[0].conflict is False
    assert results[0].server_version == 1

    # 以正确 base_version 更新：clean apply，不算冲突
    results = await merge_changes(session, USER, [_item(base=1, minutes=5, data={
        "date": "2026-10-04", "type": "有氧", "duration": 30, "intensity": "低", "exercises": "跑步",
    })])
    await session.commit()
    assert results[0].status == "applied"
    assert results[0].conflict is False
    assert results[0].server_version == 2


async def test_conflict_client_wins(session):
    await merge_changes(session, USER, [_item()])
    await session.commit()

    # 客户端 A 把版本推到 2
    await merge_changes(session, USER, [_item(base=1, minutes=5)])
    await session.commit()

    # 客户端 B 持旧 base_version=1，但逻辑时间更新 → 客户端胜
    results = await merge_changes(session, USER, [_item(base=1, minutes=10)])
    await session.commit()
    r = results[0]
    assert r.status == "applied"
    assert r.conflict is True
    assert r.server_version == 3


async def test_conflict_server_wins(session):
    await merge_changes(session, USER, [_item(minutes=50)])  # 服务端较新
    await session.commit()

    # 客户端 base_version 不匹配且逻辑时间更旧 → 服务端胜
    results = await merge_changes(session, USER, [_item(base=0, minutes=0)])
    await session.commit()
    r = results[0]
    assert r.status == "conflict"
    assert r.conflict is True
    assert r.server_version == 1  # 服务端版本不变
    assert r.server_record is not None  # 快照供客户端覆盖本地


async def test_replay_is_idempotent(session):
    first = await merge_changes(session, USER, [_item()])
    await session.commit()
    # 完全相同的变更重放（例如网络超时后重试）
    second = await merge_changes(session, USER, [_item()])
    await session.commit()
    assert second[0].status == first[0].status
    assert second[0].server_version == first[0].server_version == 1


async def test_soft_delete_propagates(session):
    await merge_changes(session, USER, [_item()])
    await session.commit()
    results = await merge_changes(session, USER, [_item(op="delete", base=1, minutes=5)])
    await session.commit()
    assert results[0].status == "applied"
    assert results[0].server_version == 2

    page = await pull_changes(session, USER)
    deletes = [c for c in page.changes if c.op == "delete"]
    assert len(deletes) == 1
    assert deletes[0].id == "r1"
    assert deletes[0].data is None


async def test_pull_incremental_cursor(session):
    await merge_changes(session, USER, [_item(row_id="a", minutes=0)])
    await merge_changes(session, USER, [_item(row_id="b", minutes=1)])
    await session.commit()

    page1 = await pull_changes(session, USER, limit=1)
    assert len(page1.changes) == 1
    assert page1.has_more is True

    page2 = await pull_changes(
        session, USER, since=page1.next_since, cursor_id=page1.next_cursor_id, limit=10
    )
    ids = {c.id for c in page2.changes}
    assert "a" in ids or "b" in ids
    assert len(page1.changes) + len(page2.changes) == 2  # 不重不漏


async def test_batch_too_large(session):
    items = [_item(row_id=f"x{i}") for i in range(501)]
    with pytest.raises(AppError) as exc:
        await merge_changes(session, USER, items)
    assert exc.value.status_code == 413


async def test_invalid_table_rejected(session):
    with pytest.raises(AppError) as exc:
        await merge_changes(session, USER, [_item(table="food_catalog")])
    assert exc.value.code == "invalid_table"
