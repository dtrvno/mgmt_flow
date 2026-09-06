# Running mgmt_flow (start / stop)

The stack runs on a local `kind` Kubernetes cluster: Postgres, RabbitMQ, the
`mgmt-flow` dashboard/API, and `mgmt-flow-engine` (runs each task as a
Kubernetes Job).

## Quick start

```bash
./scripts/start.sh
```

This will:
- Start Docker Desktop's kind container if it's stopped (e.g. after a reboot)
- Load the `mgmt-flow-static` and `mgmt-flow-engine` images into the cluster
- Apply all manifests in `k8s/`
- Wait for every Deployment to become ready
- Start port-forwards in the background for you

Once it finishes, open:
- **Dashboard:** http://localhost:8080
- **RabbitMQ management UI:** http://localhost:15672 (`guest` / `guest`)

## Quick stop

```bash
./scripts/stop.sh
```

This stops the background port-forwards and scales `mgmt-flow`,
`mgmt-flow-engine`, and `rabbitmq` down to 0 replicas. **Postgres is left
running** so your schema and data stay in place — this is a pause, not a
teardown. If you also want Postgres stopped:

```bash
kubectl scale deployment/postgres --replicas=0
```

## First-time setup (before the scripts will work)

If this is a fresh checkout, build the two images once before running
`start.sh`:

```bash
docker build -t mgmt-flow-static:latest .
docker build -f Dockerfile.engine -t mgmt-flow-engine:latest .
```

If no `kind` cluster exists yet, `start.sh` creates one automatically. If you
prefer to do it yourself first:

```bash
kind create cluster
```

## Manual steps (if you'd rather not use the scripts)

```bash
# 1. Make sure Docker Desktop is running, then confirm the cluster is up
kubectl cluster-info --context kind-kind

# 2. Load images (only needed after building/rebuilding an image)
kind load docker-image mgmt-flow-static:latest
kind load docker-image mgmt-flow-engine:latest

# 3. Apply everything
kubectl apply -k k8s/

# 4. Check status
kubectl get pods

# 5. Port-forward (each needs its own terminal tab, since the command blocks)
kubectl port-forward svc/mgmt-flow 8080:3000
kubectl port-forward svc/rabbitmq 15672:15672
```

To stop manually without the script:

```bash
kubectl scale deployment/mgmt-flow --replicas=0
kubectl scale deployment/mgmt-flow-engine --replicas=0
kubectl scale deployment/rabbitmq --replicas=0
# (leave postgres running, or scale it to 0 too if you want a full stop)
```

## Restarting from scratch (keeping the database)

```bash
kubectl delete deployment mgmt-flow mgmt-flow-engine rabbitmq
kubectl delete service mgmt-flow mgmt-flow-engine rabbitmq
kubectl delete job -l app=mgmt-flow-task
kubectl apply -k k8s/
```

Postgres's Deployment, Service, and PVC are never touched by this, so schema
and data survive. Note RabbitMQ itself has no persistent volume in this
setup, so this also clears any queued/in-flight messages.

## Troubleshooting

- **Port-forward "connection refused" / browser 404:** the `kubectl
  port-forward` process died or was never started in this terminal session —
  re-run it (or `./scripts/start.sh`, which restarts them for you).
- **`ErrImagePull` / `ImagePullBackOff` on mgmt-flow or mgmt-flow-engine:**
  the image was rebuilt but never reloaded into the cluster — run `kind load
  docker-image <image>:latest` again, then `kubectl delete pod -l
  app=<mgmt-flow|mgmt-flow-engine>` to force a retry.
- **`relation "..." does not exist` in the app logs:** this means Postgres
  started with an empty volume and never ran the init scripts in `db/init/`.
  This only happens on a truly fresh PVC — see the "first-time setup" section
  in the main README for how to load the schema manually if it ever comes up
  again.
- **A flow run gets stuck at "queued" forever:** check
  `kubectl get pods -l app=mgmt-flow-engine` — if it's not `Running`, that's
  why nothing is consuming the queue. Check its logs with `kubectl logs -l
  app=mgmt-flow-engine`.
- **After a full Mac/Docker Desktop restart:** everything should come back
  via `./scripts/start.sh` without any data loss — Postgres data lives inside
  the `kind-control-plane` container's filesystem, so it survives
  Docker/Mac restarts but would **not** survive `kind delete cluster` —
  back up with `pg_dump` first if you ever need to do that.
