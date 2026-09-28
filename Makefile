COVERAGE_DIR ?= coverage

.PHONY: test coverage

test:
	dart test

coverage:
	dart test --coverage=$(COVERAGE_DIR)
	dart run coverage:format_coverage --lcov --in=$(COVERAGE_DIR) --out=$(COVERAGE_DIR)/lcov.info --packages=.dart_tool/package_config.json --report-on=lib
	genhtml $(COVERAGE_DIR)/lcov.info --output-directory $(COVERAGE_DIR)/html
