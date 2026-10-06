"""种子数据：内置公共食物库（food_catalog，只读公共表）。

数据源自 App 内置的 `lib/data/food_catalog_data.dart`，以 JSON 形式固化在
`app/data/food_catalog.json`。幂等：仅在表为空时写入。
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.tables import TABLES, utcnow

_DATA_FILE = Path(__file__).parent / "data" / "food_catalog.json"


async def ensure_seeded(session: AsyncSession) -> bool:
    """food_catalog 为空时导入内置食物库。返回是否执行了写入。"""
    tbl = TABLES["food_catalog"]
    count = (await session.execute(select(func.count()).select_from(tbl))).scalar() or 0
    if count > 0:
        return False
    if not _DATA_FILE.exists():
        return False
    items = json.loads(_DATA_FILE.read_text(encoding="utf-8"))
    now = utcnow()
    for item in items:
        await session.execute(
            tbl.insert().values(
                id=uuid.uuid4().hex,
                name=item["name"],
                calories_per_100g=item["calories_per_100g"],
                protein_per_100g=item.get("protein_per_100g"),
                fat_per_100g=item.get("fat_per_100g"),
                carbs_per_100g=item.get("carbs_per_100g"),
                category=item.get("category"),
                updated_at=now,
                version=1,
            )
        )
    await session.commit()
    return True
