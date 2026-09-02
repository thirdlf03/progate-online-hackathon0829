# -*- mode: python ; coding: utf-8 -*-
"""配布用 `.app` に同梱する device-bridge を PyInstaller で固める設定。

ユーザーの Mac に uv も Python も要らない状態で `Mihari.app` を動かすためのもの。
`desktop/build.sh` が `BUNDLE_BRIDGE=1` のときだけ、ここで出来た
`dist/device-bridge/` を `Mihari.app/Contents/Resources/device-bridge/` へ丸ごと入れる。

    cd bridge && uv run --group dist pyinstaller device-bridge.spec

onedir(1 ディレクトリ)で作る。onefile は `.app` への同梱には公式に非推奨
(起動のたびに一時ディレクトリへ展開するため、署名と TCC の同一性が壊れる)。

実行ファイルは 2 本入る。

- `device-bridge`  … アプリが子プロセスとして常駐させる本体
- `pymobiledevice3` … tunneld(`pymobiledevice3 remote tunneld`)を root で起動する側が使う

2 本は同じ COLLECT を共有するので、Python ランタイムと依存は 1 組しか入らない。
"""

from pathlib import Path

from PyInstaller.utils.hooks import collect_all, collect_submodules, copy_metadata

BRIDGE_DIR = Path(SPECPATH)  # noqa: F821 - PyInstaller が spec に注入する

#: まるごと集める必要があるパッケージ。
#:
#: pyinstaller-hooks-contrib にフックがあるもの(uvicorn / pydantic / usb)は放っておいても
#: 拾われる。ここに並ぶのはフックが無く、かつ動的 import かデータファイルを持つもの。
#:
#: - pymobiledevice3: サブコマンドを `importlib.import_module` で引くうえ、
#:   DeveloperDiskImage の一覧などのデータファイルを同梱している
#: - construct / qh3: pymobiledevice3 がプロトコル定義と QUIC 実装に使う
#: - typer / typer_injector / click: pymobiledevice3 の CLI 土台
#: - discord / google.genai: bridge が実行時に遅延 import する
_COLLECT_ALL = (
    "pymobiledevice3",
    "construct",
    "qh3",
    "typer",
    "typer_injector",
    "click",
    "discord",
    "google.genai",
)

datas = []
binaries = []
hiddenimports = []

for package in _COLLECT_ALL:
    package_datas, package_binaries, package_hiddenimports = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_hiddenimports

# device_bridge 自身も、ルーターなどが遅延 import される経路があるので全部入れる。
hiddenimports += collect_submodules("device_bridge")

# `importlib.metadata.version(...)` を import 時に呼ぶパッケージがある(apple_compress など)。
# dist-info を入れておかないと `PackageNotFoundError` で起動時に落ちる。
# recursive=True で依存ツリーぶんまとめて入れる。
for package in ("pymobiledevice3", "fastapi", "uvicorn", "google-genai", "discord.py"):
    datas += copy_metadata(package, recursive=True)

common = dict(
    pathex=[str(BRIDGE_DIR / "src")],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)

bridge_analysis = Analysis(  # noqa: F821
    [str(BRIDGE_DIR / "scripts" / "frozen_entry.py")],
    **common,
)

pymobiledevice3_analysis = Analysis(  # noqa: F821
    [str(BRIDGE_DIR / "scripts" / "frozen_pymobiledevice3.py")],
    **common,
)

bridge_exe = EXE(  # noqa: F821
    PYZ(bridge_analysis.pure),  # noqa: F821
    bridge_analysis.scripts,
    [],
    exclude_binaries=True,
    name="device-bridge",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

pymobiledevice3_exe = EXE(  # noqa: F821
    PYZ(pymobiledevice3_analysis.pure),  # noqa: F821
    pymobiledevice3_analysis.scripts,
    [],
    exclude_binaries=True,
    name="pymobiledevice3",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

# 2 本の実行ファイルを 1 つのディレクトリにまとめる。依存は同じ venv から来るので、
# 重複するファイルは COLLECT 側で 1 つに畳まれる。
coll = COLLECT(  # noqa: F821
    bridge_exe,
    bridge_analysis.binaries,
    bridge_analysis.datas,
    pymobiledevice3_exe,
    pymobiledevice3_analysis.binaries,
    pymobiledevice3_analysis.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="device-bridge",
)
