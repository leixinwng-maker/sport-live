"""AI 服务配置云端备份：GET / PUT /ai-settings（每用户一行，服务端加密落库）。

客户端在登录后拉取一次、每次修改配置后上传一次。
payload 由服务端 AES-256-GCM 加密后落库，明文只存在于请求内存与客户端本地。
"""
from __future__ import annotations

import json

from fastapi import APIRouter
from sqlalchemy import delete, select

from app.api.deps import CurrentUser, SessionDep
from app.core.crypto import decrypt_settings, encrypt_settings
from app.core.errors import AppError
from app.models.tables import ai_settings, utcnow

router = APIRouter(prefix="/ai-settings", tags=["ai-settings"])

# 单条上限：模型元数据 + 密钥，正常远小于此；防止滥用把数据库当网盘
_MAX_PAYLOAD_BYTES = 256 * 1024

_EMPTY = {"models": [], "activeId": None, "vision": None, "version": 1}


@router.get("")
async def get_ai_settings(user_id: CurrentUser, session: SessionDep) -> dict:
    """拉取云端 AI 配置；未备份过返回空结构（不是 404，客户端据此判定"首次"）。"""
    row = (
        await session.execute(
            select(ai_settings.c.payload, ai_settings.c.updated_at).where(
                ai_settings.c.user_id == user_id
            )
        )
    ).mappings().first()
    if row is None:
        return {**_EMPTY, "updatedAt": None}
    try:
        data = json.loads(decrypt_settings(row["payload"], user_id=user_id) or "null")
    except json.JSONDecodeError:
        data = None
    if not isinstance(data, dict):
        # 密文损坏或被换了密钥：不要让客户端拿到半个坏配置，直接当空处理
        return {**_EMPTY, "updatedAt": None}
    updated_at = row["updated_at"]
    return {
        "models": data.get("models") or [],
        "activeId": data.get("activeId"),
        "vision": data.get("vision"),
        "version": data.get("version") or 1,
        "updatedAt": updated_at.isoformat() if updated_at else None,
    }


@router.put("")
async def put_ai_settings(body: dict, user_id: CurrentUser, session: SessionDep) -> dict:
    """整体覆盖式上传（客户端每次保存都发全量，不做增量合并）。"""
    models = body.get("models")
    if models is not None and not isinstance(models, list):
        raise AppError(code="invalid_payload", message="models 必须是数组", status_code=422)
    if models is not None:
        for m in models:
            if not isinstance(m, dict):
                raise AppError(
                    code="invalid_payload", message="models 每项必须是对象", status_code=422
                )

    # 只透传白名单字段：避免客户端把任意结构塞进加密区，也避免密钥被复制进多余字段
    payload_obj: dict = {"version": 1}
    if models is not None:
        payload_obj["models"] = [
            {
                "id": str(m.get("id") or ""),
                "name": str(m.get("name") or ""),
                "baseUrl": str(m.get("baseUrl") or ""),
                "model": str(m.get("model") or ""),
                "apiKey": str(m.get("apiKey") or ""),
                "supportsTools": bool(m.get("supportsTools")),
                "enabled": bool(m.get("enabled", True)),
            }
            for m in models
        ]
    active = body.get("activeId")
    payload_obj["activeId"] = str(active) if active is not None else None
    vision = body.get("vision")
    if isinstance(vision, dict):
        payload_obj["vision"] = {
            "baseUrl": str(vision.get("baseUrl") or ""),
            "model": str(vision.get("model") or ""),
            "apiKey": str(vision.get("apiKey") or ""),
        }
    else:
        payload_obj["vision"] = None

    raw = json.dumps(payload_obj, ensure_ascii=False, separators=(",", ":"))
    if len(raw.encode("utf-8")) > _MAX_PAYLOAD_BYTES:
        raise AppError(code="payload_too_large", message="AI 配置过大", status_code=413)

    now = utcnow()
    cipher = encrypt_settings(raw, user_id=user_id)
    # 方言无关的 upsert：先查后写。ai_settings 每用户一行、写入极低频，
    # 比维护 sqlite/postgres 两套 on_conflict 语句更不容易出错。
    existing = (
        await session.execute(
            select(ai_settings.c.user_id).where(ai_settings.c.user_id == user_id)
        )
    ).first()
    if existing is None:
        await session.execute(
            ai_settings.insert().values(
                user_id=user_id, payload=cipher, updated_at=now
            )
        )
    else:
        await session.execute(
            ai_settings.update()
            .where(ai_settings.c.user_id == user_id)
            .values(payload=cipher, updated_at=now)
        )
    await session.commit()
    return {"ok": True, "updatedAt": now.isoformat(), "count": len(payload_obj.get("models") or [])}


@router.delete("")
async def delete_ai_settings(user_id: CurrentUser, session: SessionDep) -> dict:
    """清空云端备份（用户在客户端手动"移除云端配置"时调用）。"""
    await session.execute(delete(ai_settings).where(ai_settings.c.user_id == user_id))
    await session.commit()
    return {"ok": True}
