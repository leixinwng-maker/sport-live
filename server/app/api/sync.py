"""同步路由：push（客户端→服务端增量）与 pull（服务端→客户端增量）。"""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import CurrentUser, SessionDep
from app.core.sync_engine import (
    ChangeItem,
    merge_changes,
    parse_ts,
    pull_changes,
    touch_device,
)
from app.schemas.common import PullIn, PullOut, PushIn, PushOut, SyncChangeOut

router = APIRouter(prefix="/sync", tags=["sync"])


@router.post("/push", response_model=PushOut)
async def push(body: PushIn, user_id: CurrentUser, session: SessionDep) -> PushOut:
    items = [
        ChangeItem(
            table=item.table,
            id=item.id,
            op=item.op,
            base_version=item.base_version,
            updated_at=parse_ts(item.updated_at),
            data=item.data,
        )
        for item in body.changes
    ]
    results = await merge_changes(session, user_id, items)
    await touch_device(session, user_id, body.device_id, body.platform, push=True)
    await session.commit()

    from app.models.tables import utcnow

    return PushOut(
        results=[
            SyncChangeOut(
                table=r.table,
                id=r.id,
                status=r.status,
                server_version=r.server_version,
                conflict=r.conflict,
                server_record=r.server_record,
            )
            for r in results
        ],
        server_time=utcnow().isoformat(),
    )


@router.post("/pull", response_model=PullOut)
async def pull(body: PullIn, user_id: CurrentUser, session: SessionDep) -> PullOut:
    from app.config import get_settings

    settings = get_settings()
    page = await pull_changes(
        session,
        user_id,
        since=parse_ts(body.since),
        cursor_id=body.cursor_id,
        tables=body.tables,
        limit=body.limit or settings.pull_page_limit,
    )
    await touch_device(session, user_id, body.device_id, pull=True)
    await session.commit()
    return PullOut(
        changes=[c.to_dict() for c in page.changes],
        has_more=page.has_more,
        next_since=page.next_since.isoformat() if page.next_since else None,
        next_cursor_id=page.next_cursor_id,
    )
