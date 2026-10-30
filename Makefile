.PHONY: build check test-deps test-rex

build:
	cargo build --release --locked

test-deps:
	luarocks --tree .test-deps install luaunit 3.5

check:
	cargo fmt --check
	cargo test --locked
	cargo clippy --locked --all-targets -- -D warnings
	cargo build --locked
	lua tests/test_core.lua
	lua tests/test_guard.lua
	python3 -m unittest discover -s tests -p 'test_terminal.py' -v

# Opt in to isolated live-server tests with REX_FASTCOPY_TEST_REX=/path/to/rex.
test-rex: build
	@test -n "$(REX_FASTCOPY_TEST_REX)" || (echo "Set REX_FASTCOPY_TEST_REX to the Rex CLI path"; exit 1)
	python3 -m unittest discover -s tests -p 'test_rex_capture.py' -v
