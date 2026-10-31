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
            "intensity": 3,
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
        "date": "2026-10-04", "type": "有氧", "duration": 30, "intensity": 2, "exercises": "跑步",
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


# ---------------------------------------------- v1.3.2 新增两表的最小覆盖
# adjustment_logs / weekly_summaries 已登记进 BUSINESS_TABLES（默认
# user_scoped 且 writable，自动进入 SYNCED_TABLES），但此前没有用例触及；
# 以下参数化用例以完整 payload 补齐 push/pull 往返验证（建表 schema、
# 必填列、可选列、null 业务列 weekly_quiz、Float 类型收敛随断言一并覆盖）。

_NEW_TABLE_PAYLOADS = {
    # 必填：created_at / field / reason / source；其余为可选列
    "adjustment_logs": {
        "created_at": "2026-10-04T08:00:00Z",
        "field": "calorie_target",
        "old_value": "2000",
        "new_value": "2200",
        "reason": "周复盘建议采纳",
        "observation": "连续两周体重下降偏快",
        "source": "weekly_review",
    },
    # 必填：week_start / week_end / status；weekly_quiz 未答为 null
    "weekly_summaries": {
        "week_start": "2026-09-28",
        "week_end": "2026-10-04",
        "weight_slope": -0.35,
        "weight_delta": -2.45,
        "avg_intake": 2150.0,
        "train_volume": 12400.0,
        "real_tdee": 2680.0,
        "status": "applied",
        "weekly_quiz": None,
    },
}


@pytest.mark.parametrize(
    "table,payload",
    sorted(_NEW_TABLE_PAYLOADS.items()),
    ids=sorted(_NEW_TABLE_PAYLOADS),
)
async def test_new_tables_push_pull_roundtrip(session, table, payload):
    """新表 push 落库后 pull 原样往返，覆盖 schema 与 payload 映射全字段。"""
    results = await merge_changes(session, USER, [_item(table=table, data=payload)])
    await session.commit()
    assert results[0].status == "applied"
    assert results[0].server_version == 1

    page = await pull_changes(session, USER, tables=[table])
    assert [c.id for c in page.changes] == ["r1"]
    assert page.changes[0].data == payload
