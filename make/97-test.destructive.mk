DESTRUCTIVE_TEST_DIR:=$(SHELL_TESTS)/destructive

# Prompt the user before running tests that permanently modify local Docker state.
# Requires an interactive terminal (will abort in piped/CI contexts).
test.destructive:
	@printf '\n'; \
	printf 'WARNING: Destructive tests modify your local Docker daemon state.\n'; \
	printf 'All ai-sandbox:* images will be removed. Other images should not\n'; \
	printf 'be affected, but there is no guarantee.\n\n'; \
	if [ ! -t 0 ]; then \
	    printf 'Non-interactive session — aborting. Run from a terminal.\n'; \
	    exit 1; \
	fi; \
	printf 'Type "yes" to continue, anything else to abort: '; \
	read -r _confirm; \
	[ "$$_confirm" = "yes" ] || { printf 'Aborted.\n'; exit 1; }
	@$(SDLC_SHELLSPEC) $(DESTRUCTIVE_TEST_DIR)
.PHONY: test.destructive
