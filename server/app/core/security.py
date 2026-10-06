"""JWT 签发/校验与密码哈希（bcrypt + PyJWT）。"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import uuid4

import bcrypt
import jwt

from ..config import settings
from .errors import unauthorized


# ------------------------------------------------------------ 密码哈希


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))
    except ValueError:
        return False


# ----------------------------------------------------------------- JWT


def _create_token(user_id: str, token_type: str, expires_delta: timedelta) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "type": token_type,
        "iat": now,
        "exp": now + expires_delta,
        "jti": uuid4().hex,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def create_access_token(user_id: str) -> str:
    return _create_token(
        user_id, "access", timedelta(minutes=settings.access_token_expire_minutes)
    )


def create_refresh_token(user_id: str) -> str:
    return _create_token(
        user_id, "refresh", timedelta(days=settings.refresh_token_expire_days)
    )


def decode_token(token: str, expected_type: str) -> dict[str, Any]:
    """解码并校验 token；失败抛 401。"""
    try:
        payload = jwt.decode(
            token, settings.jwt_secret, algorithms=[settings.jwt_algorithm]
        )
    except jwt.ExpiredSignatureError:
        raise unauthorized("凭证已过期")
    except jwt.InvalidTokenError:
        raise unauthorized("凭证无效")
    if payload.get("type") != expected_type or not payload.get("sub"):
        raise unauthorized("凭证类型错误")
    return payload


def token_response(user_id: str) -> dict[str, str]:
    return {
        "access_token": create_access_token(user_id),
        "refresh_token": create_refresh_token(user_id),
        "token_type": "bearer",
        "user_id": user_id,
    }
