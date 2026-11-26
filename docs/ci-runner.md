# The owner's CI runner

GitHub's free macOS runners are what a pull request here waits for: a free account runs a few macOS jobs at once, and every pull request needs two of them. The owner's spare Mac mini (M2, 8 GB), set up as below, can run those jobs instead, as a self-hosted runner named `pi2-mini`. It has one runner, so it runs one job at a time. Two repository variables switch it on and off, job by job (#990), and the two required macOS checks go there only when the mini is free as a run starts (#1041). With neither set, CI runs exactly as before, on GitHub's runners.

## The switch

| Variable (Settings › Secrets and variables › Actions › Variables) | What it moves | Where they run without it |
|---|---|---|
| `CI_MAC_RUNNER` = `pi2-mini` | `Engine (type-check and tests)`, `App (build)` (the two required macOS checks), **when the mini is free** | `macos-26` |
| `CI_MAC_RUNNER_MORE` = `pi2-mini` | `Relay (protocol test)`, `iPhone app (tests and Release build)`: each is queued for the mini and waits for it | `macos-26`, `xcode-27` |

### What each variable does

- **`CI_MAC_RUNNER_MORE` names a runner.** A job it moves is queued for the mini and waits there until the runner is free, as it always has: several pull requests pushed together queue behind each other for as long as the jobs take.
- **`CI_MAC_RUNNER` names the runner whose free time a run asks about.** GitHub settles `runs-on` when a job is queued, and a queued job never moves to another runner, so the choice cannot be made job by job once the run is going. It is made by the run's first job, `Which jobs the change needs`, on Linux, which already decides which jobs run ([The free check](#the-free-check)): when the mini is free, **one job of the run at most** goes there — the App job if the change needs it, since it is the longer one, else the Engine job — and the other macOS job of the same pull request runs on GitHub's runners at the same time. So one pull request never holds the mini for two jobs one after the other.

### The free check

With the conditions below met, the run's first job asks GitHub for the repository's runners (`GET /repos/{owner}/{repo}/actions/runners?per_page=100`, five seconds at most, with the token in [The token](#the-token)) and calls the mini **free** only when exactly one runner carries the label the variable names (`pi2-mini`) and that runner's `status` is `online` and its `busy` is `false`. Then:

- **Free:** one job goes there, as above. A change that needs neither macOS job (a docs-only pull request) sends nothing.
- **Not free, for any reason:** offline, asleep, busy with another job, two runners with that label, an answer that is not what GitHub documents, a request that fails or takes more than five seconds, or no token at all — every macOS job runs on GitHub's runners, exactly as if the variable were unset. The job's log says which it was in one line, and holds nothing else of the answer.
- **A re-run** (attempt 2 and later) is on GitHub's runners, whatever the first attempt did.

The decision itself is `scripts/ci-runner-free`, which `scripts/test-ci-runner-free` holds to its cases (in `Scripts (tests)`). The workflow reads that script out of the commit the pull request is merged on, never out of the pull request's own tree, and the step that holds the token runs before anything of the change is checked out and runs no code of it.

**Two runs asking in the same seconds both see "free".** GitHub has no way to reserve a runner, so the second run's job is queued behind the first run's, for one job's length on the mini: at most about twelve minutes for the App job, less for the Engine job. That is the cost of asking once, at the start, and it is accepted: it is shorter than the wait on GitHub's runners that the same job would have had, and nothing queues for the mini when the check finds it busy.

### When a job goes to the mini

Both variables move a job only when all of these hold, in the expression in `ci.yml` and in the step that asks about the runner: the variable is set and not empty; the run is for a **pull request from a branch of this repository** (`github.event.pull_request.head.repo.full_name == github.repository`); that pull request was **opened by the repository's owner** (`github.event.pull_request.user.login == github.repository_owner`, so no account's name is written in the file); and the owner started the run (`github.actor == github.repository_owner`: someone else's push to the owner's pull request stays on GitHub's runners). For App and Engine, **only the first attempt** can go to the mini. A re-run of those two checks uses `macos-26` and tests the same SHA and ref ([When the mini is off](#when-the-mini-is-off)). Relay and iPhone routing does not change on re-runs. Anything else runs on GitHub's runner exactly as before:

- a push to `main`, so every merge is still built and tested on a new, clean machine with GitHub's Xcode (see [Build folders](#build-folders-kept-on-purpose));
- a pull request from a fork, and **anyone else's pull request**, a collaborator's included, from a branch of this repository or not (see [Conditions](#conditions));
- every other event;
- every workflow but `ci.yml`. **A release is always built on GitHub's runners**: `main`'s `release.yml` names no variable and runs on `macos-26` whatever is set, because it holds the signing certificate, the notarisation key and the update feed's signing key, and none of those may reach a machine that runs pull requests' code. `relay.yml`, which deploys the relay, runs on Linux on GitHub's runners too. What keeps that true of a release is who can push a `v*` tag: a tag at a commit whose `release.yml` names `pi2-mini` would get the `release` environment's secrets there, and until that environment has a required reviewer (#712's list) anyone with write access, the agents included, can push one.

**The agents' pull requests are the owner's.** The agents of the owner's pi² open their pull requests and push their branches with the owner's sign-in, so every one of them can run on the mini **as soon as it is pushed, before anyone has read it**: its changes to `ci.yml`, to `scripts/ci-runner-clean`, and to `package-lock.json` or `Package.resolved` (new dependencies and their install scripts run there) included. The agents work from issues, which anyone can file on this public repository, and from what models write. And because they hold the owner's sign-in, they could also change every setting this page relies on: set or delete the variables and the secret, register runners, approve a fork's run, change the fork-approval setting. Until #712, every lock described here is held by that same credential.

### The token

Reading the repository's runners needs access to its administration, which a workflow's own token cannot have: `ci.yml` gives that token `permissions: contents: read`. So the owner makes a fine-grained token of their own, read-only, for this repository alone, and puts it in the secret `CI_RUNNER_STATUS_TOKEN` ([Turning it on and off](#turning-it-on-and-off)).

- **What it can read:** this repository's administration, the runners among it. **What it can change:** nothing. It is a fine-grained token with one repository permission, Administration, at Read-only.
- **Where it is:** in the environment of one step of one job, and nowhere else. It goes to `curl` through `curl`'s own standard input, so it is in no command line and in no file, and `curl`'s answer is written to the runner's own temporary folder, read by a step that holds no secret. Nothing of the token or of the answer reaches an output or a log: the first job's output is one word, `app` or `engine`.
- **What it cannot reach:** a pull request from a fork, which is given no secrets at all — the step's conditions leave one out as well — and any step that runs the change's own files: the step runs before the change is checked out, and the script that decides is read out of the commit the pull request is merged on.
- **What it does not stand against:** a pull request that changes `ci.yml` itself, which runs its own copy of the workflow and can print any secret of the repository, as it always could ([Conditions](#conditions)). What it would get is a read of this repository's administration, and nothing more. That is why `.github/CODEOWNERS` asks for the owner's review of every workflow, and why the token is read-only rather than one that could register a runner.

### Turning it on and off

To turn it on, all three, in this order:

1. **The token**, in the owner's account: Settings › Developer settings › Personal access tokens › Fine-grained tokens › Generate new token. Resource owner: the owner. Repository access: **Only select repositories** → `KellamA/pi2`. Repository permissions: **Administration: Read-only**, and nothing else. An expiry of the owner's choosing: when it expires the check answers "not free" and every macOS job runs on GitHub's runners until a new token is in the secret.
2. **The secret**: repository Settings › Secrets and variables › Actions › **Secrets** › New repository secret, named `CI_RUNNER_STATUS_TOKEN`, holding that token.
3. **The variable**: Settings › Secrets and variables › Actions › **Variables**, `CI_MAC_RUNNER` = `pi2-mini`.

Set the variable last, or it does nothing: without the secret the check answers "not free". **Merging #1041 switches nothing on**: with no secret, every macOS job is on GitHub's runners exactly as before.

The first pull request of the owner's after that says which it was, in the first job's log: one line for the runner's state and one naming the job that goes there, or why none does.

To turn it off, **delete the variable `CI_MAC_RUNNER`** (or empty it). The next run sends both macOS jobs to GitHub's runners, and no request is made at all, since the step's conditions exclude it. Deleting the secret alone does the same through the "not free" answer, and is the quicker switch if something looks wrong. Revoke the token on GitHub when it is no longer needed. `CI_MAC_RUNNER_MORE` is turned off the same way, and its jobs are queued for the mini as before. A run already waiting for the mini keeps waiting ([When the mini is off](#when-the-mini-is-off)); a job given a GitHub runner cannot be moved to the mini.

The value is the runner's label. `runs-on: "${{ … && vars.CI_MAC_RUNNER || 'macos-26' }}"` is GitHub's form "a single variable containing a string" ([workflow syntax, `runs-on`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idruns-on)), and a variable that is not set reads as an empty string, which picks GitHub's runner. A list of labels would require a runner matching **all** of them; it is not a fallback. In the first job's step the same expression is what decides whether to ask about the runner at all.

## Conditions

The repository is public, and a self-hosted runner runs whatever a pull request's workflow says.

- **The expression in `ci.yml` is the routing for honest pull requests, not the lock.** A pull request runs its own copy of the workflow, so a pull request that changes `ci.yml` can drop the expression and name `pi2-mini` directly, whoever opened it.
- **The lock for outsiders** is GitHub's setting *Settings › Actions › General*, "Approval for running fork pull request workflows from contributors": **Require approval for all external contributors**. With it, nothing from a stranger runs until the owner approves that run. Before approving, read the stranger's whole change, and anything under `.github/workflows/` first: a change there can send the run to the mini. The weaker values are not enough: with "Require approval for first-time contributors" anyone with one merged commit (a typo fixed, or a stranger's commit an agent carried into its own pull request) runs without approval, and from a fork can name `pi2-mini` whatever the variables say. That is why the setting is [the first step of the setup](#setting-up-the-mini), before the runner exists.
- **For a collaborator with write access there is no lock, only trust.** A collaborator can push a branch of this repository whose `ci.yml` names the runner, and its run starts without anyone's approval. `.github/CODEOWNERS` asks for the owner's review of a change to `ci.yml`, but GitHub does not hold the pull request for it: `main`'s branch protection requires no reviews and there are no rulesets, so until a real phone is paired and that protection is turned on (#712), only `scripts/auto-merge`'s refusal holds such a pull request, and that is a convention among the agents, not a rule GitHub enforces. Nothing stops the run itself at all. Give write access only to people you would let run code on the mini.
- **Why the author, and the actor too.** `github.event.pull_request.user.login` is the pull request's author and stays so. `github.actor` is whoever's push started the run (the owner, when the owner pushes to someone else's branch), and `github.triggering_actor` is whoever ran it again (the owner, when the owner re-runs someone else's checks). With either alone, the owner's push to a collaborator's branch, or the owner's click on *Re-run*, would send the collaborator's code to the mini. With the author, someone else's pull request stays on GitHub's runners whoever pushes to it or runs it again; with `github.actor` as well, so does a collaborator's push to the owner's pull request (a re-run keeps the first run's actor). In a repository owned by an organisation, `github.repository_owner` is the organisation's name, which no pull request's author has, so nothing would go to the mini.
- What can reach the mini is then a pull request the owner opened from a branch of this repository, the owner's own or an agent's working for the owner, plus anything a collaborator or an approved stranger's change sends there on purpose. Its jobs can do anything the `runner` user can, and the machine is not new at the next job: a job could leave something behind for later jobs (a changed `~/.zshrc`, a LaunchAgent, a changed runner in `~/actions-runner`, hooks or settings in the kept checkout's `.git`, which run in the next job's checkout before its clean-up). [The clean-up](#what-the-clean-up-removes) takes away what the jobs leave by accident, not what a hostile job hides on purpose.
- **What the mini's result decides.** `App (build)` and `Engine (type-check and tests)` are required checks, so for a check that ran there, **the mini's result alone is what lets it merge**, by `scripts/auto-merge` too. And what is kept between jobs (the build folders `app/.build`, with SwiftPM's checked-out sources, and `iphone/build/DerivedData`; the Node in `_work/_tool`; npm's cache `~/.npm`) is writable by every job, so one pull request can poison them on purpose for the next, making a later pull request's checks pass falsely or run its code: not only a stale build by accident. What stands against that is after the merge: every push to `main` is built and tested from nothing on GitHub's runners, and releases are built only there. To narrow it, the owner can keep `CI_MAC_RUNNER_MORE` unset, delete the kept build folders now and then (and `~/.npm` and `_work/_tool`), and unset `CI_MAC_RUNNER` whenever the agents work from issues the owner has not read.
- If a pull request that ran on the mini ever looks hostile, delete the variables, remove the runner on GitHub's Runners page (not only on the mini: a job can read the runner's own credentials in `~/actions-runner`, `.runner`, `.credentials` and `.credentials_rsaparams`, and run it elsewhere), and delete the `runner` user.

### What separates the jobs from the owner's account, and what does not

The mini is the owner's own Mac, not wiped: it keeps the owner's administrator account, with its Apple ID and data. The jobs run as a second user, `runner`: a **standard** user (not an administrator, so no `sudo`), with no Apple ID, no iCloud and no GitHub sign-in. pi² is never installed on the mini.

What keeps a job away from the owner's things is macOS's separation of users:

- `runner`'s processes cannot read or signal the owner's processes, and cannot read the owner's Keychain or the private folders of the owner's home (Desktop, Documents, Downloads, Library and the rest). It can list the names at the top of the owner's home folder and read its Public folder, and anything else the owner makes readable to everyone.
- `runner` cannot write in `/Applications` or the system's folders, or install anything for other users.
- FileVault stays on: the disk is encrypted when the mini is off.

What does not separate them:

- **A local privilege escalation.** A job is code running as `runner`. A bug in macOS that lets a standard user become an administrator or root would give that code the owner's account, data and Apple ID. Keep macOS up to date, and do not give `runner` administrator rights, ever.
- **What is shared on the machine.** `/Applications` (`runner` runs the owner's apps and Xcode, though it cannot change them), `/tmp` (anyone can write there, so a job can leave files and sockets that the owner's programs might read), and services the owner's account runs on `127.0.0.1` or the local network, which `runner`'s processes can connect to like any other program.
- **Folders any user can write.** `/Users/Shared` and the owner's `~/Public/Drop Box` take files from `runner` too.
- **Other jobs' environments.** A process a job leaves running can read the environment of later jobs' processes (`ps -E`), which holds that job's `GITHUB_TOKEN` (read-only here) and the runner's token for its pull request; `ci.yml` uses no secrets.
- **The network.** A job sees the network the mini is on, the other computers at home included. A guest network keeps them apart, if there is one the mini can use.
- **Memory and the processor.** `runner` stays logged in behind fast user switching while the owner uses the Mac, and a job takes most of the 8 GB and all of the processor while it runs.
- **The owner's password.** A job can put up a genuine-looking macOS administrator prompt in `runner`'s session (`osascript … with administrator privileges` does). **Never type the owner's name and password into anything that appears in `runner`'s session**: nothing a job does needs it, and typing it there gives the job the owner's account. Anything that needs the administrator is done after switching to the owner's own account. This matters most when `runner`'s session is left in front ([What differs](#what-differs-from-githubs-runner)).

The runner only runs while `runner` is logged in. After a restart (a macOS update, a power cut), FileVault asks the owner to unlock the disk and there is no automatic login, so **the runner is offline until the owner logs in as `runner`** (and can then switch back to their own account). Jobs wait meanwhile ([When the mini is off](#when-the-mini-is-off)).

## Setting up the mini

The owner's setup, as their own administrator account, keeping the Mac as it is. About an hour, mostly the download.

1. **First, before any runner exists**: in the repository's **Settings › Actions › General**, under "Approval for running fork pull request workflows from contributors", choose **Require approval for all external contributors**. Then check it:
   ```
   gh api repos/KellamA/pi2/actions/permissions/fork-pr-contributor-approval
   ```
   must say `"approval_policy":"all_external_contributors"`, not `first_time_contributors` or anything else. The order matters: once the runner is registered, anyone who may run a fork's workflow without approval can send it there.
2. Software Update to **macOS 27.2** (what Xcode 27.2 and this project are built on).
3. Download **Xcode 27.2** (`.xip`) from developer.apple.com/download/all, then install it machine-wide under the name the iPhone app's job names in `DEVELOPER_DIR`, and the simulators:
   ```
   xip --expand ~/Downloads/Xcode_27.2.xip
   sudo mv Xcode.app /Applications/Xcode_27.2.app
   sudo xcode-select -s /Applications/Xcode_27.2.app
   sudo xcodebuild -license accept
   sudo xcodebuild -runFirstLaunch
   xcodebuild -downloadPlatform iOS
   ```
   Nothing else is installed: git comes with Xcode, `jq` (which `scripts/iphone-sim` needs) with macOS, and each job fetches the Node it needs into `runner`'s own folder. No Homebrew for the jobs.
4. Make the standard user, with a password of its own (`sysadminctl` asks for it with `-password -`):
   ```
   sudo sysadminctl -addUser runner -fullName "CI runner" -password -
   ```
5. System Settings:
   - *Control Centre*: Fast User Switching shown, so the owner can switch between the two accounts. *Users & Groups*: no automatic login. FileVault stays on.
   - *Energy*: prevent automatic sleeping when the display is off; start up automatically after a power failure (it then waits at FileVault's unlock).
   - *Sharing*: as the owner wants it; nothing needs to be on for the runner.
   - The guest network, if there is one the mini can use.
6. In a browser in the owner's account, signed in to GitHub: the repository's **Settings › Actions › Runners › New self-hosted runner**, macOS, ARM64. Keep that page open: it shows the runner's download and a one-time registration token.
7. Log in as `runner` on screen (fast user switching, not over ssh: the runner has to run in `runner`'s own logged-in session). In Terminal there, download and unpack the runner into `~/actions-runner` with the page's commands, then register and start it:
   ```
   cd ~/actions-runner
   ./config.sh --unattended --url https://github.com/KellamA/pi2 --token <token from the page> --name pi2-mini --labels pi2-mini --work _work
   ./svc.sh install && ./svc.sh start
   ```
   `svc.sh install` makes it a LaunchAgent of `runner`, so it starts each time `runner` logs in. Its template has `SessionCreate` true, so each job runs in a security session of its own, apart from `runner`'s login session: that is what leaves the login keychain locked and unopenable to a job ([above](#what-differs-from-githubs-runner)), and why the jobs on the mini bring a keychain of their own. Leave it as `svc.sh` writes it: taking `SessionCreate` out would have a job's tests write into the login keychain, and each runner update would put it back. The work folder must be `_work`: the clean-up refuses any other. Nobody signs in to GitHub in `runner`'s session. The token stays in `runner`'s shell history; it is good for an hour only, but `history -c` (or deleting `~/.zsh_history`) takes it away.
8. The Runners page shows `pi2-mini` as **Idle**. Switch back to the owner's account; `runner` stays logged in.
Then turn the mini on ([Turning it on and off](#turning-it-on-and-off)): the secret `CI_RUNNER_STATUS_TOKEN`, then `CI_MAC_RUNNER` = `pi2-mini`. Set `CI_MAC_RUNNER_MORE` too once the first two jobs have run well there for a while.

**The alternative, a mini of its own.** A Mac that holds nothing of the owner's is a harder boundary: erase it (General › Transfer or Reset › Erase All Content and Settings), set it up with no Apple ID, an `admin` account only for installing Xcode, and `runner` logged in automatically (FileVault off, since nothing personal is on the disk; the screen saver and its password off for `runner`), so that it comes back online by itself after a restart. The rest of the steps are the same. A privilege escalation then reaches nothing of the owner's.

## What differs from GitHub's runner

A job on the mini reads a few things that are not what GitHub's image has:

- **Xcode and Swift.** The mini has Xcode 27.2 at `/Applications/Xcode_27.2.app` (the path the iPhone app's job names in `DEVELOPER_DIR`), selected machine-wide with `xcode-select`, on macOS 27.2. GitHub's `macos-26` has Xcode 26 and an older Swift. So `App (build)` and `Engine (type-check and tests)` build with a newer Swift on the mini than on GitHub's runner, where `main` and releases are built: code that only the newer Swift accepts passes on the mini and then fails on `main`'s run. That run is the check; a failure there is fixed like any other. The clean-up's first lines in each job's log say which macOS, Xcode and Swift it ran on.
- **Node.** `actions/setup-node` fetches Node 26 into the runner's tool cache (`~/actions-runner/_work/_tool`) the first time and reuses it; npm's own cache, `~/.npm`, stays between jobs too.
- **A logged-in session, mostly in the background.** The runner is a LaunchAgent of `runner`, who stays logged in behind fast user switching, so the app's checks that open off-screen windows have a window server. The App job's parked-window check needs `runner`'s desktop to be **the one on screen**: it passed in run 45762698209 with `runner`'s session in front and failed in run 45761538325 with that session behind another account's, on the same code, while GitHub's `xcode-27` image passed it in run 45761218366. So it is the session, not macOS 27. Leave `runner`'s session in front while jobs run, and then never type a password into a prompt that appears there ([The owner's password](#what-separates-the-jobs-from-the-owners-account-and-what-does-not)). A locked screen is fine, and another account's session in front is not ([Keeping the mini able to pass](#keeping-the-mini-able-to-pass)).
- **A security session of its own.** `svc.sh install` makes the runner a LaunchAgent, and the template it installs from has `SessionCreate` true, so a job runs in a security session of its own rather than in `runner`'s login session. There `runner`'s login keychain is locked, and the session may not be shown the prompt that would open it: `security show-keychain-info` on the default keychain exits 36, "interaction not allowed", in runs 45761434972 and 45762635116, with `runner`'s desktop in front and behind. That is why the ten Engine test files, which write dummy items to the default keychain, were not accepted there, and why the jobs give themselves a keychain of their own ([The job's own keychain](#the-jobs-own-keychain), [#993](https://github.com/KellamA/pi2/issues/993)).
- **One job at a time.** One runner process takes one job; the others wait in GitHub's queue for it. 8 GB is enough for one of these jobs, not for two, so do not add a second runner on the same mini. That is why `CI_MAC_RUNNER` gives a run one job at a time, and only when the mini is free ([The free check](#the-free-check)), while a job moved by `CI_MAC_RUNNER_MORE` waits for the runner.
- **The temporary folder.** Each job's `TMPDIR` is an empty folder inside the runner's own temporary folder (`_work/_temp/tmp/`), which the runner empties after every job, instead of the user's folder in `/var/folders`. Everything the tests make with `mktemp` or Node's `os.tmpdir()` goes there and goes with the job.

## Keeping the mini able to pass

A job on the mini that fails with nothing in the code to explain it is usually the machine. These are the things that keep it passing, as the qualification's runs found them ([Qualifying the mini](#qualifying-the-mini)):

- **`runner`'s desktop has to be the session in front.** The App job's step "Check how computer use reaches controls" passes only while `runner`'s desktop is the one on screen. A **locked screen is fine**, since that session is still the front one; another account's session in front fails the step, as run 45761538325 did. After a restart, or after using your own account, log `runner` in or switch to it **last**, so that its desktop is the one in front. The runner only runs while `runner` is logged in ([above](#what-separates-the-jobs-from-the-owners-account-and-what-does-not)).
- **The Mac must not sleep.** The *Energy* settings of [Setting up the mini](#setting-up-the-mini) are what keep it awake with the display off; a Mac that slept runs no jobs until it wakes.
- **One claim is measured on GitHub's runners only.** On the mini, `pi2-presented-check`'s DNS group says `info … /usr/bin/log show could not be read`, because a standard user may not read the log. So that one claim is `info` there rather than a pass, and it is measured on GitHub's runners, which every push to `main` still uses.
- **What the mini gains:** the qualification measured the Engine job at about 6.5 minutes and the App job at 10 to 12 there, against 11 to 13 and 15 to 28 on GitHub's runners.

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
| The job's own keychain, `_work/_temp/pi2-job-<run id>-<attempt>.keychain-db`, and the record of what it replaced, `_work/_temp/pi2-job-keychain` | the job's own keychain's steps, and a job the runner killed while it had one ([below](#the-jobs-own-keychain)) |

Ports are freed with the processes that held them.

**Nothing is removed through a symbolic link.** A link where it removes things (a simulator's record, an entry in `/tmp`, a folder in `~/Library`) is removed as a link, never what it points to, and the log says so. A folder on the way that has been replaced by a link (`~/Library/WebKit` pointing elsewhere, say) is refused: nothing in it is touched, and the clean-up fails, with a warning on the run.

**It reaches nothing of the owner's account.** It runs as `runner`, never with `sudo`, and could not do otherwise: it stops only processes whose user is `runner` (and a standard user cannot signal another user's processes anyway); it removes only in `runner`'s own home, `runner`'s own Keychain, preferences and simulators, the checkout, and the entries in `/tmp` that `runner` owns (`find -user`). It never looks in the owner's home, which `runner` cannot read.

It refuses to do anything, and says why, unless it is on the runner: `RUNNER_ENVIRONMENT` is `self-hosted`, the work folder is `_work` with the runner's own `.runner` beside it and the job's folders inside it, it is not root or an administrator (a member of `admin`, as a person's own account almost always is), and there is no sign of an installed pi²: `pi².app` in `/Applications`, which is machine-wide and so covers the owner's account too (pi² is never installed on the mini), or pi²'s data folder, login item or `~/Applications/pi².app` in `runner`'s own home. `scripts/test-ci-runner-clean`, in `Scripts (tests)`, holds it to all of this in a temporary folder made to look like the runner, with stand-in processes and stand-ins for `security`, `defaults`, `openssl` and `xcrun`.

A job that starts reading or leaving something new (another folder in `~/Library`, another Keychain service) adds it to the script and its test, and to this table.

### The job's own keychain

A job's security session cannot open `runner`'s login keychain, so the Engine job, whose tests write dummy items to the default keychain, and the App job, whose checks and release check write there too, give the job a keychain of its own: two more steps of `scripts/ci-runner-clean`, which `ci.yml` and `mini-qualify.yml` run only on the mini.

- `keychain-start`, right after the job's start clean-up: it records the present default keychain and the present user search list in `_work/_temp/pi2-job-keychain`, then makes `_work/_temp/pi2-job-<run id>-<attempt>.keychain-db` with a password made in the script (`openssl rand -hex 24`) and thrown away with the keychain, gives it no timeout and no lock on sleep (`set-keychain-settings` with no `-t` and no `-l`: `-t` sets a lock interval, and leaving it out is what `security` spells as no timeout), unlocks it, and makes it the first of the user's search list and the default.
- `keychain-end`, with `if: always()` before the job's closing clean-up: it puts the recorded default and search list back, deletes the job's keychain and removes the record. It is safe when `keychain-start` never ran or half ran: a record is written only once both reads have answered with absolute paths, so a read that failed writes none and makes nothing, and the end that follows then does nothing and exits 0. The record names the job's keychain and nothing else: the only keychain either mode ever deletes is a `pi2-job-*.keychain-db` directly in the runner's temporary folder, whatever the record says, so a record that names `runner`'s login keychain is refused, its default and search list are still put back, and the mode exits non-zero.

It needs no secret, and spends none: a keychain's password can do no more than open that keychain, and this one holds the tests' dummy items and lives for one job. The password does pass on `security`'s command line, where another process of the same machine could see it for a moment (`ps -E`); it opens nothing of the owner's. Nothing here unlocks, deletes or changes `runner`'s login keychain itself, and no `-A` or `-T` is used. The steps print one line each with its exit status and nothing else: no path, and never the password. On GitHub's runners both are skipped, as that runner's default keychain is new at each job.

A job the runner killed can leave the default, or an entry of the search list, naming its keychain. The next job's `start` puts the default back to `~/Library/Keychains/login.keychain-db`, takes such entries out of the search list, and deletes the `pi2-job-*.keychain-db` files it finds, saying one line when it repaired something.

## When the mini is off

**Recovery is manual, even after a runner failure.** GitHub's run-ID retry applies to the current attempt, which could change after the controller's last read. The [job-ID endpoint](https://docs.github.com/en/rest/actions/workflow-runs#re-run-a-job-from-a-workflow-run) identifies a job but also re-runs its downstream dependents. Its public contract does not guarantee that a job from an earlier attempt is rejected if another attempt starts or completes before the request. The controller therefore uses neither endpoint for mini recovery. It also keeps a later hosted attempt out of the existing hosted-capacity retry if App or Engine requested the mini earlier in the run.

**A queued job does not move.** It shows *Queued* and "Waiting for a runner to pick up this job…". It can wait up to 24 hours; `timeout-minutes` starts on a runner and does not bound this wait. GitHub has no API to cancel just that queued job or to cancel only if it is still queued. Cancelling the workflow could interrupt unrelated checks or a job that just started. The controller never cancels a run. This is a job the free check gave the mini, which went offline or was taken by another run before it started ([the race](#the-free-check)): a run that finds the mini busy never waits for it, and both its macOS jobs are on GitHub's runners at once.

**Owner's same-commit fallback:**

1. If the App or Engine job that the free check gave the mini has been queued for **10 minutes**, check whether `pi2-mini` is offline in Settings › Actions › Runners. After a restart, unlocking FileVault and logging in as `runner` brings it back ([What separates the jobs](#what-separates-the-jobs-from-the-owners-account-and-what-does-not)). If that is not practical, check that this is still the latest run for the PR and that the job is still queued, not running. Let other checks finish first where possible, then cancel the run (`gh run cancel <run-id>`) and wait for cancellation to complete. This acts on the whole run, so other interrupted checks may need recovery too.
2. If the job already started, don't infer an outage from elapsed time. Read the log and terminal result. Retry an infrastructure failure such as a runner disconnect, or a job that never got a runner, not a genuine build or test failure. Leave unclear results for investigation.
3. Review the latest attempt immediately before retrying. Check what depends on the affected job, then use its **Re-run job** button or `gh run rerun --job <job-id>` (`gh run view <run-id> --json jobs --jq '.jobs[] | {name, databaseId}'` gives the API IDs, not the numbers in the job URLs). GitHub can reject job IDs from earlier attempts. If both jobs need recovery, use `gh run rerun <run-id> --failed` only after confirming that **every** non-passing job is safe to rerun; don't use it to erase a real failure. Check that the retry actually passes on a GitHub-hosted runner at the original SHA and ref.

This needs no variable change for a run whose CI already has the attempt-1 routing rule. A re-run of an older workflow uses that older definition; it has no same-commit switch. To get a fresh run in that case, update the branch from `main` first, or bring the mini back.

## Qualifying the mini

A pull request's App and Engine checks may run on the mini again only once its two trial failures are explained: the App job's parked-window accessibility check, and the ten Engine test files whose Keychain writes were not accepted ([#993](https://github.com/KellamA/pi2/issues/993)). `.github/workflows/mini-qualify.yml` is the small, separate run for each step of that. Only the owner can start it: every job runs only when `github.actor` is the repository's owner, so anyone else's dispatch of this file as it stands on `main` runs nothing. A person with write access can put a changed copy of the file on a branch and dispatch that, and its jobs run what it says; that is the same boundary `ci.yml` has ([Conditions](#conditions)), and why `.github/CODEOWNERS` asks for the owner's review of every workflow. It is never required, nothing calls it, and it changes neither `ci.yml` nor which runner a job uses: **both variables stay unset while it runs**, and its result is no part of a pull request's checks. Besides `check` and `runner` it takes **`keychain`**, `login` (the default) or `job`: with `job`, a job that runs on the mini makes a keychain of its own ([above](#the-jobs-own-keychain)), and on a GitHub-hosted runner it does nothing.

Start one on a branch or a commit, with `check` (below), `runner` (`pi2-mini`, or `macos-26` and `xcode-27` for the comparison) and, where it applies, `keychain=job`:

```bash
gh workflow run mini-qualify.yml --ref <branch or commit> -f runner=pi2-mini -f check=computer
gh workflow run mini-qualify.yml --ref <branch or commit> -f runner=pi2-mini -f check=keychain -f keychain=job
gh run list --workflow mini-qualify.yml --limit 3
```

In order, each with what passing and failing say:

1. **`check=computer`, on the mini**, with `runner`'s session in front (fast user switching to `runner`; never typing a password into a prompt that appears there, [above](#what-separates-the-jobs-from-the-owners-account-and-what-does-not)), then again with it switched to the background, and once with the display asleep if that is easy: the App job's step "Check how computer use reaches controls" and the `swift build` it needs. **Pass:** the step exits 0, and its group "a parked window joins the app's accessibility list when the copy raises it once" prints its four `ok` lines. **Fail:** an assertion prints FAIL, as step 15 of run 45721625385 did. Then the same `check` on `xcode-27`, which is macOS 27 as the mini is. **Reading:** front-most passes, background fails, `xcode-27` passes → the runner's session, and the App job can pass on the mini only while `runner`'s session is the one in front; front-most fails and `xcode-27` fails too → macOS 27's AppKit, and the mini is not at fault. **What it found:** the first, 45762698209 in front and 45761538325 behind against 45761218366 on `xcode-27`: the check needs `runner`'s session on screen.
2. **`check=keychain`**, a status-only probe: whether there is a default keychain and whether it is unlocked, then one dummy item added, read back, compared and deleted, under a service of the run's own (`dev.pi2.credentials.qualify-<run id>-<attempt>`). It prints step names, exit statuses and yes/no words and nothing else: never a listing, never what `security` printed, never a value. It reads each command's status and prints its line, so every line appears even when one fails, and with the keychain locked it says `add: skipped, the keychain is locked` instead of trying; a `trap` deletes the dummy item on any exit. **Pass:** every line says yes or exits 0, and the job exits 0. **Fail:** any other status, which the line names (`51` a locked keychain or a refused password, `37` no default keychain, `36` a session that may not show a prompt). **What it found:** the default keychain is there, and `show-keychain-info` exits 36, in runs 45761434972 and 45762635116, with `runner`'s desktop in front and behind: the job's security session, not the session in front, is what the Keychain answers to. So the same run again **with `-f keychain=job`**, which makes the job's keychain first: it passes if that keychain is unlocked, and every run after it, `credentials`, `engine` and `app`, is started with `-f keychain=job` too.
3. **`check=credentials`**, only once `keychain` passed, with `-f keychain=job`: `node --test test/credentials.ts` on the mini, under a test service of its own. **Pass:** that file green. **Fail** with the trial's message → not that file alone; the ten files run one at a time say whether it is load, and step 4's `xcode-27` run says whether it is macOS 27 instead.
4. **`check=engine`**, with `-f keychain=job`: `npm run test:macos`. **Pass:** the whole suite green on the mini, which with step 3 clears it. **Fail:** the same files, and the same `check` on `xcode-27` says whether macOS 27 is the cause.
5. **`check=app`**, with `-f keychain=job`: the whole App (build) job, its 25 steps in order, which a green step 1 does not settle. **Pass:** every step green on the mini, in the session state step 1 found. **Fail:** the first step that fails, and step 1 says which assertion to read.

Each run starts and ends with `scripts/ci-runner-clean` on the mini, as `ci.yml` does, so it leaves the mini as it found it: the probe's dummy item is deleted by the step itself, and under a test's service the clean-up would take it too. A run with `keychain=job` also ends with the account's own default keychain back in place.

## Upkeep

- **Is it online?** Settings › Actions › Runners shows `pi2-mini` as Idle (waiting) or Active (running a job). A job's log says which runner ran it in its first lines ("Runner name: 'pi2-mini'").
- **macOS and Xcode updates.** Update when the project moves on, not before: macOS by Software Update in the owner's account (then log in as `runner` again after the restart); Xcode by repeating step 3 with the new `.xip` under its own name (`/Applications/Xcode_27.2.app` is named in `ci.yml`'s iPhone job, so a new Xcode for it means a change to that line). Run a pull request's jobs on the mini after each update before leaving it on.
- **The runner itself** updates itself when GitHub releases a new one. If it ever stops, `cd ~/actions-runner && ./svc.sh status`, as `runner`, says why; `./svc.sh stop` and `./svc.sh start` restart it.
- **Disk space.** The clean-up's last lines in each log say how much is free, and add a warning to the run under 20 GB. The kept build folders and Xcode's own caches are what grow: remove `app/.build` and `iphone/build/DerivedData` in `~/actions-runner/_work/pi2/pi2`, `~/Library/Developer/Xcode/DerivedData`, and old simulator runtimes (`xcrun simctl runtime list`, `xcrun simctl runtime delete`), as `runner` (the runtimes as the owner's administrator account).
- **Removing it.** Delete both variables and the secret first, and revoke the token on GitHub. Then on the mini, as `runner`: `cd ~/actions-runner && ./svc.sh stop && ./svc.sh uninstall`, and `./config.sh remove --token <token>` with the token Settings › Actions › Runners › `pi2-mini` › Remove gives (or remove it there and delete `~/actions-runner`). Then, in the owner's account, log `runner` out and delete the user with everything it made: `sudo sysadminctl -deleteUser runner`.
