const express = require('express');
const path = require('path');
const pool = require('./db');

const PORT = process.env.PORT || 3000;

const app = express();
app.use(express.json());
app.use('/api', require('./routes/flows'));

// --- API ---

app.get('/api/workflows', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT id, name, description, schedule, is_active, created_at, updated_at FROM workflows ORDER BY id'
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch workflows' });
  }
});

app.patch('/api/workflows/:id', async (req, res) => {
  const { id } = req.params;
  const { is_active } = req.body;
  try {
    const { rows } = await pool.query(
      'UPDATE workflows SET is_active = $1, updated_at = now() WHERE id = $2 RETURNING *',
      [is_active, id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to update workflow' });
  }
});

app.get('/api/jobs', async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT j.id, j.name, j.status, j.progress, j.triggered_by, j.started_at, j.completed_at, j.created_at,
              j.flow_definition_id, w.name AS workflow_name
       FROM jobs j
       LEFT JOIN workflows w ON w.id = j.workflow_id
       ORDER BY j.created_at DESC`
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch jobs' });
  }
});

app.get('/api/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok', db: 'connected' });
  } catch (err) {
    res.status(500).json({ status: 'error', db: 'unreachable' });
  }
});

// --- Static dashboard ---
app.use(express.static(path.join(__dirname), { index: 'mgmt_flow_dashboard.html' }));

app.listen(PORT, () => {
  console.log(`mgmt_flow dashboard running at http://localhost:${PORT}`);
});
