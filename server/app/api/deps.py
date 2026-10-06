"""API 依赖：从 Bearer token 解析当前用户。"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AppError
from app.core.security import decode_token
from app.database import get_session


async def get_current_user_id(request: Request) -> str:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise AppError.unauthorized("缺少或非法的 Authorization 头")
    token = auth[len("Bearer "):].strip()
    payload = decode_token(token, expected_type="access")
    user_id = payload.get("sub")
    if not user_id:
        raise AppError.unauthorized("token 缺少用户标识")
    return user_id


SessionDep = Annotated[AsyncSession, Depends(get_session)]
CurrentUser = Annotated[str, Depends(get_current_user_id)]
