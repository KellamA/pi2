# Security

## Reporting a problem

Please report security problems privately, not in a public issue. Use **Report a vulnerability** under this repository's Security tab (GitHub's private vulnerability reporting).

Say what you found, how to reproduce it, and what it lets someone do. You will get a reply as soon as it has been looked at.

## What pi² is trusted with

pi² runs with your permissions. It is worth knowing what that means.

- **Keys and sign-ins** are stored in the macOS Keychain under the service `dev.pi2.credentials`. They are never written to pi²'s own files or passed on a command line.
- **Agents run tools as you.** With tool access above "Off", an agent can read files in its folder; above "Read", it can change them and run commands, after asking if you chose "Ask first".
- **Computer use** lets an agent see and work the apps you list, using the Accessibility and Screen Recording permissions you grant to pi². Terminals, script editors and password managers cannot be listed, browsers and System Settings are look-only, and password fields are never typed into. These limits are enforced in the engine and again in the app.
- **The browser** lets an agent open public web pages and act in them, in a browser of pi²'s own. Its cookies and website sign-ins are kept by WebKit, as in any browser, apart from Safari's and Chrome's; an agent is signed in only where you signed in there, and on those sites it can act as you. It does not open addresses on your Mac or local network, never types into password fields, and downloads nothing. These limits are enforced in the engine and again in the app.
- **The engine listens on a Unix socket** in your data folder. Anything running as you can connect to it and do what the app can do, including starting agent runs.
- **Text an agent reads is not trusted.** A web page, a file or a window can contain text written to steer an agent. Approvals are the safeguard: keep "Ask first", "Ask before each action" and the browser's "Ask before clicking buttons, typing and uploading" on for anything that matters.

## In scope

- A way for an agent, or for content an agent reads, to act without the approval the settings call for.
- A way around the computer-use limits or the browser limits above.
- Keys or provider sign-ins ending up outside the Keychain.
- Another user on the Mac, or a remote party, reaching the engine.

## Not in scope

- What a program already running as you can do through the engine's socket. That is the same access it has to your files.
- The behaviour of model providers, MCP servers, or pi durable itself. Report those to their own projects.
