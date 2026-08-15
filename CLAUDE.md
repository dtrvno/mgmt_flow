# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

mgmt_flow is an ops dashboard plus a real workflow execution engine: an Express API server backed by Postgres, a RabbitMQ-driven `engine.js` worker that runs workflow tasks inside per-task Docker containers, and a single static HTML dashboard. There is no frontend build step — the entire UI (markup, CSS, JS) lives in `mgmt_flow_dashboard.html`.

## Commands

- Install deps: `npm install`
- Run the API server (needs Postgres + RabbitMQ reachable via `DATABASE_URL` / `RABBITMQ_URL`): `npm start` (runs `node server.js`, listens on `PORT`, default 3000)
- Run the execution engine worker: `node engine.js` (needs Postgres, RabbitMQ, and Docker socket access)
- Full stack via Docker (db + rabbitmq + app + engine, schema auto-applied on first boot): `docker compose up --build`
- No test suite, lint config, or type checker is present in this repo.

## Architecture

- `server.js` — Express app. Defines the legacy JSON API (`workflows`/`jobs`), mounts `routes/flows.js` under `/api`, and serves `mgmt_flow_dashboard.html` as static content.
- `routes/flows.js` — the execution-engine API: `POST /api/flow-definitions` (validate + upsert a workflow JSON definition), `POST /api/flow-definitions/:id/run` (create a `jobs` row + `flow_tasks` rows, publish only the first task to RabbitMQ), `GET /api/flows/:id` (job + its tasks in `seq` order).
- `engine.js` — separate long-running process (own `command:` in docker-compose, same image as `app`). Consumes `mgmt_flow.tasks` from RabbitMQ one task at a time, spawns a Docker container per task via `dockerode` (`alpine:3.20` for `task_type: "shell"`, `python:3.12-alpine` for `"python"`), waits for exit, writes status/exit_code/output back to `flow_tasks`/`jobs`, and publishes the next task in the chain only if the current one succeeded (a failed task stops the chain). Needs `/var/run/docker.sock` mounted — `app` deliberately does not get this mount.
- `db.js` / `queue.js` — shared `pg.Pool` and amqplib channel helpers used by `server.js`, `routes/flows.js`, and `engine.js`.
- `mgmt_flow_dashboard.html` — the entire frontend: layout/CSS in `<style>`, view-switching and API calls in the inline `<script>` at the bottom of the file. Tabs (`overview`, `resources`, `workflow`, `settings`, `admin`, `help`) are plain `<div class="view">` blocks toggled by JS; only `workflow` (job queue) and `settings` (workflow toggles) are wired to the legacy API (`loadJobs()` / `loadWorkflows()`). It does not yet call the flow-definitions/engine API.
- `db/init/001_schema.sql` — original schema + seed data (`workflows`, `jobs`), auto-run by the official `postgres` image's docker-entrypoint-initdb.d on first container start only.
- `db/init/002_execution_engine.sql` — adds `flow_definitions` (JSON workflow definitions, keyed by `display_id`), `flow_tasks` (one row per task execution: `task_type`, `params`, `status`, `container_id`, `exit_code`, `output`), and `jobs.flow_definition_id`. Also idempotent but **only applied automatically on a fresh volume** — on an existing `pgdata` volume it must be applied manually, e.g. `docker exec -i <db-container> psql -U mgmtflow -d mgmtflow < db/init/002_execution_engine.sql`.
- Task type inference (MVP convention, no explicit `type` field in the workflow JSON): a task's `plugin_params.commands` (array) maps to `shell`; `plugin_params.code` (string) maps to `python`. Anything else is rejected with 400 at definition-submit time. The full `plugin_params`/`package_id`/`frontend`-module generality from the original spec, retries/backoff, kill/cancel, and multi-node fan-out (`flow_level` is stored but unused) are all out of scope of the current implementation.

## Local Postgres

`docker-compose.yml` runs Postgres on `5432` with user/db `mgmtflow`/`mgmtflow` and mounts `db/init` for schema bootstrapping. The app container connects via `DATABASE_URL=postgres://mgmtflow:mgmtflow@db:5432/mgmtflow`; when running `server.js` directly on the host against the compose Postgres, use `postgres://mgmtflow:mgmtflow@localhost:5432/mgmtflow` (the server's default).

To pick up schema changes, drop the `pgdata` volume and let Postgres re-run `db/init` on next `docker compose up`.

## Local RabbitMQ

`docker-compose.yml` runs RabbitMQ (`rabbitmq:3.13-management-alpine`) with the default `guest/guest` credentials, AMQP on `5672` and the management UI on `localhost:15672`. `app` publishes the first task of a run; `engine` consumes from and republishes to the single durable queue `mgmt_flow.tasks`.


## Tasks

1 I want create workflow. 
  Workflow represent as json file wiith parameters:
  {
    "display_id": "bootstrap",
    "package_id": "sco_common",
    "name": "Bootstrap",
    "desc": "Bootstrap flow",
    "version": "1.0",
    "flow_level": "Node",
    "frontend": {
        "flow_module": "bootstrap_flow_engine",
        "flow_class": "BootStrapFlowEngine"
    },
   
    "tasks": [
        {
            "display_id": "node_available_space",
            "package_id": "sco_common"
        },
        {
            "display_id": "execute_commands_on_nodes",
            "package_id": "sco_common",
            "name": "Perform prerequisite",
            "plugin_params": {
                "commands": [
                    "mkdir -p /etc/tmpfiles.d",
                    "echo 'd /tmp 1777 root root 20d' > /etc/tmpfiles.d/tmp.conf"
                ]
            }
        }
    ]
  }
 2 That flow as a task store in rabit mq.
 3 Engine read task from rabit mq trigger coresponding docker for execution
 4 docker has a status of execution and it is stored in db
 5 we suppose to have api list running, kill flow, status of flow
 6 task can be python or script, please start with simple task 
