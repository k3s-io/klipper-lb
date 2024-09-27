UNAME_M = $(shell uname -m)
ARCH=
ifeq ($(UNAME_M), x86_64)
	ARCH=amd64
else ifeq ($(UNAME_M), aarch64)
	ARCH=arm64
else 
	ARCH=$(UNAME_M)
endif

ifndef TARGET_PLATFORMS
	ifeq ($(UNAME_M), x86_64)
		TARGET_PLATFORMS:=linux/amd64
	else ifeq ($(UNAME_M), aarch64)
		TARGET_PLATFORMS:=linux/arm64
	else 
		TARGET_PLATFORMS:=linux/$(UNAME_M)
	endif
endif

ORG ?= rancher
TAG ?= ${GITHUB_ACTION_TAG}
BUILDDATE ?= $(date +%Y%m%d)

IMAGE ?= $(ORG)/klipper-lb:$(TAG)

.DEFAULT_GOAL := ci
.PHONY: ci
ci:
	@. ./scripts/version; docker build --build-arg BUILDDATE=$(date +%Y%m%d) -f Dockerfile -t $${IMAGE} .
	@. ./scripts/version; echo Built $${IMAGE}

.PHONY: push-image
push-image:
	docker buildx build \
		--sbom=true \
		--attest type=provenance,mode=max \
		--platform=$(TARGET_PLATFORMS) \
		--build-arg BUILDDATE=$(BUILDDATE) \
		--tag $(IMAGE) \
		--tag $(IMAGE)-$(ARCH) \
		--push \
		.

PHONY: log
log:
	@echo "ARCH=$(ARCH)"
	@echo "TAG=$(TAG:$(BUILD_META)=)"
	@echo "ORG=$(ORG)"
	@echo "IMAGE=$(IMAGE)"
	@echo "UNAME_M=$(UNAME_M)"
	@echo "TARGET_PLATFORMS=$(TARGET_PLATFORMS)"
