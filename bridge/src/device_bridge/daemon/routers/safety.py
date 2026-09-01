"""セーフティー設定の受け取り (``POST /safety``)。

Swift 側は起動時と設定変更時にここへ機能トグルの状態を送ってくる。受け取った値は
``app.state.safety`` に置き、以後 ``require_feature`` の判定に使う。

「iPhone を見張る」を OFF にしたときは、遅延起動済みの監視タスクをここで止める。
止め忘れると ON のまま観測が続き、REST や SSE に状態が漏れ続ける。
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status

from device_bridge.daemon.auth import verify_token
from device_bridge.daemon.routers import iphone_state
from device_bridge.daemon.safety import SafetyState, get_safety

router = APIRouter(tags=["safety"], dependencies=[Depends(verify_token)])


@router.post("/safety")
async def update_safety(request: Request, body: dict[str, Any]) -> dict[str, Any]:
    """機能トグルの状態を受け取り、以後の要求の判定に使う。

    ``{"features": {"iphonePresence": false, "iphoneScreenshot": false, "discordExposure": false}}``
    の形(camelCase、3 キーとも bool 必須)。欠けや型違いは 422 にする。応答は
    ``{"ok": true}``。
    """
    try:
        state = SafetyState.from_payload(body.get("features"))
    except (TypeError, ValueError) as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"セーフティー設定の形が不正: {error}",
        ) from error

    previous = get_safety(request)
    request.app.state.safety = state
    # 「iPhone を見張る」を OFF にしたら観測タスクも止める。OFF のあとに観測が
    # 続くと、モニタが止まるまでの変化が SSE ``iphone.state`` から漏れ続ける。
    if previous.iphone_presence and not state.iphone_presence:
        await iphone_state.stop_monitor(request.app.state)
    return {"ok": True}
