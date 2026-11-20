// Invoked by test-copy only after checking that the copy and process belong to this checkout.
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as sleep } from 'node:timers/promises';

const [command, target, suffix, ...args] = process.argv.slice(2);
const limit = 30_000;
// The key the copy's engine wrote for test-copy, with which it takes an answer for the person from this connection, which
// is not the app's (#504). Read from its file, never passed on a command line.
let key;
try { if (process.env.TEST_COPY_KEY_FILE) key = readFileSync(process.env.TEST_COPY_KEY_FILE, 'utf8').trim(); } catch {}

function integer(value, label, max = Number.MAX_SAFE_INTEGER) {
	const n = Number(value);
	if (!/^\d+$/.test(value ?? '') || !Number.isSafeInteger(n) || n < 1 || n > max) {
		throw new Error(`${label} must be a positive integer${max === Number.MAX_SAFE_INTEGER ? '' : ` (up to ${max})`}`);
	}
	return n;
}

async function windowCommand(folder, request) {
	mkdirSync(folder, { recursive: true, mode: 0o700 });
	if (!lstatSync(folder).isDirectory()) throw new Error('the copy’s window control path is not a directory');
	const dir = mkdtempSync(join(folder, 'request-'));
	try {
		const pending = join(dir, 'pending.json');
		writeFileSync(pending, JSON.stringify(request));
		renameSync(pending, join(dir, 'request.json'));
		const deadline = performance.now() + limit;
		while (performance.now() < deadline) {
			try {
				const response = JSON.parse(readFileSync(join(dir, 'response.json'), 'utf8'));
				if (response.error) throw new Error(response.error);
				if (typeof response.result !== 'string') throw new Error('invalid response from the copy’s window');
				return response.result;
			} catch (error) {
				if (error.code !== 'ENOENT') throw error;
			}
			await sleep(100);
		}
		throw new Error('the main window did not answer within 30 seconds; check it is open and rebuild and reopen the copy if needed');
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

function engineCommand(prepare, seconds = limit / 1000) {
	return new Promise((resolve, reject) => {
		const socket = connect(target);
		const lines = createInterface({ input: socket });
		let sent = false;
		let request;
		const timer = setTimeout(() => finish(new Error(`the engine did not answer within ${seconds} seconds`)), seconds * 1000);
		function finish(error, result) {
			clearTimeout(timer);
			lines.close();
			socket.destroy();
			if (error) reject(error); else resolve(result);
		}
		function accept(prepared) {
			if (!prepared) return;
			if ('snapshot' in prepared) { finish(null, prepared.snapshot); return; }
			request = prepared;
			sent = true;
			socket.write(JSON.stringify({ id: 1, method: request.method, params: request.params }) + '\n');
		}
		socket.once('connect', () => {
			if (key) socket.write(JSON.stringify({ id: 0, method: 'test-copy.answerer', params: { key } }) + '\n');
			try { accept(prepare()); } catch (error) { finish(error); }
		});
		socket.once('error', error => finish(error));
		socket.once('close', () => finish(new Error('the engine connection closed before it answered')));
		lines.on('line', line => {
			try {
				const message = JSON.parse(line);
				if (message.event === undefined && message.id === 0) {
					if (message.error !== undefined) throw new Error(`the copy's engine did not take its key: ${message.error}`);
				} else if (!sent) accept(prepare(message));
				else if (message.event === undefined && message.id === 1) {
					if (message.error !== undefined) throw new Error(message.error);
					finish(null, request.summary(message.result));
				}
			} catch (error) { finish(error); }
		});
	});
}

try {
	let summary;
	switch (command) {
		case 'show': {
			const [pid, selection, , hub] = args;
			// A project, the Dashboard and a conversation number as they were, and every other page PI2_SHOW takes by
			// name (usage, archive, settings:<tab>, …), which the app reads as it reads PI2_SHOW (#553).
			let view;
			if (selection === 'dashboard' || selection?.startsWith('project:')) view = { show: selection, hub };
			else if (/^\d+$/.test(selection ?? '')) view = { id: integer(selection, 'conversation') };
			else if (selection) view = { page: selection };
			else throw new Error('conversation must be a positive integer');
			summary = await windowCommand(target, { pid: Number(pid), command, ...view });
			break;
		}
		case 'size': {
			const [pid, width, height] = args;
			const size = width === 'smallest' ? { smallest: true } : { width: integer(width, 'width', 10_000), height: integer(height, 'height', 10_000) };
			summary = await windowCommand(target, { pid: Number(pid), command, ...size });
			break;
		}
		case 'choose': {
			const [pid, ...paths] = args;
			if (!paths.length || paths.some(path => !path) || (paths[0] === 'cancel' && paths.length !== 1)) {
				throw new Error('choose takes one or more paths, or cancel on its own');
			}
			const absolute = paths[0] === 'cancel' ? [] : paths.map(path => path.startsWith('/') ? path : `${process.cwd()}/${path}`);
			summary = await windowCommand(target, { pid: Number(pid), command, paths: absolute });
			break;
		}
		case 'conversations': {
			// The engine sends the same initial Library and Archive to every connection. No request is needed.
			const rows = await engineCommand(event => {
				if (event?.event !== 'library') return;
				return { snapshot: [...event.conversations, ...event.archived] };
			});
			// Escape tabs and line breaks in titles so each conversation still takes one line and three fields.
			const field = value => JSON.stringify(value).slice(1, -1);
			for (const { id, title, agentId } of rows) console.log(`${id}\t${field(title)}\t${field(agentId ?? '-')}`);
			break;
		}
		case 'answer': {
			const [value, decision] = args;
			if (decision !== 'allow' && decision !== 'deny') {
				const answer = JSON.parse(decision);
				if (answer === null || typeof answer !== 'object' || Array.isArray(answer)) throw new Error('answer needs a JSON object');
				summary = await engineCommand(() => ({
					method: 'needs.answer', params: { id: value, answer },
					summary: () => `Answered Needs you item ${value}`,
				}));
				break;
			}
			const id = integer(value, 'conversation');
			summary = await engineCommand(event => {
				if (event?.event !== 'inbox') return;
				const items = event.items.filter(item => item.kind === 'approval' && item.conversationId === id);
				if (!items.length) throw new Error(`no approval waiting in conversation #${id}`);
				if (items.length !== 1) throw new Error(`conversation #${id} has ${items.length} approvals waiting; choose one in the copy instead`);
				return {
					method: 'inbox.decide', params: { id: items[0].id, decision: decision === 'allow' ? 'once' : 'deny' },
					summary: () => `${decision === 'allow' ? 'Allowed once' : 'Denied'} the request in conversation #${id}`,
				};
			});
			break;
		}
		case 'fill': {
			if (args[0] === '--project' || args[0] === 'project') {
				// A name for one project of that name, or a count of them; neither makes one as before (#481).
				const given = args[1] ?? '';
				if (given.includes('\n')) throw new Error('a project name takes one line');
				const params = given === '' ? {} : /^\d+$/.test(given) ? { count: integer(given, 'count', 8) } : { name: given };
				const project = await engineCommand(() => ({ method: 'test-copy.fillProject', params, summary: result => result }), 150 * (params.count ?? 1));
				const made = Array.isArray(project) ? project : [project];
				for (const one of made) console.log(JSON.stringify(one));
				console.error(`Not seeded: ${made[0].omitted.join('; ')}.`);
				break;
			}
			const entries = integer(args[0], 'entries', 10_000);
			summary = await engineCommand(() => ({
				method: 'test-copy.fill', params: { entries },
				summary: result => `Created conversation #${result.id} with ${result.entries} entries`,
			}));
			break;
		}
		default: throw new Error('unknown test-copy command');
	}
	if (summary !== undefined) console.log(`${summary} in ${suffix}.`);
} catch (error) {
	console.error(`test-copy: ${error.message.replace(/[\r\n]+/g, ' ')}`);
	process.exitCode = 1;
}
