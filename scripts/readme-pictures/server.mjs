// A stand-in for an OpenAI-compatible model server, for staging the README's pictures in a throwaway copy of pi²
// (README.md here). Each answer comes from scenario.mjs: the turn is chosen by the newest message from the person (or
// a wake), and the step by how many answers have followed it. Tools run for real in the copy; their results are not
// read here. It listens on 127.0.0.1 only, and prints a line for each request.
//
//   node scripts/readme-pictures/server.mjs [port]     (47291 by default)
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";

const here = new URL(".", import.meta.url).pathname;
const log = (line) => console.log(`${new Date().toISOString()} ${line}`);
const port = Number(process.argv[2] ?? 47291);

const textOf = (content) => typeof content === "string" ? content : Array.isArray(content) ? content.map((part) => part?.text ?? "").join("") : "";

async function scenario() {
	// Read afresh on every request, so the script can be corrected while a copy runs.
	return (await import(`${pathToFileURL(`${here}scenario.mjs`).href}?${Date.now()}`)).turns;
}

function pick(turns, messages) {
	let index = -1;
	for (let i = messages.length - 1; i >= 0; i--) if (messages[i].role === "user") { index = i; break; }
	const said = index < 0 ? "" : textOf(messages[index].content);
	const step = messages.slice(index + 1).filter((message) => message.role === "assistant").length;
	const turn = turns.find((candidate) => candidate.match(said, messages));
	return { said, step, turn, steps: turn?.steps ?? [] };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let calls = 0;

createServer(async (req, res) => {
	try {
		if (req.method === "GET" && req.url.endsWith("/models")) {
			res.writeHead(200, { "content-type": "application/json" });
			res.end(JSON.stringify({ object: "list", data: ["qwen3-coder:30b", "gpt-oss:120b", "gemma3:27b"].map((id) => ({ id, object: "model" })) }));
			return;
		}
		let body = "";
		for await (const chunk of req) body += chunk;
		const request = JSON.parse(body);
		const { said, step, turn, steps } = pick(await scenario(), request.messages ?? []);
		const reply = steps[step] ?? { text: turn === undefined ? "Noted." : "Done." };
		log(`${request.model} turn=${turn?.name ?? "(none)"} step=${step} said=${JSON.stringify(said.slice(0, 160))}`);
		if (reply.delay) await sleep(reply.delay);
		res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
		const id = `chatcmpl-${Date.now()}`;
		const send = (choice, extra = {}) => res.write(`data: ${JSON.stringify({ id, object: "chat.completion.chunk", created: Math.floor(Date.now() / 1000), model: request.model, choices: choice === null ? [] : [{ index: 0, ...choice }], ...extra })}\n\n`);
		const text = reply.text ?? "";
		const words = text.match(/\S+\s*|\s+/g) ?? [];
		send({ delta: { role: "assistant", content: "" }, finish_reason: null });
		for (let i = 0; i < words.length; i += 3) {
			send({ delta: { content: words.slice(i, i + 3).join("") }, finish_reason: null });
			await sleep(reply.pace ?? 12);
		}
		const tools = reply.tools ?? [];
		tools.forEach(([name, args], index) => {
			send({ delta: { tool_calls: [{ index, id: `call_${++calls}_${Date.now()}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] }, finish_reason: null });
		});
		send({ delta: {}, finish_reason: tools.length > 0 ? "tool_calls" : "stop" });
		const prompt = Math.round(body.length / 3.7);
		const completion = Math.max(8, Math.round((text.length + JSON.stringify(tools).length) / 3.6));
		send(null, { usage: { prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion } });
		res.write("data: [DONE]\n\n");
		res.end();
	} catch (error) {
		log(`error ${error?.stack ?? error}`);
		if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" });
		res.end(JSON.stringify({ error: { message: String(error) } }));
	}
}).listen(port, "127.0.0.1", function () {
	const address = this.address();
	log(`listening on http://127.0.0.1:${address.port}/v1`);
});
