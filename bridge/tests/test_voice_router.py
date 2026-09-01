"""セリフのエンドポイント。"""

from __future__ import annotations

import asyncio
import base64
from typing import Any

import pytest
from fastapi.testclient import TestClient

from device_bridge.daemon.routers import voice as voice_router
from device_bridge.voice.context import Escalation, IPhoneState, SpeechContext, VisionLabel
from device_bridge.voice.screen_reader import ScreenCategory, ScreenReadError, ScreenReading
from device_bridge.voice.voicevox import VoiceTuning, VoicevoxUnavailableError

WAV = b"RIFF....WAVE"
PNG = b"\x89PNG\r\n\x1a\n" + b"body"
PNG_B64 = base64.b64encode(PNG).decode("ascii")

READING = ScreenReading(
    app="YouTube",
    activity="料理動画",
    category=ScreenCategory.SLACKING,
    line="その料理動画、そんなに楽しい?",
)

#: 固定文言へ落ちたことを検証するとき、乱数で揺れないよう差し替える定数。
_FIXED_LINE = "手が止まってますよ"


def _fixed_fallback(context: SpeechContext, *, rng: Any = None) -> str:
    """テスト用の固定文言。``fallback_line`` の代わりに差し替える。"""
    return _FIXED_LINE


class _StubVoicevox:
    def __init__(self, *, audio: bytes | None = WAV, delay: float = 0.0) -> None:
        self._audio = audio
        self._delay = delay
        self.base_url = "http://engine"
        self.speaker = 1
        self.tuning = VoiceTuning()
        self.cached_count = 0

    async def is_reachable(self) -> bool:
        return self._audio is not None

    async def synthesize(self, text: str, *, speaker: int | None = None) -> bytes:
        await asyncio.sleep(self._delay)
        if self._audio is None:
            raise VoicevoxUnavailableError("VOICEVOX に繋がらない(http://engine)")
        return self._audio


class _StubScreenReader:
    def __init__(self, result: Any, *, is_configured: bool = True, delay: float = 0.0) -> None:
        self._result = result
        self._delay = delay
        self.is_configured = is_configured
        self.model = "test-screen-model"
        self.seen: list[bytes] = []
        self.require_line: list[bool] = []

    async def read(
        self, png: bytes, context: SpeechContext, *, require_line: bool = True
    ) -> ScreenReading:
        self.seen.append(png)
        self.require_line.append(require_line)
        await asyncio.sleep(self._delay)
        if isinstance(self._result, Exception):
            raise self._result
        return self._result


class _RecordingReader(_StubScreenReader):
    """読んだスクショに加え、渡された状況も記録する。パースの検証に使う。"""

    def __init__(self, result: Any = READING) -> None:
        super().__init__(result)
        self.contexts: list[SpeechContext] = []

    async def read(
        self, png: bytes, context: SpeechContext, *, require_line: bool = True
    ) -> ScreenReading:
        self.contexts.append(context)
        return await super().read(png, context, require_line=require_line)


def _install(client: TestClient, voicevox: Any, screen_reader: Any | None = None) -> None:
    """状態をスタブで置き換える。Claude 経路は廃止したので、画面読み取りと VOICEVOX だけを持つ。"""
    client.app.state.voicevox = voicevox
    client.app.state.screen_reader = screen_reader or _StubScreenReader(READING)


