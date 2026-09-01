"""セーフティートグル(機能 OFF)の状態と、OFF の機能を拒否する判定。

macOS アプリ(Swift)は起動時と設定変更時に ``POST /safety`` で 3 本のトグルを
送ってくる。契約は ``desktop/Sources/MihariCore/Safety/SafetyDaemonPayload.swift``
で、JSON のキーは camelCase のまま共有している(変えてはいけない)。

Swift 側(#49)が機能の入口で判定していても、Swift にバグがあったときに Python が
実行しないよう、ここでも OFF の機能を 403 で拒否する(二重防御)。つまり OFF の
機能は、Swift の判定が効いているかどうかにかかわらず、デーモンには届かない。

一度も ``POST /safety`` が来ていない間の既定は全 OFF(= 全て拒否)。Swift がまだ
起動していないのにデーモンだけが動いても、OFF の機能は一切動かない。
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from fastapi import HTTPException, Request, status

#: 機能名 → 表示名。403 の理由に載せる。想定外の名前は Factory の時点で KeyError に落ちる。
FEATURE_LABELS: dict[str, str] = {
    "iphone_presence": "iPhone を見張る",
    "iphone_screenshot": "iPhone の画面を撮る",
    "discord_exposure": "Discord に晒す",
}

#: 機能名(属性名) → Swift と共有する JSON のキー。camelCase のまま変えてはいけない。
#: ``from_payload`` / ``to_payload`` が両方ここを参照するので、契約を 1 箇所に閉じ込める。
_PAYLOAD_KEYS: dict[str, str] = {
    "iphone_presence": "iphonePresence",
    "iphone_screenshot": "iphoneScreenshot",
    "discord_exposure": "discordExposure",
}


@dataclass(frozen=True, slots=True)
class SafetyState:
    """セーフティートグル 3 本の現在値。既定は全 OFF(全て拒否)。"""

    iphone_presence: bool = False
    iphone_screenshot: bool = False
    discord_exposure: bool = False

    @classmethod
    def all_enabled(cls) -> SafetyState:
        """全機能を ON にした状態。既存テストが従来どおり通るように conftest から使う。"""
        return cls(iphone_presence=True, iphone_screenshot=True, discord_exposure=True)

    @classmethod
    def from_payload(cls, features: dict[str, Any]) -> SafetyState:
        """Swift が送ってくる camelCase の辞書から作る。検証込み。

        :raises ValueError: キーの欠け・型違いなど、契約に合わないとき。
        """
        if not isinstance(features, dict):
            raise ValueError("features がオブジェクトではない")
        values: dict[str, bool] = {}
        for attribute, key in _PAYLOAD_KEYS.items():
            try:
                raw = features[key]
            except KeyError as error:
                raise ValueError(f"セーフティー設定のキーが欠けている: {key}") from error
            if not isinstance(raw, bool):
                raise ValueError(f"{key} は bool でなければならない")
            values[attribute] = raw
        return cls(**values)

    def to_payload(self) -> dict[str, bool]:
        """REST の応答で使う camelCase の辞書に直す。``/health`` のデバッグ表示用。"""
        return {key: getattr(self, attribute) for attribute, key in _PAYLOAD_KEYS.items()}


def _state_of(app_state: Any) -> SafetyState:
    """アプリ状態からセーフティー設定を取り出す。設定が無ければ既定の全 OFF。"""
    safety: SafetyState | None = getattr(app_state, "safety", None)
    return safety if safety is not None else SafetyState()


def get_safety(request: Request) -> SafetyState:
    """要求の処理対象のアプリ状態からセーフティー設定を取り出す。

    一度も ``POST /safety`` が来ていない間は既定の全 OFF を返す。
    """
    return _state_of(request.app.state)


def require_feature(name: str) -> Callable[[Request], None]:
    """OFF の機能を拒否する FastAPI の依存関数を作るファクトリ。

    エンドポイント単位で ``dependencies=[Depends(require_feature("..."))]`` と足す。
    ルーター全体には付けない。チャンネル選択・テスト投稿など本人の明示操作まで
    塞いでしまうから。

    :param name: ``FEATURE_LABELS`` のキー(``iphone_presence`` など)。
    :returns: その機能が OFF のとき 403 を投げる依存関数。
    """
    label = FEATURE_LABELS[name]

    def dependency(request: Request) -> None:
        if not getattr(_state_of(request.app.state), name):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"セーフティー設定で「{label}」が OFF になっている",
            )

    return dependency
