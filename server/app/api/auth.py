"""鉴权路由：注册 / 登录 / 刷新 token / 注销账号。"""

from __future__ import annotations

import uuid

from fastapi import APIRouter
from pydantic import BaseModel
from sqlalchemy import delete, select

from app.api.deps import CurrentUser, SessionDep
from app.core.errors import AppError
from app.core.ratelimit import login_limiter
from app.core.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    token_response,
    verify_password,
)
from app.models.tables import (
    BUSINESS_TABLES,
    TABLES,
    ai_settings,
    devices,
    sync_applied,
)
from app.models.tables import users as users_tbl
from app.schemas.common import LoginIn, RegisterIn, TokenOut

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=TokenOut, status_code=201)
async def register(body: RegisterIn, session: SessionDep) -> TokenOut:
    email = body.email.lower().strip()
    existing = await session.execute(select(users_tbl.c.id).where(users_tbl.c.email == email))
    if existing.first() is not None:
        raise AppError(code="email_taken", message="该邮箱已注册", status_code=409)

    user_id = uuid.uuid4().hex
    await session.execute(
        users_tbl.insert().values(
            id=user_id,
            email=email,
            password_hash=hash_password(body.password),
            display_name=body.display_name or email.split("@")[0],
        )
    )
    await session.flush()
    await session.commit()
    return TokenOut(**token_response(user_id))


@router.post("/login", response_model=TokenOut)
async def login(body: LoginIn, session: SessionDep) -> TokenOut:
    email = body.email.lower().strip()
    if not login_limiter.check(f"login:{email}"):
        raise AppError.rate_limited("登录尝试过于频繁，请稍后再试")

    row = (
        await session.execute(
            select(users_tbl.c.id, users_tbl.c.password_hash).where(users_tbl.c.email == email)
        )
    ).first()
    if row is None or not verify_password(body.password, row.password_hash):
        raise AppError.unauthorized("邮箱或密码错误")
    return TokenOut(**token_response(row.id))


class RefreshIn(BaseModel):
    refresh_token: str


@router.post("/refresh", response_model=TokenOut)
async def refresh(body: RefreshIn, session: SessionDep) -> TokenOut:
    payload = decode_token(body.refresh_token, expected_type="refresh")
    user_id = payload.get("sub")
    row = (
        await session.execute(select(users_tbl.c.id).where(users_tbl.c.id == user_id))
    ).first()
    if row is None:
        raise AppError.unauthorized("用户不存在")
    return TokenOut(**token_response(user_id))


@router.get("/me")
async def me(user_id: CurrentUser, session: SessionDep) -> dict:
    row = (
        await session.execute(
            select(users_tbl.c.id, users_tbl.c.email, users_tbl.c.display_name).where(
                users_tbl.c.id == user_id
            )
        )
    ).first()
    if row is None:
        raise AppError.unauthorized("用户不存在")
    return {"id": row.id, "email": row.email, "display_name": row.display_name}


class DeleteAccountIn(BaseModel):
    """注销账号必须二次校验密码：防止 token 被盗后直接销毁账号。"""

    password: str


@router.delete("/account")
async def delete_account(
    body: DeleteAccountIn, user_id: CurrentUser, session: SessionDep
) -> dict:
    """注销账号：级联删除该用户的全部云端数据。

    覆盖范围（对应《个人信息保护法》第 47 条删除权）：
    业务表 → 同步幂等账本 → 设备记录 → AI 配置密文 → 账号本身。

    说明：
    - 已签发的 access token 最长 60 分钟后自然失效，refresh token 因账号不存在而失效；
      因此不做额外的令牌吊销表。
    - 数据库备份按既定保留期（默认 14 天）自然过期，前端须在注销前如实告知。
    - 客户端本地数据由调用方在成功响应后自行清除，服务端不触碰本地库。
    """
    if not login_limiter.check(f"delete:{user_id}"):
        raise AppError.rate_limited("操作过于频繁，请稍后再试")

    row = (
        await session.execute(
            select(users_tbl.c.password_hash).where(users_tbl.c.id == user_id)
        )
    ).first()
    if row is None:
        raise AppError.unauthorized("用户不存在")
    if not verify_password(body.password, row.password_hash):
        raise AppError.unauthorized("密码错误，无法注销账号")

    # 业务表：只删 user_scoped 的表（food_catalog 是公共只读表，不属于任何用户）
    for name, spec in BUSINESS_TABLES.items():
        if not spec.user_scoped:
            continue
        table = TABLES[name]
        await session.execute(delete(table).where(table.c.user_id == user_id))

    await session.execute(delete(devices).where(devices.c.user_id == user_id))
    await session.execute(
        delete(sync_applied).where(sync_applied.c.user_id == user_id)
    )
    await session.execute(delete(ai_settings).where(ai_settings.c.user_id == user_id))
    await session.execute(delete(users_tbl).where(users_tbl.c.id == user_id))
    await session.commit()
    return {"deleted": True}
