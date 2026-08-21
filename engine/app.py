import json
import os
import sys
import threading
import time
import uuid

import pika
import psycopg2
import psycopg2.extras
from flask import Flask, jsonify
from kubernetes import client, config
from kubernetes.client.rest import ApiException

DATABASE_URL = os.environ.get('DATABASE_URL', 'postgres://mgmtflow:mgmtflow@localhost:5432/mgmtflow')
RABBITMQ_URL = os.environ.get('RABBITMQ_URL', 'amqp://guest:guest@localhost:5672')
TASKS_QUEUE = 'mgmt_flow.tasks'
MAX_OUTPUT_BYTES = 64 * 1024

K8S_NAMESPACE = os.environ.get('K8S_NAMESPACE', 'default')
JOB_TTL_SECONDS = int(os.environ.get('JOB_TTL_SECONDS', '300'))
JOB_POLL_INTERVAL = float(os.environ.get('JOB_POLL_INTERVAL', '1.0'))
JOB_TIMEOUT_SECONDS = int(os.environ.get('JOB_TIMEOUT_SECONDS', '600'))

app = Flask(__name__)

# Load this Pod's ServiceAccount credentials to talk to the Kubernetes API.
# Falls back to a local kubeconfig so the engine can still run outside the
# cluster (e.g. on a dev machine) without code changes.
try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config()

batch_v1 = client.BatchV1Api()
core_v1 = client.CoreV1Api()

db_conn = psycopg2.connect(DATABASE_URL)
db_conn.autocommit = True
db_lock = threading.Lock()


def db_query(sql, params=None):
    with db_lock, db_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql, params or ())
        if cur.description:
            return cur.fetchall()
        return []


def image_and_cmd(task_type, params):
    if task_type == 'shell':
        return 'alpine:3.20', ['/bin/sh', '-c', ' && '.join(params['commands'])]
    if task_type == 'python':
        return 'python:3.12-alpine', ['python3', '-c', params['code']]
    raise ValueError(f'Unsupported task_type: {task_type}')


def run_k8s_task(job_id, task_id, image, cmd):
    """Run one task as a Kubernetes Job and return (exit_code, output),
    mirroring what the old docker_client.containers.create/start/wait/logs
    flow did with a real Docker container."""
    job_name = f'mgmt-flow-task-{task_id}-{uuid.uuid4().hex[:6]}'

    job_manifest = client.V1Job(
        metadata=client.V1ObjectMeta(
            name=job_name,
            labels={
                'app': 'mgmt-flow-task',
                'mgmt-flow-job-id': str(job_id),
                'mgmt-flow-task-id': str(task_id),
            },
        ),
        spec=client.V1JobSpec(
            backoff_limit=0,
            ttl_seconds_after_finished=JOB_TTL_SECONDS,
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(
                    labels={
                        'app': 'mgmt-flow-task',
                        'mgmt-flow-job-id': str(job_id),
                        'mgmt-flow-task-id': str(task_id),
                    }
                ),
                spec=client.V1PodSpec(
                    restart_policy='Never',
                    containers=[
                        client.V1Container(
                            name='task',
                            image=image,
                            command=cmd,
                        )
                    ],
                ),
            ),
        ),
    )

    batch_v1.create_namespaced_job(namespace=K8S_NAMESPACE, body=job_manifest)

    try:
        exit_code, output = _wait_and_collect(job_name)
    finally:
        try:
            batch_v1.delete_namespaced_job(
                name=job_name,
                namespace=K8S_NAMESPACE,
                propagation_policy='Background',
            )
        except ApiException as err:
            print(f'warning: failed to delete job {job_name}: {err}', file=sys.stderr)

    return exit_code, output


def _wait_and_collect(job_name):
    deadline = time.time() + JOB_TIMEOUT_SECONDS
    pod_name = None

    while time.time() < deadline:
        pods = core_v1.list_namespaced_pod(
            namespace=K8S_NAMESPACE, label_selector=f'job-name={job_name}'
        )
        if pods.items:
            pod = pods.items[0]
            pod_name = pod.metadata.name
            if pod.status.phase in ('Succeeded', 'Failed'):
                break
        time.sleep(JOB_POLL_INTERVAL)
    else:
        return 1, f'engine error: task timed out after {JOB_TIMEOUT_SECONDS}s'

    if pod_name is None:
        return 1, 'engine error: task pod never appeared'

    try:
        output = core_v1.read_namespaced_pod_log(
            name=pod_name, namespace=K8S_NAMESPACE, tail_lines=2000
        )
    except ApiException as err:
        output = f'engine error: could not read logs: {err}'

    pod = core_v1.read_namespaced_pod(name=pod_name, namespace=K8S_NAMESPACE)
    exit_code = 1
    statuses = pod.status.container_statuses or []
    if statuses and statuses[0].state and statuses[0].state.terminated:
        exit_code = statuses[0].state.terminated.exit_code

    return exit_code, output[:MAX_OUTPUT_BYTES]


