# The owner's CI runner

GitHub's free macOS runners are what a pull request here waits for: a free account runs a few macOS jobs at once, and every pull request needs two of them. The owner's spare Mac mini (M2, 8 GB), set up as below, can run those jobs instead, as a self-hosted runner named `pi2-mini`. Two repository variables switch it on and off, job by job (#990). With neither set, CI runs exactly as before, on GitHub's runners.

## The switch

| Variable (Settings › Secrets and variables › Actions › Variables) | Jobs it moves | Where they run without it |
|---|---|---|
| `CI_MAC_RUNNER` = `pi2-mini` | `Engine (type-check and tests)`, `App (build)` (the two required macOS checks) | `macos-26` |
| `CI_MAC_RUNNER_MORE` = `pi2-mini` | `Relay (protocol test)`, `iPhone app (tests and Release build)` | `macos-26`, `xcode-27` |

Each job's `runs-on` in `.github/workflows/ci.yml` is the variable's value only when all three hold: the variable is set and not empty; the run is for a **pull request from a branch of this repository** (`github.event.pull_request.head.repo.full_name == github.repository`); and that pull request was **opened by the repository's owner** (`github.event.pull_request.user.login == github.repository_owner`, so no account's name is written in the file). The agents of the owner's pi² open their pull requests with the owner's sign-in, so theirs count as the owner's. Anything else runs on GitHub's runner exactly as before:

