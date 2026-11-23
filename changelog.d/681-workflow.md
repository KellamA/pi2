### For contributors
- CI builds and tests the iPhone app: `.github/workflows/iphone.yml` runs its unit tests in a simulator and makes a Release build, unsigned, on every pull request and push to `main` that changes the app, the targets it shares with the Mac app or `app/Package.swift`. `Scripts (tests)` runs `scripts/test-iphone-sim` too.
