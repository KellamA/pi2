// A stand-in for the engine that runs models on this Mac (Strata), for engine/test/localrun.ts. Not a test itself.
//
// It takes the command line localengine.ts gives Strata's server (`server.py --engine strata --config <run config>
// --host --port --parallel --shutdown-timeout`, started as the control package's Python, which the test makes a script
// that runs this), serves the same OpenAI-compatible API on the address it is given, and behaves as its "model" file
// says: a JSON file the run config names as the engine's `--native` file, as Strata's names the model's first file:
//
//   { "gate": "<path>" }     loading ends once that file exists, so a test decides when it is loaded; else at once
//   { "fail": "<words>" }    it prints them and exits 1 while loading, as an engine that cannot load the model does
//   { "child": true }        it starts a program of its own in a process group of its own, as Strata's server starts
//                            its engine (#290), which a signal to the stand-in's group does not reach
//   { "ignoreTerm": true }   it ignores SIGTERM, so only SIGKILL ends it
//
// While loading it prints "loading model … N%" and "[strata] mapping the experts ...", as Strata does, and answers 503; once loaded, `GET /v1/models` lists the model and
// `POST /v1/chat/completions` answers "You said: <the last message>". A message holding "/crash" makes it exit
// mid-answer, once per model file (a `.crashed` file beside it remembers). A `/engine-stop <file> <count> [<gate>]`
// request gets Strata's engine-exit error for its first <count> attempts, once the optional gate exists. The file
// records every prompt. Replace <gate> with `tool` to answer with a tool call, then repeat the failures after its result.
// One holding "/hold <path>" is answered in
// part, and finished once that file exists. When the engine gave it a key (STRATA_API_KEY), a request without it is
// refused. It writes its own process number, and its program's, beside the model file (`.pid`, `.child`), with its
// command line (`.args`) and the run config it was given (`.config`).

import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename } from "node:path";

const args = process.argv.slice(2);
const flag = (name: string) => {
	const at = args.indexOf(name);
	return at === -1 ? undefined : args[at + 1];
};
// The run config pi² wrote for this start, with the engine's arguments in it.
const config = JSON.parse(readFileSync(flag("--config") ?? "", "utf8")) as { args: string[]; vision?: unknown };
const engineFlag = (name: string) => {
	const at = config.args.indexOf(name);
	return at === -1 ? undefined : config.args[at + 1];
};
const modelPath = engineFlag("--native") ?? "";
const host = flag("--host") ?? "";
const port = Number(flag("--port"));
const behaviour = JSON.parse(readFileSync(modelPath, "utf8")) as { gate?: string; fail?: string; child?: boolean; ignoreTerm?: boolean };
const modelId = basename(modelPath).replace(/\.json$/, "");
const key = process.env.STRATA_API_KEY;

writeFileSync(`${modelPath}.pid`, String(process.pid));
writeFileSync(`${modelPath}.args`, JSON.stringify(args));
writeFileSync(`${modelPath}.config`, JSON.stringify(config));
if (behaviour.ignoreTerm === true) process.on("SIGTERM", () => console.log("SIGTERM ignored"));
if (behaviour.child === true) {
	const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1e9)"], { stdio: "ignore", detached: true });
	writeFileSync(`${modelPath}.child`, String(child.pid));
}

console.log(`stand-in engine: serving ${modelId} on ${host}:${port}, context ${engineFlag("--max-context")}`);
if (host !== "127.0.0.1") {
	console.error(`error: asked to listen on ${host}, not 127.0.0.1`);
	process.exit(2);
}

let loaded = false;
const loading = setInterval(() => {
	if (behaviour.fail !== undefined) {
		console.log("loading model … 10%");
		console.error(`error: ${behaviour.fail}`);
		process.exit(1);
	}
	if (behaviour.gate === undefined || existsSync(behaviour.gate)) {
		console.log("loading model … 100%");
		console.log("model loaded; ready");
		loaded = true;
		clearInterval(loading);
	} else {
		console.log("loading model … 40%");
		console.log("[strata] mapping the experts ...");
	}
}, 50);

