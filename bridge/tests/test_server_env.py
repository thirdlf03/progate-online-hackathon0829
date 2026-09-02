"""認証情報の .env をどの順で読むか。

アプリの設定画面は設定ディレクトリ(既定 ``~/.mihari``)の .env に書き、開発者は
bridge/.env に書く。画面から入れたのに効かない事故を防ぐため、設定ディレクトリ側を
先に読む(``override=False`` なので先に読んだ方が勝つ)。
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from device_bridge.daemon.server import load_env

#: このテストが触るキー。実行環境の値を持ち込まないよう、毎回消してから始める。
KEYS = ("GEMINI_API_KEY", "DISCORD_BOT_TOKEN", "DISCORD_CLIENT_ID")


@pytest.fixture
def env_files(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Path, Path]:
    """設定ディレクトリと bridge/.env の置き場所。対象キーは未設定にしておく。

    ``monkeypatch.delenv`` は元の値(無かったことも含めて)を覚えるので、
    ``load_dotenv`` が os.environ に入れた値もテストの終わりに片付く。
    """
    for key in (*KEYS, "MIHARI_SETTINGS_DIR"):
        monkeypatch.delenv(key, raising=False)
    settings_dir = tmp_path / "settings"
    settings_dir.mkdir()
    return settings_dir, tmp_path / "bridge.env"


def test_settings_env_wins_over_bridge_env(env_files: tuple[Path, Path]) -> None:
    """両方にあるキーは、設定ディレクトリ(= 設定画面が書いた方)が勝つ。"""
    settings_dir, bridge_env = env_files
    (settings_dir / ".env").write_text("DISCORD_BOT_TOKEN=from-settings\n", encoding="utf-8")
    bridge_env.write_text("DISCORD_BOT_TOKEN=from-bridge\n", encoding="utf-8")

    load_env(settings_dir, bridge_env)

    assert os.environ["DISCORD_BOT_TOKEN"] == "from-settings"


def test_bridge_env_fills_the_rest(env_files: tuple[Path, Path]) -> None:
    """設定ディレクトリ側に無いキーは bridge/.env から読む。"""
    settings_dir, bridge_env = env_files
    (settings_dir / ".env").write_text("DISCORD_BOT_TOKEN=from-settings\n", encoding="utf-8")
    bridge_env.write_text("GEMINI_API_KEY=from-bridge\n", encoding="utf-8")

    load_env(settings_dir, bridge_env)

    assert os.environ["DISCORD_BOT_TOKEN"] == "from-settings"
    assert os.environ["GEMINI_API_KEY"] == "from-bridge"


def test_real_environment_wins_over_both(
    env_files: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    """実環境変数はどちらの .env にも上書きされない。"""
    settings_dir, bridge_env = env_files
    monkeypatch.setenv("GEMINI_API_KEY", "from-environment")
    (settings_dir / ".env").write_text("GEMINI_API_KEY=from-settings\n", encoding="utf-8")
    bridge_env.write_text("GEMINI_API_KEY=from-bridge\n", encoding="utf-8")

    load_env(settings_dir, bridge_env)

    assert os.environ["GEMINI_API_KEY"] == "from-environment"


def test_missing_files_are_ignored(env_files: tuple[Path, Path]) -> None:
    """どちらの .env も無いのが既定。読めなくても起動を止めない。"""
    settings_dir, bridge_env = env_files

    load_env(settings_dir, bridge_env)

    assert "GEMINI_API_KEY" not in os.environ


def test_settings_directory_comes_from_environment(
    env_files: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    """設定ディレクトリの場所は ``MIHARI_SETTINGS_DIR`` で決まる。"""
    settings_dir, bridge_env = env_files
    monkeypatch.setenv("MIHARI_SETTINGS_DIR", str(settings_dir))
    (settings_dir / ".env").write_text("DISCORD_CLIENT_ID=123\n", encoding="utf-8")

    load_env(bridge_env=bridge_env)

    assert os.environ["DISCORD_CLIENT_ID"] == "123"
