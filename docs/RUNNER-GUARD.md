# Protecting a local runner from foreign code

A self-hosted GitHub Actions runner executes a job with the rights of the user it runs as. For a **public**
repository foreign code can get there in two ways:

1. **A pull request that changes the workflow.** The PR sets `runs-on: [self-hosted, windows]` in
   `.github/workflows/ci.yml`; after "Approve and run" its code runs on your machine.
2. **A merge and the push run after it.** Every push to the default branch runs on the runner with everything in the
   repository: specs, `.testing.lua`, `scripts/*.sh`, lock files. Malicious code in a test or script runs here, the
   first time, after the merge.

A check in the workflow or in `scripts/ci.sh` is no barrier: the pull request changes it. So the check lives on the
machine of the runner, outside every work folder. It is the same act as running the tests locally: the review before
the merge is the protection, and `testing ci trust` is where you say you did it.

## What is checked

The runner calls `ACTIONS_RUNNER_HOOK_JOB_STARTED` before every job; a non-zero exit cancels the job. The hook script
only calls `testing ci runner-guard check`, which decides from the `GITHUB_*` variables, in this order:

| # | Rule | Result |
| --- | --- | --- |
| 1 | mode of the repository is `off` | run |
| 2 | event `pull_request` or `pull_request_target` | **refuse** (the code of a pull request never runs here) |
| 2b | any event other than `push`, `workflow_dispatch`, `workflow_run`, `schedule`, `release` (an allowlist: `pull_request_review` and the like run the merge ref of a pull request) | **refuse** |
| 3 | actor, or the actor who triggered a re-run, is not the owner of the repository (the maintainer) | **refuse** |
| 4 | the repository is private and the mode is not `always` | run |
| 5 | the commit (`GITHUB_SHA`) is on the list of reviewed commits | run |
| 6 | every commit since a reviewed ancestor is SSH-signed by a key of the device registry ([below](#your-own-devices-signed-commits)) | run (and the commit goes on the list), else **refuse** |

Anything that cannot be decided refuses: no `GITHUB_*` variables, no `gh` (the repository then counts as public), a
hook script whose `nvim` or `testing.lua` is missing. A list file that is not ours (another version, garbage, too
large) is an empty list: nothing is trusted from it, never an error that lets a job through.

Review is **per commit id, never per author**: the author of a commit is free text and proves nothing. A reviewed id
covers the tree that runs; its ancestors are not executed.

Rules 5 and 6 only apply to public repositories (rule 4), so the private repositories are unaffected and keep their
no-friction CI; use `--mode=always` to guard one anyway. A public repository you work on alone can skip them too:
[`--mode=solo`](#working-alone---modesolo).

## Hosted legs

The guard protects the machine of the runner and exists only there: `install` writes one line into the `.env` of a local
runner folder. A GitHub-hosted job, such as the macOS leg of `testing init --workflow=two-runner`
([WORKFLOW-CI.md](WORKFLOW-CI.md#one-pipeline-two-kinds-of-runner)), runs in a VM without that line, so no rule above
applies to it. It starts while the local job is refused or queued, and a commit needs no `trust` for it.

## Setting up

```sh
testing ci runner-guard install      # hook script in <runners>/_guard, one line in each runner's .env
testing ci runner-guard status       # per runner: guarded | not guarded | foreign hook; the list
```

`<runners>` is `$TESTING_RUNNER_ROOT`, else `~/actions-runners` (`--runners=<dir>` overrides both). `install` writes
`<runners>/_guard/job-started.ps1` (it names your `nvim` and this checkout's `scripts/testing.lua` by absolute path)
and sets exactly one line `ACTIONS_RUNNER_HOOK_JOB_STARTED=...` in the `.env` of every runner folder (a folder with a
`run.cmd`). Other lines stay; a hook of someone else is never replaced (reported, exit 1). It is idempotent, and a
runner update keeps `.env`. **A running runner reads `.env` only at its start**: stop and start it.

The runner scripts of the nvim config do this for you: `runners.ps1 start|ensure` runs `install` before it starts a
runner (`-NoGuard` leaves it out).

## Releasing a commit

A refused push run says so in its log ("Set up job") and names the command: first the short one,
`testing ci release <repo> <sha>` (`testing.nvim/bin` on the PATH, which `setup-claude-code.ps1` sets), then the call that
works from anywhere (`"<nvim>" -n -i NONE --headless -u NONE -l "<checkout>/scripts/testing.lua" ci release <repo> <sha>`).

**The short way: `testing ci release`.** One word for the whole way, a small wizard in a terminal:

```sh
testing ci release                                  # asks: which repository, which commit, then shows, asks, releases
testing ci release WKDSteve/tasks.nvim              # asks only for the commit
testing ci release WKDSteve/tasks.nvim <sha> --yes  # nothing to ask (a script: all three are needed)
```

1. The repository: the one given, else a choice of the `origin` of the current folder and the repositories on the list
   of reviewed commits (Enter takes the first, or type `owner/name`).
2. The commit: the one given, else a choice of the last `--count` (10) commits of the default branch, each with its
   title, author and date; the ones already released are marked `(released)` (Enter takes the newest, or type an id).
3. What changed since the last reviewed commit (the review aid of `--show`, below).
4. One question, `release <repo> <sha>? [y/N]` (`--yes` skips it; anything but y/yes/j/ja releases nothing, exit 1).
5. The release, then `gh run rerun <id> --failed` for every failed or cancelled run of that commit.

Without a terminal nothing is asked: then the repository, the commit and `--yes` must all be given, so a script never
releases a commit it did not name. A bare `testing ci trust` without any argument stays refused (it would release the
head of whatever the current folder names, unasked); `testing ci release` is the short way.

**The steps one by one, as data (`--json`).** For the editor and testing-desktop each step of the wizard can be called
on its own; `--json` prints one line, a document of `testing-ci-release/1` (`schemas/testing-ci-release/1/`, with a
`.d.ts`), and never asks:

```sh
testing ci release --repos --json                          # step 1: the repositories (this folder first) with mode and count
testing ci release WKDSteve/tasks.nvim --commits --json    # step 2: the last --count commits, `released` marked
testing ci release WKDSteve/tasks.nvim <sha> --show --json # step 3: what changed, each file with its `flag`; records nothing
testing ci release WKDSteve/tasks.nvim <sha> --yes --json  # step 5: the release and the re-runs (`release.reruns`)
```

Every document has `schema`, `step` (`repos`, `commits`, `show`, `release`, or `usage` for refused arguments), `exit`
and, on exit 2 or 3, `problem`. `show` carries `already` (on the list, nothing compared), `prev`, `status` (anything but
`ahead`: history rewritten or another branch), `commits`, and `files` with `flag` (`.github`, `scripts`, `lockfile`,
...) and `truncated` (GitHub lists at most 300 files). Titles, authors and file names from GitHub reach the document
without control characters. Without `--json` the same steps print text (`--repos`, `--commits`, `--show`). The release
stays its own call with the full id the page showed: a UI never releases "the head", which may have moved.

The single steps of the guard itself:

```sh
testing ci trust WKDSteve/tasks.nvim --show        # what changed since the last reviewed commit; records nothing
testing ci trust WKDSteve/tasks.nvim               # release the head of the default branch
testing ci trust WKDSteve/tasks.nvim <sha>         # release a given commit (7 to 40 hex digits, resolved at GitHub)
gh run rerun <id> -R WKDSteve/tasks.nvim           # the refused job, again
```

Without a repository the `origin` of the current folder is used. The review aid lists the commits since the last
reviewed one, their authors, and the files that deserve a close look: `.github/`, `scripts/`, `*.sh`, `*.ps1`,
`*.cmd`, `.testing.lua`, `TESTS/`, `package.json` and lock files, `Cargo.toml`, `build.rs`, `.deps/`. It is
**assistance for you, not a verdict**: a person releases the commit. (A machine reading of the diff can be fooled by
obfuscated code or by instructions written into it.)

Other commands: `testing ci trust --list`; `--revoke [<repo>] [<sha>]` (one commit, or all of the repository);
`--mode=auto|always|off <repo>`; `--note=<text>`. The list is `<runners>/reviewed.json`, at most 50 commits per
repository.

## Your own devices: signed commits

A maintainer who works alone does not read every commit of every machine. Rule 6 releases by origin instead: each of
your devices signs its commits with an SSH key of its own (`git config gpg.format ssh`, `user.signingkey`,
`commit.gpgsign true`), and the public keys are listed in the **device registry**, an `allowed_signers` file of
ssh-keygen:

```
STEVESPC,you@example.com namespaces="git" ssh-ed25519 AAAA... STEVESPC
WORKSTATION,you@example.com namespaces="git" ssh-ed25519 AAAA... WORKSTATION
```

The registry is `$TESTING_ALLOWED_SIGNERS`, else `<runners>/allowed_signers`. `runner-guard install` writes the
path of the variable into the hook script (a runner started before the variable was set does not see it), and
`status` shows which registry is used. A reinstall in a shell that does not see the variable (one started before
it was set, or `runners.ps1 start|ensure` from such a shell) keeps the registry the hook script already names, as
long as that file is still there, and says so. A new device: add its line; run `install` again only when the path
changed.

For a commit that is not on the list, the hook asks GitHub for the commits between the newest of the last three
reviewed commits that is an ancestor and `GITHUB_SHA` (`compare`), and checks each one with `ssh-keygen -Y
find-principals` and `-Y verify` (namespace `git`) against the registry, over the payload and signature GitHub keeps
for it. It does not use GitHub's "Verified": GitHub signs its own web merges (also of a foreign pull request), and
that signature is verified too. The job runs only when every commit of the range is signed by a registered key; the
commit then goes on the list (note `signed: <principal>`), so the next job of the run and the next push start from it.

The jobs of one run start together (one per system and job) and would each ask the same comparison, which empties the
API rate limit when a few runs come at once. So the first job of a run (`GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT` and
`GITHUB_SHA`) takes the lock `<runners>/_answers/<run id>-<attempt>-<sha>.lock`, asks, and keeps its answer beside it
(`.json`); a re-run is a new attempt and asks again. The others wait for that
answer (at most two minutes, then they ask themselves) and come to the same verdict. A lock older than that belongs to
a job that died and is taken over; answers of runs older than two days are removed. Without a run id every job asks
for itself.

It refuses when:

- a commit is unsigned, GPG-signed (GitHub's web merges) or signed by a key that is not in the registry;
- a signature does not match its payload;
- none of the last three reviewed commits is an ancestor (history rewritten), there is no reviewed commit at all, or
  the range holds more than 250 commits;
- there is no `ssh-keygen` on the `PATH` (Windows has its OpenSSH client there);
- GitHub gave no answer to the comparison (an exhausted API rate limit, HTTP 403 or 429, or the network). That is
  not "no ancestor": the refusal says `the comparison with GitHub failed (<error>)`, with the minutes until the rate
  limit resets when that was the error, and names `gh run rerun <run id> --failed` instead of a release. A restart
  once GitHub answers is enough; only a `404` (GitHub does not know the commit, or no common ancestor) reads as a
  rewritten history.

A refused job names `testing ci trust` as before. Rules 2 and 3 come first: a pull request or a foreign actor is
refused, signed or not.

What it rests on: a key on a device of yours signs whatever is committed there, by you or by a tool you run there.
Code that was committed on your machine has normally run there already (tests before the push); the guard keeps out
what did not come from your devices. A foreign commit that you rebase or cherry-pick is signed anew by your key and
counts as yours, as with `--pushed`.

## Working alone: `--mode=solo`

A maintainer who is the only contributor has nobody whose code the guard needs to keep out, and every release is
friction. Mode `solo` says so: the guard lets the owner's own pushes through without a release, and turns itself on,
for good, when that stops being true.

```sh
testing ci trust --mode=solo --all                 # every repository on the list
testing ci trust --mode=solo WKDSteve/tasks.nvim   # one repository (also one that was never released)
testing ci runner-guard status                     # which repositories are alone, which lost it and why
```

`solo` is also the **default** for a repository that has no entry (never released, not on the list): a new repository
with a runner needs no first release while you are alone. A repository gets an entry when somebody else is found
(then as `auto`, with the reason) or when you release a commit. Want it strict: `--mode=auto <repo>`.

What stays the same in `solo`: rule 2 and 2b (a pull request, an event outside the allowlist) and rule 3 (an actor
that is not the owner) still refuse, and a private repository still runs by rule 4. Only rules 5 and 6 (the list of
reviewed commits, the signature of the device registry) are not asked.

**When it is "alone".** The hook asks GitHub (`gh`, the login of the runner's user) three things, each over the newest
100 entries: the **collaborators**, the **contributors** (bots such as `dependabot[bot]` included: their commits are not
yours) and the **authors of pull requests** of the repository. Any account other than the owner is somebody else, except
the ones you put on the **ignore list**. A commit whose author GitHub cannot link to any account lists nobody.

Claude's commits (author or co-author `noreply@anthropic.com`) are linked to the GitHub account `claude`, so that account
shows up as a contributor in nearly every repository you work on with it, and solo mode ends at the first job. Whether
that account is "somebody else" is your decision, so nothing is ignored by default:

```sh
testing ci runner-guard solo-ignore add claude      # the accounts that are you or your tools; one login per line in
testing ci runner-guard solo-ignore remove claude   # <runners>/solo_ignore
testing ci runner-guard solo-ignore list            # (runner-guard status shows it too)
```

An ignored account is left out of all three questions. It means: a commit whose author is that account is as good as
yours. The author of a commit is free text, so an outsider's pull request could carry that address too; the checks
that stay in front are the collaborators (only people with write access) and the authors of pull requests (who opened
it, not what a commit says). Do not ignore an account you do not control.

- **Found:** the repository's mode becomes `auto`, with the signal and the day in `reviewed.json` (`flipped`), and the
  job is judged by rules 5 and 6 as always. It stays `auto` when the other account is gone again; you turn `solo` on
  again by hand, after looking (`--mode=solo` clears the note).
- **No answer** (no `gh`, a rate limit, the network): this job is judged by rules 5 and 6, nothing is recorded: a
  rate limit says nothing about the repository.
- **Alone** is kept only for the jobs of the same run (`<runners>/_solo/`, keyed by run id, attempt and commit): a run's
  jobs start together and would each ask GitHub the same three things. Every new run asks again, so a pull request
  that somebody opens and you merge minutes later is seen by the push run of the merge.

**The limit.** `solo` trusts that nobody but you pushes. Commits that an agent or a cloud session made under your
account run without a release, as does a push with a stolen token: the signature rule is what stopped them. Use it
while you work alone and keep `auto` for a repository an agent works in unattended. The pre-push hook
(`testing ci hook install --auto-trust`, below) is the other way to get fewer releases and keeps the guard on.

## Going back

```sh
testing ci runner-guard remove       # takes our line out of each .env and deletes the hook script
```

Then stop and start the runners. The list stays (`testing ci trust --revoke <repo>` empties one repository, deleting
`reviewed.json` all). A single repository can be taken out with `--mode=off`.

## Releasing your own pushes (pre-push)

```sh
testing ci hook install --auto-trust     # the pre-push hook, plus the release below
```

After the hook is green it calls `testing ci trust --pushed`, which reads the lines git gives a pre-push hook and
releases the tip of each pushed branch **only if every commit the push adds was made on this machine**: no merge
commit, and no commit reachable from a remote-tracking ref (a commit you fetched, also one built upon, comes from a
remote). Anything else prints the `testing ci trust` command for a review and releases nothing. A deleted branch, a
tag, a remote tip that was never fetched, and a push without an `origin` release nothing. The call never fails the
push. A git that does not answer in time (a busy machine) is asked once more with a longer wait; when it still says
nothing the hook says so (`git did not answer in time`) instead of "no origin", and a range git could not read is
named as such, never as a merge commit. It is opt-in (`--auto-trust`): without it the hook releases nothing.
The release happens before git sends the push: a push that is then rejected leaves an entry for a commit that is not on
GitHub, which does no harm (it names exactly that content). `trust --pushed` reads git's lines from stdin, so run
it by hand only with a pipe.

This is a convenience of the maintainer, not a review. Git cannot prove who wrote a commit: a commit you made
from foreign text (copied code, a patch, a cherry-pick of a commit you never fetched) counts as made here. The pull
request path stays closed in any case (rule 2).

## Limits

- It stops foreign code that you did not release. It does not stop code you released after a careless review, and not
  someone who can already write to your runner folder or your user account.
- A push of your own to a public repository needs a `trust` call before its run goes through, unless its commits
  are signed by a registered device or the pre-push hook releases it (sections above).
- Running jobs in a sandbox (own Windows account, Windows Sandbox, container) would limit the damage of a
  missed review too; it is not part of this guard.
- `testing.nvim`'s own workspace trust (`docs/CLI.md`, `testing trust`) does not help here: `CI=true` makes every
  root trusted in a CI job, which is what a throwaway machine needs and a personal runner is not.
