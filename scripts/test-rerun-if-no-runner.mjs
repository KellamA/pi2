// Run with: node --test scripts/test-rerun-if-no-runner.mjs
// Only synthetic GitHub run/job statuses: even a POST is recorded locally by the fake API.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./rerun-if-no-runner', import.meta.url));
const runPath = 'repos/{owner}/{repo}/actions/runs/42';
const run = {
	id: 42, status: 'completed', conclusion: 'failure', run_attempt: 1, workflow_id: 71,
	event: 'pull_request', head_branch: 'owner/topic',
};
const app = {
	id: 2, name: 'App (build)', status: 'completed', conclusion: 'failure', labels: ['pi2-mini'],
	runner_id: 11, runner_name: 'pi2-mini', steps: [
		{ status: 'completed', conclusion: 'success' }, { status: 'in_progress', conclusion: null },
	],
};
const engine = { ...app, id: 3, name: 'Engine (type-check and tests)' };
const queued = { ...app, runner_id: null, runner_name: null, steps: [] };
const missed = { ...queued, conclusion: 'cancelled' };
const hosted = { ...missed, id: 4, labels: ['macos-26'] };
const missedMini = 'The job was not acquired by Runner of type self-hosted even after multiple attempts';
const missedHosted = 'The job was not acquired by Runner of type hosted even after multiple attempts';
const annotation = message => ({ annotation_level: 'failure', message });
const defaultFixture = { run, newest: 42, jobs: [app], annotations: { 4: [annotation(missedHosted)] } };

