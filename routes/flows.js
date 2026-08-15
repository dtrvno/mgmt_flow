const express = require('express');
const pool = require('../db');
const { publishTask } = require('../queue');

const router = express.Router();

function inferTaskType(task) {
  const params = task.plugin_params;
  if (params && Array.isArray(params.commands)) return 'shell';
  if (params && typeof params.code === 'string') return 'python';
  return null;
}

router.post('/flow-definitions', async (req, res) => {
  const def = req.body;
  if (!def || typeof def.display_id !== 'string' || !def.display_id) {
    return res.status(400).json({ error: 'display_id is required' });
  }
  if (!Array.isArray(def.tasks) || def.tasks.length === 0) {
    return res.status(400).json({ error: 'tasks must be a non-empty array' });
  }
  for (const task of def.tasks) {
    if (!inferTaskType(task)) {
      return res.status(400).json({
        error: `Task "${task.display_id}" is not a supported type — expected plugin_params.commands (shell) or plugin_params.code (python)`
      });
    }
  }
  try {
    const { rows } = await pool.query(
      `INSERT INTO flow_definitions (display_id, package_id, name, version, definition)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (display_id) DO UPDATE
         SET package_id = EXCLUDED.package_id, name = EXCLUDED.name,
             version = EXCLUDED.version, definition = EXCLUDED.definition, updated_at = now()
       RETURNING *`,
      [def.display_id, def.package_id || null, def.name || def.display_id, def.version || null, def]
    );
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to store flow definition' });
  }
});

router.post('/flow-definitions/:id/run', async (req, res) => {
  const { id } = req.params;
  const client = await pool.connect();
  try {
    const lookupQuery = /^\d+$/.test(id)
      ? 'SELECT * FROM flow_definitions WHERE id = $1'
      : 'SELECT * FROM flow_definitions WHERE display_id = $1';
    const { rows: defRows } = await client.query(lookupQuery, [id]);
    if (!defRows.length) return res.status(404).json({ error: 'Flow definition not found' });
    const flowDef = defRows[0];
    const tasks = flowDef.definition.tasks;

    await client.query('BEGIN');
    const { rows: jobRows } = await client.query(
      `INSERT INTO jobs (flow_definition_id, name, status, triggered_by)
       VALUES ($1, $2, 'queued', $3) RETURNING *`,
      [flowDef.id, flowDef.name, req.body && req.body.triggered_by || null]
    );
    const job = jobRows[0];

    const taskRows = [];
    for (let seq = 0; seq < tasks.length; seq++) {
      const task = tasks[seq];
      const taskType = inferTaskType(task);
      const { rows } = await client.query(
        `INSERT INTO flow_tasks (job_id, seq, display_id, task_type, params)
         VALUES ($1, $2, $3, $4, $5) RETURNING *`,
        [job.id, seq, task.display_id, taskType, task.plugin_params]
      );
      taskRows.push(rows[0]);
    }
    await client.query('COMMIT');

    const first = taskRows[0];
    await publishTask({
      job_id: job.id,
      task_id: first.id,
      seq: first.seq,
      task_type: first.task_type,
      params: first.params
    });

    res.json(job);
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err);
    res.status(500).json({ error: 'Failed to start flow run' });
  } finally {
    client.release();
  }
});

router.get('/flows/:id', async (req, res) => {
  const { id } = req.params;
  try {
    const { rows: jobRows } = await pool.query('SELECT * FROM jobs WHERE id = $1', [id]);
    if (!jobRows.length) return res.status(404).json({ error: 'Not found' });
    const { rows: taskRows } = await pool.query(
      'SELECT * FROM flow_tasks WHERE job_id = $1 ORDER BY seq', [id]
    );
    res.json({ ...jobRows[0], tasks: taskRows });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch flow status' });
  }
});

module.exports = router;
