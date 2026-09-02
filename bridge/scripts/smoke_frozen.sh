#!/usr/bin/env bash
# PyInstaller で固めた device-bridge が、uv も Python も無しで動くことを確かめる。
#
# ビルド直後の bridge/dist/device-bridge/ と、.app に同梱したあとの
# Mihari.app/Contents/Resources/device-bridge/ の両方に対して同じ検査を掛ける。
# 同梱の過程(コピーと再署名)で壊れていないかを見るのが後者の目的。
#
# 使い方:
#   bridge/scripts/smoke_frozen.sh                      # 既定の bridge/dist/device-bridge
#   bridge/scripts/smoke_frozen.sh <ディレクトリ>        # device-bridge と pymobiledevice3 が並ぶ場所
#
# 検査するのは 3 つ。
#   1. `device-bridge list` が JSON を 1 つ返して正常終了する(iPhone が無くても空リストが返る)
#   2. `device-bridge serve` がポートを通知し、認証付きの GET /devices に 200 を返す
#   3. `pymobiledevice3 --help` が正常終了する
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${1:-${BRIDGE_DIR}/dist/device-bridge}"

if [ ! -d "${DIST_DIR}" ]; then
    echo "error: 同梱物のディレクトリが無い: ${DIST_DIR}" >&2
    echo "       先に cd bridge && uv run --group dist pyinstaller device-bridge.spec を実行する" >&2
    exit 1
fi

DEVICE_BRIDGE_BIN="${DIST_DIR}/device-bridge"
PYMOBILEDEVICE3_BIN="${DIST_DIR}/pymobiledevice3"

for binary in "${DEVICE_BRIDGE_BIN}" "${PYMOBILEDEVICE3_BIN}"; do
    if [ ! -x "${binary}" ]; then
        echo "error: 実行できるファイルが無い: ${binary}" >&2
        exit 1
    fi
done

echo "==> 対象: ${DIST_DIR}"

# --- 1. list が JSON を 1 つ返す ------------------------------------------------
echo "==> [1/3] device-bridge list"
LIST_OUTPUT="$("${DEVICE_BRIDGE_BIN}" list)"
echo "    出力: ${LIST_OUTPUT}"
# JSON として読めることを確かめる。python3 は macOS に最初から入っているものでよい
# (ここで検査したいのは同梱物のほうなので、検査する側が uv を使ってはいけない)。
echo "${LIST_OUTPUT}" | /usr/bin/python3 -c 'import json,sys; json.load(sys.stdin)'
echo "    OK: JSON として読めた"

# --- 2. serve がポートを通知し、/devices に 200 を返す --------------------------
echo "==> [2/3] device-bridge serve → GET /devices(トークン認証あり)"
TOKEN="smoke-$(/usr/bin/python3 -c 'import uuid; print(uuid.uuid4())')"
SERVE_STDOUT="$(mktemp)"
SERVE_STDERR="$(mktemp)"
SERVE_PID=""

cleanup_serve() {
    if [ -n "${SERVE_PID}" ] && kill -0 "${SERVE_PID}" 2>/dev/null; then
        kill -TERM "${SERVE_PID}" 2>/dev/null || true
        # 落ちきるのを少し待ってから、まだ生きていれば強制終了する。
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "${SERVE_PID}" 2>/dev/null || break
            sleep 0.5
        done
        kill -KILL "${SERVE_PID}" 2>/dev/null || true
    fi
    rm -f "${SERVE_STDOUT}" "${SERVE_STDERR}"
}
trap cleanup_serve EXIT

"${DEVICE_BRIDGE_BIN}" serve --token "${TOKEN}" > "${SERVE_STDOUT}" 2> "${SERVE_STDERR}" &
SERVE_PID=$!

# stdout に 1 行だけ出るポート通知 {"port": ..., "pid": ...} を待つ。
# 起動直後は import が重いので長めに待つ。
PORT=""
for _ in $(seq 1 120); do
    if [ -s "${SERVE_STDOUT}" ]; then
        PORT="$(/usr/bin/python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    line = f.readline().strip()
print(json.loads(line)["port"] if line else "")
' "${SERVE_STDOUT}" 2>/dev/null || true)"
        [ -n "${PORT}" ] && break
    fi
    if ! kill -0 "${SERVE_PID}" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

if [ -z "${PORT}" ]; then
    echo "error: serve がポートを通知しなかった" >&2
    echo "--- stdout ---" >&2
    cat "${SERVE_STDOUT}" >&2
    echo "--- stderr ---" >&2
    cat "${SERVE_STDERR}" >&2
    exit 1
fi
echo "    ポート通知: $(cat "${SERVE_STDOUT}")"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Mihari-Token: ${TOKEN}" \
    "http://127.0.0.1:${PORT}/devices")"
if [ "${STATUS}" != "200" ]; then
    echo "error: GET /devices が ${STATUS} を返した(200 を期待)" >&2
    echo "--- stderr ---" >&2
    cat "${SERVE_STDERR}" >&2
    exit 1
fi
echo "    OK: GET /devices → 200"

cleanup_serve
SERVE_PID=""
trap - EXIT
echo "    OK: SIGTERM で終了した"

# --- 3. pymobiledevice3 が起動する ---------------------------------------------
echo "==> [3/3] pymobiledevice3 --help"
"${PYMOBILEDEVICE3_BIN}" --help > /dev/null
echo "    OK"

echo ""
echo "==> スモークテスト 3 項目すべて通過: ${DIST_DIR}"
