# Code mode

An agent with **Write scripts that call its tools** switched on gets the `codemode` tool. The model writes a short JavaScript program, which runs in a QuickJS sandbox and calls the conversation's other tools as `await tools.<name>(args)`: many reads at once, a loop over files, a command whose output decides the next step. The script survives an engine restart and picks up where it was without running finished calls again. The tool and the sandbox are pi durable's (`@earendil-works/pi-durable/codemode`, `@earendil-works/pi-codemode`); `engine/src/codemode.ts` changes only what the model is told about them.

## What the model is told

Two things describe code mode to the model:

- **The tool's description**, the same in every conversation: how a script runs, what a call resolves to, the globals (`text`, `image`, `store`, `load`, `ALL_TOOLS`, `searchTools`, `describeTool`, `describeNamespace`, `models.*`), and that the `codemode` section says which tools a script can call.
- **The `codemode` section of the system prompt**, made for each request from the conversation's tools.

pi durable's own section declares, in TypeScript, every tool a script can call, up to about 3,000 tokens of them. That suits a model given few tools directly that reaches the rest through scripts. pi² gives a conversation all of its tools directly, MCP tools included, so those declarations said again what the tool definitions already say, and the section went into every conversation, with code mode or without it (#163). pi² makes the section from the same tools, as follows:

- **No `codemode` tool, no section.**
- **Tools the model was given directly** get a few lines, not declarations: scripts call them by the same names and with the same arguments; each resolves to its text output, except the tools that resolve to an object, which are named with the object's type (in pi², `read` and `bash`); a tool whose name is not a JavaScript name is given its name in scripts; and `ALL_TOOLS`, `searchTools(query)` and `describeTool(name)` list, find and describe them all.
- **Tools a script can call that the model was not given directly** are declared in full by pi durable's own listing, after those lines, as before. No conversation in pi² has such a tool today; the listing is there for one that does.
- **Tools pi durable defers** (none in pi² so far) stay out of the section, as they did before: scripts find them with `searchTools()`.

With the built-in tools the section is these lines, about 530 characters:

```
Scripts can call your other tools, by the same names and with the same arguments, as `await tools.<name>(args)`.
Each call resolves to the tool's text output, as a string, except:
- `tools.read()`: `string | { data: string; mimeType: string; type: "image"; }`
- `tools.bash()`: `{ exitCode: number; fullOutputPath?: string; output: string; truncated: boolean; }`
`ALL_TOOLS` lists every tool a script can call, `searchTools(query)` finds them by topic, and `describeTool(name)` gives a tool's declaration.
```

What a script can do is unchanged: it gets every tool the conversation can call, and `ALL_TOOLS`, `searchTools()` and `describeTool()` answer from all of them, whatever the section shows.

## Checking it

`engine/test/codemode.ts` (`npm run test:codemode`) starts an engine and checks the section for a plain agent with and without code mode, an agent with everything switched on, and one with a test MCP server of 40 tools, and that a script calls, lists, finds and describes an MCP tool the section does not show. It checks the full listing on the section itself, with a tool the model was not given. It also prints how long each section of the system prompt is in those conversations. The demo model's `/system sizes` answers with those lengths, and `/system codemode` with the section itself and the tools offered (see [development.md](development.md)).

Whether a real model writes scripts as well from these few lines as from the declarations has not been measured: the tests use the scripted demo model.
