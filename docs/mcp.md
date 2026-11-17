# MCP servers

An MCP server adds tools from another app or service. Add one in **Settings › Tools**, as a program pi² runs on this Mac or as a URL, and tick it for the agents that should have its tools, under Extra tools in each agent's settings. A server's tools reach a conversation at its next message after the server connects. The engine's side is `engine/src/mcp.ts`; what happens to a call when a server is reconnected, edited or removed is in [architecture.md](architecture.md#an-mcp-server-changed-while-a-call-runs-on-it).

## Read-only tools

A server can mark each of its tools as read-only, with `readOnlyHint: true` in the tool's `annotations`. pi² goes by that mark alone, and treats any tool without it as one that can change things, like its own commands and file edits:

- **Approval.** With tool access set to "Ask first", a call to a tool not marked read-only waits for your approval. A read-only one runs without asking.
- **The order of calls.** A model can make several tool calls in one answer. When one of them is a tool not marked read-only, the whole answer's calls run one at a time, in the order the model gave them, so a call that reads what the one before it wrote sees it (#190). An answer whose calls are all read-only tools (or other tools that only look) runs them side by side. See [architecture.md](architecture.md#the-calls-of-one-answer).

So for someone writing a server, or choosing one:

- Mark every tool that only reads as read-only. Unmarked, it asks for approval under Ask first, and an answer that calls it waits for each call in turn, even beside other reads.
- Do not mark a tool read-only if it writes, sends, deletes or starts anything. Marked, it runs without asking and beside the answer's other calls, so a read in the same answer can miss what it did.
- A server whose tools carry no marks at all works, but every call to it is asked about under Ask first, and its calls never run side by side.
