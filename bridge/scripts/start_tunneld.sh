#!/usr/bin/env bash
# iOS 17+ の developer 系サービス(スクリーンショット含む)を使うのに必要な tunneld を
# root 権限で起動する。
#
# tunneld は RemoteXPC トンネルを維持し続ける常駐プロセスで、root でなければ
# 起動できない。Ctrl-C で終了するまでフォアグラウンドで動き続ける。
# デーモン化したい場合は `nohup` 等で自前にバックグラウンド化すること。
#
# 使い方:
#   bridge/scripts/start_tunneld.sh          # 直接実行(root でなければ自動で sudo する)
#   sudo bridge/scripts/start_tunneld.sh     # 先に sudo を付けてもよい
#
# `uv` が PATH に無い環境向けに `UV_PATH` で明示的に指定できる(ルート README.md の
# 環境変数の説明と同じ探索順)。
#
# `PYMOBILEDEVICE3_PATH` に実行できるバイナリを渡すと、uv を使わずにそれを直接起動する。
# 配布した `Mihari.app` に同梱した `pymobiledevice3` を指すために使う。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

find_uv() {
  if [[ -n "${UV_PATH:-}" ]]; then
    echo "${UV_PATH}"
    return
  fi
  local candidate
  for candidate in "${HOME}/.local/bin/uv" "/opt/homebrew/bin/uv" "/usr/local/bin/uv"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
  command -v uv
}

if [[ -n "${PYMOBILEDEVICE3_PATH:-}" ]]; then
  # 同梱バイナリを渡された場合は uv を一切使わない。
  if [[ ! -x "${PYMOBILEDEVICE3_PATH}" ]]; then
    echo "error: PYMOBILEDEVICE3_PATH が実行できない: ${PYMOBILEDEVICE3_PATH}" >&2
    exit 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "tunneld は root 権限が必要なため、sudo で再実行する。" >&2
    exec sudo "${PYMOBILEDEVICE3_PATH}" remote tunneld
  fi
  exec "${PYMOBILEDEVICE3_PATH}" remote tunneld
fi

UV_BIN="$(find_uv)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "tunneld は root 権限が必要なため、sudo で再実行する。" >&2
  exec sudo "${UV_BIN}" run --project "${BRIDGE_DIR}" pymobiledevice3 remote tunneld
fi

exec "${UV_BIN}" run --project "${BRIDGE_DIR}" pymobiledevice3 remote tunneld
