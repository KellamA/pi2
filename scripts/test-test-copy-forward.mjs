// Checks scripts/test-copy-forward.mjs, the forwarder remote-on starts (#951), against a stand-in for pi² Remote: an
// echo server on 127.0.0.1. Starts nothing but the forwarder, and stops it by its pid.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { connect, createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const folder = mkdtempSync(join(tmpdir(), 'pi2-forward-'));
const script = join(import.meta.dirname, 'test-copy-forward.mjs');
const run = (...args) => new Promise(resolve => {
	execFile(process.execPath, [script, ...args], { timeout: 60_000 }, (error, out, err) => {
		resolve([error?.code ?? 0, out.trim(), err.trim()]);
	});
});
const listening = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
// A port nothing listens on, from a server opened and closed again.
const freePort = async () => {
	const server = createServer();
	const port = await listening(server);
	await new Promise(resolve => server.close(resolve));
	return port;
};
// What a client connecting to `port` and sending `text` hears back before the connection closes, and whether it closed
// within `limit` milliseconds.
const exchange = (port, text, limit = 10_000) => new Promise(resolve => {
	let heard = '';
	const client = connect({ host: '127.0.0.1', port }, () => client.write(text));
	const timer = setTimeout(() => { client.destroy(); resolve({ heard, closed: false }); }, limit);
	client.on('data', data => {
		heard += data;
		if (heard.length >= text.length) client.end();
	});
	client.on('error', () => {});
	client.on('close', () => { clearTimeout(timer); resolve({ heard, closed: true }); });
});

const started = [];
let failures = 0;
const check = async (what, body) => {
	try {
		await body();
		console.log(`ok: ${what}`);
	} catch (error) {
		failures++;
		console.log(`FAIL: ${what}: ${error.message}`);
	}
};

const echo = createServer(socket => socket.pipe(socket));
const target = await listening(echo);
const known = await freePort();

await check('the forwarder carries bytes both ways from the port the phone knows to pi² Remote\'s', async () => {
	const [code, out, err] = await run('start', String(known), String(target), join(folder, 'forward.log'));
	assert.equal(code, 0, err);
	assert.match(out, /^[0-9]+$/);
	started.push(Number(out));
	const { heard } = await exchange(known, 'a line of the channel\n');
	assert.equal(heard, 'a line of the channel\n');
});

await check('a second forwarder on a port in use is refused, saying so', async () => {
	const [code, , err] = await run('start', String(known), String(target), join(folder, 'second.log'));
	assert.equal(code, 1);
	assert.match(err, /could not listen on 127\.0\.0\.1:[0-9]+/);
});

await check('with pi² Remote gone, a connection is closed at once, as a port with nothing on it refuses one', async () => {
	await new Promise(resolve => echo.close(resolve));
	echo.unref();
	const { heard, closed } = await exchange(known, 'hello', 5_000);
	assert.equal(closed, true);
	assert.equal(heard, '');
});

for (const [what, args] of [
	['the same port twice', ['start', '50000', '50000', join(folder, 'same.log')]],
	['a port that is not one', ['start', '0', '50000', join(folder, 'zero.log')]],
	['a port too large', ['start', '70000', '50000', join(folder, 'large.log')]],
	['no log file', ['start', '50000', '50001']],
]) {
	await check(`the forwarder refuses ${what}`, async () => {
		const [code] = await run(...args);
		assert.equal(code, 2);
	});
}

for (const pid of started) {
	try { process.kill(pid, 'SIGTERM'); } catch {}
}
await sleep(200);
for (const pid of started) {
	let alive = true;
	try { process.kill(pid, 0); } catch { alive = false; }
	if (alive) {
		failures++;
		console.log(`FAIL: the forwarder (${pid}) did not stop on TERM`);
		process.kill(pid, 'SIGKILL');
	}
}
rmSync(folder, { recursive: true, force: true });
process.exit(failures ? 1 : 0);
