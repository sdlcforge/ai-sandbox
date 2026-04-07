.PHONY: build lint qa test test.all test.unit test.integration

SHELLSCRIPTS := $(shell find scripts -type f -name '*.sh') $(shell find spec -type f -name '*.sh')
SRC_SCRIPTS := ./scripts/index.sh $(shell find scripts/ -type f -name '*.sh' -not -path 'scripts/index.sh')
DOCKER_FILES := $(shell find docker -type f)
BASH_ROLLUP := npx bash-rollup
BIN_OUT := ./bin/ai-sandbox.sh

## !category Build
## Builds the script. At the moment, this is actually a noop.
build: $(BIN_OUT)

$(BIN_OUT): $(SRC_SCRIPTS)
	$(BASH_ROLLUP) $< $@

## !category QA
## Runs all linting checks.
lint: $(SHELLSCRIPTS)
	shellcheck -P scripts $(SHELLSCRIPTS)

## Runs all QA checks; linting and tests.
qa: lint test.all

## Runs all unit and integration tests.
test: test.unit

test.all: test.unit test.integration

## Runs all unit tests. This covers local scripts without involving Docker.
test.unit: $(SHELLSCRIPTS) build
	shellspec spec/unit

## Runs all integration tests. This involves running the playground on a Docker container and testing its behavior there.
test.integration: $(SHELLSCRIPTS) $(DOCKER_FILES) build
	shellspec spec/integration
