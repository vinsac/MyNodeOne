#!/usr/bin/env python3
"""Static checks of the storage and backup manifests. Nothing is applied anywhere.

Usage: check_manifests.py REPO_ROOT WORK_DIR
Writes the two embedded job scripts to WORK_DIR so test-backup.sh can run them.
"""
import re
import sys

import yaml

root, work = sys.argv[1], sys.argv[2]
failed = 0


def check(name, ok, detail=''):
    global failed
    print(('ok    ' if ok else 'FAIL  ') + name)
    if not ok:
        failed += 1
        if detail:
            print('      | ' + str(detail))


def load(path):
    with open(root + '/' + path) as f:
        return [d for d in yaml.safe_load_all(f) if d]


def check_pod_security(name, pod):
    sc = pod['securityContext']
    container = pod['containers'][0]
    csc = container['securityContext']
    check(name + ': runs as non-root', sc['runAsNonRoot'] is True and sc['runAsUser'] == 70)
    check(name + ': fsGroup lets UID 70 use the volume', sc['fsGroup'] == 70)
    check(name + ': no privilege escalation', csc['allowPrivilegeEscalation'] is False)
    check(name + ': read-only root filesystem', csc['readOnlyRootFilesystem'] is True)
    check(name + ': drops all capabilities', csc['capabilities']['drop'] == ['ALL'])
    check(name + ': image pinned by digest', '@sha256:' in container['image'], container['image'])
    env = {e['name']: e for e in container['env']}
    secret = env['PGPASSWORD']['valueFrom']['secretKeyRef']
    check(name + ': password from the llmapi-db Secret',
          (secret['name'], secret['key']) == ('llmapi-db', 'postgres-password'))
    check(name + ': connects to llmapi-postgres as llmapi',
          env['PGHOST']['value'] == 'llmapi-postgres' and env['PGUSER']['value'] == 'llmapi')
    return container, env


# Backup
docs = load('scripts/backup/llmapi-postgres-backup.yaml')
kinds = {d['kind']: d for d in docs}
check('backup manifest has a PVC and a CronJob', set(kinds) == {'PersistentVolumeClaim', 'CronJob'}, list(kinds))
pvc, cron = kinds['PersistentVolumeClaim'], kinds['CronJob']
check('all in the llmapi namespace', all(d['metadata']['namespace'] == 'llmapi' for d in docs))
check('PVC names a StorageClass', bool(pvc['spec'].get('storageClassName')))
check('no concurrent dumps', cron['spec']['concurrencyPolicy'] == 'Forbid')
pod = cron['spec']['jobTemplate']['spec']['template']['spec']
container, env = check_pod_security('backup', pod)
check('dump job mounts the backup PVC',
      pod['volumes'][0]['persistentVolumeClaim']['claimName'] == pvc['metadata']['name'])
with open(root + '/scripts/backup/llmapi-postgres-backup.yaml') as f:
    text = f.read()
check('backup manifest says it is not off-machine', 'NOT AN OFF-MACHINE BACKUP' in text)
check('backup manifest documents the restore', 'llmapi-postgres-restore-job.yaml' in text)
with open(work + '/backup-job.sh', 'w') as f:
    f.write(container['args'][0])

# Must match what the deployment actually runs
db = load('scripts/apps/llmapi/manifests/postgres.yaml')
deployment = next(d for d in db if d['kind'] == 'Deployment')
db_container = deployment['spec']['template']['spec']['containers'][0]
db_env = {e['name']: e for e in db_container['env']}
major = lambda image: image.split(':')[1].split('-')[0].split('.')[0]
check('same Postgres major version as the server', major(container['image']) == major(db_container['image']),
      (container['image'], db_container['image']))
check('database name matches the server', env['PGDATABASE']['value'] == db_env['POSTGRES_DB']['value'])
check('user matches the server', env['PGUSER']['value'] == db_env['POSTGRES_USER']['value'])
service = next(d for d in db if d['kind'] == 'Service')
check('host is the Postgres Service', env['PGHOST']['value'] == service['metadata']['name'])

# Restore
docs = load('scripts/backup/llmapi-postgres-restore-job.yaml')
check('restore manifest has one Job', [d['kind'] for d in docs] == ['Job'])
job = docs[0]
pod = job['spec']['template']['spec']
container, env = check_pod_security('restore', pod)
check('restore never retries', job['spec']['backoffLimit'] == 0)
check('restore mounts backups read-only', container['volumeMounts'][0]['readOnly'] is True)
check('restore reads the same PVC',
      pod['volumes'][0]['persistentVolumeClaim']['claimName'] == pvc['metadata']['name'])
with open(work + '/restore-job.sh', 'w') as f:
    f.write(container['args'][0])

# MinIO manifests, after the substitutions install-minio.sh makes
subs = {
    'MINIO_IMAGE_PLACEHOLDER': 'cgr.dev/chainguard/minio@sha256:abc',
    'MINIO_UID_PLACEHOLDER': '65532',
    'HOST_PATH_PLACEHOLDER': '/mnt/minio',
    'PV_NAME_PLACEHOLDER': 'node1',
    'NODE_PLACEHOLDER': 'node1',
    'STORAGE_SIZE_PLACEHOLDER': '16Ti',
    'NAMESPACE_PLACEHOLDER': 'minio-node1',
    'CLUSTER_DOMAIN_PLACEHOLDER': 'mynodeone',
}

with open(root + '/scripts/storage/minio/install-minio.sh') as f:
    installer = f.read()


def render(path):
    with open(root + '/' + path) as f:
        text = f.read()
    for placeholder in set(re.findall(r'[A-Z_]+_PLACEHOLDER', text)):
        check(path.split('/')[-1] + ': install-minio.sh fills ' + placeholder, placeholder in installer)
    for key, value in subs.items():
        text = text.replace(key, value)
    leftover = re.findall(r'[A-Z_]+_PLACEHOLDER', text)
    return list(yaml.safe_load_all(text)), leftover


docs, leftover = render('scripts/storage/minio/manifests/statefulset.yaml')
check('statefulset: only known placeholders', not leftover, leftover)
ss = next(d for d in docs if d['kind'] == 'StatefulSet')
spec = ss['spec']['template']['spec']
minio = spec['containers'][0]
check('statefulset: image comes from a placeholder', minio['image'].startswith('cgr.dev/'), minio['image'])
check('statefulset: UID set', spec['securityContext']['runAsUser'] == 65532)
check('statefulset: no privilege escalation', minio['securityContext']['allowPrivilegeEscalation'] is False)

docs, leftover = render('scripts/storage/minio/manifests/pv-hostpath.yaml')
check('PV: only known placeholders', not leftover, leftover)
pv = next(d for d in docs if d['kind'] == 'PersistentVolume')
check('PV: path comes from the installer', pv['spec']['hostPath']['path'] == '/mnt/minio')
check('PV: data is retained', pv['spec']['persistentVolumeReclaimPolicy'] == 'Retain')
check('PV: labelled for cleanup-node-minio.sh', pv['metadata']['labels'].get('app') == 'minio'
      and pv['metadata']['labels'].get('node') == 'node1', pv['metadata']['labels'])

check('default MinIO image is pinned by digest',
      re.search(r'MINIO_IMAGE_DEFAULT="[^"]+@sha256:[0-9a-f]{64}"', installer) is not None)
check('old unpullable image is gone', 'minio/minio:RELEASE' not in installer)

# Example
docs = load('scripts/storage/examples/app-with-minio-backup.yaml')
check('example manifest parses', len(docs) > 0)

sys.exit(1 if failed else 0)
