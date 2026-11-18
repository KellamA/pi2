// Protocol regressions, with a private stand-in socket; no app, engine, provider or sign-in.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const folder = mkdtempSync(join(tmpdir(), 'pi2-send-'));
const children = new Set(), sockets = new Set();
const guard = setTimeout(() => { console.error('send tests exceeded ten minutes'); process.exit(1); }, 600_000);
process.on('exit', () => {
	for (const child of children) child.kill();
	for (const socket of sockets) socket.destroy();
	rmSync(folder, { recursive: true, force: true });
});
try {
	for (const mode of ['fast', 'queued', 'failed', 'waiting', 'error', 'close', 'timeout']) {
		const path = join(folder, mode + '.sock');
		let submitted = false, subscribed = false, gets = 0;
		const server = createServer(socket => {
			sockets.add(socket);
			socket.on('close', () => sockets.delete(socket));
			const send = message => socket.write(JSON.stringify(message) + '\n');
			const event = (items = []) => send({ event: 'conversation', id: 8, items, state: { busy: false }, reset: false });
			let buffer = '';
			socket.setEncoding('utf8').on('data', chunk => {
				buffer += chunk;
				const lines = buffer.split('\n'); buffer = lines.pop();
				for (const line of lines) {
					const request = JSON.parse(line);
					const reply = result => send({ id: request.id, result });
					if (request.method === 'conversation.open') {
						subscribed = true;
						event([{ id: 1, kind: 'assistant', text: 'old answer' }]);
						reply({});
					} else if (request.method === 'submit') {
						assert.ok(subscribed);
						submitted = true;
						if (mode === 'error') { send({ id: request.id, error: 'archived' }); continue; }
						// The committed answer may arrive BEFORE submit's response, with no busy=true ever sent.
						if (mode === 'fast') event([{ id: 22, kind: 'assistant', text: 'new answer' }]);
						reply({ submissionId: 10 });
					} else if (request.method === 'submission.get') {
						assert.ok(submitted);
						assert.deepEqual(request.params, { id: 8, submissionId: 10 });
						gets++;
						if (mode === 'close') { socket.destroy(); continue; }
						if (mode === 'timeout') continue;
						if (mode === 'failed') {
							reply({ submission: { id: 10, status: 'unanswered', reason: 'model_error' }, busy: false });
						} else if (mode === 'waiting') {
							reply({ submission: { id: 10, status: 'placed' }, busy: true });
							send({ event: 'inbox', items: [{ id: 'approval', conversationId: 8, kind: 'approval' }] });
						} else if (mode === 'queued' && gets === 1) {
							// An old idle event cannot complete the new queued submission. A later event releases it.
							reply({ submission: { id: 10, status: 'queued' }, busy: false });
							setImmediate(() => event([{ id: 22, kind: 'assistant', text: 'new answer' }]));
						} else {
							reply({ submission: { id: 10, status: 'done', answer: 22 }, busy: false });
						}
					} else assert.fail('unexpected request ' + request.method);
				}
			});
		});
		await new Promise(resolve => server.listen(path, resolve));
		const child = spawn(process.execPath, [join(import.meta.dirname, 'test-copy-send.mjs'), path, '8', 'hello', mode === 'timeout' ? '0.05' : '600']);
		children.add(child);
		let out = '', err = '';
		child.stdout.setEncoding('utf8').on('data', chunk => out += chunk);
		child.stderr.setEncoding('utf8').on('data', chunk => err += chunk);
		const code = await new Promise(resolve => child.once('close', resolve));
		children.delete(child);
		for (const socket of sockets) socket.destroy();
		await new Promise(resolve => server.close(resolve));
		const result = JSON.parse(out);
		const expected = { fast: ['done', 0], queued: ['done', 0], failed: ['failed', 1], waiting: ['waiting', 2], error: ['error', 1], close: ['error', 1], timeout: ['timeout', 124] }[mode];
		assert.deepEqual([result.status, code], expected, `${mode}: ${out} ${err}`);
		if (mode === 'fast' || mode === 'queued') assert.equal(result.answer, 'new answer');
		if (mode === 'queued') assert.ok(gets >= 2);
		console.log(`ok: send ${mode}`);
	}
} finally {
	clearTimeout(guard);
	rmSync(folder, { recursive: true, force: true });
}
