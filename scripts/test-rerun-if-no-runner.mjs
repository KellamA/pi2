// Run with: node --test scripts/test-rerun-if-no-runner.mjs
// Synthetic GitHub responses only. Even the POST goes to the stand-in; no runs or settings are touched.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./rerun-if-no-runner', import.meta.url));
const runPath = 'repos/{owner}/{repo}/actions/runs/42';
const ref = 'owner/topic';
const sha = 'a'.repeat(40);
const repo = { full_name: 'owner/project', owner: { login: 'owner' } };
const run = {
	id: 42, status: 'completed', conclusion: 'failure', run_attempt: 1, workflow_id: 71,
	event: 'pull_request', path: '.github/workflows/ci.yml', repository: repo, head_repository: repo,
	actor: { login: 'owner' }, head_branch: ref, head_sha: sha, pull_requests: [{ number: 7 }],
};
const pr = { state: 'open', user: { login: 'owner' }, base: { repo }, head: { sha, ref, repo } };
const changes = {
	id: 1, name: 'Which jobs the change needs', status: 'completed', conclusion: 'success', labels: ['ubuntu-latest'],
	steps: [{ name: 'Decide which jobs to run (App and Engine retries are hosted)', conclusion: 'success' }],
};
const app = {
	id: 2, name: 'App (build)', status: 'completed', conclusion: 'failure', labels: ['pi2-mini'],
	runner_id: 11, runner_name: 'pi2-mini', steps: [
		{ status: 'completed', conclusion: 'success' }, { status: 'in_progress', conclusion: null },
	],
};
const engine = { ...app, id: 3, name: 'Engine (type-check and tests)', conclusion: 'success', steps: [] };
const queued = { ...app, runner_id: null, runner_name: null, steps: [] };
const hosted = { ...queued, labels: ['macos-26'], conclusion: 'cancelled' };
const lost = 'The self-hosted runner: pi2-mini lost communication with the server. Verify the machine is running and has a healthy network connection. Anything in your workflow that terminates the runner process, starves it for CPU/Memory, or blocks its network access can cause this error.';
const missedMini = 'The job was not acquired by Runner of type self-hosted even after multiple attempts';
const missedHosted = 'The job was not acquired by Runner of type hosted even after multiple attempts';
const annotation = message => ({ annotation_level: 'failure', message });
const defaultFixture = {
	run, pr, newest: 42, jobs: [changes, app, engine], annotations: { 2: [annotation(lost)] },
};

// The fake API accepts only the controller's known endpoints and records any attempt to mutate GitHub.
const standIn = `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
const f = JSON.parse(fs.readFileSync(process.env.FIXTURE, 'utf8'));
const base = ${JSON.stringify(runPath)};
const emit = value => console.log(JSON.stringify(value));
if (args[0] === '--disable' && args.at(-1) === 'https://api.github.com/repos/owner/project/pulls/7') {
	if (f.pr === null) process.exit(22);
	emit(f.pr);
} else if (args[0] === 'api' && args[1] === base) {
	const alreadyRead = fs.existsSync(process.env.READ);
	fs.writeFileSync(process.env.READ, '');
	emit(alreadyRead ? f.recheck ?? f.run : f.run);
} else if (args[0] === 'api' && args[1] === '--paginate' && args[2].startsWith(base + '/attempts/')) {
	const attempt = Number(args[2].split('/').at(-2));
	emit({ jobs: attempt === f.run.run_attempt ? f.jobs : f.first });
} else if (args[0] === 'api' && args[1] === '--paginate' && args[2].startsWith('repos/{owner}/{repo}/check-runs/')) {
	const id = args[2].split('/').at(-2);
	if (!(id in f.annotations)) process.exit(1);
	for (const a of f.annotations[id]) emit([a]);
} else if (args[0] === 'api' && args[1] === '-X' && args[2] === 'GET' && args[3] === 'repos/{owner}/{repo}/actions/workflows/71/runs') {
	emit(f.newest);
} else if (args[0] === 'api' && args[1] === '-X' && args[2] === 'POST' && args[3] === base + '/rerun-failed-jobs') {
	fs.appendFileSync(process.env.WRITES, args[3] + '\\n');
} else {
	throw new Error('Unexpected command: ' + args.join(' '));
}
`;

