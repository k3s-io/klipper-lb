DOCKER_ARGS=
ifeq ($(ARCH),riscv64)
	export DOCKER_BUILDKIT = 1
	DOCKER_ARGS=--platform=linux/riscv64
endif

.DEFAULT_GOAL := ci
.PHONY: ci
ci:
	@. ./scripts/version; docker build ${DOCKER_ARGS} --build-arg BUILDDATE=$(date +%Y%m%d) -f Dockerfile -t $${IMAGE} .
	@. ./scripts/version; echo Built $${IMAGE}