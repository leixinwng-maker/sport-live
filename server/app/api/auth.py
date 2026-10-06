"""鉴权路由：注册 / 登录 / 刷新 token。"""

from __future__ import annotations

import uuid

from fastapi import APIRouter
from pydantic import BaseModel
from sqlalchemy import select

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