- a push to `main`, so every merge is still built and tested on a new, clean machine with GitHub's Xcode (see [Build folders](#build-folders-kept-on-purpose));
- a pull request from a fork, and **anyone else's pull request**, a collaborator's included, from a branch of this repository or not (see [Conditions](#conditions));
- every other event;
- every workflow but `ci.yml`. **A release is always built on GitHub's runners**: `release.yml` names no variable and runs on `macos-26` whatever is set, because it holds the signing certificate, the notarisation key and the update feed's signing key, and none of those may reach a machine that runs pull requests' code. `relay.yml`, which deploys the relay, runs on Linux on GitHub's runners too.

To go back at any time, **delete the variable** (or empty it). The next run of every job it moved is on GitHub's runner again; a run already waiting for the mini keeps waiting (see [When the mini is off](#when-the-mini-is-off)).

The value is the runner's label. `runs-on: "${{ … && vars.CI_MAC_RUNNER || 'macos-26' }}"` is GitHub's form "a single variable containing a string" ([workflow syntax, `runs-on`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idruns-on)), and a variable that is not set reads as an empty string, which picks GitHub's runner.

## Conditions

The repository is public, and a self-hosted runner runs whatever a pull request's workflow says.

- **The expression in `ci.yml` is the routing for honest pull requests, not the lock.** A pull request runs its own copy of the workflow, so a pull request that changes `ci.yml` can drop the expression and name `pi2-mini` directly, whoever opened it.
- **The lock for outsiders** is GitHub's setting *Settings › Actions › General › Fork pull request workflows*: **Require approval for all external contributors**. With it, nothing from a stranger runs until the owner approves that run. Before approving, read the stranger's whole change, and anything under `.github/workflows/` first: a change there can send the run to the mini.
- **For a collaborator with write access there is no lock, only trust.** A collaborator can push a branch of this repository whose `ci.yml` names the runner, and its run starts without anyone's approval. `.github/CODEOWNERS` makes such a change visible (the pull request waits for the owner's review before it can merge), but it does not stop the run, which happens as soon as the branch is pushed. Give write access only to people you would let run code on the mini.
- **Why the author and not who ran it.** `github.event.pull_request.user.login` is the pull request's author and stays so. `github.actor` is whoever's push started the run (the owner, when the owner pushes to someone else's branch), and `github.triggering_actor` is whoever ran it again (the owner, when the owner re-runs someone else's checks). With either of those, the owner's push to a collaborator's branch, or the owner's click on *Re-run*, would send the collaborator's code to the mini. With the author, someone else's pull request stays on GitHub's runners whoever pushes to it or runs it again. In a repository owned by an organisation, `github.repository_owner` is the organisation's name, which no pull request's author has, so nothing would go to the mini.
- What can reach the mini is then a pull request the owner opened from a branch of this repository, the owner's own or an agent's working for the owner, plus anything a collaborator or an approved stranger's change sends there on purpose. Its jobs can do anything the `runner` user can, and the machine is not new at the next job: a job could leave something behind for later jobs (a changed `~/.zshrc`, a LaunchAgent, a changed runner in `~/actions-runner`). [The clean-up](#what-the-clean-up-removes) takes away what the jobs leave by accident, not what a hostile job hides on purpose. That is why a push to `main` and every release stay on GitHub's runners: what is merged and what is shipped are never judged by the mini alone. If a pull request that ran on the mini ever looks hostile, delete the variables, remove the runner, and erase the mini.
- **The mini holds nothing personal**: no Apple ID, no iCloud, no keys, no accounts but its own two. A **standard** user, `runner`, runs the jobs; the administrator's account is used only to install Xcode. It is on a guest network if there is one, so that a job cannot reach the other computers at home.

## Setting up the mini

About an hour, mostly downloads. No Apple ID is needed on the mini: only downloading Xcode asks for one, and that is done on another Mac.

1. *On another Mac*: download **Xcode 27.2** (`.xip`) from developer.apple.com/download/all and copy it to the mini (AirDrop, a USB stick or file sharing).
2. *On the mini*: if it holds anything of yours, erase it first (System Settings › General › Transfer or Reset › Erase All Content and Settings). In the set-up assistant: **Set Up Later** for the Apple ID, no iCloud, no Siri, no analytics. Make the first account an administrator's, say `admin`.
3. Software Update to **macOS 27.2** (what Xcode 27.2 and this project are built on).
4. System Settings:
   - *Users & Groups*: add a **standard** user `runner`; then *Automatically log in as* `runner` (FileVault has to be off for this; nothing personal is on the disk).
   - *Energy*: prevent automatic sleeping when the display is off; start up automatically after a power failure.
   - *Lock Screen*: never start the screen saver, never require a password after it, for `runner`.
   - *Sharing*: everything off, except Screen Sharing or Remote Login if you want to look after it from another Mac.
   - Join the guest network if you have one.
5. As `admin`, in Terminal, install Xcode and the simulators:
   ```
   xip --expand ~/Downloads/Xcode_27.2.xip        # or double-click it
   sudo mv Xcode.app /Applications/
   sudo ln -s /Applications/Xcode.app /Applications/Xcode_27.2.app
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   sudo xcodebuild -runFirstLaunch
   xcodebuild -downloadPlatform iOS
   ```
   Nothing else is installed by hand: git comes with Xcode, `jq` (which `scripts/iphone-sim` needs) with macOS, and each job fetches the Node it needs into the runner's own folder. No Homebrew.
6. Log out, log in as `runner` (on screen, not over ssh: the app's checks need a logged-in session).
7. In a browser on the mini, signed in to GitHub as the repository's owner: the repository's **Settings › Actions › Runners › New self-hosted runner**, macOS, ARM64. Run the commands that page shows (they carry a one-time token; they download the runner into `~/actions-runner` and run `./config.sh`). When asked: name `pi2-mini`; additional label `pi2-mini`; work folder as offered (`_work`: the clean-up refuses any other).
8. Make it start at login and start it now, still as `runner`:
   ```
   cd ~/actions-runner
   ./svc.sh install
   ./svc.sh start
   ```
9. The Runners page shows `pi2-mini` as **Idle**. Sign out of GitHub in that browser.
10. In the repository's **Settings › Actions › General**, under *Fork pull request workflows*: **Require approval for all external contributors**.

Then set `CI_MAC_RUNNER` to `pi2-mini` ([The switch](#the-switch)). Set `CI_MAC_RUNNER_MORE` too once the first two jobs have run well there for a while.

## What differs from GitHub's runner

A job on the mini reads a few things that are not what GitHub's image has:

- **Xcode and Swift.** The mini has Xcode 27.2 at `/Applications/Xcode.app` (selected with `xcode-select`, and linked as `/Applications/Xcode_27.2.app`, the path the iPhone app's job names in `DEVELOPER_DIR`), on macOS 27.2. GitHub's `macos-26` has Xcode 26 and an older Swift. So `App (build)` and `Engine (type-check and tests)` build with a newer Swift on the mini than on GitHub's runner, where `main` and releases are built: code that only the newer Swift accepts passes on the mini and then fails on `main`'s run. That run is the check; a failure there is fixed like any other. The clean-up's first lines in each job's log say which macOS, Xcode and Swift it ran on.
- **Node.** `actions/setup-node` fetches Node 26 into the runner's tool cache (`~/actions-runner/_work/_tool`) the first time and reuses it; npm's own cache, `~/.npm`, stays between jobs too.
- **A logged-in session.** The runner is a LaunchAgent of `runner`, who is logged in on screen, so the app's checks that open off-screen windows have a window server, as on GitHub's runners.
- **One job at a time.** One runner process takes one job; the others wait in GitHub's queue for it. 8 GB is enough for one of these jobs, not for two, so do not add a second runner on the same mini.
- **The temporary folder.** Each job's `TMPDIR` is an empty folder inside the runner's own temporary folder (`_work/_temp/tmp/`), which the runner empties after every job, instead of the user's folder in `/var/folders`. Everything the tests make with `mktemp` or Node's `os.tmpdir()` goes there and goes with the job.

## Build folders, kept on purpose

A warm Swift build is most of what the mini gains. GitHub's `actions/checkout` removes every file git does not track before it checks out, build folders included, so on the mini it is told not to (`clean: false`, only when `runner.environment` is `self-hosted`; on GitHub's runners it cleans as it always has). The clean-up then removes everything git does not track **except** `app/.build` (SwiftPM's builds: debug, release and the iOS build of RemoteKit) and `iphone/build/DerivedData` (Xcode's, for the iPhone app's job).

A build folder kept from another pull request could hide a failure a clean build would show. SwiftPM and Xcode build incrementally from what the sources are now, which is reliable, but not perfectly so. What catches the rest is that **every push to `main` runs on GitHub's runners**, from nothing, as before: a merge that only a warm build let through fails there. That is simpler than a weekly clean on the mini, and it also checks `main` with the Xcode releases are built with. If a pull request fails on the mini in a way that looks like a stale build, delete the folder (`rm -rf ~/actions-runner/_work/pi2/pi2/app/.build`, as `runner`) and run the job again.

## What the clean-up removes

Each job that runs on the mini starts, after its checkout, with `scripts/ci-runner-clean start`, and ends, whatever happened before (`if: always()`), with `scripts/ci-runner-clean end`. Both remove the same things; `start` also points the job's `TMPDIR` at an empty folder. The end's clean-up does not fail the job (`continue-on-error`): the next job's start runs it again, and that one does fail its job if something cannot be removed. On GitHub's runners both steps are skipped.

It removes, as `runner`, never with `sudo`:

| What | Left by |
|---|---|
| Every process of `runner` whose command line or environment names the work folder (`~/actions-runner/_work`), except the clean-up itself and the runner processes it runs under. (macOS shows no environment for Apple's own programs, so one of those is found only by its arguments.) | engines, pi² Remote and its check, the app the release check opens, Wrangler and workerd, stand-ins of the tests, a job cancelled half-way |
| The simulators `scripts/iphone-sim` recorded in the checkout (`iphone/build/simulators`), shut down and deleted by their ids, and the records | the iPhone app's job |
| What git does not track in the checkout, but `app/.build` and `iphone/build/DerivedData` | every job (`node_modules`, `app/build`, test output) |
| Keychain items under a test's service, `dev.pi2.credentials.<anything>` (never `dev.pi2.credentials` itself) | the engine's tests, the release check |
| The preferences of `dev.pi2.app` and `dev.pi2.app.<anything>`, and their folders in `~/Library/Caches`, `HTTPStorages`, `WebKit` and `Saved Application State` | the release check, which opens a release build, and test copies |
| `~/Library/Application Support/pi2-<anything>` | development builds and test copies |
| `runner`'s `pi2-<anything>` in `/tmp` | the engines' sockets and scratch folders (`/tmp/pi2-<uid>`), the checks' folders |
| The job's temporary folder, `_work/_temp/tmp` | every job |

Ports are freed with the processes that held them. It refuses to do anything, and says why, unless it is on the runner: `RUNNER_ENVIRONMENT` is `self-hosted`, the work folder is `_work` with the runner's own `.runner` beside it and the job's folders inside it, it is not root, and the account shows no sign of an installed pi² (its data folder or login item, or `pi².app` in `/Applications`). `scripts/test-ci-runner-clean`, in `Scripts (tests)`, holds it to all of this in a temporary folder made to look like the runner, with stand-in processes and stand-ins for `security`, `defaults` and `xcrun`.

A job that starts reading or leaving something new (another folder in `~/Library`, another Keychain service) adds it to the script and its test, and to this table.

## When the mini is off

A job for the mini that finds no runner online is not cancelled as GitHub's are when they are short of runners: it waits in the queue, up to 24 hours, and then fails. So nothing fails and nothing is run again by `scripts/rerun-if-no-runner`: the pull requests just wait, in silence.

It shows as a check that stays at *Queued*, with "Waiting for a runner to pick up this job…" in its log, and as `pi2-mini` **Offline** on Settings › Actions › Runners (or `gh api repos/KellamA/pi2/actions/runners --jq '.runners[] | "\(.name) \(.status)"'`, which needs the owner's sign-in).

Then either start the mini again (it starts after a power failure, logs `runner` in, and the runner starts with it), or go back to GitHub's runners:

1. Delete `CI_MAC_RUNNER` (and `CI_MAC_RUNNER_MORE`).
2. Cancel each run still waiting, and run its jobs again: `gh run cancel <run-id>`, then `gh run rerun <run-id>`, or the buttons on the run's page. If a job run again still waits for `pi2-mini`, start a new run instead: merge `origin/main` into the pull request's branch and push.

## Upkeep

- **Is it online?** Settings › Actions › Runners shows `pi2-mini` as Idle (waiting) or Active (running a job). A job's log says which runner ran it in its first lines ("Runner name: 'pi2-mini'").
- **macOS and Xcode updates.** Update when the project moves on, not before: macOS by Software Update as `admin`; Xcode by repeating step 5 with the new `.xip` (the link `/Applications/Xcode_27.2.app` is named in `ci.yml`'s iPhone job, so a new Xcode for it means a new link and a change to that line). Run a pull request's jobs on the mini after each update before leaving it on.
- **The runner itself** updates itself when GitHub releases a new one. If it ever stops, `cd ~/actions-runner && ./svc.sh status`, as `runner`, says why; `./svc.sh stop` and `./svc.sh start` restart it.
- **Disk space.** The clean-up's last lines in each log say how much is free, and add a warning to the run under 20 GB. The kept build folders and Xcode's own caches are what grow: remove `app/.build` and `iphone/build/DerivedData` in `~/actions-runner/_work/pi2/pi2`, `~/Library/Developer/Xcode/DerivedData`, and old simulator runtimes (`xcrun simctl runtime list`, `xcrun simctl runtime delete`), as `runner` or `admin`.
- **Removing it.** Delete both variables first. Then on the mini, as `runner`: `cd ~/actions-runner && ./svc.sh stop && ./svc.sh uninstall`, and `./config.sh remove --token <token>` with the token Settings › Actions › Runners › `pi2-mini` › Remove gives (or remove it there and delete `~/actions-runner`). Erase the mini if it is to be used for anything else.
