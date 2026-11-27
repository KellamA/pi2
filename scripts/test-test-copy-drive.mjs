// Protocol checks with stand-ins for the app and engine. Nothing is launched except the script under test.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { appendFileSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as sleep } from 'node:timers/promises';

const folder = mkdtempSync(join(tmpdir(), 'pi2-drive-'));
const path = join(folder, 'engine.sock');
const script = join(import.meta.dirname, 'test-copy-drive.mjs');
// The child's own waits (30 seconds for a window command, 10 for attached) bound a healthy run; this ceiling only
// guards a hang. A heavily loaded CI runner can take well over four seconds to start Node and answer, which once
// failed the show check by chance (#860), so it is a minute and not a race against the runner's load.
const run = (command, target, ...args) => new Promise(resolve => {
	const env = { ...process.env, TEST_COPY_KEY_FILE: keyFile };
	execFile(process.execPath, [script, command, target, 'test-7', ...args], { timeout: 60_000, env }, (error, out, err) => {
		resolve([error?.code ?? 0, out.trim(), err.trim()]);
	});
});
const approval = { id: 'first', kind: 'approval', conversationId: 8, rootConversationId: 4 };
// What the script under test prints of the copy's words, such as a pressed control's label: every control character
// flattened to a space, as the script itself flattens them.
const flat = text => String(text).replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ');
let items, requests, response, keyFile = join(folder, 'no-key'), keyResponse = { result: {} };
const emptyLibrary = { event: 'library', conversations: [], archived: [] };
let library = emptyLibrary;
const server = createServer(socket => {
	// The client under test may close its end before the stand-in has answered everything (#787): a write then fails
	// with EPIPE, which must not end this process, and nothing more is written.
	socket.on('error', () => {});
	const send = message => { if (socket.writable && !socket.writableEnded) socket.write(JSON.stringify(message) + '\n'); };
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
	// As the copy's own writer (TestCopyControl's answer): written whole under a temporary name and renamed into
	// place, so the reader never finds a half-written response.json (#860).
	const answer = (dir, reply) => {
		const file = join(control, dir, 'response.json.tmp');
		writeFileSync(file, JSON.stringify(reply));
		renameSync(file, join(control, dir, 'response.json'));
	};
	for (const [command, args, fields, reply] of [
		['show', ['project:Demo project#agent:Atlas', '--hub', 'board-folded'],
			{ show: 'project:Demo project#agent:Atlas', hub: 'board-folded' }, { result: 'Recorded project:Demo project#agent:Atlas (board-folded)' }],
		['show', ['dashboard'], { show: 'dashboard' }, { result: 'Recorded dashboard' }],
		['show', ['8'], { id: 8 }, { result: 'Showing conversation #8, drawn' }],
		['show', ['9'], { id: 9 }, { result: 'Showing conversation #9, though its page had not drawn it after 20 seconds' }],
		// Every other page PI2_SHOW takes goes by name, not as a conversation number (#553).
		['show', ['usage'], { page: 'usage' }, { result: 'Showing usage; test-copy cannot wait for its page to be drawn' }],
		['show', ['archive'], { page: 'archive' }, { result: 'Showing archive; test-copy cannot wait for its page to be drawn' }],
		['show', ['settings:general'], { page: 'settings:general' }, { result: 'Opened Settings on General; test-copy cannot wait for it to be drawn' }],
		['show', ['agent:atlas#tools'], { page: 'agent:atlas#tools' }, { result: 'Showing agent:atlas#tools; test-copy cannot wait for its page to be drawn' }],
		['show', ['palette:duplicate'], { page: 'palette:duplicate' }, { result: 'Opened the command palette with “duplicate” in its search field; test-copy cannot wait for it to be drawn' }],
		['show', ['nosuchpage'], { page: 'nosuchpage' }, { error: 'no page or conversation called nosuchpage' }],
		['size', ['820', '532'], { width: 820, height: 532 }, { result: 'Sized the main window to 820×532 points' }],
		['size', ['smallest'], { smallest: true }, { error: 'no main window' }],
		['expose', [], {}, { result: 'Raised the parked main window within its own level' }],
		['expose', [], {}, { error: "the main window did not join the app's accessibility window list when raised" }],
		['expose', [], {}, { error: 'unknown test-copy window command' }],
		['choose', ['app/build/file with spaces', '/tmp/second'], { paths: [join(process.cwd(), 'app/build/file with spaces'), '/tmp/second'] },
			{ result: 'Armed the next panel with 2 path(s)' }],
		['choose', ['cancel'], { paths: [] }, { result: 'Armed the next panel to cancel' }],
		['choose', ['/outside'], { paths: ['/outside'] }, { error: 'path outside allowed roots' }],
		// A control by its label, and the card and conversation, as words (#1023); what is pressed is the copy's to say.
		['press', ['Expand'], { label: 'Expand' }, { result: 'Pressed “Expand “Mockups”” in “Mockups” on the page of conversation #9' }],
		['press', ['  Expand ', '--within', 'Two pictures', '--conversation', '9'], { label: 'Expand', within: 'Two pictures', id: 9 },
			{ result: 'Pressed “Expand “Two pictures”” in “Two pictures” on the page of conversation #9' }],
		['press', ['Nothing like it'], { label: 'Nothing like it' }, { error: 'conversation #9: no control labelled “Nothing like it” is shown on the page' }],
		// A refusal repeats the page's words, and a label a model wrote can hold anything: every control character, such as
		// an escape, is flattened before the words reach the terminal. The pressed answer is flattened the same way.
		['press', ['Nothing like it'], { label: 'Nothing like it' }, { error: 'conversation #9: no control labelled “\u001b[31mNothing like it\u001b[0m” is shown on the page' }],
		['press', ['Expand'], { label: 'Expand' }, { result: 'Pressed “\u001b[31mred\u001b[0m” in “Mockups” on the page of conversation #9' }],
	]) {
		const pending = run(command, control, '321', ...args);
		// 60 seconds, not the 3 the poll needs: a loaded runner can take that long to start the child, and only a
		// request that never comes should reach the deadline (#860).
		const deadline = performance.now() + 60_000;
		let received;
		while (performance.now() < deadline) {
			try {
				const [dir] = readdirSync(control);
				if (dir) {
					const request = JSON.parse(readFileSync(join(control, dir, 'request.json'), 'utf8'));
					assert.deepEqual(request, { pid: 321, command, ...fields });
					answer(dir, reply);
					received = true;
					break;
				}
			} catch (error) { if (error.code !== 'ENOENT') throw error; }
			await sleep(20);
		}
		assert.ok(received, 'no request reached the stand-in window');
		assert.deepEqual(await pending, reply.error ? [1, '', `test-copy: ${flat(reply.error)}`] : [0, `${flat(reply.result)} in test-7.`, '']);
		assert.deepEqual(readdirSync(control), []);
	}
	// The windows attached to one, for shot (#779): printed as the copy gives them, for the script to read.
	for (const [reply, expected] of [[{ result: '17551 17552' }, [0, '17551 17552', '']], [{ result: '' }, [0, '', '']],
		[{ error: 'the copy has no window 17550' }, [1, '', 'test-copy: the copy has no window 17550']]]) {
		const pending = run('attached', control, '321', '17550');
		const deadline = performance.now() + 60_000;
		let received;
		while (performance.now() < deadline && !received) {
			const [dir] = readdirSync(control);
			try {
				if (dir) {
					assert.deepEqual(JSON.parse(readFileSync(join(control, dir, 'request.json'), 'utf8')), { pid: 321, command: 'attached', window: 17550 });
					answer(dir, reply);
					received = true;
				}
			} catch (error) { if (error.code !== 'ENOENT') throw error; }
			if (!received) await sleep(20);
		}
		assert.ok(received, 'no attached request reached the stand-in window');
		assert.deepEqual(await pending, expected);
	}
	// A writer that does not rename its answer into place can have the reader find response.json before all of it is
	// written (#860): the reader keeps reading a file that does not parse yet and answers once the rest is there.
	{
		const pending = run('attached', control, '321', '17550');
		const deadline = performance.now() + 60_000;
		let written = false;
		while (performance.now() < deadline && !written) {
			const [dir] = readdirSync(control);
			try {
				if (dir) {
					assert.deepEqual(JSON.parse(readFileSync(join(control, dir, 'request.json'), 'utf8')), { pid: 321, command: 'attached', window: 17550 });
					const half = '{"result":"17551 175';
					const file = join(control, dir, 'response.json');
					writeFileSync(file, half); // deliberately not atomic: the answer half written
					await sleep(300); // the writer still writing it
					appendFileSync(file, '52"}'); // the rest of it
					written = true;
				}
			} catch (error) { if (error.code !== 'ENOENT') throw error; }
			if (!written) await sleep(20);
		}
		assert.ok(written, 'no attached request reached the stand-in window for the half-written answer');
		assert.deepEqual(await pending, [0, '17551 17552', '']);
		assert.deepEqual(readdirSync(control), []);
	}
	assert.deepEqual(await run('attached', control, '321', 'x'), [1, '', 'test-copy: window must be a positive integer']);
	assert.deepEqual(await run('show', control, '321', '0'), [1, '', 'test-copy: conversation must be a positive integer']);
	assert.deepEqual(await run('size', control, '321', '8.5', '532'), [1, '', 'test-copy: width must be a positive integer (up to 10000)']);
	assert.deepEqual(await run('choose', control, '321', 'cancel', '/tmp/second'), [1, '', 'test-copy: choose takes one or more paths, or cancel on its own']);
	assert.deepEqual(await run('choose', control, '321', ''), [1, '', 'test-copy: choose takes one or more paths, or cancel on its own']);
	for (const [args, words] of [
		[[''], 'the label must not be empty'],
		[['two\nlines'], 'the label takes one line'],
		[['x'.repeat(301)], 'the label is at most 300 characters'],
		[['Expand', '--within', ''], '--within must not be empty'],
		[['Expand', '--conversation', 'nine'], 'conversation must be a positive integer'],
		[['Expand', '--selector', 'button'], 'press takes a label, then --within <card or group label> and --conversation <id>, each once'],
		[['Expand', '--within', 'A', '--within', 'B'], 'press takes a label, then --within <card or group label> and --conversation <id>, each once'],
	]) assert.deepEqual(await run('press', control, '321', ...args), [1, '', `test-copy: ${words}`]);
	assert.deepEqual(readdirSync(control), []);
	console.log('ok: show, size, choose, press and attached send requests to the recorded app and report only after it replies');
} finally {
	server.close();
	rmSync(folder, { recursive: true, force: true });
}
