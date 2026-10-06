"""数据模型注册表：16 张业务表（与 App 本地 sqflite 表一一镜像）+ 元数据表。

设计要点：
- 每张业务表统一追加同步字段：
    id              TEXT 主键（客户端生成，UUID 或本地 id 字符串化）
    user_id         用户隔离（food_catalog 公共表除外）
    updated_at      服务端权威时间戳，用作 pull 游标（避免客户端时钟漂移）
    client_updated_at  客户端逻辑时间，仅用于冲突时"最后写入胜出"比较
    deleted_at      软删除标记（同步删除事件用）
    version         版本号，冲突兜底
- 业务表字段以 lib/services/database_helper.dart 的 CREATE TABLE 为准；
  本地 REAL/INTEGER/TEXT 分别映射 Float/Integer/Text。
- assets.updated_at / debts.updated_at 是业务列，与同步字段重名，
  库内列名映射为 biz_updated_at，payload 字段名保持 "updated_at" 不变。
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import Column, DateTime, Float, Integer, MetaData, String, Table, Text

naming_convention = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

metadata = MetaData(naming_convention=naming_convention)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


# ---------------------------------------------------------------- 组件定义


@dataclass(frozen=True)
class ColumnSpec:
    """业务列规格。name 为客户端 payload 字段名；db_name 用于规避列名冲突。"""

    name: str
    type: Any
    required: bool = False
    db_name: str = ""

    @property
    def column_name(self) -> str:
        return self.db_name or self.name


@dataclass(frozen=True)
class TableSpec:
    name: str
    columns: tuple[ColumnSpec, ...]
    user_scoped: bool = True  # 是否按用户隔离
    writable: bool = True  # 是否允许写（food_catalog 公共只读）

    @property
    def column_map(self) -> dict[str, ColumnSpec]:
        return {c.name: c for c in self.columns}

    @property
    def required_fields(self) -> tuple[str, ...]:
        return tuple(c.name for c in self.columns if c.required)

    @property
    def payload_fields(self) -> tuple[str, ...]:
        return tuple(c.name for c in self.columns)


def _t(name: str, type_: Any, required: bool = False, db_name: str = "") -> ColumnSpec:
    return ColumnSpec(name=name, type=type_, required=required, db_name=db_name)


# ------------------------------------------------------- 16 张业务表规格

BUSINESS_TABLES: dict[str, TableSpec] = {
    spec.name: spec
    for spec in (
        TableSpec(
            "user_profile",
            (
                _t("height", Float, True),
                _t("weight", Float, True),
                _t("age", Integer, True),
                _t("gender", Text, True),
                _t("goal", Text, True),
                _t("bmr", Float, True),
                _t("body_fat", Float),
                _t("gym_equipment", Text),
            ),
        ),
        TableSpec(
            "workouts",
            (
                _t("date", Text, True),
                _t("type", Text, True),
                _t("duration", Integer, True),
                _t("intensity", Integer, True),
                _t("exercises", Text, True),
            ),
        ),
        TableSpec(
            "diet_records",
            (
                _t("date", Text, True),
                _t("meal_type", Text, True),
                _t("total_calories", Float, True),
                _t("foods", Text, True),
            ),
        ),
        TableSpec(
            "food_catalog",
            (
                _t("name", Text, True),
                _t("calories_per_100g", Float, True),
                _t("protein_per_100g", Float, True),
                _t("fat_per_100g", Float, True),
                _t("carbs_per_100g", Float, True),
                _t("category", Text, True),
            ),
            user_scoped=False,
            writable=False,
        ),
        TableSpec(
            "finance_records",
            (
                _t("date", Text, True),
                _t("type", Text, True),
                _t("category", Text, True),
                _t("amount", Float, True),
                _t("note", Text),
            ),
        ),
        TableSpec(
            "budgets",
            (
                _t("category", Text, True),
                _t("monthly_limit", Float, True),
                _t("year", Integer, True),
                _t("month", Integer, True),
            ),
        ),
        TableSpec(
            "assets",
            (
                _t("name", Text, True),
                _t("type", Text, True),
                _t("principal", Float, True),
                _t("market_value", Float, True),
                _t("updated_at", Text, True, db_name="biz_updated_at"),
                _t("note", Text),
            ),
        ),
        TableSpec(
            "debts",
            (
                _t("name", Text, True),
                _t("amount", Float, True),
                _t("due_date", Text),
                _t("is_paid", Integer, True),
                _t("updated_at", Text, True, db_name="biz_updated_at"),
                _t("note", Text),
            ),
        ),
        TableSpec(
            "knowledge_entries",
            (
                _t("domain", Text, True),
                _t("master", Text, True),
                _t("category", Text, True),
                _t("title", Text, True),
                _t("content", Text, True),
                _t("keywords", Text),
                _t("source", Text),
            ),
        ),
        TableSpec(
            "books",
            (
                _t("title", Text, True),
                _t("author", Text, True),
                _t("domain", Text, True),
                _t("content", Text, True),
                _t("added_at", Text, True),
            ),
        ),
        TableSpec(
            "book_notes",
            (
                _t("book_id", String(64), True),
                _t("content", Text, True),
                _t("created_at", Text, True),
            ),
        ),
        TableSpec(
            "life_status",
            (
                _t("date", Text, True),
                _t("tags", Text, True),
                _t("energy_score", Integer, True),
                _t("sleep_hours", Float, True),
                _t("note", Text),
            ),
        ),
        TableSpec(
            "ai_advice",
            (
                _t("created_at", Text, True),
                _t("type", Text, True),
                _t("content", Text, True),
                _t("related_data", Text),
            ),
        ),
        TableSpec(
            "sync_records",
            (
                _t("sync_type", Text, True),
                _t("data_version", Integer, True),
                _t("sync_time", Text, True),
            ),
        ),
        TableSpec(
            "health_profile",
            (
                _t("blood_type", Text),
                _t("chronic_diseases", Text),
                _t("allergies", Text),
                _t("family_history", Text),
                _t("medications", Text),
                _t("surgeries", Text),
                _t("special_notes", Text),
            ),
        ),
        TableSpec(
            "health_metrics",
            (
                _t("date", Text, True),
                _t("type", Text, True),
                _t("value", Float, True),
                _t("unit", Text),
                _t("note", Text),
            ),
        ),
        TableSpec(
            "health_reports",
            (
                _t("date", Text, True),
                _t("title", Text, True),
                _t("file_path", Text, True),
                _t("file_type", Text),
                _t("ocr_text", Text),
                _t("ai_summary", Text),
                _t("created_at", Text, True),
            ),
        ),
    )
}

SYNCED_TABLES: tuple[str, ...] = tuple(
    name for name, spec in BUSINESS_TABLES.items() if spec.user_scoped
)


# --------------------------------------------------------------- 建表


def _build_business_table(spec: TableSpec) -> Table:
    columns: list[Column] = [Column("id", String(64), primary_key=True)]
    if spec.user_scoped:
        columns.append(Column("user_id", String(64), nullable=False, index=True))
    for c in spec.columns:
        columns.append(Column(c.column_name, c.type, nullable=not c.required))
    columns.extend(
        [
            Column("updated_at", DateTime(timezone=True), nullable=False, default=utcnow),
            Column("client_updated_at", DateTime(timezone=True), nullable=True),
            Column("deleted_at", DateTime(timezone=True), nullable=True),
            Column("version", Integer, nullable=False, default=1),
        ]
    )
    return Table(spec.name, metadata, *columns)


TABLES: dict[str, Table] = {
    name: _build_business_table(spec) for name, spec in BUSINESS_TABLES.items()
}

# ----------------------------------------------------------------- 元数据表

users = Table(
    "users",
    metadata,
    Column("id", String(64), primary_key=True),
    Column("email", String(255), nullable=False, unique=True, index=True),
    Column("password_hash", String(255), nullable=False),
    Column("display_name", String(255), nullable=False, default=""),
    Column("created_at", DateTime(timezone=True), nullable=False, default=utcnow),
)

devices = Table(
    "devices",
    metadata,
    Column("user_id", String(64), primary_key=True),
    Column("device_id", String(64), primary_key=True),
    Column("platform", String(64), nullable=False, default=""),
    Column("last_push_at", DateTime(timezone=True), nullable=True),
    Column("last_pull_at", DateTime(timezone=True), nullable=True),
    Column("created_at", DateTime(timezone=True), nullable=False, default=utcnow),
)

# 幂等账本：同一 (user_id, table, row_id, base_version, client_ts) 的变更只应用一次
# client_ts 是客户端逻辑时间，用于区分"同 base_version 的不同变更"与"网络重试重放"
sync_applied = Table(
    "sync_applied",
    metadata,
    Column("user_id", String(64), primary_key=True),
    Column("table_name", String(64), primary_key=True),
    Column("row_id", String(64), primary_key=True),
    Column("base_version", Integer, primary_key=True),
    Column("client_ts", String(40), primary_key=True, default=""),
    Column("status", String(16), nullable=False),
    Column("server_version", Integer, nullable=False),
    Column("applied_at", DateTime(timezone=True), nullable=False, default=utcnow),
)


# ------------------------------------------------------------ payload 映射


def payload_to_row(spec: TableSpec, data: dict[str, Any]) -> dict[str, Any]:
    """客户端 payload → 数据库列值字典（仅业务列）。"""
    return {spec.column_map[key].column_name: value for key, value in data.items()}


def row_to_payload(spec: TableSpec, row: Any) -> dict[str, Any]:
    """数据库行 → 客户端 payload 字段字典（仅业务列）。"""
    return {c.name: row[c.column_name] for c in spec.columns}


def validate_payload(spec: TableSpec, data: dict[str, Any], *, partial: bool = False) -> list[str]:
    """校验 payload 字段，返回错误列表（空即通过）。"""
    errors: list[str] = []
    for key in data:
        if key not in spec.column_map:
            errors.append(f"unknown field: {key}")
    if not partial:
        for key in spec.required_fields:
            if data.get(key) is None:
                errors.append(f"missing required field: {key}")
    return errors
