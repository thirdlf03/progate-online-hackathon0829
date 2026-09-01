"""macOS アプリへイベントを push する SSE エンドポイント。"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import StreamingResponse

from device_bridge.daemon.auth import verify_token
from device_bridge.daemon.events import Event, EventBus

router = APIRouter(tags=["events"], dependencies=[Depends(verify_token)])

#: 何も流れないときに送るコメント行の間隔（秒）。
#: 無音のままだと切断に気づけないため、定期的に生存を示す。
KEEPALIVE_INTERVAL = 15.0

#: ``POST /events/publish`` から流せるイベント名の接頭辞。
#: この口は任意の名前を流せるので、``iphone.state`` のようにセーフティーの判定を
#: 通ってから流れるはずのイベントを、判定を迂回して流せてしまう。用途は接続確認だけ
#: なので、``test.`` で始まる名前に限る(唯一の呼び出し元は Swift の ``test.ping``)。
PUBLISHABLE_NAME_PREFIX = "test."


@router.get("/events")
async def stream_events(request: Request) -> StreamingResponse:
    """イベントを SSE で流し続ける。"""
    bus: EventBus = request.app.state.events
    queue = bus.subscribe()

    async def generate() -> AsyncIterator[str]:
        try:
            # 接続できたことをアプリ側に伝える。ここまで届けば経路は生きている。
            yield Event(name="connected", payload={}).to_sse()
            while True:
                if await request.is_disconnected():
                    break
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=KEEPALIVE_INTERVAL)
                except TimeoutError:
                    yield ": keepalive\n\n"
                    continue
                yield event.to_sse()
        finally:
            bus.unsubscribe(queue)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


@router.post("/events/publish")
async def publish_event(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """接続確認用のイベントを 1 件流す。

    経路が通っているかを端から端まで確かめるために置いている。
    Discord Bot や iPhone の状態監視も、最終的にはここと同じ `EventBus.publish` を使う。
    ただしそれらは自前でセーフティーの判定を通してから流すので、判定を持たない
    この口から流せるのは ``test.`` で始まる名前だけにする。
    """
    name = str(body.get("name") or "message")
    if not name.startswith(PUBLISHABLE_NAME_PREFIX):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                f"/events/publish から流せるのは接続確認用の "
                f"「{PUBLISHABLE_NAME_PREFIX}」で始まるイベントだけ(受け取った名前: {name})"
            ),
        )
    payload = body.get("payload")
    event = Event(name=name, payload=payload if isinstance(payload, dict) else {})
    bus: EventBus = request.app.state.events
    bus.publish(event)
    return {"published": True, "name": event.name, "subscribers": bus.subscriber_count}
