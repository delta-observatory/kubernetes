"""Release acceptance check of the run workflow through the deployed API.

The check uses a person client. It submits small tess-bls runs on registered development observations:
estimate, submission, progress, cancellation of a running job and of a queued job, an inconclusive outcome,
a retry run, a run comparison, and two identical run exports that scripts/verify_export.py checks.
It makes no scientific claim. It writes one JSON report.

Usage, from the kubernetes/ directory:
  DELTA_TOKEN_FILE=~/.config/delta-observatory/richard.token python3 scripts/acceptance.py --report <file>
The report never contains the token.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = os.environ.get('DELTA_API_URL', 'http://localhost:30870/api').rstrip('/')
VERIFY = Path(__file__).resolve().parents[2] / 'backend/scripts/verify_export.py'
SCHEMA = Path(__file__).resolve().parents[2] / 'database/contracts/exports/manifest/v1.schema.json'


class Api:
    def __init__(self, token: str):
        self.token = token

    def call(self, method: str, path: str, body=None, raw=False):
        request = urllib.request.Request(API + path, method=method, headers={'Authorization': f'Bearer {self.token}'})
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            request.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(request, data, timeout=300) as response:
                payload = response.read()
                return response.status, (payload, {k.lower(): v for k, v in response.headers.items()}) if raw else json.loads(payload)
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b'null')


def wait(api: Api, run_id: str, seconds: float = 600) -> dict:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        _, run = api.call('GET', f'/runs/{run_id}')
        if not any(j['state'] in ('queued', 'running') for j in run['jobs']):
            return run
        time.sleep(1)
    raise SystemExit(f'run {run_id} did not finish in {seconds} s')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    api = Api(Path(os.environ['DELTA_TOKEN_FILE']).expanduser().read_text().strip())
    report, checks = {'api': API}, []

    def check(name: str, ok: bool, detail=None):
        checks.append({'check': name, 'passed': bool(ok), **({'detail': detail} if detail is not None else {})})

    status, health = api.call('GET', '/health')
    check('health', status == 200 and health['database'] == 'ok', health)
    status, rules = api.call('GET', '/rules')
    check('rules', {'run-comparison/1', 'free-text/1', 'candidate-status/1'} <= {r['id'] for r in rules},
          sorted(r['id'] for r in rules))
    status, default = api.call('GET', '/runs/default')
    base = default['run']['id']
    status, targets = api.call('GET', f'/targets?run_id={base}&sort=target_id&limit=5')
    ids = [t['observation_id'] for t in targets['items']]
    method = {'id': 'tess-bls', 'version': 1}

    status, estimate = api.call('POST', '/runs/estimate', {'method': method, 'observation_ids': ids[:4]})
    check('estimate', status == 200 and estimate['estimate']['trials']['total'] > 0,
          {'trials': estimate['estimate']['trials'], 'worker_seconds': estimate['estimate']['worker_seconds']})

    status, run_a = api.call('POST', '/runs', {'method': method, 'observation_ids': ids[:4],
                                               'label': 'Acceptance: cancel and retry on development data'})
    check('submit run', status == 201 and len(run_a['jobs']) == 4)
    run_id = run_a['id']
    running = None
    for _ in range(600):
        _, run = api.call('GET', f'/runs/{run_id}')
        running = next((j for j in run['jobs'] if j['state'] == 'running'), None)
        if running:
            break
        time.sleep(0.1)
    status, cancelled = api.call('POST', f'/jobs/{running["id"]}/cancel')
    check('cancel running job', status == 200 and cancelled.get('was_running') is True, cancelled)
    _, run = api.call('GET', f'/runs/{run_id}')
    queued = [j for j in run['jobs'] if j['state'] == 'queued']
    if queued:
        status, body = api.call('POST', f'/jobs/{queued[-1]["id"]}/cancel')
        check('cancel queued job', status == 200 and body.get('was_running') is False, body)
    run = wait(api, run_id)
    states = {j['observation_id']: j['state'] for j in run['jobs']}
    report['run_a'] = {'id': run_id, 'states': states}
    status, body = api.call('POST', f'/jobs/{running["id"]}/cancel')
    check('finished job does not change', status == 409, body)
    _, results = api.call('GET', f'/runs/{run_id}/results')
    cancelled_rows = [j for j in results['jobs'] if j['state'] == 'cancelled']
    check('cancelled jobs have no measurements or artifacts',
          all(not j['artifacts'] and not any(j['measurements'].values()) for j in cancelled_rows), len(cancelled_rows))

    status, run_b = api.call('POST', f'/runs/{run_id}/retry', {'label': 'Acceptance: retry of the cancelled jobs'})
    check('retry run', status == 201 and run_b['retry_of'] == run_id
          and sorted(run_b['inputs']) == sorted(o for o, s in states.items() if s in ('failed', 'cancelled')),
          {'id': run_b.get('id'), 'inputs': len(run_b.get('inputs', []))})
    run_b = wait(api, run_b['id'])
    report['run_b'] = {'id': run_b['id'], 'states': {j['observation_id']: j['state'] for j in run_b['jobs']}}
    complete = [o for o, s in states.items() if s == 'complete'] + \
               [j['observation_id'] for j in run_b['jobs'] if j['state'] == 'complete']
    check('each observation has one complete job across the run and its retry',
          sorted(complete) == sorted(ids[:4]), len(complete))
    status, body = api.call('POST', f'/runs/{run_b["id"]}/retry', {})
    check('retry without failed or cancelled jobs', status == 409, body)

    status, run_c = api.call('POST', '/runs', {'method': method, 'observation_ids': ids[4:5],
                                               'parameters': {'minimum_baseline_days': 1000},
                                               'label': 'Acceptance: inconclusive outcome on development data'})
    run_c = wait(api, run_c['id'])
    job_c = run_c['jobs'][0]
    check('inconclusive outcome reports its reason', job_c['state'] == 'inconclusive'
          and (job_c['error'] or {}).get('kind') == 'short_baseline', job_c['error'])
    report['run_c'] = {'id': run_c['id'], 'state': job_c['state'], 'error': job_c['error']}

    status, comparison = api.call('GET', f'/runs/compare?run_a={base}&run_b={run_id}')
    check('compare runs', status == 200 and comparison['rule'] == 'run-comparison/1', comparison.get('summary'))

    with tempfile.TemporaryDirectory() as tmp:
        digests = []
        for n in (1, 2):
            started = time.monotonic()
            status, (payload, headers) = api.call('GET', f'/runs/{run_id}/export?artifacts=all', raw=True)
            elapsed = time.monotonic() - started
            path = Path(tmp, f'export-{n}.zip')
            path.write_bytes(payload)
            digests.append(hashlib.sha256(payload).hexdigest())
            report[f'export_{n}'] = {'bytes': len(payload), 'sha256': digests[-1], 'seconds': round(elapsed, 2),
                                     'manifest_sha256': headers.get('x-export-manifest-sha256')}
        check('export is reproducible', digests[0] == digests[1], digests)
        # The schema check needs the jsonschema package. uv supplies it for this one command.
        verify = subprocess.run(['uv', 'run', '-q', '--no-project', '--with', 'jsonschema==4.25.1', 'python', str(VERIFY),
                                 str(Path(tmp, 'export-1.zip')), '--schema', str(SCHEMA),
                                 '--manifest-sha256', report['export_1']['manifest_sha256']], capture_output=True, text=True)
        verified = json.loads(verify.stdout)
        check('export manifest check', verify.returncode == 0 and verified['passed'], verified.get('files_checked'))
        data = bytearray(Path(tmp, 'export-1.zip').read_bytes())
        # Change one byte inside the stored ZIP content. The checker must report a failure.
        import zipfile
        with zipfile.ZipFile(Path(tmp, 'export-1.zip')) as archive:
            info = next(i for i in archive.infolist() if i.filename == 'run.json')
        offset = info.header_offset + 30 + len(info.filename.encode()) + len(info.extra) + 10
        data[offset] ^= 0x01
        Path(tmp, 'tampered.zip').write_bytes(bytes(data))
        tampered = subprocess.run([sys.executable, str(VERIFY), str(Path(tmp, 'tampered.zip'))], capture_output=True, text=True)
        check('export check detects a changed file', tampered.returncode != 0)

    report['checks'] = checks
    report['passed'] = all(c['passed'] for c in checks)
    Path(args.report).write_text(json.dumps(report, indent=1, default=str) + '\n')
    print(json.dumps({'passed': report['passed'], 'failed': [c for c in checks if not c['passed']]}, indent=1, default=str))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
