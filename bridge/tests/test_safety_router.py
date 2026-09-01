"""``POST /safety`` の契約と、受け取った値の反映・取り消しを確かめる。

契約(Swift 側 ``SafetyDaemonPayload.swift`` と共有)は ``POST /safety`` に
``{"features": {"iphonePresence": bool, "iphoneScreenshot": bool, "discordExposure": bool}}``
を送ると ``{"ok": true}`` が返り、以後の判定に使われること。キーは camelCase のまま、
3 キーとも bool 必須で、欠けや型違いは 422。
"""

from __future__ import annotations

from typing import Any

import pytest
from fastapi.testclient import TestClient

from device_bridge.daemon.routers import safety as safety_router
from device_bridge.daemon.safety import SafetyState

_ALL_OFF: dict[str, Any] = {
    "features": {
        "iphonePresence": False,
        "iphoneScreenshot": False,
        "discordExposure": False,
    }
}

_ALL_ON: dict[str, Any] = {
    "features": {
        "iphonePresence": True,
        "iphoneScreenshot": True,
        "discordExposure": True,
    }
}


def test_accepts_the_contract_payload(client: TestClient, auth: dict[str, str]) -> None:
    response = client.post("/safety", json=_ALL_OFF, headers=auth)

    assert response.status_code == 200
    assert response.json() == {"ok": True}
    state = client.app.state.safety
    assert isinstance(state, SafetyState)
    assert state == SafetyState()


def test_enabling_everything_is_reflected(client: TestClient, auth: dict[str, str]) -> None:
    # 起動時(全 OFF から)に全機能を ON に切り替える経路。
    response = client.post("/safety", json=_ALL_ON, headers=auth)

    assert response.status_code == 200
    assert client.app.state.safety == SafetyState.all_enabled()


def test_screenshot_is_forced_off_without_presence(
    client: TestClient, auth: dict[str, str]
) -> None:
    """「iPhone の画面を撮る」は「iPhone を見張る」が前提(Epic #58 の #2)。

    Swift 側の上書きで前提が OFF のまま届いても、bridge 側で OFF に倒して
    ``/iphone/screenshot`` を拒否すること。
    """
    payload = {
        "features": {
            "iphonePresence": False,
            "iphoneScreenshot": True,
            "discordExposure": False,
        }
    }

    response = client.post("/safety", json=payload, headers=auth)

    assert response.status_code == 200
    assert client.app.state.safety == SafetyState()
    # 正規化後の値を返すこと。前提が OFF なのに ON と見えてはいけない。
    body = client.get("/health", headers=auth).json()
    assert body["safety"]["iphoneScreenshot"] is False
    assert client.post("/iphone/screenshot", headers=auth).status_code == 403


def test_health_reports_the_safety_state(client: TestClient, auth: dict[str, str]) -> None:
    # デバッグ用の表示。キーは Swift 側と共有する camelCase のまま出す。
    client.post("/safety", json=_ALL_OFF, headers=auth)

    body = client.get("/health", headers=auth).json()

    assert body["safety"] == {
        "iphonePresence": False,
        "iphoneScreenshot": False,
        "discordExposure": False,
    }


def test_a_missing_feature_key_is_422(client: TestClient, auth: dict[str, str]) -> None:
    # 3 キーとも必須。1 つ欠けても受け取らない。
    payload = {"features": {"iphonePresence": False, "iphoneScreenshot": False}}
    response = client.post("/safety", json=payload, headers=auth)

    assert response.status_code == 422


def test_a_non_bool_value_is_422(client: TestClient, auth: dict[str, str]) -> None:
    # 型違いは 422。真偽値として解釈できる文字列でも、契約どおりの bool だけ受け付ける。
    payload = {
        "features": {
            "iphonePresence": "false",
            "iphoneScreenshot": False,
            "discordExposure": False,
        }
    }
    response = client.post("/safety", json=payload, headers=auth)

    assert response.status_code == 422


def test_a_missing_features_key_is_422(client: TestClient, auth: dict[str, str]) -> None:
    response = client.post("/safety", json={}, headers=auth)

    assert response.status_code == 422


def test_requires_the_token(safe_client: TestClient) -> None:
    # 認証なしでは受け付けない。トークンはルーター全体で検証している。
    response = safe_client.post("/safety", json=_ALL_OFF)

    assert response.status_code == 401


def test_turning_presence_off_stops_the_monitor(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    """「iPhone を見張る」を OFF にしたら、遅延起動済みの監視タスクも止めること。

    止め忘れると、OFF の設定の裏で観測が続き REST / SSE に状態が漏れ続ける。
    """
    stopped: list[Any] = []

    async def fake_stop_monitor(app_state: Any) -> None:
        stopped.append(app_state)

    monkeypatch.setattr(safety_router.iphone_state, "stop_monitor", fake_stop_monitor)

    response = client.post("/safety", json=_ALL_OFF, headers=auth)

    assert response.status_code == 200
    assert stopped == [client.app.state]


def test_staying_off_does_not_stop_the_monitor(
    safe_client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    """既に OFF のまま送っても stop_monitor は呼ばれない(むやみに止めない)。"""
    stopped: list[Any] = []

    async def fake_stop_monitor(app_state: Any) -> None:
        stopped.append(app_state)

    monkeypatch.setattr(safety_router.iphone_state, "stop_monitor", fake_stop_monitor)

    response = safe_client.post("/safety", json=_ALL_OFF, headers=auth)

    assert response.status_code == 200
    assert stopped == []