def run_task(task):
    job_id = task['job_id']
    task_id = task['task_id']
    seq = task['seq']
    task_type = task['task_type']
    params = task['params']

    db_query("UPDATE flow_tasks SET status = 'running', started_at = now() WHERE id = %s", (task_id,))
    db_query(
        "UPDATE jobs SET status = 'running', started_at = COALESCE(started_at, now()) WHERE id = %s",
        (job_id,)
    )

    image, cmd = image_and_cmd(task_type, params)

    exit_code, output = run_k8s_task(job_id, task_id, image, cmd)

    status = 'complete' if exit_code == 0 else 'failed'
    db_query(
        'UPDATE flow_tasks SET status = %s, exit_code = %s, output = %s, completed_at = now() WHERE id = %s',
        (status, exit_code, output, task_id)
    )

    if status == 'failed':
        db_query("UPDATE jobs SET status = 'failed', completed_at = now() WHERE id = %s", (job_id,))
        return

    next_rows = db_query(
        'SELECT * FROM flow_tasks WHERE job_id = %s AND seq = %s', (job_id, seq + 1)
    )
    total = db_query(
        'SELECT COUNT(*)::int AS total FROM flow_tasks WHERE job_id = %s', (job_id,)
    )[0]['total']

    if next_rows:
        db_query('UPDATE jobs SET progress = %s WHERE id = %s', (int((seq + 1) / total * 100), job_id))
        next_task = next_rows[0]
        publish_task({
            'job_id': job_id,
            'task_id': next_task['id'],
            'seq': next_task['seq'],
            'task_type': next_task['task_type'],
            'params': next_task['params']
        })
    else:
        db_query(
            "UPDATE jobs SET status = 'complete', progress = 100, completed_at = now() WHERE id = %s", (job_id,)
        )


_publish_channel = None


def publish_task(payload):
    _publish_channel.basic_publish(
        exchange='',
        routing_key=TASKS_QUEUE,
        body=json.dumps(payload).encode('utf-8'),
        properties=pika.BasicProperties(delivery_mode=2)
    )


def on_message(channel, method, properties, body):
    task = json.loads(body.decode('utf-8'))
    try:
        run_task(task)
    except Exception as err:
        print(f'task failed: {err}', file=sys.stderr)
        note = f'engine error: {err}'
        try:
            db_query(
                "UPDATE flow_tasks SET status = 'failed', output = %s, completed_at = now() WHERE id = %s",
                (note, task['task_id'])
            )
            db_query(
                "UPDATE jobs SET status = 'failed', completed_at = now() WHERE id = %s", (task['job_id'],)
            )
        except Exception as db_err:
            print(f'failed to record task failure: {db_err}', file=sys.stderr)
    finally:
        channel.basic_ack(delivery_tag=method.delivery_tag)


def run_consumer():
    global _publish_channel
    connection = pika.BlockingConnection(pika.URLParameters(RABBITMQ_URL))
    channel = connection.channel()
    channel.queue_declare(queue=TASKS_QUEUE, durable=True)
    channel.basic_qos(prefetch_count=4)
    _publish_channel = channel

    print(f'engine: waiting for tasks on {TASKS_QUEUE}')
    channel.basic_consume(queue=TASKS_QUEUE, on_message_callback=on_message, auto_ack=False)
    channel.start_consuming()


def consume_forever():
    try:
        run_consumer()
    except Exception as err:
        print(f'engine failed to start: {err}', file=sys.stderr)
        os._exit(1)


@app.route('/health')
def health():
    return jsonify({'status': 'ok'})


if __name__ == '__main__':
    threading.Thread(target=consume_forever, daemon=True).start()
    app.run(host='0.0.0.0', port=5000)
