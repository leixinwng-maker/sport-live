"""共享的请求/响应模型。业务表数据是 schema-less 的 JSON（见 tables.py 校验）。"""

from __future__ import annotations

from typing import Any, Optional

from pydantic import BaseModel, EmailStr, Field


class MessageOut(BaseModel):
    code: str = "ok"
    message: str = "success"


class ErrorOut(BaseModel):
    code: str
    message: str
    detail: Optional[Any] = None


class HealthOut(BaseModel):
    status: str
    db: str


# ---------- auth ----------

class RegisterIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=6, max_length=128)
    display_name: str = Field(default="", max_length=64)


class LoginIn(BaseModel):
    email: EmailStr
    password: str


class TokenOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user_id: str


# ---------- sync ----------

class SyncItemIn(BaseModel):
    table: str
    id: str = Field(min_length=1, max_length=64)
    op: str = Field(pattern="^(upsert|delete)$")
    base_version: int = Field(default=0, ge=0)
    updated_at: Optional[str] = None  # ISO8601，客户端逻辑时间，用于 LWW
    data: Optional[dict[str, Any]] = None


class PushIn(BaseModel):
    device_id: str = Field(default="", max_length=64)
    platform: str = Field(default="", max_length=32)
    changes: list[SyncItemIn] = Field(default_factory=list)


class SyncChangeOut(BaseModel):
    table: str
    id: str
    status: str  # applied | conflict
    server_version: int
    conflict: bool = False
    server_record: Optional[dict[str, Any]] = None


class PushOut(BaseModel):
    results: list[SyncChangeOut]
    server_time: str


class PullIn(BaseModel):
    device_id: str = Field(default="", max_length=64)
    since: Optional[str] = None  # ISO8601 游标时间
    cursor_id: Optional[str] = None
    tables: Optional[list[str]] = None
    limit: Optional[int] = Field(default=None, ge=1, le=1000)


class PullOut(BaseModel):
    changes: list[dict[str, Any]]
    has_more: bool
    next_since: Optional[str] = None
    next_cursor_id: Optional[str] = None