def test_line_without_a_screenshot_falls_back_to_a_fixed_line(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    # カメラ経路などスクショが無いときは LLM を呼ばず、同封の固定文言に落とす。
    monkeypatch.setattr(voice_router, "fallback_line", _fixed_fallback)
    _install(client, _StubVoicevox())

    response = client.post("/voice/line", json={"idle_seconds": 300}, headers=auth)

    assert response.status_code == 200
    assert response.json() == {
        "text": _FIXED_LINE,
        "from_llm": False,
        "fallback_reason": "固定文言(スクショ無し)",
        "screen": None,
        "screen_error": None,
    }


def test_line_parses_every_signal(client: TestClient, auth: dict[str, str]) -> None:
    reader = _RecordingReader()
    _install(client, _StubVoicevox(), reader)

    client.post(
        "/voice/line",
        json={
            "idle_seconds": 120,
            "escalation": "expose",
            "frontmost_app": "Safari",
            "iphone": "active",
            "iphone_app": "YouTube",
            "vision": "sleeping",
            "screenshot_png": PNG_B64,
        },
        headers=auth,
    )

    context = reader.contexts[0]
    assert context.idle_seconds == 120
    assert context.escalation is Escalation.EXPOSE
    assert context.frontmost_app == "Safari"
    assert context.iphone is IPhoneState.ACTIVE
    assert context.iphone_app == "YouTube"
    assert context.vision is VisionLabel.SLEEPING


def test_unknown_enum_values_fall_back_to_defaults(
    client: TestClient, auth: dict[str, str]
) -> None:
    # 送り手と受け手の版がずれても喋り続ける方を選んでいる。
    reader = _RecordingReader()
    _install(client, _StubVoicevox(), reader)

    response = client.post(
        "/voice/line",
        json={
            "idle_seconds": 1,
            "escalation": "未知",
            "vision": "未知",
            "screenshot_png": PNG_B64,
        },
        headers=auth,
    )

    assert response.status_code == 200
    assert reader.contexts[0].escalation is Escalation.NUDGE
    assert reader.contexts[0].vision is VisionLabel.UNKNOWN
    # iphone_app はキーごと無くてよい。
    assert reader.contexts[0].iphone_app is None


def test_invalid_idle_seconds_is_422(client: TestClient, auth: dict[str, str]) -> None:
    _install(client, _StubVoicevox())

    response = client.post("/voice/line", json={"idle_seconds": -5}, headers=auth)

    assert response.status_code == 422


def test_speak_returns_base64_audio(client: TestClient, auth: dict[str, str]) -> None:
    _install(client, _StubVoicevox())

    body = client.post("/voice/speak", json={"idle_seconds": 60}, headers=auth).json()

    assert base64.b64decode(body["audio"]) == WAV
    assert body["audio_error"] is None


def test_speak_still_returns_the_line_when_the_engine_is_down(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    # 喋れないことは検知や送信を止める理由にならないので、200 で返してテキストは渡す。
    monkeypatch.setattr(voice_router, "fallback_line", _fixed_fallback)
    _install(client, _StubVoicevox(audio=None))

    response = client.post("/voice/speak", json={"idle_seconds": 60}, headers=auth)

    assert response.status_code == 200
    body = response.json()
    assert body["text"] == _FIXED_LINE
    assert body["from_llm"] is False
    assert body["audio"] is None
    assert "繋がらない" in body["audio_error"]


def test_status_reports_what_is_missing(client: TestClient, auth: dict[str, str]) -> None:
    # Claude は廃止したので、状態に出るのは画面読み取りと VOICEVOX だけ。
    _install(client, _StubVoicevox(audio=None))

    body = client.get("/voice/status", headers=auth).json()

    # llm_configured / llm_model は macOS アプリが必須としてデコードするので、
    # 形だけ残して無効にする(Claude 経路はもう無い)。
    assert body["llm_configured"] is False
    assert body["llm_model"] == ""
    assert body["screen_llm_configured"] is True
    assert body["screen_llm_model"] == "test-screen-model"
    assert body["voicevox_reachable"] is False
    assert body["voicevox_url"] == "http://engine"


def test_voice_endpoints_need_a_token(client: TestClient) -> None:
    assert client.get("/voice/status").status_code == 401
    assert client.post("/voice/line", json={}).status_code == 401
    assert client.post("/voice/speak", json={}).status_code == 401
    assert client.post("/voice/screen", json={}).status_code == 401


def test_a_screenshot_makes_the_line_from_the_screen(
    client: TestClient, auth: dict[str, str]
) -> None:
    reader = _StubScreenReader(READING)
    _install(client, _StubVoicevox(), reader)

    body = client.post(
        "/voice/line",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    ).json()

    assert body["text"] == READING.line
    assert body["from_llm"] is True
    assert body["fallback_reason"] is None
    assert body["screen"] == {
        "app": "YouTube",
        "activity": "料理動画",
        "category": "slacking",
    }
    assert body["screen_error"] is None
    assert reader.seen == [PNG]
    # 喋るときはセリフごと要る。
    assert reader.require_line == [True]


def test_an_unreadable_screenshot_falls_back_to_a_fixed_line(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    # 画面が読めないことは喋らない理由にならないので、理由を載せて固定文言に落とす。
    monkeypatch.setattr(voice_router, "fallback_line", _fixed_fallback)
    _install(
        client,
        _StubVoicevox(),
        _StubScreenReader(ScreenReadError("レート制限に当たった")),
    )

    body = client.post(
        "/voice/line",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    ).json()

    assert body["text"] == _FIXED_LINE
    assert body["from_llm"] is False
    assert body["fallback_reason"] == "レート制限に当たった"
    assert body["screen"] is None
    assert body["screen_error"] == "レート制限に当たった"


def test_without_a_gemini_key_it_says_so(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    # キーが無くても黙らない。理由を付けて固定文言に落とす。
    monkeypatch.setattr(voice_router, "fallback_line", _fixed_fallback)
    _install(
        client,
        _StubVoicevox(),
        _StubScreenReader(READING, is_configured=False),
    )

    body = client.post(
        "/voice/line",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    ).json()

    assert body["text"] == _FIXED_LINE
    assert body["from_llm"] is False
    assert body["fallback_reason"] == "GEMINI_API_KEY が未設定"
    assert body["screen"] is None
    assert body["screen_error"] == "GEMINI_API_KEY が未設定"


def test_a_broken_base64_screenshot_is_422(client: TestClient, auth: dict[str, str]) -> None:
    _install(client, _StubVoicevox())

    response = client.post(
        "/voice/line",
        json={"idle_seconds": 1, "screenshot_png": "これは base64 ではない"},
        headers=auth,
    )

    assert response.status_code == 422
    assert "base64" in response.json()["detail"]


def test_a_non_png_screenshot_is_422(client: TestClient, auth: dict[str, str]) -> None:
    _install(client, _StubVoicevox())

    response = client.post(
        "/voice/line",
        json={
            "idle_seconds": 1,
            "screenshot_png": base64.b64encode(b"\xff\xd8\xff JPEG").decode("ascii"),
        },
        headers=auth,
    )

    assert response.status_code == 422
    assert "PNG" in response.json()["detail"]


def test_speak_uses_the_screen_too(client: TestClient, auth: dict[str, str]) -> None:
    _install(client, _StubVoicevox(), _StubScreenReader(READING))

    body = client.post(
        "/voice/speak",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    ).json()

    assert body["text"] == READING.line
    assert body["screen"]["category"] == "slacking"
    assert body["screen_error"] is None
    assert base64.b64decode(body["audio"]) == WAV


@pytest.fixture
def short_deadline(monkeypatch: pytest.MonkeyPatch) -> None:
    """テストを待たせないために上限だけ縮める。落ち方は本番と同じ経路を通る。"""
    monkeypatch.setattr(voice_router, "SPEAK_DEADLINE_SECONDS", 0.05)


def test_a_slow_screen_read_falls_back_to_a_fixed_line(
    client: TestClient, auth: dict[str, str], short_deadline: None
) -> None:
    # 呼び出し元は 60 秒で諦めるので、それより手前で必ず返す。
    _install(client, _StubVoicevox(), _StubScreenReader(READING, delay=5.0))

    response = client.post(
        "/voice/speak",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["text"]
    assert body["text"] != READING.line
    assert body["from_llm"] is False
    assert "用意できなかった" in body["fallback_reason"]
    assert body["screen"] is None
    assert "用意できなかった" in body["screen_error"]
    assert body["audio"] is None
    assert "用意できなかった" in body["audio_error"]


def test_a_slow_synthesis_also_falls_back(
    client: TestClient, auth: dict[str, str], short_deadline: None
) -> None:
    # 画面が読めても合成で詰まれば同じ。上限は読み取りと合成の合計にかかる。
    _install(client, _StubVoicevox(delay=5.0), _StubScreenReader(READING))

    body = client.post(
        "/voice/speak",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    ).json()

    assert body["text"] != READING.line
    assert body["from_llm"] is False
    assert body["audio"] is None
    assert "用意できなかった" in body["audio_error"]


def test_line_falls_back_when_it_is_too_slow(
    client: TestClient, auth: dict[str, str], short_deadline: None
) -> None:
    _install(client, _StubVoicevox(), _StubScreenReader(READING, delay=5.0))

    response = client.post(
        "/voice/line",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    )

    assert response.status_code == 200
    body = response.json()
    assert body["text"]
    assert body["text"] != READING.line
    assert body["from_llm"] is False
    assert "用意できなかった" in body["fallback_reason"]
    assert body["screen"] is None
    assert "用意できなかった" in body["screen_error"]
    # 読み上げの鍵は返さない。/voice/line は音声を扱わない。
    assert "audio" not in body


def test_screen_reads_the_screenshot_without_making_a_line(
    client: TestClient, auth: dict[str, str]
) -> None:
    # 同封済みの音声を鳴らすモード用。Discord の文面の材料だけが要る。
    voicevox = _StubVoicevox()
    reader = _StubScreenReader(READING)
    _install(client, voicevox, reader)

    response = client.post(
        "/voice/screen",
        json={"idle_seconds": 300, "iphone": "active", "screenshot_png": PNG_B64},
        headers=auth,
    )

    assert response.status_code == 200
    assert response.json() == {
        "screen": {"app": "YouTube", "activity": "料理動画", "category": "slacking"},
        "screen_error": None,
    }
    assert reader.seen == [PNG]
    # セリフも音声も作らない。セリフが壊れていても見立てを捨てないよう、読み取りにも要求しない。
    assert reader.require_line == [False]


def test_screen_passes_the_situation_to_the_reader(
    client: TestClient, auth: dict[str, str]
) -> None:
    reader = _RecordingReader()
    _install(client, _StubVoicevox(), reader)

    client.post(
        "/voice/screen",
        json={
            "idle_seconds": 120,
            "escalation": "expose",
            "iphone": "active",
            "iphone_app": "YouTube",
            "screenshot_png": PNG_B64,
        },
        headers=auth,
    )

    context = reader.contexts[0]
    assert context.idle_seconds == 120
    assert context.escalation is Escalation.EXPOSE
    assert context.iphone is IPhoneState.ACTIVE
    assert context.iphone_app == "YouTube"


def test_screen_without_a_screenshot_says_so(client: TestClient, auth: dict[str, str]) -> None:
    # 読めないことは Discord へ送るのをやめる理由にならないので、200 で理由だけ返す。
    reader = _StubScreenReader(READING)
    _install(client, _StubVoicevox(), reader)

    response = client.post("/voice/screen", json={"idle_seconds": 300}, headers=auth)

    assert response.status_code == 200
    assert response.json()["screen"] is None
    assert "スクリーンショット" in response.json()["screen_error"]
    assert reader.seen == []


def test_screen_without_a_gemini_key_says_so(client: TestClient, auth: dict[str, str]) -> None:
    _install(
        client,
        _StubVoicevox(),
        _StubScreenReader(READING, is_configured=False),
    )

    body = client.post(
        "/voice/screen",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    ).json()

    assert body["screen"] is None
    assert body["screen_error"] == "GEMINI_API_KEY が未設定"


def test_screen_returns_the_reason_when_the_read_fails(
    client: TestClient, auth: dict[str, str]
) -> None:
    _install(
        client,
        _StubVoicevox(),
        _StubScreenReader(ScreenReadError("レート制限に当たった")),
    )

    body = client.post(
        "/voice/screen",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    ).json()

    assert body["screen"] is None
    assert body["screen_error"] == "レート制限に当たった"


def test_screen_falls_back_when_the_read_is_too_slow(
    client: TestClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(voice_router, "SCREEN_DEADLINE_SECONDS", 0.05)
    _install(
        client,
        _StubVoicevox(),
        _StubScreenReader(READING, delay=5.0),
    )

    response = client.post(
        "/voice/screen",
        json={"idle_seconds": 300, "screenshot_png": PNG_B64},
        headers=auth,
    )

    assert response.status_code == 200
    assert response.json()["screen"] is None
    assert "読めなかった" in response.json()["screen_error"]


def test_screen_rejects_a_broken_screenshot(client: TestClient, auth: dict[str, str]) -> None:
    _install(client, _StubVoicevox())

    response = client.post(
        "/voice/screen",
        json={"idle_seconds": 1, "screenshot_png": "これは base64 ではない"},
        headers=auth,
    )

    assert response.status_code == 422