function refuse(response: ServerResponse, status: number, message: string): void {
	response.writeHead(status, { "content-type": "application/json" });
	response.end(JSON.stringify({ error: { message } }));
}

function body(request: IncomingMessage): Promise<string> {
	return new Promise((resolve) => {
		let text = "";
		request.setEncoding("utf8").on("data", (chunk: string) => (text += chunk)).on("end", () => resolve(text));
	});
}

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((part: { type?: string; text?: string }) => (part?.type === "text" ? (part.text ?? "") : "")).join("");
}

const chunk = (delta: Record<string, unknown>, finish: string | null = null) =>
	`data: ${JSON.stringify({ id: "chatcmpl-standin", object: "chat.completion.chunk", created: Math.floor(Date.now() / 1000), model: modelId, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;

const server = createServer(async (request, response) => {
	if (key !== undefined && request.headers.authorization !== `Bearer ${key}`) return refuse(response, 401, "wrong key");
	if (!loaded) return refuse(response, 503, "Loading model");
	if (request.method === "GET" && request.url === "/v1/models") {
		response.writeHead(200, { "content-type": "application/json" });
		return response.end(JSON.stringify({ object: "list", data: [{ id: modelId, object: "model" }] }));
	}
	if (request.method !== "POST" || request.url !== "/v1/chat/completions") return refuse(response, 404, "not found");
	const asked = JSON.parse(await body(request)) as { messages?: { role?: string; content?: unknown }[]; stream?: boolean };
	const last = textOf([...(asked.messages ?? [])].reverse().find((message) => message.role === "user")?.content).trim();
	const failure = /^\/engine-stop (\S+) (\d+)(?: (\S+))?$/.exec(last);
	if (failure !== null) {
		const path = failure[1]!;
		const count = Number(failure[2]);
		const gate = failure[3];
		const withTool = gate === "tool";
		const afterTool = withTool && asked.messages?.some((message) => message.role === "tool");
		const record = afterTool ? `${path}.after-tool` : path;
		const prompts: unknown[] = existsSync(record) ? JSON.parse(readFileSync(record, "utf8")) : [];
		prompts.push(asked.messages);
		writeFileSync(record, JSON.stringify(prompts));
		if (prompts.length <= count) {
			if (gate !== undefined && !withTool) while (!existsSync(gate)) await new Promise((resolve) => setTimeout(resolve, 50));
			return refuse(response, 500, "the engine stopped unexpectedly (exit code -6); the next request restarts it");
		}
		if (withTool && !afterTool) {
			const fn = { name: "update_plan", arguments: JSON.stringify({ items: [{ content: "Test retry reset", status: "completed" }] }) };
			response.writeHead(200, { "content-type": "text/event-stream" });
			response.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: "call_reset", type: "function", function: fn }] }));
			response.write(chunk({}, "tool_calls"));
			return response.end("data: [DONE]\n\n");
		}
	}
	const answer = `You said: ${last}`;
	response.writeHead(200, { "content-type": "text/event-stream" });
	response.write(chunk({ role: "assistant", content: "" }));
	response.write(chunk({ content: "You said: " }));
	if (last.includes("/crash") && !existsSync(`${modelPath}.crashed`)) {
		writeFileSync(`${modelPath}.crashed`, "");
		console.error("crashing, as asked");
		process.exit(3);
	}
	const hold = /\/hold (\S+)/.exec(last)?.[1];
	if (hold !== undefined) while (!existsSync(hold)) await new Promise((resolve) => setTimeout(resolve, 50));
	response.write(chunk({ content: answer.slice("You said: ".length) }));
	response.write(chunk({}, "stop"));
	response.write(`data: ${JSON.stringify({ id: "chatcmpl-standin", object: "chat.completion.chunk", choices: [], usage: { prompt_tokens: 12, completion_tokens: 6, total_tokens: 18 } })}\n\n`);
	response.end("data: [DONE]\n\n");
});
server.listen(port, host);
