"""通用业务数据 REST 路由：/data/{table} 增删改查（多用户隔离 + 软删除）。

与 /sync 是同一数据的两个访问通道：REST 供管理/调试/未来 Web 端使用，
push/pull 供 App 离线优先同步。写操作语义与同步引擎一致（LWW、软删除）。
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, SessionDep
from app.core.errors import AppError
from app.models.tables import (
    BUSINESS_TABLES,
    TABLES,
    payload_to_row,
    row_to_payload,
    utcnow,
    validate_payload,
)

router = APIRouter(prefix="/data", tags=["data"])


@router.get("/food-catalog")
async def list_food_catalog(
    session: SessionDep,
    limit: int = Query(default=500, ge=1, le=2000),
    offset: int = Query(default=0, ge=0),
    category: str | None = None,
) -> dict:
    """公共只读食物库（无需鉴权，不分用户）。"""
    spec = BUSINESS_TABLES["food_catalog"]
    tbl = TABLES["food_catalog"]
    stmt = select(tbl).offset(offset).limit(limit)
    if category:
        stmt = stmt.where(tbl.c.category == category)
    rows = (await session.execute(stmt)).mappings().all()
    return {
        "items": [{"id": r["id"], **row_to_payload(spec, r)} for r in rows],
        "count": len(rows),
    }


def _spec_or_404(table: str):
    spec = BUSINESS_TABLES.get(table)
    if spec is None or not spec.user_scoped:
        raise AppError.not_found(f"未知的数据表: {table}")
    return spec


def _row_or_404(row, table: str, row_id: str):
    if row is None:
        raise AppError.not_found(f"{table}/{row_id} 不存在")
    return row


@router.get("/{table}")
async def list_rows(
    table: str,
    user_id: CurrentUser,
    session: SessionDep,
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
    include_deleted: bool = False,
) -> dict:
    spec = _spec_or_404(table)
    tbl = TABLES[table]
    stmt = select(tbl).where(tbl.c.user_id == user_id).offset(offset).limit(limit)
    if not include_deleted:
        stmt = stmt.where(tbl.c.deleted_at.is_(None))
    rows = (await session.execute(stmt)).mappings().all()
    return {
        "items": [
            {
                "id": r["id"],
                "data": row_to_payload(spec, r),
                "version": r["version"],
                "updated_at": r["updated_at"],
            }
            for r in rows
        ],
        "count": len(rows),
    }


@router.get("/{table}/{row_id}")
async def get_row(table: str, row_id: str, user_id: CurrentUser, session: SessionDep) -> dict:
    spec = _spec_or_404(table)
    tbl = TABLES[table]
    row = (
        await session.execute(
            select(tbl).where(tbl.c.id == row_id, tbl.c.user_id == user_id)
        )
    ).mappings().first()
    _row_or_404(row, table, row_id)
    return {
        "id": row["id"],
        "data": row_to_payload(spec, row),
        "version": row["version"],
        "updated_at": row["updated_at"],
        "deleted_at": row["deleted_at"],
    }


@router.post("/{table}", status_code=201)
async def create_row(
    table: str, body: dict, user_id: CurrentUser, session: SessionDep
) -> dict:
    spec = _spec_or_404(table)
    errors = validate_payload(spec, body, partial=True)
    if errors:
        raise AppError(code="invalid_payload", message="数据校验失败", status_code=422, detail=errors)
    tbl = TABLES[table]
    row_id = str(body.get("id") or uuid.uuid4().hex)
    now = utcnow()
    values = payload_to_row(spec, {k: v for k, v in body.items() if k != "id"})
    await session.execute(
        tbl.insert().values(
            id=row_id,
            user_id=user_id,
            **values,
            updated_at=now,
            client_updated_at=now,
            version=1,
        )
    )
    await session.commit()
    return {"id": row_id, "version": 1, "updated_at": now.isoformat()}


@router.put("/{table}/{row_id}")
async def update_row(
    table: str, row_id: str, body: dict, user_id: CurrentUser, session: SessionDep
) -> dict:
    spec = _spec_or_404(table)
    tbl = TABLES[table]
    row = (
        await session.execute(
            select(tbl).where(tbl.c.id == row_id, tbl.c.user_id == user_id)
        )
    ).mappings().first()
    _row_or_404(row, table, row_id)
    errors = validate_payload(spec, body, partial=True)
    if errors:
        raise AppError(code="invalid_payload", message="数据校验失败", status_code=422, detail=errors)
    now = utcnow()
    values = payload_to_row(spec, {k: v for k, v in body.items() if k != "id"})
    await session.execute(
        tbl.update()
        .where(tbl.c.id == row_id, tbl.c.user_id == user_id)
        .values(**values, updated_at=now, client_updated_at=now, version=row["version"] + 1)
    )
    await session.commit()
    return {"id": row_id, "version": row["version"] + 1, "updated_at": now.isoformat()}


@router.delete("/{table}/{row_id}")
async def delete_row(
    table: str, row_id: str, user_id: CurrentUser, session: SessionDep
) -> dict:
    _spec_or_404(table)
    tbl = TABLES[table]
    row = (
        await session.execute(
            select(tbl).where(tbl.c.id == row_id, tbl.c.user_id == user_id)
        )
    ).mappings().first()
    _row_or_404(row, table, row_id)
    now = utcnow()
    await session.execute(
        tbl.update()
        .where(tbl.c.id == row_id, tbl.c.user_id == user_id)
        .values(deleted_at=now, updated_at=now, version=row["version"] + 1)
    )
    await session.commit()
    return {"id": row_id, "deleted": True, "version": row["version"] + 1}
