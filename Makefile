.PHONY: help install build serve check clean

UV ?= uv
PRE_COMMIT ?= pre-commit

help: ## Show available make targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

install: ## Sync Python dependencies with uv
	$(UV) sync

build: ## Build the Zensical static site in strict mode
	$(UV) run zensical build --strict

serve: ## Serve the Zensical site locally with live reload
	$(UV) run zensical serve

check: build ## Run strict site build and pre-commit checks
	$(PRE_COMMIT) run --all-files

clean: ## Remove generated build artifacts and cache
	rm -rf site .cache
