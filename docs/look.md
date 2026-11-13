# Looking around without changing anything

Five tools that read and never change. Three look at files, two read the web. None of them asks for approval, all of them are safe to run again after a crash, and the engine does all the work, so none needs the pi² app to be open: a scheduled run can use them.

The code is `engine/src/look.ts`.

## Files: `list_files`, `find_files`, `search_files`

Offered when the conversation's tool access is anything but **none**. Without them an agent with "Read files" could open a file whose path it knew, but not list a folder or search it.

| Tool | Arguments | Answers with |
| --- | --- | --- |
| `list_files` | `path?` | The folder's entries: a `/` after folders, sizes for files. Folders first, then by name. |
| `find_files` | `pattern`, `path?` | Files whose path matches a glob, newest first, with sizes. |
| `search_files` | `query`, `path?`, `glob?`, `regex?`, `ignoreCase?` | Lines containing the text (or matching the regular expression), grouped by file, with line numbers. |

**Globs** are `*` (anything within one name), `**` (across folders), `?` (one character) and `{a,b}` (either; they nest). A glob with no `/` in it, such as `*.ts`, matches names anywhere below the folder searched; one with a `/`, such as `src/**/test_*.py`, matches the path below it. Matching is case sensitive.

**Where they look.** Only in the conversation's folder (or the app's scratch folder, when none was chosen). `path` is relative to it; `..` and absolute paths are accepted only if they land inside it once every link has been resolved. Links met while walking are never followed, so a link inside the folder cannot lead out of it. `list_files` shows them as "link, not followed".

**What they leave out.** `.git`, `.svn`, `.hg`, `node_modules`, `dist`, `build`, `out`, `target`, `.next`, `.build`, `DerivedData`, `Pods`, `__pycache__`, virtual environments, caches, `coverage` and a few more (the list is `SKIPPED` in the code), and `.DS_Store`. Naming one of them as `path` looks inside it. `search_files` also skips binary files (a NUL byte in the first 8,000 bytes) and files over 1 MB, and says how many.

**Limits.** `list_files` shows 300 entries and says how many more there are. `find_files` shows 200. `search_files` shows 10 matches per file and 100 in all, with each line cut to about 240 characters around the match. A walk stops after 20,000 files or 10 seconds, and the answer says so, and that `path` can narrow it. The walk reads folders with async calls and so lets the engine serve other conversations in between, and it stops when the run is stopped. A regular expression is only tried against the first 2,000 characters of a line.

## The web: `web_fetch`, `web_search`

Offered when the conversation's agent has the **browser** switched on: the same "this agent may use the web" switch as in [the browser](browser.md). There is no setting of their own. They are for reading; a page that needs JavaScript, a sign-in or a form is for the browser, which the prompt says.

`web_fetch { url, offset? }` fetches a public page and answers with its title, final address and readable text. For HTML, scripts, styles, navigation, footers and markup are dropped and the text kept, with headings, lists and tables laid out, and links shown as the text followed by the address in brackets. JSON and plain text come back as they are. PDFs, pictures and other downloads are refused with a message. At most 2 MB is read from the network, about 20,000 characters are returned at a time (`offset` reads on), it gives up after 20 seconds, and it follows at most 5 redirects.

`web_search { query }` answers with up to ten results (title, address, snippet). It fetches DuckDuckGo's script-free results page, the one the browser tool's `search` uses, and picks the results out of it. This is best effort: such a page can change or answer with a check that it is a person asking. When no results can be read, the tool says so and suggests the browser's own `search`.

### Address rules

The same as the browser's (`checkAddress` and `isPrivateHost` in `browser.ts` are used, not copied):

- Only `http` and `https`, with no user name or password in the address.
- Nothing on this Mac or the local network, by name or by number: loopback, private, link-local and shared address ranges, `localhost`, `.local`, and names with no dot.
- **Every redirect's target is checked the same way**, and a redirect to somewhere refused ends the request.
- **The address a name resolves to is checked too.** The name is looked up, all its addresses must be public, and the connection is then made to the address that was checked, so a name cannot answer one way for the check and another for the request.

### What can leave the Mac

Neither tool asks for approval, as `open` and `search` in the browser do not. **An address or a search query the agent chooses is sent to a website.** An agent that has read something private could put it in an address. The page it reads is content, not instructions, and the prompt says so, but this is the same trade as with the browser: switch the web on for agents you trust with it.

## For tests

`PI2_TEST_ALLOW_ADDRESS` names one address (host and port, such as `127.0.0.1:4821`) that `web_fetch` may reach although it is on this Mac, so a test can serve it a page. It is read once, when the engine starts. It is for tests only; never set it otherwise.

`npm run test:look` (also part of `npm test`) runs `engine/test/look.ts`: glob matching, HTML to text, picking results out of a saved results page, the address checks on redirects and resolved names, and the limits, with a server of its own. The engine test (`engine/test/engine.ts`) checks which tools are offered and that a link or `..` cannot lead out of the folder. No test loads a real website.
