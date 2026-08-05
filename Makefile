# Solar System — build, push, deploy on k3s (visora)

REGISTRY   ?= ziyadtarek99
IMAGE      ?= solar-system
TAG        ?= v1
NAMESPACE  ?= solar-system
KUBECONFIG ?= $(HOME)/.kube/config-visora
HOST       ?= solar-system.randomitilabs.dpdns.org
NODE_PORT  ?= 30080

export KUBECONFIG

KUBECTL = kubectl
DOCKER  = docker
BUILD_PLATFORM ?= linux/amd64
FULL_IMAGE = $(REGISTRY)/$(IMAGE):$(TAG)
K8S_DIR = kubernetes
DEPS_DIR = $(K8S_DIR)/dependencies

.PHONY: help build push build-push deploy-deps deploy-manifests deploy status wait test test-ingress logs undeploy clean

help:
	@echo "Solar System Kubernetes lab"
	@echo ""
	@echo "  make deploy-deps        One-time: namespace + MongoDB (cluster admin)"
	@echo "  make build              Build $(FULL_IMAGE)"
	@echo "  make push               Push image to Docker Hub"
	@echo "  make build-push         Build and push"
	@echo "  make deploy-manifests   Apply app manifests only (0-2)"
	@echo "  make deploy             Build, push, and deploy app"
	@echo "  make status             Show resources in $(NAMESPACE)"
	@echo "  make wait               Wait until app is ready"
	@echo "  make test               Smoke-test via NodePort $(NODE_PORT)"
	@echo "  make test-ingress       Smoke-test https://$(HOST)"
	@echo "  make logs               Tail app logs"
	@echo "  make undeploy           Delete app resources (keeps MongoDB)"
	@echo "  make clean              Delete namespace $(NAMESPACE) + local image"
	@echo ""
	@echo "Variables: REGISTRY=$(REGISTRY) TAG=$(TAG) KUBECONFIG=$(KUBECONFIG)"

build:
	$(DOCKER) build --platform $(BUILD_PLATFORM) -t $(FULL_IMAGE) .

push:
	$(DOCKER) push $(FULL_IMAGE)

build-push: build push

# Cluster admin — run once per cluster/lab
deploy-deps:
	$(KUBECTL) apply -f $(DEPS_DIR)/
	$(KUBECTL) wait --for=condition=ready pod -l app=mongodb -n $(NAMESPACE) --timeout=180s

# App only (CI/CD applies these)
deploy-manifests:
	$(KUBECTL) apply -f $(K8S_DIR)/0-deployment.yaml
	$(KUBECTL) apply -f $(K8S_DIR)/1-service.yaml
	$(KUBECTL) apply -f $(K8S_DIR)/2-ingress.yaml

deploy: build-push deploy-manifests
	@echo "Deployed $(FULL_IMAGE). Run 'make wait' then 'make test'."

status:
	$(KUBECTL) get all,ingress,pvc,secret,configmap -n $(NAMESPACE)

wait:
	$(KUBECTL) wait --for=condition=available deployment/solar-system -n $(NAMESPACE) --timeout=180s

test: wait
	@NODE_IP=$$($(KUBECTL) get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $$1}'); \
	URL="http://$$NODE_IP:$(NODE_PORT)"; \
	echo "Testing $$URL ..."; \
	curl -sf "$$URL/live" | grep -q live && echo "live OK" || { echo "live FAILED"; exit 1; }; \
	curl -sf "$$URL/ready" | grep -q ready && echo "ready OK" || { echo "ready FAILED"; exit 1; }; \
	curl -sf -X POST "$$URL/planet" -H 'Content-Type: application/json' -d '{"id":3}' | grep -q Earth && echo "planet OK" || { echo "planet FAILED"; exit 1; }; \
	echo "All NodePort smoke tests passed."

test-ingress: wait
	@echo "Testing https://$(HOST)/live ..."
	@curl -sf "https://$(HOST)/live" | grep -q live && echo "live OK" || (echo "live FAILED"; exit 1)
	@curl -sf -X POST "https://$(HOST)/planet" -H 'Content-Type: application/json' -d '{"id":3}' | grep -q Earth && echo "planet OK" || (echo "planet FAILED"; exit 1)
	@echo "All Ingress smoke tests passed."

logs:
	$(KUBECTL) logs -n $(NAMESPACE) -l app=solar-system --tail=50 --prefix=true

undeploy:
	-$(KUBECTL) delete -f $(K8S_DIR)/2-ingress.yaml --ignore-not-found
	-$(KUBECTL) delete -f $(K8S_DIR)/1-service.yaml --ignore-not-found
	-$(KUBECTL) delete -f $(K8S_DIR)/0-deployment.yaml --ignore-not-found

clean: undeploy
	-$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) wait --for=delete namespace/$(NAMESPACE) --timeout=120s 2>/dev/null || true
	-$(DOCKER) rmi $(FULL_IMAGE) 2>/dev/null
