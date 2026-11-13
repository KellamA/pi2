# Contributing to pi²

Thanks for looking. Bug reports, fixes and improvements are all welcome.

## Reporting a bug

Open an issue with:

- what you did, what you expected, and what happened instead;
- your macOS version, and whether it is a development or a release build;
- the model and provider involved, if it matters;
- anything relevant from `engine.log` in `~/Library/Application Support/pi2`. Check it for keys or private text before pasting.

For a security problem, do not open an issue. See [SECURITY.md](SECURITY.md).

## Making a change

1. Read [docs/development.md](docs/development.md) to build and run the project, and [docs/architecture.md](docs/architecture.md) for how it fits together.
2. Keep the change to one thing. A small pull request is reviewed sooner.
3. If you touch the engine, run `npm run check` and `npm test` in `engine/`, and add to `engine/test/engine.ts` when you add behaviour.
4. If you touch the app, build it and try the change on a throwaway data folder (the development doc shows how). Apart from the browser's page handling, which `pi2-browser-probe` checks, the app has no automated tests, so say in the pull request what you tried by hand.
5. Say plainly what is and is not tested.

## What fits

- Fixes, and features that make agents more useful or easier to keep an eye on.
- Anything that widens what an agent can do without asking needs a clear reason and a way for the person to see and stop it.
- Secrets go in the Keychain. Nothing about the person leaves the Mac except to the providers and servers they connected.

## Style

- Swift: SwiftUI, Swift 6, no third-party packages so far. Shared colours and controls live in `Theme.swift`.
- TypeScript: strict, run directly by Node, tabs for indentation.
- Comments explain why, not what.
- Text the person reads is plain and specific: say what happened and what to do next.
