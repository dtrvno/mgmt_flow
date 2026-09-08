const express = require('express');
const pool = require('../db');

const router = express.Router();

const REQUIRED_FIELDS = ['hostname', 'bmc_ip', 'bmc_user', 'bmc_password', 'node_user', 'node_password'];
const ALLOWED_FIELDS = [...REQUIRED_FIELDS, 'mgmt_ip'];

function validateParams(body) {
  for (const field of REQUIRED_FIELDS) {
    if (!body || typeof body[field] !== 'string' || !body[field]) {
      return `${field} is required`;
    }
  }
  return null;
}

function extractParams(body) {
  const params = {};
  for (const field of ALLOWED_FIELDS) {
    if (body[field] !== undefined && body[field] !== null && body[field] !== '') {
      params[field] = body[field];
    }
  }
  return params;
}

router.get('/nodes', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT id, params, created_at, updated_at FROM nodes ORDER BY created_at DESC');
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch nodes' });
  }
});

router.get('/nodes/:id', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT id, params, created_at, updated_at FROM nodes WHERE id = $1', [req.params.id]);
    if (!rows.length) return res.status(404).json({ error: 'Not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch node' });
  }
});

router.post('/nodes', async (req, res) => {
  const error = validateParams(req.body);
  if (error) return res.status(400).json({ error });
  try {
    const { rows } = await pool.query(
      'INSERT INTO nodes (params) VALUES ($1) RETURNING id, params, created_at, updated_at',
      [extractParams(req.body)]
    );
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to create node' });
  }
});

router.put('/nodes/:id', async (req, res) => {
  const error = validateParams(req.body);
  if (error) return res.status(400).json({ error });
  try {
    const { rows } = await pool.query(
      'UPDATE nodes SET params = $1, updated_at = now() WHERE id = $2 RETURNING id, params, created_at, updated_at',
      [extractParams(req.body), req.params.id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to update node' });
  }
});

router.delete('/nodes/:id', async (req, res) => {
  try {
    const { rowCount } = await pool.query('DELETE FROM nodes WHERE id = $1', [req.params.id]);
    if (!rowCount) return res.status(404).json({ error: 'Not found' });
    res.status(204).end();
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to delete node' });
  }
});

module.exports = router;
