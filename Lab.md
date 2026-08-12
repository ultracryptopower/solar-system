# Solar System Lab — Local Demo (full runbook)

Instructor runbook to demo the app **locally** before CI/CD + Kubernetes.

**Idea to repeat for students:**

| Layer | Local | Later (cluster / CI) |
|-------|--------|----------------------|
| Database | `docker compose` Mongo + mongo-express | `kubernetes/dependencies/` (manual) |
| Seed | Import `data/planets.json` in UI | Mongo init ConfigMap |
| App | `npm start` or Docker image | CI builds/pushes image + applies app manifests |
| Tests | `npm test` against local Mongo | Same tests against Actions Mongo **service** |

---

## 0) Prerequisites

- Docker Desktop running
- Node.js 18+ and npm
- Repo cloned

```bash
cd ~/Desktop/solar-system
```

Optional helpers:

```bash
make help
```

---

## 1) Start MongoDB + mongo-express

Compose brings **only the database stack** — not the app.

```bash
docker compose up -d
docker compose ps
```

Both services should be **Up** (mongo healthy).

| Service | URL / port | Credentials |
|---------|------------|-------------|
| MongoDB | `localhost:27017` | `admin` / `password` |
| mongo-express | http://localhost:30081 | `mongoexpressuser` / `mongoexpresspass` |

Shortcut:

```bash
make local-db
```

---

## 2) Seed planets from the UI

1. Open http://localhost:30081  
2. Login: `mongoexpressuser` / `mongoexpresspass`  
3. Create database: **`solar-system`**  
4. Create collection: **`planets`**  
5. Open **planets** → **Import** / Import File  
6. Choose repo file: `data/planets.json`  
7. Confirm documents (Sun + 8 planets)

**Talking point:** same planet data the cluster Mongo init script loads automatically from `kubernetes/dependencies/2-mongodb-seed-configmap.yaml`.

---

## 3) Install app dependencies (once)

```bash
cp .env.example .env
npm install
```

`.env` values (host → compose Mongo):

```env
MONGO_URI=mongodb://localhost:27017/solar-system?authSource=admin
MONGO_USERNAME=admin
MONGO_PASSWORD=password
NODE_ENV=development
```

Export into the current shell before tests/start:

```bash
set -a && source .env && set +a
```

---

## 4) Run unit tests (same commands as CI Tests job)

Order matches the pipeline: **DB up → seed → test → coverage**.

```bash
set -a && source .env && set +a

npm test                 # mocha → test-results.xml
npm run coverage         # nyc (CI allows soft-fail)
```

**Talking points:**

- `npm test` is what GitHub Actions runs — not a special Actions command.
- Locally Mongo is compose; in CI it is a **service container** on the runner.
- That CI Mongo is **not** the k3s Mongo.

Quick check that seed + API agree (optional, after `npm start` in next step):

```bash
curl -s -X POST http://localhost:3000/planet \
  -H 'Content-Type: application/json' \
  -d '{"id":3}'
# expect JSON with "name":"Earth"
```

---

## 5) Run the application

### Path A — Node on the host (simplest for live demo)

```bash
set -a && source .env && set +a
npm start
```

App: http://localhost:3000  

Stop with `Ctrl+C`.

### Path B — Docker image (closer to CI/CD)

Container cannot use `localhost` for Mongo on the Mac host — use `host.docker.internal`.

```bash
make local-app
```

Or manually:

```bash
docker build --platform linux/amd64 -t solar-system:local .

docker run --rm -p 3000:3000 \
  -e MONGO_URI='mongodb://host.docker.internal:27017/solar-system?authSource=admin' \
  -e MONGO_USERNAME=admin \
  -e MONGO_PASSWORD=password \
  -e NODE_ENV=development \
  solar-system:local
```

App: http://localhost:3000  

Smoke:

```bash
curl -s http://localhost:3000/live
curl -s http://localhost:3000/ready
curl -s -X POST http://localhost:3000/planet \
  -H 'Content-Type: application/json' \
  -d '{"id":3}'
```

---

## 6) Simulate CI image-tag rewrite (`sed` on macOS)

Pipeline (Linux runner) does roughly:

```bash
sed -i "s|image: ziyadtarek99/solar-system:.*|image: ziyadtarek99/solar-system:${GITHUB_SHA}|" \
  kubernetes/0-deployment.yaml
```

On **macOS** (BSD `sed`), use `sed -i ''`:

```bash
cd ~/Desktop/solar-system

# show before
grep 'image:' kubernetes/0-deployment.yaml

# pretend github.sha = current commit
SHA=$(git rev-parse HEAD)

sed -i '' "s|image: ziyadtarek99/solar-system:.*|image: ziyadtarek99/solar-system:${SHA}|" \
  kubernetes/0-deployment.yaml

# show after
grep 'image:' kubernetes/0-deployment.yaml
```

Restore after the demo:

```bash
git checkout -- kubernetes/0-deployment.yaml
```

**Talking point:** CI rewrites the tag in the runner checkout, then `kubectl apply`s app manifests only — it does **not** apply `kubernetes/dependencies/`.

---

## 7) Tear down local stack

```bash
# stop npm start / docker run first
docker compose down
# or: make local-db-down
```

---

## Cheat sheet

```bash
# DB
make local-db
# → seed via http://localhost:30081  (mongoexpressuser / mongoexpresspass)
# → DB solar-system / collection planets / import data/planets.json

# App + tests
cp .env.example .env
set -a && source .env && set +a
npm install
npm test
npm run coverage
npm start                    # http://localhost:3000

# Or containerized app
make local-app

# Simulate deploy sed (Mac)
SHA=$(git rev-parse HEAD)
sed -i '' "s|image: ziyadtarek99/solar-system:.*|image: ziyadtarek99/solar-system:${SHA}|" \
  kubernetes/0-deployment.yaml
git checkout -- kubernetes/0-deployment.yaml   # restore

# Cleanup
docker compose down
```

---

## Appendix — what comes next (cluster + CI, not local)

Do this **after** the local demo, on the k3s cluster.

### A) Manual deps (instructor / cluster admin)

```bash
export KUBECONFIG=~/.kube/config-visora
make deploy-deps
# applies kubernetes/dependencies/  → namespace, secrets, MongoDB + seed
```

### B) GitHub secrets / vars (once)

- `vars.DOCKERHUB_USERNAME`
- `secrets.DOCKERHUB_TOKEN`
- `secrets.KUBECONFIG` (contents of `~/.kube/config-visora`)

### C) Run the workflow

Workflow is **`workflow_dispatch` only** (push does not auto-run).

Actions → **Solar System CI/CD** → **Run workflow**

Flow: **tests → build & push → deploy app** (`kubernetes/0-deployment.yaml`, `1-service.yaml`, `2-ingress.yaml` only).

### D) Verify on cluster

```bash
export KUBECONFIG=~/.kube/config-visora
make status
make test              # NodePort :30080
make test-ingress      # https://solar-system.randomitilabs.dpdns.org
```
