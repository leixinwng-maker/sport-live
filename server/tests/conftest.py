"""测试夹具：内存 SQLite + ASGI 客户端。必须在导入 app 之前设置环境变量。"""

from __future__ import annotations

import os

os.environ["DATABASE_URL"] = "sqlite+aiosqlite://"
os.environ["JWT_SECRET"] = "test-secret-key-for-pytest-0123456789abcdef"
os.environ["AUTO_CREATE_TABLES"] = "false"
os.environ["LOGIN_RATE_LIMIT"] = "100"

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from app.database import SessionLocal, engine, get_session
from app.main import app
from app.models import metadata


@pytest_asyncio.fixture
async def setup_db():
    async with engine.begin() as conn:
        await conn.run_sync(metadata.create_all)
    yield
    async with engine.begin() as conn:
        await conn.run_sync(metadata.drop_all)


@pytest_asyncio.fixture
async def session(setup_db):
    async with SessionLocal() as s:
        yield s


@pytest_asyncio.fixture
async def client(setup_db):
    async def _override():
        async with SessionLocal() as s:
            yield s

    app.dependency_overrides[get_session] = _override
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()
