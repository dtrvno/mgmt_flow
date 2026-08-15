-- Default example flow definition, runnable from the dashboard's Workflow tab.
INSERT INTO flow_definitions (display_id, package_id, name, version, definition)
VALUES (
  'bootstrap',
  'sco_common',
  'Bootstrap',
  '1.0',
  '{
    "display_id": "bootstrap",
    "package_id": "sco_common",
    "name": "Bootstrap",
    "desc": "Bootstrap flow",
    "version": "1.0",
    "flow_level": "Node",
    "tasks": [
      {
        "display_id": "execute_commands_on_nodes",
        "package_id": "sco_common",
        "name": "Perform prerequisite",
        "plugin_params": {
          "commands": [
            "mkdir -p /etc/tmpfiles.d",
            "echo ''d /tmp 1777 root root 20d'' > /etc/tmpfiles.d/tmp.conf",
            "echo bootstrap complete"
          ]
        }
      }
    ]
  }'::jsonb
)
ON CONFLICT (display_id) DO NOTHING;
