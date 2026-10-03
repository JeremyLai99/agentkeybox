.PHONY: build test smoke cli-smoke security check doctor run release notarize install-dev

build:
	swift build

test:
	swift test

smoke:
	./Scripts/mcp-smoke-test.sh

cli-smoke:
	./Scripts/cli-smoke-test.sh

security:
	./Scripts/security-static-check.sh

check:
	./Scripts/check-all.sh

doctor:
	$$(swift build --show-bin-path)/akb doctor

run:
	./Scripts/run-dev-macos.sh

release:
	./Scripts/build-release-macos.sh

notarize:
	./Scripts/notarize-release-macos.sh

install-dev:
	./Scripts/install-dev-macos.sh
