# Xylem developer commands. `make` lists them.

.DEFAULT_GOAL := help
.PHONY: help check-claude check-claude-keep test

help:
	@echo "make check-claude       after a Claude Code update: does everything Xylem relies on still work?"
	@echo "                        (runs claude for real in a temp folder, a few Haiku turns, about a cent)"
	@echo "make check-claude-keep  the same, keeping everything it captured for a closer look"
	@echo "make test               unit tests"

check-claude:
	@python3 -I scripts/check-claude.py

check-claude-keep:
	@python3 -I scripts/check-claude.py --keep

test:
	xcodebuild -project Xylem.xcodeproj -scheme Xylem -configuration Debug test \
		-only-testing:XylemTests -derivedDataPath /tmp/xylem-dd-tests -skipPackagePluginValidation \
		DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=-
