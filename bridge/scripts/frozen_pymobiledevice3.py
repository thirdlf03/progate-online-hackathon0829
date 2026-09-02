"""PyInstaller で固めた ``pymobiledevice3`` CLI のエントリポイント。

tunneld(`install_tunneld_daemon.sh` / `start_tunneld.sh`)は
``pymobiledevice3 remote tunneld`` を別プロセスとして root で起動する。
uv も Python も無い環境ではこのコマンドも同梱物から供給する必要があるため、
`device-bridge` と同じ COLLECT に 2 本目の実行ファイルとして入れる。
"""

import multiprocessing
import sys

from pymobiledevice3.__main__ import main

if __name__ == "__main__":
    multiprocessing.freeze_support()
    main()
    sys.exit(0)
