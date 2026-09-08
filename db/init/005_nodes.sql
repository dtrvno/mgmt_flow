-- Managed nodes: one row per physical/virtual node, keyed by a generated
-- UUID, with all node parameters (BMC/mgmt IPs, credentials, etc.) held in
-- a single JSONB blob rather than fixed columns, since the parameter set
-- is expected to grow (MVP fields: hostname, bmc_ip, mgmt_ip, bmc_user,
-- bmc_password, node_user, node_password).

CREATE TABLE IF NOT EXISTS nodes (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  params        JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_nodes_hostname ON nodes ((params->>'hostname'));
