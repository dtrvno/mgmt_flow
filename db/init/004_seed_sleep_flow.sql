-- Long-running example flow (30s sleep task) for watching the engine spawn
-- and later remove a Docker container in real time, e.g. via `docker ps`.
INSERT INTO flow_definitions (display_id, package_id, name, version, definition)
VALUES (
  'sleep-30',
  NULL,
  'Sleep 30s',
  NULL,
  '{
    "display_id": "sleep-30",
    "name": "Sleep 30s",
    "tasks": [
      {
        "display_id": "long_running_task",
        "plugin_params": { "commands": ["echo starting", "sleep 30", "echo done sleeping"] }
      }
    ]
  }'::jsonb
)
ON CONFLICT (display_id) DO NOTHING;