function fixture(name, overrides, { post = false, dry = false, expected = '', output, error = false } = {}) {
	test(name, () => {
		const dir = mkdtempSync(join(process.env.PI2_SCRATCH || tmpdir(), 'ci-rerun-'));
		const file = join(dir, 'fixture.json');
		const writes = join(dir, 'writes');
		try {
			writeFileSync(file, JSON.stringify({ ...defaultFixture, ...overrides }));
			writeFileSync(writes, '');
			for (const cmd of ['gh', 'curl']) {
				writeFileSync(join(dir, cmd), standIn);
				chmodSync(join(dir, cmd), 0o700);
			}
			const result = spawnSync('/bin/bash', [script, '42', ...(dry ? ['--dry-run'] : [])], {
				encoding: 'utf8', timeout: 5000,
				env: { PATH: `${dir}:${process.env.PATH}`, EXPECTED_ATTEMPT: expected, FIXTURE: file,
					READ: join(dir, 'read'), WRITES: writes },
			});
			assert.ifError(result.error);
			if (error) assert.notEqual(result.status, 0, result.stdout);
			else assert.equal(result.status, 0, result.stderr);
			assert.equal(readFileSync(writes, 'utf8'), post ? `${runPath}/rerun-failed-jobs\n` : '', result.stdout);
			if (output) assert.match(result.stdout, output);
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
}

fixture('assigned mini lost communication; re-run only failed checks in the same run', {},
	{ post: true, expected: '1', output: /attempt 2 for 1 mini checks on macos-26/ });
fixture('terminal unassigned mini with the exact acquisition error', {
	jobs: [changes, queued, engine], annotations: { 2: [annotation(missedMini)] },
}, { post: true });
fixture('two mini infrastructure failures still request only one attempt', {
	jobs: [changes, queued, { ...engine, ...app, id: 3, name: engine.name }],
	annotations: { 2: [annotation(missedMini)], 3: [annotation(lost)] },
}, { post: true, output: /2 mini checks/ });
fixture('dry run writes nothing', {}, { dry: true, output: /Would rerun/ });
fixture('queued while the workflow is active', { run: { ...run, status: 'in_progress' },
	jobs: [changes, { ...queued, status: 'queued', conclusion: null }, engine] });
fixture('queued in a stale job snapshot', { jobs: [changes, { ...queued, status: 'queued', conclusion: null }, engine] });
fixture('still running in a stale job snapshot', { jobs: [changes, { ...app, status: 'in_progress', conclusion: null }, engine] });
fixture('timed out, rather than lost', { jobs: [changes, { ...app, conclusion: 'timed_out' }, engine] });
fixture('an ordinary test failure, even with a lost-runner annotation', { jobs: [changes, { ...app,
	steps: [...app.steps, { status: 'completed', conclusion: 'failure' }] }, engine] });
fixture('another failure annotation in the same job', { annotations: { 2: [annotation(lost), annotation('test failed')] } });
fixture('ordinary failure annotation', { annotations: { 2: [annotation('Swift compilation failed')] } });
fixture('missing annotations', { annotations: {} });
fixture('user cancellation is not unacquired', { jobs: [changes, { ...queued, conclusion: 'cancelled' }, engine],
	annotations: { 2: [annotation('The operation was canceled.')] } });
fixture('a sibling failed real tests', { jobs: [changes, app, { ...engine, conclusion: 'failure' }],
	annotations: { 2: [annotation(lost)], 3: [annotation('Process completed with exit code 1.')] } });
fixture('a sibling failed on the hosted image', { jobs: [changes, app, { ...hosted, id: 3, name: engine.name }],
	annotations: { 2: [annotation(lost)], 3: [annotation(missedHosted)] } });
fixture('optional mini checks are not recovered', { jobs: [changes, { ...app, name: 'Relay (protocol test)' }, engine] });
fixture('fork PR', { run: { ...run, head_repository: { full_name: 'other/project' } } });
fixture('non-owner actor', { run: { ...run, actor: { login: 'other' } } });
fixture('non-owner PR author', { pr: { ...pr, user: { login: 'other' } } });
fixture('main push', { run: { ...run, event: 'push' } });
fixture('release cannot use the mini path', { run: { ...run, path: '.github/workflows/release.yml' } });
fixture('no routing marker on older CI', { jobs: [{ ...changes, steps: [] }, app, engine] });
fixture('missing PR link', { run: { ...run, pull_requests: [] } });
fixture('closed PR', { pr: { ...pr, state: 'closed' } });
fixture('PR head moved', { pr: { ...pr, head: { ...pr.head, sha: 'b'.repeat(40) } } });
fixture('stale run', { newest: 50 });
fixture('stale event delivery', {}, { expected: '2' });
fixture('intervening re-run after classification', { recheck: { ...run, status: 'in_progress', run_attempt: 2 } });
fixture('PR API unavailable: fail closed', { pr: null }, { error: true });
fixture('no extra retry if the hosted fallback was not picked up', { run: { ...run, run_attempt: 2 },
	jobs: [hosted], first: defaultFixture.jobs, annotations: { 2: [annotation(missedHosted)] } });
fixture('old hosted retry still works for a release', { run: { ...run, path: '.github/workflows/release.yml',
	event: 'push', run_attempt: 3, conclusion: 'cancelled' }, jobs: [hosted],
	annotations: { 2: [annotation(missedHosted)] } }, { post: true });
fixture('the old hosted retry budget is unchanged', { run: { ...run, event: 'push', run_attempt: 4 },
	jobs: [hosted], annotations: { 2: [annotation(missedHosted)] } });
