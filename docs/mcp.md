# MCP servers

An MCP server adds tools from another app or service. Add one in **Settings › Tools**, as a program pi² runs on this Mac or as a URL, and tick it for the agents that should have its tools, under Extra tools in each agent's settings. A server's tools reach a conversation at its next message after the server connects. The engine's side is `engine/src/mcp.ts`; what happens to a call when a server is reconnected, edited or removed is in [architecture.md](architecture.md#an-mcp-server-changed-while-a-call-runs-on-it). A server run as a program gets the engine's environment, with the `PATH` and `SSH_AUTH_SOCK` from your login shell, but without the `PI2_` variables that configure pi² itself, and without the variables you give an agent, since one server serves every agent that uses it ([architecture.md](architecture.md#what-an-agents-commands-get)). It gets variables of its own instead, [below](#a-servers-own-variables).

## A server's own variables

A server run as a program can have environment variables of its own, such as a token it needs (#273), so that a secret does not have to go in its command or in a wrapper script, both of which end up in `mcp.json`. In **Settings › Tools**, **Variables…** beside the server lists them by name, and sets, replaces and removes them. The sheet says plainly that the server's program can read these values, and so can whatever it starts. They are kept exactly as [an agent's own variables](architecture.md#an-agents-own-variables) are, by the same code (`VariableValues` and `refusal` in `src/variables.ts`):

- **Where values are kept.** In the macOS Keychain, under the service the engine keeps sign-ins under, in one item per server, `mcp-variables/<server id>`. Never in `mcp.json`, the database, a backup or the app: `mcp.json` holds the names only, and whether each has a value (`variables: [{ name, set }]`), and the `mcp` event sends the app the same. A value can be set and replaced, never read back.
- **Adding a server with them.** The **Add Server…** sheet takes them too, for a server run on this Mac, so a server that needs a token is never first started without it (#298). `mcp.save` for a new server takes `variables: [{ name, value }]`: every name and value is checked first (the same refusals, and no name twice), the values are put in the Keychain, the names in `mcp.json`, and then the server is started once, with them. If the Keychain cannot keep them, the server is not added. An existing server's variables are changed only as below; `mcp.save` with an `id` refuses them.
- **Changing them.** `mcp.setVariable { id, name, value }` sets or replaces one, adding the name if it is new, and `mcp.removeVariable { id, name }` removes one with its value. Each applies at once and starts the server again with its variables as they are then, as Reconnect does: the new copy takes over once it has connected, and a call running on the old one finishes there ([architecture.md](architecture.md#an-mcp-server-changed-while-a-call-runs-on-it)). Saving the server's other settings keeps them. A server may have 50, each value 16 KB at most, with no NUL character. A server reached at a URL has none; its access token is its own setting.
- **Names that are refused** are the ones refused for an agent, for the same reasons, each saying why: anything that is not a name a shell can use, `PATH`, `PI2_` names, the names bash reads as it starts (`BASH_ENV`, `IFS` and the like, every `BASH_` name) and `DYLD_` names. Other names, `SSH_AUTH_SOCK` and `HOME` among them, win over the engine's.
- **If the values cannot be read** from the Keychain when the server starts, it is not started, and shows why, rather than run without them.
- **Removing the server** removes its values from the Keychain first; if they cannot be removed, the server is not removed, and the person is told why.
- **Another Mac, or another copy of pi².** A backup holds `mcp.json`, so the names, not the values. As the engine starts, a variable that `mcp.json` says has a value the Keychain does not hold is shown as having none, to be set again.

## Read-only tools

A server can mark each of its tools as read-only, with `readOnlyHint: true` in the tool's `annotations`. pi² goes by that mark alone, and treats any tool without it as one that can change things, like its own commands and file edits:

- **Approval.** With tool access set to "Ask first", a call to a tool not marked read-only waits for your approval. A read-only one runs without asking.
- **The order of calls.** A model can make several tool calls in one answer. When one of them is a tool not marked read-only, the whole answer's calls run one at a time, in the order the model gave them, so a call that reads what the one before it wrote sees it (#190). An answer whose calls are all read-only tools (or other tools that only look) runs them side by side. See [architecture.md](architecture.md#the-calls-of-one-answer).

So for someone writing a server, or choosing one:

- Mark every tool that only reads as read-only. Unmarked, it asks for approval under Ask first, and an answer that calls it waits for each call in turn, even beside other reads.
- Do not mark a tool read-only if it writes, sends, deletes or starts anything. Marked, it runs without asking and beside the answer's other calls, so a read in the same answer can miss what it did.
- A server whose tools carry no marks at all works, but every call to it is asked about under Ask first, and its calls never run side by side.
