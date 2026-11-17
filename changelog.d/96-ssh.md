### Fixed
- An agent's `git push` over SSH could not use the keys of an SSH agent your shell profile points at (1Password, Secretive, a `gpg-agent`), since its commands got macOS's own `SSH_AUTH_SOCK`. pi² now takes `SSH_AUTH_SOCK` from your login shell along with `PATH`, and nothing else from it.
