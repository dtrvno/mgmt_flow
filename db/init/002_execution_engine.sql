-- Workflow execution engine: JSON flow definitions, and per-task execution
-- rows for a run (jobs stays the "run" row; flow_tasks is the task detail).

CREATE TABLE IF NOT EXISTS flow_definitions (
  id            SERIAL PRIMARY KEY,
  display_id    TEXT NOT NULL UNIQUE,
  package_id    TEXT,
  name          TEXT NOT NULL,
  version       TEXT,
  definition    JSONB NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE jobs ADD COLUMN IF NOT EXISTS flow_definition_id INTEGER REFERENCES flow_definitions(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS flow_tasks (
  id            SERIAL PRIMARY KEY,
  job_id        INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  seq           INTEGER NOT NULL,
  display_id    TEXT NOT NULL,
  task_type     TEXT NOT NULL CHECK (task_type IN ('shell','python')),
  params        JSONB NOT NULL,
  status        TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','complete','failed')),
  container_id  TEXT,
  exit_code     INTEGER,
  output        TEXT,
  started_at    TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_flow_tasks_job_id ON flow_tasks(job_id);
CREATE INDEX IF NOT EXISTS idx_flow_tasks_status ON flow_tasks(status);
