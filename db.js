const { Pool } = require('pg');

const DATABASE_URL = process.env.DATABASE_URL || 'postgres://mgmtflow:mgmtflow@localhost:5432/mgmtflow';

const pool = new Pool({ connectionString: DATABASE_URL });

module.exports = pool;
