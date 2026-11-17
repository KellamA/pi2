# Changelog entries for the next version

Each file here is one entry for the next version's section of [CHANGELOG.md](../CHANGELOG.md), so that pull requests merging at the same time never add to the same lines. A release gathers them into that section and removes them. [Changelog entries](../CONTRIBUTING.md#changelog-entries) in CONTRIBUTING.md says what deserves one and how to write it.

A file is named after its issue, `237.md` (or `237-second.md` for a second entry), and holds the heading the entry goes under, then the entry as it will appear:

```markdown
### Fixed
- What used to go wrong, and what happens now.
```

`node app/changelog.mjs check` says whether every file is well formed, and `node app/changelog.mjs notes 0.7.9` shows the release notes they would make.
