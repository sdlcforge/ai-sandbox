reset-docker-images:
	@IMAGES=$$(docker images --format '{{.Repository}}:{{.Tag}}' \
	    | awk -F: '$$1 == "ai-sandbox" {print}'); \
	if [ -n "$$IMAGES" ]; then \
	    docker image rm -f $$IMAGES; \
	    echo "Removed:"; \
	    printf '  %s\n' $$IMAGES; \
	else \
	    echo "No ai-sandbox images found."; \
	fi
.PHONY: reset-docker-images