const standIn = `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
const f = JSON.parse(fs.readFileSync(process.env.FIXTURE, 'utf8'));
const base = ${JSON.stringify(runPath)};
const [command, ...params] = args;
const emit = value => console.log(JSON.stringify(value));
if (command !== 'api') throw new Error('Only gh api is expected');
if (params[0] === '-X' && params[1] !== 'GET') {
	// Includes either rerun endpoint and any other attempted write. Never call GitHub.
	fs.appendFileSync(process.env.WRITES, params.slice(1).join(' ') + '\\n');
	if (f.atWriteBoundary) throw new Error('Another attempt completed just before this write');
} else if (params[0] === base) {
	const alreadyRead = fs.existsSync(process.env.READ);
	fs.writeFileSync(process.env.READ, '');
	emit(alreadyRead ? f.recheck ?? f.run : f.run);
} else if (params[0] === '--paginate' && params[1] === base + '/attempts/' + f.run.run_attempt + '/jobs?per_page=100') {
	emit({ total_count: f.jobs.length, jobs: f.jobs });
} else if (params[0] === '--paginate' && params[1] === base + '/jobs?filter=all&per_page=100') {
	if (!f.history) process.exit(1);
	for (const jobs of f.history) emit({ total_count: f.historyCount ?? f.history.flat().length, jobs });
} else if (params[0] === '--paginate' && params[1].startsWith('repos/{owner}/{repo}/check-runs/')) {
	const id = params[1].split('/').at(-2);
	emit(f.annotations[id] ?? []);
} else if (params[0] === '-X' && params[1] === 'GET' && params[2] === 'repos/{owner}/{repo}/actions/workflows/71/runs') {
	emit(f.newest);
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
			writeFileSync(join(dir, 'gh'), standIn, { mode: 0o700 });
			writeFileSync(join(dir, 'curl'), '#!/bin/bash\nexit 99\n', { mode: 0o700 });
			const result = spawnSync('/bin/bash', [script, '42', ...(dry ? ['--dry-run'] : [])], {
				encoding: 'utf8', timeout: 5000,
				env: { PATH: `${dir}:${process.env.PATH}`, EXPECTED_ATTEMPT: expected, FIXTURE: file,
					READ: join(dir, 'read'), WRITES: writes },
			});
			assert.ifError(result.error);
			if (error) assert.notEqual(result.status, 0, result.stdout);
			else assert.equal(result.status, 0, result.stderr);
			assert.equal(readFileSync(writes, 'utf8'), post ? `POST ${runPath}/rerun-failed-jobs\n` : '', result.stdout);
			if (output) assert.match(result.stdout, output);
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
}

const manual = { output: /retry manually/ };
const lost = 'The self-hosted runner: pi2-mini lost communication with the server. Verify the machine is running and has a healthy network connection. Anything in your workflow that terminates the runner process, starves it for CPU/Memory, or blocks its network access can cause this error.';
fixture('a mini disconnect stays manual even if another attempt can finish at the write boundary', {
	annotations: { 2: [annotation(lost)] }, atWriteBoundary: true,
}, manual);
fixture('terminal mini acquisition failure does not get a run-ID or job-ID retry', {
	jobs: [missed], annotations: { 2: [annotation(missedMini)] },
}, manual);
fixture('two failed mini jobs do not cause two writes or a blanket retry', { jobs: [app, engine] }, manual);
fixture('a passing mini job does not allow a hosted capacity retry to bypass the guard', {
	jobs: [{ ...engine, conclusion: 'success' }, hosted],
}, manual);
// #1041: a run gives the mini one of its two macOS jobs at most, and the other to GitHub's. The one that ran there
// still keeps the whole run out of the hosted capacity retry, whichever of the two it is.
fixture('a failed mini job and a hosted capacity miss stay manual (#1041)', {
	jobs: [app, hosted],
}, manual);
fixture('a mini job and a downstream failure stay manual', { jobs: [app, {
	...hosted, name: 'Dependent check', conclusion: 'failure', steps: [{ conclusion: 'failure' }],
}] }, manual);
fixture('a reported build/test failure stays visible', {
	jobs: [{ ...app, steps: [{ status: 'completed', conclusion: 'failure' }] }],
}, manual);
fixture('queued or running workflow does not trigger a retry', { run: { ...run, status: 'in_progress' } });
fixture('queued job in a supposedly completed run stays manual', {
	jobs: [{ ...queued, status: 'queued', conclusion: null }, hosted],
}, manual);
fixture('mini label matching is case-insensitive and supports multiple labels', {
	jobs: [{ ...missed, labels: ['self-hosted', 'PI2-MINI'] }, hosted],
}, manual);
fixture('known mini runner but no matching label still stays manual', {
	jobs: [{ ...app, labels: ['self-hosted'] }, hosted],
}, manual);
fixture('unknown routing on a non-skipped App check fails closed', { jobs: [{ ...hosted, labels: [] }] }, manual);
fixture('a hosted capacity miss after a manual retry does not bypass a mini job on a later history page', {
	run: { ...run, run_attempt: 3 }, jobs: [hosted], history: [[hosted], [app]],
}, manual);
fixture('missing history for a hosted-looking partial attempt fails closed', {
	run: { ...run, run_attempt: 2 }, jobs: [hosted],
}, { error: true });
fixture('truncated attempt history fails closed', {
	run: { ...run, run_attempt: 2 }, jobs: [hosted], history: [[hosted]], historyCount: 2,
}, { error: true });
fixture('a stale completion event does not select the jobs from the new attempt', {
	run: { ...run, run_attempt: 2 }, jobs: [hosted],
}, { expected: '1', output: /Not the completed failed attempt/ });
fixture('the separate hosted capacity path still works for an ordinary PR', {
	run: { ...run, run_attempt: 2 }, jobs: [hosted], history: [[hosted]],
}, { post: true });
fixture('a hosted-only release still gets the existing capacity retry', {
	run: { ...run, event: 'push', run_attempt: 3, conclusion: 'cancelled' }, jobs: [hosted],
}, { post: true });
fixture('a hosted capacity miss does not retry a sibling that failed tests', {
	jobs: [hosted, { ...app, labels: ['macos-26'], runner_name: 'GitHub Actions', steps: [{ conclusion: 'failure' }] }],
});
fixture('legacy hosted budget is unchanged', { run: { ...run, event: 'push', run_attempt: 4 }, jobs: [hosted] });
fixture('correctly classified hosted misses are not retried from stale runs', { jobs: [hosted], newest: 50 });
fixture('a newer attempt already visible on the last read blocks the legacy retry', { jobs: [hosted],
	recheck: { ...run, run_attempt: 2 } }, { output: /attempt changed/ });
fixture('dry run has no writes', { jobs: [hosted] }, { dry: true, output: /Would rerun/ });
fixture('a self-hosted miss is never mistaken for a hosted miss', {
	jobs: [{ ...missed, name: 'Relay (protocol test)' }], annotations: { 2: [annotation(missedMini)] },
});
