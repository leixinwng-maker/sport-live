"""同步引擎：变更合并、冲突处理（最后写入胜出 + 版本号）、幂等去重、增量拉取。

协议要点（与设计文档第 7 节一致）：
- 幂等：以 (user_id, table, row_id, base_version) 记账，同一变更重复 push 不再应用。
- 冲突：base_version 与服务端 version 不一致时，比较客户端逻辑时间
  （client_updated_at），新者胜出；服务端胜出返回 status=conflict + server_record，
  客户端胜出返回 status=applied + conflict=true + 被覆盖的 server_record。
- 软删除：delete 不物理删行，置 deleted_at 并 version+1，pull 时以删除事件下发。
- pull 游标：服务端权威时间戳 updated_at（避免客户端时钟漂移），
  以 (updated_at, id) 复合游标翻页。
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional, Sequence

from sqlalchemy import and_, delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..models import (
    BUSINESS_TABLES,
    SYNCED_TABLES,
    TABLES,
    TableSpec,
    payload_to_row,
    row_to_payload,
    sync_applied,
    utcnow,
    validate_payload,
)
from .errors import AppError


def as_utc(dt: Optional[datetime]) -> Optional[datetime]:
    """统一为 UTC aware datetime（SQLite 读出的是 naive，按 UTC 解释）。"""
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def parse_ts(value: Any) -> Optional[datetime]:
    """ISO8601 字符串 → aware datetime。兼容 'Z' 后缀（Python 3.10 不认）。"""
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return as_utc(value)
    text = str(value).strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        return as_utc(datetime.fromisoformat(text))
    except ValueError:
        raise AppError("invalid_payload", f"非法时间格式: {value!r}")


@dataclass
class ChangeItem:
    table: str
    id: str
    op: str  # upsert | delete
    base_version: int = 0
    updated_at: Optional[datetime] = None  # 客户端逻辑时间（LWW 比较依据）
    data: Optional[dict[str, Any]] = None


@dataclass
class ChangeResult:
    table: str
    id: str
    status: str  # applied | conflict
    server_version: int
    conflict: bool = False
    server_record: Optional[dict[str, Any]] = None
    detail: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "table": self.table,
            "id": self.id,
            "status": self.status,
            "server_version": self.server_version,
            "conflict": self.conflict,
            "server_record": self.server_record,
            "detail": self.detail,
        }


# ------------------------------------------------------------ 批次校验


def _validate_batch(items: Sequence[ChangeItem], batch_limit: int) -> None:
    if len(items) > batch_limit:
        raise AppError(
            "batch_too_large",
            f"单次批量上限 {batch_limit} 条，请分批提交",
            status_code=413,
        )
    for item in items:
        spec = BUSINESS_TABLES.get(item.table)
        if spec is None or not spec.user_scoped or not spec.writable:
            raise AppError("invalid_table", f"不可同步的表: {item.table}")
        if not item.id or len(item.id) > 64:
            raise AppError("invalid_payload", f"非法 id: {item.id!r}")
        if item.op not in ("upsert", "delete"):
            raise AppError("invalid_payload", f"非法 op: {item.op!r}")
        if item.op == "upsert":
            data = item.data or {}
            errors = validate_payload(spec, data)
            if errors:
                raise AppError("invalid_payload", "字段校验失败", detail=errors)


# ------------------------------------------------------------ 变更合并


def _item_key(item: ChangeItem) -> str:
    """变更的幂等键组成部分：客户端逻辑时间（区分同 base_version 的不同变更）。"""
    return item.updated_at.isoformat() if item.updated_at else ""


async def _ledger_get(
    session: AsyncSession,
    user_id: str,
    table: str,
    row_id: str,
    base_version: int,
    client_ts: str,
) -> Optional[dict[str, Any]]:
    stmt = select(sync_applied).where(
        sync_applied.c.user_id == user_id,
        sync_applied.c.table_name == table,
        sync_applied.c.row_id == row_id,
        sync_applied.c.base_version == base_version,
        sync_applied.c.client_ts == client_ts,
    )
    row = (await session.execute(stmt)).mappings().first()
    return dict(row) if row else None


async def _ledger_put(
    session: AsyncSession,
    user_id: str,
    table: str,
    row_id: str,
    base_version: int,
    client_ts: str,
    status: str,
    server_version: int,
) -> None:
    await session.execute(
        sync_applied.insert().values(
            user_id=user_id,
            table_name=table,
            row_id=row_id,
            base_version=base_version,
            client_ts=client_ts,
            status=status,
            server_version=server_version,
            applied_at=utcnow(),
        )
    )


async def _load_row(
    session: AsyncSession, spec: TableSpec, user_id: str, row_id: str
) -> Optional[dict[str, Any]]:
    table = TABLES[spec.name]
    stmt = select(table).where(table.c.id == row_id)
    if spec.user_scoped:
        stmt = stmt.where(table.c.user_id == user_id)
    return (await session.execute(stmt)).mappings().first()


def _lww_client_wins(item: ChangeItem, row: dict[str, Any]) -> bool:
    client_time = as_utc(item.updated_at) or utcnow()
    server_time = as_utc(row.get("client_updated_at")) or as_utc(row.get("updated_at"))
    if server_time is None:
        return True
    return client_time > server_time


async def _apply_upsert(
    session: AsyncSession,
    spec: TableSpec,
    user_id: str,
    item: ChangeItem,
    row: Optional[dict[str, Any]],
) -> ChangeResult:
    table = TABLES[spec.name]
    now = utcnow()
    client_time = as_utc(item.updated_at) or now
    values = payload_to_row(spec, item.data or {})

    if row is None:
        await session.execute(
            table.insert().values(
                id=item.id,
                user_id=user_id,
                **values,
                updated_at=now,
                client_updated_at=client_time,
                deleted_at=None,
                version=1,
            )
        )
        return ChangeResult(spec.name, item.id, "applied", 1)

    current_version = row["version"]
    clean = item.base_version == current_version and item.base_version > 0

    if clean:
        await session.execute(
            table.update()
            .where(table.c.id == item.id)
            .values(
                **values,
                updated_at=now,
                client_updated_at=client_time,
                deleted_at=None,
                version=current_version + 1,
            )
        )
        return ChangeResult(spec.name, item.id, "applied", current_version + 1)

    # 版本冲突 → 最后写入胜出
    snapshot = row_to_payload(spec, row)
    if _lww_client_wins(item, row):
        await session.execute(
            table.update()
            .where(table.c.id == item.id)
            .values(
                **values,
                updated_at=now,
                client_updated_at=client_time,
                deleted_at=None,
                version=current_version + 1,
            )
        )
        return ChangeResult(
            spec.name,
            item.id,
            "applied",
            current_version + 1,
            conflict=True,
            server_record=snapshot,
            detail="conflict resolved by last-write-wins（客户端胜出）",
        )
    return ChangeResult(
        spec.name,
        item.id,
        "conflict",
        current_version,
        conflict=True,
        server_record=snapshot,
        detail="conflict resolved by last-write-wins（服务端胜出）",
    )


async def _apply_delete(
    session: AsyncSession,
    spec: TableSpec,
    user_id: str,
    item: ChangeItem,
    row: Optional[dict[str, Any]],
) -> ChangeResult:
    table = TABLES[spec.name]
    now = utcnow()
    client_time = as_utc(item.updated_at) or now

    if row is None:
        return ChangeResult(
            spec.name, item.id, "applied", 0, detail="记录不存在，删除视为完成"
        )
    if row["deleted_at"] is not None:
        return ChangeResult(spec.name, item.id, "applied", row["version"])

    current_version = row["version"]
    clean = item.base_version == current_version and item.base_version > 0

    if clean or _lww_client_wins(item, row):
        await session.execute(
            table.update()
            .where(table.c.id == item.id)
            .values(
                deleted_at=now,
                updated_at=now,
                client_updated_at=client_time,
                version=current_version + 1,
            )
        )
        return ChangeResult(
            spec.name,
            item.id,
            "applied",
            current_version + 1,
            conflict=not clean,
            server_record=None if clean else row_to_payload(spec, row),
        )
    return ChangeResult(
        spec.name,
        item.id,
        "conflict",
        current_version,
        conflict=True,
        server_record=row_to_payload(spec, row),
        detail="conflict resolved by last-write-wins（服务端胜出）",
    )


async def merge_changes(
    session: AsyncSession,
    user_id: str,
    items: Sequence[ChangeItem],
    *,
    batch_limit: int = 500,
) -> list[ChangeResult]:
    """合并一批客户端变更（调用方负责 commit）。"""
    _validate_batch(items, batch_limit)

    results: list[ChangeResult] = []
    for item in items:
        spec = BUSINESS_TABLES[item.table]

        # 幂等：同一 (table, id, base_version, client_ts) 只应用一次
        applied = await _ledger_get(
            session, user_id, item.table, item.id, item.base_version, _item_key(item)
        )
        if applied is not None:
            result = ChangeResult(
                item.table,
                item.id,
                applied["status"],
                applied["server_version"],
                conflict=applied["status"] == "conflict",
                detail="idempotent replay",
            )
            if applied["status"] == "conflict":
                row = await _load_row(session, spec, user_id, item.id)
                result.server_record = row_to_payload(spec, row) if row else None
            results.append(result)
            continue

        row = await _load_row(session, spec, user_id, item.id)
        if item.op == "upsert":
            result = await _apply_upsert(session, spec, user_id, item, row)
        else:
            result = await _apply_delete(session, spec, user_id, item, row)

        await _ledger_put(
            session,
            user_id,
            item.table,
            item.id,
            item.base_version,
            _item_key(item),
            result.status,
            result.server_version,
        )
        results.append(result)
    return results


# ------------------------------------------------------------ 增量拉取


@dataclass
class PullItem:
    table: str
    id: str
    op: str  # upsert | delete
    version: int
    updated_at: datetime
    client_updated_at: Optional[datetime]
    data: Optional[dict[str, Any]]

    def to_dict(self) -> dict[str, Any]:
        return {
            "table": self.table,
            "id": self.id,
            "op": self.op,
            "version": self.version,
            "updated_at": self.updated_at.isoformat(),
            "client_updated_at": (
                self.client_updated_at.isoformat() if self.client_updated_at else None
            ),
            "data": self.data,
        }


@dataclass
class PullPage:
    changes: list[PullItem] = field(default_factory=list)
    has_more: bool = False
    next_since: Optional[datetime] = None
    next_cursor_id: Optional[str] = None


async def pull_changes(
    session: AsyncSession,
    user_id: str,
    *,
    since: Optional[datetime] = None,
    cursor_id: Optional[str] = None,
    tables: Optional[Sequence[str]] = None,
    limit: int = 500,
) -> PullPage:
    """按 (updated_at, id) 复合游标增量拉取（含软删除事件）。"""
    names = list(tables) if tables else list(SYNCED_TABLES)
    for name in names:
        if name not in SYNCED_TABLES:
            raise AppError("invalid_table", f"不可同步的表: {name}")

    collected: list[tuple[datetime, str, str, dict[str, Any]]] = []
    for name in names:
        table = TABLES[name]
        conds = [table.c.user_id == user_id]
        if since is not None:
            if cursor_id:
                conds.append(
                    or_(
                        table.c.updated_at > since,
                        and_(table.c.updated_at == since, table.c.id > cursor_id),
                    )
                )
            else:
                conds.append(table.c.updated_at > since)
        stmt = (
            select(table)
            .where(*conds)
            .order_by(table.c.updated_at.asc(), table.c.id.asc())
            .limit(limit + 1)
        )
        rows = (await session.execute(stmt)).mappings().all()
        for row in rows:
            collected.append(
                (as_utc(row["updated_at"]), row["id"], name, dict(row))
            )

    collected.sort(key=lambda x: (x[0], x[1]))
    has_more = len(collected) > limit
    page_rows = collected[:limit]

    changes: list[PullItem] = []
    for updated_at, row_id, name, row in page_rows:
        spec = BUSINESS_TABLES[name]
        deleted = row["deleted_at"] is not None
        changes.append(
            PullItem(
                table=name,
                id=row_id,
                op="delete" if deleted else "upsert",
                version=row["version"],
                updated_at=updated_at,
                client_updated_at=as_utc(row.get("client_updated_at")),
                data=None if deleted else row_to_payload(spec, row),
            )
        )

    return PullPage(
        changes=changes,
        has_more=has_more,
        next_since=page_rows[-1][0] if page_rows else since,
        next_cursor_id=page_rows[-1][1] if page_rows else cursor_id,
    )


# -------------------------------------------------------------- 设备登记


async def touch_device(
    session: AsyncSession,
    user_id: str,
    device_id: str,
    platform: str = "",
    *,
    push: bool = False,
    pull: bool = False,
) -> None:
    if not device_id:
        return
    from ..models import devices

    stmt = select(devices).where(
        devices.c.user_id == user_id, devices.c.device_id == device_id
    )
    row = (await session.execute(stmt)).mappings().first()
    now = utcnow()
    if row is None:
        await session.execute(
            devices.insert().values(
                user_id=user_id,
                device_id=device_id,
                platform=platform or "",
                last_push_at=now if push else None,
                last_pull_at=now if pull else None,
                created_at=now,
            )
        )
        return
    updates: dict[str, Any] = {}
    if push:
        updates["last_push_at"] = now
    if pull:
        updates["last_pull_at"] = now
    if platform and platform != row["platform"]:
        updates["platform"] = platform
    if updates:
        await session.execute(
            devices.update()
            .where(devices.c.user_id == user_id, devices.c.device_id == device_id)
            .values(**updates)
        )


__all__ = [
    "ChangeItem",
    "ChangeResult",
    "PullItem",
    "PullPage",
    "as_utc",
    "merge_changes",
    "pull_changes",
    "touch_device",
]
