// The socket half of test-copy send. The shell checks ownership and the socket before invoking this file.
import { connect } from 'node:net';

const [path, idText, text, seconds = '600'] = process.argv.slice(2);
const id = Number(idText), timeout = Number(seconds);
if (!/^[1-9][0-9]*$/.test(idText ?? '') || !Number.isSafeInteger(id)) {
	console.error('test-copy: conversation must be a positive integer');
	process.exit(1);
}
if (typeof text !== 'string' || text.trim() === '') {
	console.error('test-copy: the message is empty');
	process.exit(1);
}
if (!Number.isFinite(timeout) || timeout <= 0 || timeout > 600) {
	console.error('test-copy: --timeout must be seconds greater than 0 and at most 600');
	process.exit(1);
}

const socket = connect(path);
let buffer = '', done = false, next = 1, submissionId, inbox = [], checking = false, dirty = false;
const replies = new Map(), items = new Map();
const timer = setTimeout(() => end('timeout', 124, `wait exceeded ${timeout} seconds; work was not stopped`), timeout * 1000);
function end(status, code, message, extra = {}) {
	if (done) return;
	done = true;
	clearTimeout(timer);
	process.exitCode = code;
	console.log(JSON.stringify({ id, submissionId: submissionId ?? null, status, ...extra }));
	if (message) console.error(`test-copy: ${message}`);
	socket.destroy();
}
function call(method, params) {
	return new Promise((resolve, reject) => {
		const request = next++;
		replies.set(request, { resolve, reject });
		socket.write(JSON.stringify({ id: request, method, params }) + '\n');
	});
}
// Conversation watches are coalesced: a fast run may go straight from idle to idle, with no busy event. Ask for the
// exact submission's durable status on each change, including once after submit. Never accept a prior idle state.
async function check() {
	if (submissionId === undefined || done) return;
	dirty = true;
	if (checking) return;
	checking = true;
	try {
		while (dirty && !done) {
			dirty = false;
			const { submission, busy } = await call('submission.get', { id, submissionId });
			if (done) return;
			if (submission.id !== submissionId) throw new Error('the engine returned a different submission');
			if (submission.status === 'unanswered') {
				end('failed', 1, `submission ${submissionId} ended without an answer: ${submission.reason}`, { submission });
			} else if (submission.status === 'done' && !busy && items.has(submission.answer)) {
				end('done', 0, null, { submission, answer: items.get(submission.answer)?.text ?? null });
			} else {
				const waiting = inbox.filter(item => item.conversationId === id || item.rootConversationId === id);
				if (waiting.length) end('waiting', 2, 'waiting for approval or an answer from the person; nothing was answered or stopped', { waiting });
			}
		}
	} catch (error) { end('error', 1, error.message); }
	finally { checking = false; }
}
socket.once('connect', async () => {
	try {
		await call('conversation.open', { id });
		// The subscription is installed before this request. Even a run finished before submit answers is found.
		const accepted = await call('submit', { id, text });
		submissionId = accepted.submissionId;
		if (!Number.isSafeInteger(submissionId)) throw new Error('the engine returned no submission id');
		void check();
	} catch (error) { end('error', 1, error.message); }
});
socket.once('error', error => end('error', 1, error.message));
socket.once('close', () => end('error', 1, 'the connection to the engine closed before the run finished; work was not stopped'));
socket.setEncoding('utf8').on('data', chunk => {
	buffer += chunk;
	const lines = buffer.split('\n');
	buffer = lines.pop();
	try {
		for (const line of lines) {
			if (done) break;
			const message = JSON.parse(line);
			if (message.event === 'conversation' && message.id === id) {
				if (message.reset) items.clear();
				for (const item of message.items) items.set(item.id, item);
				void check();
			} else if (message.event === 'inbox') {
				inbox = message.items;
				void check();
			} else if (message.event === undefined) {
				const reply = replies.get(message.id);
				replies.delete(message.id);
				if (message.error !== undefined) reply?.reject(new Error(message.error));
				else reply?.resolve(message.result);
			}
		}
	} catch (error) { end('error', 1, `invalid engine response: ${error.message}`); }
});
