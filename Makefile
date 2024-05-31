.DEFAULT_GOAL := ci
.PHONY: ci
ci:
	@. ./scripts/version; docker build --build-arg BUILDDATE=$(date +%Y%m%d) -f package/Dockerfile -t $${IMAGE} .
	@. ./scripts/version; echo Built $${IMAGE}