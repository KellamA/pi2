// scripts/test-copy remote-on (#951): keeps a paired phone's address working after the copy's pi² Remote starts again.
//
// A phone in the simulator knows the Mac only by the address in its pairing code (a copy's pi² Remote has no Bonjour
// and dials no relay), and pi² Remote, started again, listens on a new port. This forwards the port the phone knows to
// the one pi² Remote has now, on 127.0.0.1 alone, byte for byte: the channel is the phone's and pi² Remote's own,
// sealed end to end, and nothing here reads it. A connection whose other end cannot be reached is closed at once, as
// a port with nothing on it would refuse it.
//
//   node scripts/test-copy-forward.mjs start <port the phone knows> <pi² Remote's port> <log file>
//     starts the forwarder on its own (a new session, so it outlives the command that started it), waits until it
//     listens or fails, and prints its process id; test-copy records it, and stops it by that pid
//   node scripts/test-copy-forward.mjs serve <port the phone knows> <pi² Remote's port>
//     is the forwarder itself
import { spawn } from 'node:child_process';
import { closeSync, openSync, readFileSync } from 'node:fs';
import { connect, createServer } from 'node:net';
import { setTimeout as sleep } from 'node:timers/promises';

const HOST = '127.0.0.1';
const LISTENING = 'forwarding';
const [mode, from, to, log] = process.argv.slice(2);
const port = text => {
	const n = Number(text);
	if (!/^[1-9][0-9]{0,4}$/.test(text ?? '') || n > 65535) {
		console.error(`test-copy-forward: '${text}' is not a port`);
		process.exit(2);
	}
	return n;
};
const listen = port(from), target = port(to);
if (listen === target) {
	console.error('test-copy-forward: the two ports are the same; nothing to forward');
	process.exit(2);
}

if (mode === 'serve') {
	const server = createServer({ pauseOnConnect: true }, phone => {
		const mac = connect({ host: HOST, port: target });
		const end = () => { phone.destroy(); mac.destroy(); };
		for (const socket of [phone, mac]) socket.on('error', end).on('close', end);
		mac.on('connect', () => {
			phone.pipe(mac);
			mac.pipe(phone);
			phone.resume();
		});
	});
	server.on('error', error => {
		console.error(`test-copy-forward: could not listen on ${HOST}:${listen}: ${error.message}`);
		process.exit(1);
	});
	server.listen(listen, HOST, () => console.log(`${LISTENING} ${HOST}:${listen} to ${HOST}:${target}`));
	for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => process.exit(0));
} else if (mode === 'start' && log) {
	// Written afresh, so that an earlier forwarder's line is never taken for this one's.
	const out = openSync(log, 'w');
	const child = spawn(process.execPath, [import.meta.filename, 'serve', from, to], { detached: true, stdio: ['ignore', out, out], env: {} });
	closeSync(out);
	let exited = null;
	child.on('exit', code => { exited = code ?? 1; });
	child.unref();
	for (let waited = 0; waited < 200; waited++) {
		const said = readFileSync(log, 'utf8');
		if (said.includes(`${LISTENING} ${HOST}:${listen} `)) {
			console.log(child.pid);
			process.exit(0);
		}
		if (exited !== null) {
			console.error(said.trim().split('\n').at(-1) || `test-copy-forward: the forwarder exited (${exited})`);
			process.exit(1);
		}
		await sleep(50);
	}
	child.kill('SIGTERM');
	console.error('test-copy-forward: the forwarder did not listen within ten seconds');
	process.exit(1);
} else {
	console.error('use: node scripts/test-copy-forward.mjs start <port> <port> <log> | serve <port> <port>');
	process.exit(2);
}
