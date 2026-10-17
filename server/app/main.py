"""FastAPI 应用入口。

启动：
    uvicorn app.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy import inspect, text
from sqlalchemy.engine import Connection

from app.api import ai_settings as ai_settings_api
from app.api import auth as auth_api
from app.api import data as data_api
from app.api import sync as sync_api
from app.config import get_settings
from app.core.errors import register_exception_handlers
from app.core.logging import configure_logging, install_request_id_middleware
from app.database import SessionLocal, engine
from app.models import metadata
from app.schemas.common import HealthOut

# 存量库增量列迁移：create_all 只建缺失表、不给已有表加列，
# 客户端新版本通过同步 push 的整行 payload 携带新列，服务端必须同步扩列，
# 否则 push 会因 unknown field 整批 400、客户端队列卡死。
# 每项：(表名, [(列名, DDL 类型), ...])；新库由 create_all 直接建成完整结构，自动跳过。
_ADDED_COLUMNS: dict[str, tuple[tuple[str, str], ...]] = {
    "health_metrics": (
        ("source_report_id", "TEXT"),
        ("risk_level", "TEXT"),
        ("reference_range", "TEXT"),
    ),
    "health_reports": (
        ("report_type", "TEXT"),
        ("risk_level", "TEXT"),
        ("actions_json", "TEXT"),
    ),
}


def _run_column_migrations(sync_conn: Connection) -> None:
    """幂等补列：仅当表已存在且列缺失时执行 ALTER TABLE ADD COLUMN。"""
    insp = inspect(sync_conn)
    existing_tables = set(insp.get_table_names())
    for table_name, columns in _ADDED_COLUMNS.items():
        if table_name not in existing_tables:
            continue
        existing_cols = {c["name"] for c in insp.get_columns(table_name)}
        for col_name, col_type in columns:
            if col_name not in existing_cols:
                sync_conn.exec_driver_sql(
                    f"ALTER TABLE {table_name} ADD COLUMN {col_name} {col_type}"
                )


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    configure_logging()
    if settings.auto_create_tables:
        async with engine.begin() as conn:
            await conn.run_sync(metadata.create_all)
            await conn.run_sync(_run_column_migrations)
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
    app.include_router(ai_settings_api.router)

    # 法务静态页（隐私政策 / 用户协议，供上架审核与 App 内引用）：
    # /legal/privacy-policy.html、/legal/user-agreement.html
    legal_dir = Path(__file__).resolve().parent / "static" / "legal"
    legal_dir.mkdir(parents=True, exist_ok=True)
    app.mount("/legal", StaticFiles(directory=legal_dir), name="legal")

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
