const amqplib = require('amqplib');

const RABBITMQ_URL = process.env.RABBITMQ_URL || 'amqp://guest:guest@localhost:5672';
const TASKS_QUEUE = 'mgmt_flow.tasks';

let channelPromise;

async function connect() {
  const conn = await amqplib.connect(RABBITMQ_URL);
  const channel = await conn.createChannel();
  await channel.assertQueue(TASKS_QUEUE, { durable: true });
  return channel;
}

function getChannel() {
  if (!channelPromise) channelPromise = connect();
  return channelPromise;
}

async function publishTask(task) {
  const channel = await getChannel();
  channel.sendToQueue(TASKS_QUEUE, Buffer.from(JSON.stringify(task)), { persistent: true });
}

module.exports = { getChannel, publishTask, TASKS_QUEUE };
