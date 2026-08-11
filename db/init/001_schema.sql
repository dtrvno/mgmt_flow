-- mgmt_flow schema: workflows (automation rules / pipeline definitions)
-- and jobs (individual pipeline runs, shown in the Workflow queue view)

CREATE TABLE IF NOT EXISTS workflows (
  id            SERIAL PRIMARY KEY,
  name          TEXT NOT NULL,
  description   TEXT,
  schedule      TEXT,                 -- e.g. cron expr or human trigger condition
  is_active     BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS jobs (
  id            SERIAL PRIMARY KEY,
  workflow_id   INTEGER REFERENCES workflows(id) ON DELETE SET NULL,
  name          TEXT NOT NULL,
  status        TEXT NOT NULL CHECK (status IN ('queued','running','complete','failed')),
  progress      INTEGER NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  triggered_by  TEXT,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_jobs_workflow_id ON jobs(workflow_id);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);

-- Seed: automation rules (workflows)
INSERT INTO workflows (name, description, schedule, is_active) VALUES
  ('Auto-scale worker pool', 'Add nodes when CPU > 75% for 5 min', 'cpu_threshold', true),
  ('Burst-protect rate limiting', 'Raise limits temporarily under load spikes', 'load_spike', true),
  ('Nightly backups', 'Snapshot all prod databases', '0 23 * * *', true),
  ('Auto-restart failed pipelines', 'Retry once before paging on-call', 'on_failure', false),
  ('Cost anomaly detection', 'Alert on spend > 20% above 7-day average', 'daily', true);

-- Seed: pipeline runs (jobs)
INSERT INTO jobs (workflow_id, name, status, progress, triggered_by, started_at, completed_at) VALUES
  (NULL, 'deploy-prod-api-gateway', 'running', 70, 'dtrubitsyn', now() - interval '2 minutes', NULL),
  (3,    'nightly-backup-db-cluster', 'queued', 0, 'schedule', NULL, NULL),
  (NULL, 'migrate-schema-billing-service', 'failed', 60, 'dtrubitsyn', now() - interval '25 minutes', now() - interval '18 minutes'),
  (NULL, 'rotate-secrets-auth-service', 'complete', 100, 'svc-ci-runner', now() - interval '50 minutes', now() - interval '38 minutes');
