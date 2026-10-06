"""FastAPI 应用入口。

启动：
    uvicorn app.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text

from app.api import auth as auth_api
from app.api import data as data_api
from app.api import sync as sync_api
from app.config import get_settings
from app.core.errors import register_exception_handlers
from app.core.logging import configure_logging, install_request_id_middleware
from app.database import SessionLocal, engine
from app.models import metadata
from app.schemas.common import HealthOut


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    configure_logging()
    if settings.auto_create_tables:
        async with engine.begin() as conn:
            await conn.run_sync(metadata.create_all)
        from app.seed import ensure_seeded

        async with SessionLocal() as session:
            await ensure_seeded(session)
    yield
    await engine.dispose()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="问道 WenDao API",
        description="个人 AI 规划助手后端：多用户数据服务 + 离线优先增量同步",
        version="0.1.0",
        lifespan=lifespan,
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    install_request_id_middleware(app)
    register_exception_handlers(app)

    app.include_router(auth_api.router)
    app.include_router(sync_api.router)
    app.include_router(data_api.router)

    @app.get("/health", response_model=HealthOut, tags=["meta"])
    async def health() -> HealthOut:
        try:
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
            return HealthOut(status="ok", db="ok")
        except Exception:  # noqa: BLE001
            return HealthOut(status="ok", db="error")

    @app.get("/", tags=["meta"])
    async def root() -> dict:
        return {
            "name": "WenDao API",
            "version": "0.1.0",
            "docs": "/docs",
        }

    return app


app = create_app()
