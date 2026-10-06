"""SQLAlchemy 异步引擎与会话。"""
from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.pool import StaticPool

from .config import settings

_connect_args: dict = {}
_engine_kwargs: dict = {}

if settings.database_url.startswith("sqlite"):
    # aiosqlite 内存库需要 StaticPool 才能跨连接共享同一个库
    if ":memory:" in settings.database_url:
        _engine_kwargs["poolclass"] = StaticPool
    _connect_args["check_same_thread"] = False

engine = create_async_engine(
    settings.database_url,
    connect_args=_connect_args,
    **_engine_kwargs,
)

SessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def get_session() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        yield session
