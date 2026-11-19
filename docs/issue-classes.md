# Issue classes: which model an issue needs

Every open issue has one of two classes, as a label. The class says which kind of model the issue needs to be done thoroughly and accurately. It does not say how long the issue takes or how much it matters.

- **`local model`**: a model running on this Mac can do it.
- **`cloud model`**: it needs a cloud model.

The class is the least that will do. A cloud model may be given a `local model` issue, when the local model is busy or not set up. A local model is never given a `cloud model` issue.

## Who decides

The agent that hands out the work classifies every issue: when it files one, and when it looks over one a worker filed, before that issue becomes work. It is the most capable model at work and the only one trusted with this.

A worker never classifies an issue, its own or anyone else's, and `scripts/issue` refuses to in a worker's worktree. A worker that thinks an issue is in the wrong class says so in its report.

    scripts/issue classify 123 local
    scripts/issue classify 123 cloud
    scripts/issue idea "Title" --model local --body-file body.md

`scripts/issue list` shows each issue's class, and `scripts/issue audit` reports an open issue that has none.

## A local model issue

All of these hold:

1. **Nothing is left to decide.** The issue says what to change and where. If doing it would start with "find out why" or "decide how", it is not this class.
2. **It is small and can be read in parts.** A few files, with the parts to read named. Together with the rules every worker reads, it fits well inside the local model's context.
3. **A check proves it.** A test that exists, or one the issue asks for, run from the command line. Nothing has to be judged by eye, and no app or throwaway copy has to be worked by hand.
4. **A mistake is cheap.** A review or CI would catch it. It is not code that deletes files, signals processes, or touches the login item, permissions, credentials, releases or what a person is asked to approve.
5. **It does not depend on load or timing.** Nothing has to be reproduced on a busy Mac.

## A cloud model issue

Any one of these is enough:

- The cause is not known: a crash, a failure seen once, something that has to be reproduced first.
- A decision is left: a design, a trade-off, wording a person will read in the app.
- It crosses the engine, the app and the conversation page, or changes how they talk to each other.
- How it looks matters.
- It is code where a mistake is costly: see point 4 above.
- It is big enough to be split into pieces first.

When in doubt, it is `cloud model`. An issue that turns out to be in the wrong class is classified again, with a note saying why.

## Writing an issue for a local model

A `local model` issue is written to be followed: the steps in order, the files and the parts of them to read, the exact text where wording matters, the checks to run, and where to stop. #373 is the example: the first issue a model on this Mac took from reading to an open pull request.
