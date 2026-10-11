"""存量库幂等列迁移测试：模拟旧结构库 → 跑迁移 → 新列补齐且可重复执行。"""

from __future__ import annotations

from sqlalchemy import inspect

from app.database import engine
from app.main import _run_column_migrations
from app.models import metadata

_LEGACY_HEALTH_REPORTS = """
CREATE TABLE health_reports (
    user_id VARCHAR(64) NOT NULL,
    id VARCHAR(64) NOT NULL,
    date TEXT,
    title TEXT,
    file_path TEXT,
    file_type TEXT,
    ocr_text TEXT,
    ai_summary TEXT,
    created_at TEXT,
    updated_at DATETIME NOT NULL,
    client_updated_at DATETIME,
    deleted_at DATETIME,
    version INTEGER NOT NULL,
    PRIMARY KEY (user_id, id)
)
"""

_LEGACY_HEALTH_METRICS = """
CREATE TABLE health_metrics (
    user_id VARCHAR(64) NOT NULL,
    id VARCHAR(64) NOT NULL,
    date TEXT,
    type TEXT,
    value FLOAT,
    unit TEXT,
    note TEXT,
    updated_at DATETIME NOT NULL,
    client_updated_at DATETIME,
    deleted_at DATETIME,
    version INTEGER NOT NULL,
    PRIMARY KEY (user_id, id)
)
"""


def _columns_of(sync_conn, table_name: str) -> set[str]:
    return {c["name"] for c in inspect(sync_conn).get_columns(table_name)}


async def test_column_migrations_on_legacy_db(setup_db):
    """旧结构库补 6 列，且重复执行不报错（幂等）。"""
    async with engine.begin() as conn:
        await conn.run_sync(metadata.drop_all)
        await conn.exec_driver_sql(_LEGACY_HEALTH_REPORTS)
        await conn.exec_driver_sql(_LEGACY_HEALTH_METRICS)
        # 连跑两遍验证幂等
        await conn.run_sync(_run_column_migrations)
        await conn.run_sync(_run_column_migrations)

    async with engine.connect() as conn:
        reports = await conn.run_sync(_columns_of, "health_reports")
        metrics = await conn.run_sync(_columns_of, "health_metrics")

    assert {"report_type", "risk_level", "actions_json"} <= reports
    assert {"source_report_id", "risk_level", "reference_range"} <= metrics


async def test_column_migrations_skip_fresh_db(setup_db):
    """新库由 create_all 建成完整结构，迁移不重复加列也不报错。"""
    async with engine.begin() as conn:
        await conn.run_sync(metadata.create_all)
        await conn.run_sync(_run_column_migrations)

    async with engine.connect() as conn:
        reports = await conn.run_sync(_columns_of, "health_reports")

    assert {"report_type", "risk_level", "actions_json"} <= reports
