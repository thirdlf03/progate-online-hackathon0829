.PHONY: help setup fmt lint lint-swift lint-python build dist test test-swift test-python run kill clean

help:
	@echo "make setup         - bridge/ の Python 依存を同期する(初回セットアップ)"
	@echo "make build         - Mihari.app をビルドして署名する(証明書があれば使う。desktop/README.md 参照)"
	@echo "make run           - Mihari.app をビルドして起動する"
	@echo "make dist          - 配布用の Mihari.app(bridge 同梱・uv 不要)を作って zip に固める"
	@echo "make kill          - 起動中の Mihari と監視プロセス(watchdog)を止める"
	@echo "make test          - Swift / Python のテストを実行する"
	@echo "                     (test-swift / test-python で片側だけ実行できる)"
	@echo "make fmt           - Swift / Python のコードを整形する"
	@echo "make lint          - Swift / Python のフォーマットと lint を検査する"
	@echo "                     (lint-swift / lint-python で片側だけ実行できる)"
	@echo "make clean         - ビルド成果物を削除する"

setup:
	cd bridge && uv sync

build:
	cd desktop && ./build.sh

run:
	cd desktop && ./run.sh

# 配布用。bridge を PyInstaller で固めて .app に同梱し、同梱後のバイナリが本当に
# 動くことを確かめてから zip にする。受け取った人の Mac に uv も Python も要らない。
dist:
	cd desktop && BUNDLE_BRIDGE=1 ./build.sh
	./bridge/scripts/smoke_frozen.sh "$(CURDIR)/desktop/Mihari.app/Contents/Resources/device-bridge"
	@version="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' desktop/Resources/Info.plist)"; \
		rm -f "Mihari-$$version.zip"; \
		ditto -c -k --keepParent desktop/Mihari.app "Mihari-$$version.zip"; \
		echo ""; \
		echo "==> 生成物: $(CURDIR)/Mihari-$$version.zip"

kill:
	cd desktop && ./kill.sh

test: test-swift test-python

test-swift:
	cd desktop && swift test

test-python:
	cd bridge && uv run pytest -q

fmt:
	cd desktop && swift format --in-place --recursive Sources Tests
	cd bridge && uv run ruff format . && uv run ruff check --fix .

lint: lint-swift lint-python

lint-swift:
	cd desktop && swift format lint --strict --recursive Sources Tests

lint-python:
	cd bridge && uv run ruff check . && uv run ruff format --check .

clean:
	rm -rf desktop/.build desktop/Mihari.app
