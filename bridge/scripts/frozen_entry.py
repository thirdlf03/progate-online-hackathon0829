"""PyInstaller で固めた ``device-bridge`` のエントリポイント。

`.app` に同梱するバイナリはここから始まる。`[project.scripts]` の
``device_bridge.cli:main`` と中身は同じだが、凍結時だけ必要な
``multiprocessing.freeze_support()`` を先に呼ぶ点が違う。

凍結したプロセスでは子プロセスが「アプリ本体をもう一度起動する」形で作られるため、
これを呼ばないと子が親の処理をやり直して無限に増える(PyInstaller の必須事項)。
"""

import multiprocessing
import sys

from device_bridge.cli import main

if __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.exit(main())
