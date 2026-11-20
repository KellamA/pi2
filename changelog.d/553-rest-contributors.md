### For contributors
- `scripts/auto-merge` merges a pull request whose required checks have all passed already, where it used to fail with "Pull request is in clean status"; `scripts/test-auto-merge` checks it with a stand-in `gh`, and CI runs it with the other scripts' tests.
- `scripts/test-copy show` takes every page `--show` takes, such as `usage`, `archive` and `settings:<tab>`, and answers once a conversation's page or a hub has drawn it, or says plainly that it cannot wait for the page it switched to.
- `scripts/test-copy answer-of <suffix> <conversation> <submission>` reads the answer of a submission whose run was still going when `send`'s wait ended, without sending the message again.
- `scripts/test-copy start|reopen --appearance light|dark` draws a copy in that appearance whatever the Mac's own is, so that a page can be pictured in both.
- `scripts/test-copy show … '#agent:<name>' --hub board-folded` says that it unfolded the board, which the copy's preferences keep.
