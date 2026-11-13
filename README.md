<p align="center">
  <img src="docs/images/icon.png" width="112" alt="pi² icon">
</p>

<h1 align="center">pi²</h1>

<p align="center">
  <b>A native Mac app for AI agents that don't lose their work.</b><br>
  Give each agent its own model, tools and limits. Let them hand work to each other, use your apps, and run while you're away.<br>
  Approve what matters from one inbox.
</p>

<p align="center">
  <a href="https://github.com/KellamA/pi2/actions/workflows/ci.yml"><img src="https://github.com/KellamA/pi2/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-1f2026" alt="macOS 15 or later">
  <img src="https://img.shields.io/badge/app-SwiftUI-8b93ff" alt="SwiftUI">
  <img src="https://img.shields.io/badge/engine-pi%20durable%201.5.2-4cc38a" alt="pi durable 1.5.2">
</p>

<p align="center">
  <img src="docs/images/hero.png" alt="A conversation in pi²: an agent runs a test, hands a question to a second agent, edits a file, and asks before pushing" width="900">
</p>

<p align="center"><sub>The screenshots show sample conversations, with answers scripted for the pictures.</sub></p>

## What it is

pi² is a home for agents on your Mac, built on [pi durable](https://github.com/earendil-works/pi/tree/main/packages/durable). Every model turn, tool call and decision is saved before it is shown, so a crash, a restart or quitting the app does not lose a run. It picks up where it stopped.

It works with the models you already have: sign in with a subscription, paste an API key, or point it at a local server such as Ollama or LM Studio. Each agent can use a different one.

## What you can do with it

### Run a team of agents

An agent is a saved setup: a model, instructions, tools, a folder, and limits. Pick one to start a conversation.

<p align="center"><img src="docs/images/welcome.png" alt="The welcome screen with four agents to choose from" width="820"></p>

Agents can hand work to each other. Each handoff opens a sub-chat under the conversation that started it, so you can watch an orchestrator's helpers work, open any of them, and talk to them directly.

<p align="center"><img src="docs/images/orchestration.png" alt="An agent hands two tasks to other agents and writes a plan from their answers" width="820"></p>

### Stay in control

Tool access is set per conversation: off, read only, ask first, or full. With "ask first", anything that changes a file or runs a command waits for you. Approvals and questions from every conversation collect in one Inbox, and they are still there after a restart.

<p align="center"><img src="docs/images/inbox.png" alt="The Inbox with a question and two approvals waiting" width="820"></p>

### Let an agent use your apps

Turn on computer use for an agent and choose which apps it may use. It works one window at a time, in the background, while you keep working. It reads the window's buttons and fields, and sees a picture of it if its model can. Before it clicks, types or picks a menu command, it tells you what it is about to do and waits.

<p align="center"><img src="docs/images/computer-use.png" alt="An agent asks to type notes into TextEdit" width="820"></p>

Terminals and password managers can never be added. Browsers and System Settings can be looked at but not controlled. [How computer use works](docs/computer-use.md).

<p align="center"><img src="docs/images/agent-computer-use.png" alt="The Computer use section of an agent's settings" width="820"></p>

### Give an agent a browser of its own

pi² has its own browser, with its own sign-ins, separate from Safari and Chrome. An agent can open pages, search, read, follow links, fill in forms and upload a file; you can watch in the Browser window, sign in to a site yourself, solve a CAPTCHA, or take over. Reading and following links is free. Clicking buttons, typing and uploading wait for your approval, site by site. It never types into password or card fields, and cannot reach addresses on your own machine or network. [How the browser works](docs/browser.md).

### Use any model

Sign in with a subscription, add API keys for any of 40 or so providers, or add your own endpoint. Choose which of a provider's models show up in the menus; "Newest Only" keeps one of each family.

<p align="center">
  <img src="docs/images/providers.png" alt="Provider settings: a local endpoint and two API keys" width="400">
  <img src="docs/images/models.png" alt="Choosing which models show" width="400">
</p>

### Leave it running

Schedules start conversations on their own: every morning, every hour, or once at a set time. Activity shows what is running and what is waiting for you. Closing the window leaves pi² in the menu bar, and the engine can keep going after you quit.

<p align="center"><img src="docs/images/activity.png" alt="Activity: running conversations and two schedules" width="820"></p>

### Know what it costs

Usage is counted by model, agent and conversation. Models you pay for by use show a cost and count toward an optional daily budget; subscriptions and local models count tokens only.

<p align="center"><img src="docs/images/usage.png" alt="Usage by model and by agent" width="820"></p>

### And the rest

- **Looking around**: agents can list, find and search files in their folder without the shell, and fetch a page or search the web without the browser, even on a schedule with the app closed. [The look tools](docs/look.md).
- **A task list**: for work with several steps, the agent keeps a checklist pinned above the message field, so you can see the plan and where it stands.
- **Pictures and files in chats**: paste a screenshot, drop in files, or attach PDFs and Word documents. [What can be attached](docs/attachments.md).
- **Reference files**: give an agent files and folders it can always read, including Word and RTF documents. It opens them when it needs them, so they cost nothing until then.
- **MCP servers**: add tools from other apps and services, per agent.
- **Scripts**: let a model chain many tool calls in one step.
- **Fork, search, export**: branch a conversation from any answer, search everything, export to Markdown or JSON.
- **Command palette** (⌘K) and **Quick Ask** from anywhere (⌃⌥Space).
- **Backup and restore** of everything except your keys.
- **Dark and light**, dark by default.

<p align="center"><img src="docs/images/hero-light.png" alt="The same conversation in light mode" width="820"></p>

## Install

There is no download yet. pi² builds from source in a couple of minutes.

You need macOS 15 or later, Xcode's command line tools, and Node 26 or later.

```bash
git clone https://github.com/KellamA/pi2.git && cd pi2
```

```bash
cd engine && npm ci && cd ..
```

```bash
./app/build.sh
```

```bash
open "app/build/pi².app"
```

That is a development build: it runs the engine from the `engine` folder, so keep the folder where it is. For an app that carries its own engine and can be moved to Applications:

```bash
./app/build.sh release
```

## First run

1. pi² opens with a scripted demo model, so you can click around before connecting anything.
2. Open **Settings › Providers** and sign in, add a key, or add an endpoint. If Ollama or LM Studio is running, the welcome screen offers to add it for you.
3. Pick a model from the toolbar of a conversation, or set one per agent.
4. To let an agent touch files, set **tool access** in the conversation's toolbar and choose a folder. Start with "Ask first".

## Status

pi² is early. Read this before you rely on it.

- pi durable, the library underneath, is marked experimental. pi² pins one exact version.
- The engine has an end-to-end test suite that runs on every change. The app has no automated tests; it is checked by hand.
- Subscription sign-in and computer use are the newest parts and have had the least real use.
- A few things are built but have had little or no testing: Quick Ask and its global shortcut, the menu bar panel, notifications, and starting the engine at login.
- Builds are not signed or notarized, so there is no ready-made download.

Known limits are listed in [docs/architecture.md](docs/architecture.md#known-limits).

## Privacy and safety

- Conversations, agents and settings stay on your Mac, in `~/Library/Application Support/pi2`.
- Keys and sign-ins are stored in the macOS Keychain, never in pi²'s files.
- pi² sends nothing anywhere on its own. Your messages go to the model providers and MCP servers you connect, and nowhere else.
- With "Full access", an agent runs commands without asking. Tools work inside the conversation's folder.
- Whether a subscription may be used from another app is up to each provider's terms.

To report a security problem, see [SECURITY.md](SECURITY.md).

## Documentation

- [Architecture](docs/architecture.md): how the app and the engine fit together, where data lives, known limits.
- [Computer use](docs/computer-use.md): how it works, what it will not do, how to try it safely.
- [Browser](docs/browser.md): the agents' own browser, what it asks about, and what it will not do.
- [Attachments](docs/attachments.md): what can be pasted or attached to a message, and the limits.
- [Development](docs/development.md): building, testing, and the layout of the code.
- [Changelog](CHANGELOG.md)
- [The original plan and mockups](docs/design/PLAN.md)

## Contributing

Bug reports and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgements

pi² is a front end for [pi durable](https://github.com/earendil-works/pi/tree/main/packages/durable) and the rest of the [pi](https://github.com/earendil-works/pi) libraries by Earendil Works, which do the hard part: durable runs, providers, tools and MCP.
