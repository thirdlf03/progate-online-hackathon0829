"""テスト共通のフィクスチャ。"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from device_bridge.daemon.app import create_app
from device_bridge.daemon.config import DaemonConfig
from device_bridge.daemon.safety import SafetyState

TOKEN = "test-token"


@pytest.fixture
def client() -> TestClient:
    """認証トークンを固定したテストクライアント。セーフティーは全機能 ON にする。

    OFF での挙動(403 など)は ``safe_client`` で確かめるので、既存テストが
    セーフティー導入前のとおりに通るよう、こちらの既定は全部 ON にしておく。
    """
    app = create_app(DaemonConfig(token=TOKEN))
    app.state.safety = SafetyState.all_enabled()
    return TestClient(app)


@pytest.fixture
def safe_client() -> TestClient:
    """セーフティーが既定のまま(全 OFF)のテストクライアント。

    OFF の機能は 403 になること、OFF でも本人の操作は通ることを確かめるテストで使う。
    """
    app = create_app(DaemonConfig(token=TOKEN))
    return TestClient(app)


@pytest.fixture
def auth() -> dict[str, str]:
    return {"X-Mihari-Token": TOKEN}
