.PHONY: lint qa test test-unit test-integration

SHELLSCRIPTS := $(shell find . -type f -name '*.sh')
DOCKER_FILES := $(shell find docker -type f)

## !category QA
## Runs all linting checks.
lint: $(SHELLSCRIPTS)
	shellcheck $(SHELLSCRIPTS)

## Runs all QA checks; linting and tests.
qa: lint test

## Runs all unit and integration tests.
test: test.unit test.integration

## Runs all unit tests. This covers local scripts without involving Docker.
test.unit: $(SHELLSCRIPTS)
	shellspec spec/unit

## Runs all integration tests. This involves running the playground on a Docker container and testing its behavior there.
test.integration: $(SHELLSCRIPTS) $(DOCKER_FILES)
	shellspec spec/integration
