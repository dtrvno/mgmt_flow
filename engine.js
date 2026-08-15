const Docker = require('dockerode');
const pool = require('./db');
const { getChannel, publishTask, TASKS_QUEUE } = require('./queue');

const docker = new Docker({ socketPath: '/var/run/docker.sock' });
const MAX_OUTPUT_BYTES = 64 * 1024;

function imageAndCmd(taskType, params) {
  if (taskType === 'shell') {
    return { Image: 'alpine:3.20', Cmd: ['/bin/sh', '-c', params.commands.join(' && ')] };
  }
  if (taskType === 'python') {
    return { Image: 'python:3.12-alpine', Cmd: ['python3', '-c', params.code] };
  }
  throw new Error(`Unsupported task_type: ${taskType}`);
}

async function ensureImage(image) {
  try {
    await docker.getImage(image).inspect();
    return;
  } catch (err) {
    // not present locally, fall through to pull
  }
  await new Promise((resolve, reject) => {
    docker.pull(image, (err, stream) => {
      if (err) return reject(err);
      docker.modem.followProgress(stream, (err2) => (err2 ? reject(err2) : resolve()));
    });
  });
}

async function runTask(task) {
  const { job_id, task_id, seq, task_type, params } = task;

  await pool.query(`UPDATE flow_tasks SET status = 'running', started_at = now() WHERE id = $1`, [task_id]);
  await pool.query(
    `UPDATE jobs SET status = 'running', started_at = COALESCE(started_at, now()) WHERE id = $1`,
    [job_id]
  );

  const { Image, Cmd } = imageAndCmd(task_type, params);
  await ensureImage(Image);

  const container = await docker.createContainer({
    Image,
    Cmd,
    Tty: true,
    Labels: { 'mgmt_flow.job_id': String(job_id), 'mgmt_flow.task_id': String(task_id) }
  });
  await container.start();
  await pool.query(`UPDATE flow_tasks SET container_id = $1 WHERE id = $2`, [container.id, task_id]);

  const { StatusCode } = await container.wait();
  const logData = await container.logs({ stdout: true, stderr: true, tail: 2000 });
  // docker-modem JSON-parses buffered log bodies that happen to look like JSON
  // (e.g. a task whose entire stdout is "4\n"), so logs() isn't reliably a Buffer.
  const output = (Buffer.isBuffer(logData) ? logData.toString('utf8') : String(logData)).slice(0, MAX_OUTPUT_BYTES);
  await container.remove({ force: true });

  const status = StatusCode === 0 ? 'complete' : 'failed';
  await pool.query(
    `UPDATE flow_tasks SET status = $1, exit_code = $2, output = $3, completed_at = now() WHERE id = $4`,
    [status, StatusCode, output, task_id]
  );

  if (status === 'failed') {
    await pool.query(`UPDATE jobs SET status = 'failed', completed_at = now() WHERE id = $1`, [job_id]);
    return;
  }

  const { rows: nextRows } = await pool.query(
    `SELECT * FROM flow_tasks WHERE job_id = $1 AND seq = $2`, [job_id, seq + 1]
  );
  const { rows: countRows } = await pool.query(
    `SELECT COUNT(*)::int AS total FROM flow_tasks WHERE job_id = $1`, [job_id]
  );
  const total = countRows[0].total;

  if (nextRows.length) {
    await pool.query(`UPDATE jobs SET progress = $1 WHERE id = $2`, [Math.floor(((seq + 1) / total) * 100), job_id]);
    const next = nextRows[0];
    await publishTask({
      job_id,
      task_id: next.id,
      seq: next.seq,
      task_type: next.task_type,
      params: next.params
    });
  } else {
    await pool.query(
      `UPDATE jobs SET status = 'complete', progress = 100, completed_at = now() WHERE id = $1`, [job_id]
    );
  }
}

async function main() {
  const channel = await getChannel();
  channel.prefetch(4);
  console.log('engine: waiting for tasks on', TASKS_QUEUE);

  channel.consume(TASKS_QUEUE, async (msg) => {
    if (!msg) return;
    const task = JSON.parse(msg.content.toString());
    try {
      await runTask(task);
    } catch (err) {
      console.error('task failed:', err);
      const note = `engine error: ${err.message}`;
      await pool.query(
        `UPDATE flow_tasks SET status = 'failed', output = $1, completed_at = now() WHERE id = $2`,
        [note, task.task_id]
      ).catch(() => {});
      await pool.query(
        `UPDATE jobs SET status = 'failed', completed_at = now() WHERE id = $1`,
        [task.job_id]
      ).catch(() => {});
    } finally {
      channel.ack(msg);
    }
  }, { noAck: false });
}

main().catch((err) => {
  console.error('engine failed to start:', err);
  process.exit(1);
});
