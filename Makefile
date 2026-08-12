# Solar System — local + k3s lab helpers

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

.PHONY: help local-db local-db-down local-app build push build-push deploy-deps deploy-manifests deploy status wait test test-ingress logs undeploy clean

help:
	@echo "Solar System lab"
	@echo ""
	@echo "Local:"
	@echo "  make local-db           Start MongoDB + mongo-express (seed via UI :30081)"
	@echo "  make local-db-down      Stop local DB stack"
	@echo "  make local-app          Build Dockerfile and run app → host MongoDB"
	@echo ""
	@echo "Cluster (KUBECONFIG=$(KUBECONFIG)):"
	@echo "  make deploy-deps        One-time: namespace + secrets + MongoDB seed"
	@echo "  make build / push       Docker image $(FULL_IMAGE)"
	@echo "  make deploy-manifests   Apply app only (0-2) — same as CI"
	@echo "  make deploy             Build, push, deploy app"
	@echo "  make status | wait | test | test-ingress | logs"
	@echo "  make undeploy           Delete app (keeps MongoDB)"
	@echo "  make clean              Delete namespace $(NAMESPACE)"

# --- Local (docker-compose Mongo + app container) ---

local-db:
	docker compose up -d
	@echo "MongoDB:       localhost:27017  (admin/password)"
	@echo "mongo-express: http://localhost:30081  (mongoexpressuser/mongoexpresspass)"
	@echo "Seed: create DB solar-system → collection planets → import data/planets.json"

local-db-down:
	docker compose down

local-app:
	$(DOCKER) build --platform $(BUILD_PLATFORM) -t solar-system:local .
	$(DOCKER) run --rm -p 3000:3000 \
		-e MONGO_URI='mongodb://host.docker.internal:27017/solar-system?authSource=admin' \
		-e MONGO_USERNAME=admin \
		-e MONGO_PASSWORD=password \
		-e NODE_ENV=development \
		solar-system:local

# --- Image ---

build:
	$(DOCKER) build --platform $(BUILD_PLATFORM) -t $(FULL_IMAGE) .

push:
	$(DOCKER) push $(FULL_IMAGE)

build-push: build push

# --- Cluster admin (once) ---

deploy-deps:
	$(KUBECTL) apply -f $(DEPS_DIR)/
	$(KUBECTL) wait --for=condition=ready pod -l app=mongodb -n $(NAMESPACE) --timeout=180s

# --- App only (CI applies these) ---

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
	-$(DOCKER) rmi $(FULL_IMAGE) 2>/dev/null || true
