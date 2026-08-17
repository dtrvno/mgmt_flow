# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

mgmt_flow is an ops dashboard plus a real workflow execution engine: a Node/Express API server backed by Postgres, a **Python/Flask** RabbitMQ-driven worker (`engine/app.py`) that runs workflow tasks inside per-task Docker containers, and a single static HTML dashboard. There is no frontend build step — the entire UI (markup, CSS, JS) lives in `mgmt_flow_dashboard.html`. The stack is intentionally polyglot: Node owns the HTTP API, Python owns task execution, and RabbitMQ is the only thing connecting them (JSON messages on one queue — neither side has a language-specific dependency on the other).

## Commands

- Node side: `npm install`; run the API server (needs Postgres + RabbitMQ reachable via `DATABASE_URL` / `RABBITMQ_URL`): `npm start` (runs `node server.js`, listens on `PORT`, default 3000)
- Python side: `pip install -r engine/requirements.txt`; run the execution engine: `python engine/app.py` (needs Postgres, RabbitMQ, and Docker socket access; serves `/health` on port 5000)
- Full stack via Docker (db + rabbitmq + app + engine, schema auto-applied on first boot): `docker compose up --build`
- No test suite, lint config, or type checker is present in this repo (either side).

## Architecture

- `server.js` — Express app. Defines the legacy JSON API (`workflows`/`jobs`), mounts `routes/flows.js` under `/api`, and serves `mgmt_flow_dashboard.html` as static content.
- `routes/flows.js` — the execution-engine-facing API: `POST /api/flow-definitions` (validate + upsert a workflow JSON definition), `POST /api/flow-definitions/:id/run` (accepts either the numeric id or the `display_id`; creates a `jobs` row + `flow_tasks` rows, publishes only the first task to RabbitMQ), `GET /api/flows/:id` (job + its tasks in `seq` order).
- `db.js` / `queue.js` — shared `pg.Pool` and amqplib channel helpers used by `server.js` and `routes/flows.js` (Node only publishes; it never consumes `mgmt_flow.tasks`).
- **`engine/app.py`** — the execution engine, a Flask app (`docker-compose`'s `engine` service, built from `Dockerfile.engine`, a separate Python image from `app`). A background thread runs a blocking `pika` consumer on `mgmt_flow.tasks`; the Flask main thread just serves `GET /health` (port 5000, published as `localhost:5001` in compose) — Flask itself does no task-routing, it's there so the engine is an inspectable service rather than a bare script. Per task: spawns a Docker container via the `docker` SDK (`alpine:3.20` for `task_type: "shell"`, `python:3.12-alpine` for `"python"`), waits for exit, writes status/exit_code/output back to `flow_tasks`/`jobs` via a lock-guarded shared `psycopg2` connection, and publishes the next task in the chain only if the current one succeeded (a failed task stops the chain). Needs `/var/run/docker.sock` mounted — `app` deliberately does not get this mount. No reconnect/backoff logic: an AMQP failure calls `os._exit(1)` so `restart: unless-stopped` bounces the container (a plain daemon-thread exception would otherwise die silently and leave Flask up with no consumer).
- `mgmt_flow_dashboard.html` — the entire frontend: layout/CSS in `<style>`, view-switching and API calls in the inline `<script>` at the bottom of the file. Tabs (`overview`, `resources`, `workflow`, `settings`, `admin`, `help`) are plain `<div class="view">` blocks toggled by JS. `workflow` has two "Run \<flow\> flow" buttons (`.run-flow-btn`, keyed by `data-flow`) that POST to `/api/flow-definitions/:display_id/run` and poll `GET /api/flows/:id` every second to render live per-task status until terminal; `settings` still only drives the legacy `workflows` toggle API.
- `db/init/001_schema.sql` — original schema + seed data (`workflows`, `jobs`), auto-run by the official `postgres` image's docker-entrypoint-initdb.d on first container start only.
- `db/init/002_execution_engine.sql` — adds `flow_definitions` (JSON workflow definitions, keyed by `display_id`), `flow_tasks` (one row per task execution: `task_type`, `params`, `status`, `container_id`, `exit_code`, `output`), and `jobs.flow_definition_id`.
- `db/init/003_seed_default_flow.sql` / `004_seed_sleep_flow.sql` — seed two example flows: `bootstrap` (instant, `mkdir`+`echo`) and `sleep-30` (a `sleep 30` shell task, useful for watching `docker ps` show the spawned container live). All three `00N_*.sql` files are idempotent but **only applied automatically on a fresh volume** — on an existing `pgdata` volume, apply manually: `docker exec -i <db-container> psql -U mgmtflow -d mgmtflow < db/init/00N_*.sql`.
- Task type inference (MVP convention, no explicit `type` field in the workflow JSON): a task's `plugin_params.commands` (array) maps to `shell`; `plugin_params.code` (string) maps to `python`. Anything else is rejected with 400 at definition-submit time. The full `plugin_params`/`package_id`/`frontend`-module generality from the original spec, retries/backoff, kill/cancel, and multi-node fan-out (`flow_level` is stored but unused) are all out of scope of the current implementation.

## Local Postgres

`docker-compose.yml` runs Postgres on `5432` with user/db `mgmtflow`/`mgmtflow` and mounts `db/init` for schema bootstrapping. The app container connects via `DATABASE_URL=postgres://mgmtflow:mgmtflow@db:5432/mgmtflow`; when running `server.js` directly on the host against the compose Postgres, use `postgres://mgmtflow:mgmtflow@localhost:5432/mgmtflow` (the server's default).

To pick up schema changes, drop the `pgdata` volume and let Postgres re-run `db/init` on next `docker compose up`.

## Local RabbitMQ

`docker-compose.yml` runs RabbitMQ (`rabbitmq:3.13-management-alpine`) with the default `guest/guest` credentials, AMQP on `5672` and the management UI on `localhost:15672`. `app` (Node) publishes the first task of a run; `engine` (Python) consumes from and republishes to the single durable queue `mgmt_flow.tasks`.
