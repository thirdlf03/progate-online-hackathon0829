"""設定ディレクトリの場所。

アプリと bridge が同じ場所を見るための、たった 1 つの決め方。
``MIHARI_SETTINGS_DIR`` があればそこ、無ければ ``~/.mihari``。
Swift 側も ``EnvFileStore`` と ``Uninstaller`` が同じ規則で解決する。
"""

from __future__ import annotations

import os
from pathlib import Path

#: 環境変数での指定が無いときの置き場所。
DEFAULT_DIRECTORY = "~/.mihari"

#: 置き場所を上書きする環境変数。
DIRECTORY_ENV = "MIHARI_SETTINGS_DIR"


def settings_directory(override: str | Path | None = None) -> Path:
    """設定ディレクトリのパス。作りはしない(読む側は無いことを前提にする)。"""
    raw = override or os.environ.get(DIRECTORY_ENV) or DEFAULT_DIRECTORY
    return Path(raw).expanduser()
