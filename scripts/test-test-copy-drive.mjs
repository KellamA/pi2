// Protocol checks with stand-ins for the app and engine. Nothing is launched except the script under test.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as sleep } from 'node:timers/promises';

const folder = mkdtempSync(join(tmpdir(), 'pi2-drive-'));
const path = join(folder, 'engine.sock');
const script = join(import.meta.dirname, 'test-copy-drive.mjs');
const run = (command, target, ...args) => new Promise(resolve => {
	const env = { ...process.env, TEST_COPY_KEY_FILE: keyFile };
	execFile(process.execPath, [script, command, target, 'test-7', ...args], { timeout: 4000, env }, (error, out, err) => {
		resolve([error?.code ?? 0, out.trim(), err.trim()]);
	});
});
const approval = { id: 'first', kind: 'approval', conversationId: 8, rootConversationId: 4 };
let items, requests, response, keyFile = join(folder, 'no-key'), keyResponse = { result: {} };
const emptyLibrary = { event: 'library', conversations: [], archived: [] };
let library = emptyLibrary;
const server = createServer(socket => {
	const send = message => socket.write(JSON.stringify(message) + '\n');
	send({ event: 'inbox', items });
	send(library);
	createInterface({ input: socket }).on('line', line => {
		const request = JSON.parse(line);
		requests.push(request);
		send({ event: 'conversation', id: 1 }); // not the reply, despite its id
		send({ id: request.id, ...(request.id === 0 ? keyResponse : response) });
	});
});
try {
	await new Promise(resolve => server.listen(path, resolve));
	requests = [];
	assert.deepEqual(await run('conversations', path), [0, '', '']);
	library = {
		event: 'library',
		conversations: [{ id: 8, title: 'Test pane', agentId: 'atlas' }, { id: 14, title: 'Line 1\nLine 2\tTabbed', agentId: null }],
		archived: [{ id: 3, title: 'Archived conversation', agentId: 'forge' }],
	};
	assert.deepEqual(await run('conversations', path), [0, '8\tTest pane\tatlas\n14\tLine 1\\nLine 2\\tTabbed\t-\n3\tArchived conversation\tforge', '']);
	assert.deepEqual(requests, []);
	library = emptyLibrary;
	console.log('ok: conversations lists the initial Library and Archive without sending a request');

	for (const [decision, word, wire] of [['allow', 'Allowed once', 'once'], ['deny', 'Denied', 'deny']]) {
		items = [approval, { ...approval, id: 'other', conversationId: 4 }, { ...approval, id: 'question', kind: 'question' }];
		requests = []; response = { result: {} };
		assert.deepEqual(await run('answer', path, '8', decision), [0, `${word} the request in conversation #8 in test-7.`, '']);
		assert.deepEqual(requests, [{ id: 1, method: 'inbox.decide', params: { id: 'first', decision: wire } }]);
	}
	items = [approval, { ...approval, id: 'second' }]; requests = [];
	assert.deepEqual(await run('answer', path, '8', 'allow'), [1, '', 'test-copy: conversation #8 has 2 approvals waiting; choose one in the copy instead']);
	assert.deepEqual(await run('answer', path, '4', 'deny'), [1, '', 'test-copy: no approval waiting in conversation #4']);
	assert.deepEqual(requests, []);
	items = [approval]; response = { error: 'That request is no longer waiting' };
	assert.deepEqual(await run('answer', path, '8', 'allow'), [1, '', 'test-copy: That request is no longer waiting']);
	console.log('ok: the conversation form answers only a single matching approval');

	const answers = [
		{ kind: 'approval', decision: 'once' }, { kind: 'question', text: 'Friday at noon' },
		{ kind: 'decision', choice: 'c2' }, { kind: 'decision', text: 'Another layout' },
		{ kind: 'reach', allow: false }, { kind: 'limit', start: true },
		{ kind: 'rule', accept: true, text: 'Use the edited rule', binds: 'everyone' },
	];
	response = { result: {} }; requests = [];
	for (const answer of answers) {
		assert.deepEqual(await run('answer', path, '124', JSON.stringify(answer)), [0, 'Answered Needs you item 124 in test-7.', '']);
	}
	assert.deepEqual(requests, answers.map(answer => ({ id: 1, method: 'needs.answer', params: { id: '124', answer } })));
	assert.equal((await run('answer', path, 'n1', '{'))[0], 1);
	assert.equal((await run('answer', path, 'n1', '[]'))[0], 1);

	// The copy's engine takes an answer from test-copy only with the key it wrote for it (#504): sent first, from its file.
	keyFile = join(folder, 'answer-key');
	writeFileSync(keyFile, 'k3y\n');
	items = [approval]; requests = []; response = { result: {} };
	assert.deepEqual(await run('answer', path, '8', 'allow'), [0, 'Allowed once the request in conversation #8 in test-7.', '']);
	assert.deepEqual(requests, [
		{ id: 0, method: 'test-copy.answerer', params: { key: 'k3y' } },
		{ id: 1, method: 'inbox.decide', params: { id: 'first', decision: 'once' } },
	]);
	requests = [];
	const keyedAnswer = { kind: 'decision', choice: 'c1' };
	assert.deepEqual(await run('answer', path, 'n2', JSON.stringify(keyedAnswer)), [0, 'Answered Needs you item n2 in test-7.', '']);
	assert.deepEqual(requests, [
		{ id: 0, method: 'test-copy.answerer', params: { key: 'k3y' } },
		{ id: 1, method: 'needs.answer', params: { id: 'n2', answer: keyedAnswer } },
	]);
	keyResponse = { error: "That is not this test copy's key" }; requests = [];
	assert.deepEqual(await run('answer', path, '8', 'allow'), [1, '', "test-copy: the copy's engine did not take its key: That is not this test copy's key"]);
	keyFile = join(folder, 'no-key'); keyResponse = { result: {} };
	console.log('ok: answer gives the copy’s key first when it has one, and says so when the engine refuses it');

	requests = []; response = { result: { id: 32, entries: 600 } };
	assert.deepEqual(await run('fill', path, '600'), [0, 'Created conversation #32 with 600 entries in test-7.', '']);
	assert.deepEqual(await run('fill', path, '10001'), [1, '', 'test-copy: entries must be a positive integer (up to 10000)']);
	assert.deepEqual(requests, [{ id: 1, method: 'test-copy.fill', params: { entries: 600 } }]);
	console.log('ok: fill sends one fixture request and refuses an out-of-range entry count');
	const project = { id: 'p-demo', name: 'Demo project', conversations: { Orchestrator: 8 }, omitted: ['reach (#465)'] };
	requests = []; response = { result: project };
	for (const option of ['--project', 'project']) {
		assert.deepEqual(await run('fill', path, option), [0, JSON.stringify(project), 'Not seeded: reach (#465).']);
	}
	assert.deepEqual(requests, Array.from({ length: 2 }, () => ({ id: 1, method: 'test-copy.fillProject', params: {} })));

	const control = join(folder, 'control');
	for (const [command, args, fields, reply] of [
		['show', ['project:Demo project#agent:Atlas', '--hub', 'board-folded'],
			{ show: 'project:Demo project#agent:Atlas', hub: 'board-folded' }, { result: 'Recorded project:Demo project#agent:Atlas (board-folded)' }],
		['show', ['dashboard'], { show: 'dashboard' }, { result: 'Recorded dashboard' }],
		['show', ['8'], { id: 8 }, { result: 'Showing conversation #8, drawn' }],
		['show', ['9'], { id: 9 }, { result: 'Showing conversation #9, though its page had not drawn it after 20 seconds' }],
		['size', ['820', '532'], { width: 820, height: 532 }, { result: 'Sized the main window to 820×532 points' }],
		['size', ['smallest'], { smallest: true }, { error: 'no main window' }],
		['expose', [], {}, { result: "Exposed the parked main window; it is now in the app's accessibility window list" }],
		['expose', [], {}, { error: "the main window did not join the app's accessibility window list when raised" }],
		['expose', [], {}, { error: 'unknown test-copy window command' }],
		['choose', ['app/build/file with spaces', '/tmp/second'], { paths: [join(process.cwd(), 'app/build/file with spaces'), '/tmp/second'] },
			{ result: 'Armed the next panel with 2 path(s)' }],
		['choose', ['cancel'], { paths: [] }, { result: 'Armed the next panel to cancel' }],
		['choose', ['/outside'], { paths: ['/outside'] }, { error: 'path outside allowed roots' }],
	]) {
		const pending = run(command, control, '321', ...args);
		const deadline = performance.now() + 3000;
		let received;
		while (performance.now() < deadline) {
			try {
				const [dir] = readdirSync(control);
				if (dir) {
					const request = JSON.parse(readFileSync(join(control, dir, 'request.json'), 'utf8'));
					assert.deepEqual(request, { pid: 321, command, ...fields });
					writeFileSync(join(control, dir, 'response.json'), JSON.stringify(reply));
					received = true;
					break;
				}
			} catch (error) { if (error.code !== 'ENOENT') throw error; }
			await sleep(20);
		}
		assert.ok(received, 'no request reached the stand-in window');
		assert.deepEqual(await pending, reply.error ? [1, '', `test-copy: ${reply.error}`] : [0, `${reply.result} in test-7.`, '']);
		assert.deepEqual(readdirSync(control), []);
	}
	assert.deepEqual(await run('show', control, '321', '0'), [1, '', 'test-copy: conversation must be a positive integer']);
	assert.deepEqual(await run('size', control, '321', '8.5', '532'), [1, '', 'test-copy: width must be a positive integer (up to 10000)']);
	assert.deepEqual(await run('choose', control, '321', 'cancel', '/tmp/second'), [1, '', 'test-copy: choose takes one or more paths, or cancel on its own']);
	assert.deepEqual(await run('choose', control, '321', ''), [1, '', 'test-copy: choose takes one or more paths, or cancel on its own']);
	assert.deepEqual(readdirSync(control), []);
	console.log('ok: show, size and choose send requests to the recorded app and report only after it replies');
} finally {
	server.close();
	rmSync(folder, { recursive: true, force: true });
}
