---
name: pr-review
description: Review a pull request with parallel reviewer agents and a validator per finding, post the surviving findings as inline comments, and return the merge verdict. The Claude review workflow invokes it in CI.
argument-hint: "[owner/repo] [pull-request-number]"
arguments: [repository, pull_request]
disable-model-invocation: true
allowed-tools:
  - Task
  - Read
  - Grep
  - Glob
  - Bash(gh pr view:*)
  - Bash(gh pr diff:*)
  - Bash(gh pr list:*)
  - Bash(git diff:*)
  - Bash(git log:*)
  - Bash(git show:*)
  - mcp__github_inline_comment__create_inline_comment
---

# Pull request review

Review pull request #$pull_request of $repository and return the merge verdict.

This procedure is a port of the `code-review` plugin from the `claude-code-plugins`
marketplace, adapted for a blocking check: it gates the merge, so it runs on every
push to the branch and always ends with a verdict.

**Agent assumptions (apply to every agent and subagent):**

- Every tool works. Do not test a tool and do not make an exploratory call.
- Call a tool only when the task needs it. Every call has a purpose.
- Write in English and never use an em dash.

## Steps

Follow these steps precisely. Create a todo list before starting.

### 1. Read the pull request

Get the title, the description and the diff:

- `gh pr view $pull_request --repo $repository`
- `git diff origin/<base branch>...HEAD`, where the base branch comes from the
  pull request

Do not skip the review because Claude commented on this pull request before. The
check has to report a fresh verdict on every head commit, so a re-review looks at
the current diff and reports the findings that still stand on it.

### 2. Collect the project rules

Launch a haiku agent that returns the file paths, not the contents, of every
relevant `CLAUDE.md`:

- the root `CLAUDE.md`
- any `CLAUDE.md` in a directory that holds a file this pull request modifies

Note that most folders under `ImmersiveMap/` carry a `README.md` with hard
"Responsibilities / Must Not Contain" boundary rules. Include the `README.md` of
every folder the pull request touches in the same list, because those files carry
the layering rules this package is graded against.

### 3. Summarize the changes

Launch a sonnet agent that views the pull request and returns a summary of the
changes.

### 4. Review in parallel

Launch four agents in parallel. Give each of them the pull request title and
description, since the author's intent is context for every judgement. Each agent
returns a list of issues, and each issue carries a description, a `file:line`
location and the reason it was flagged, such as "CLAUDE.md adherence" or "bug".

- **Agents 1 and 2, sonnet, project rule compliance.** Audit the changes against
  the files collected in step 2. When judging a file, consider only the
  `CLAUDE.md` and folder `README.md` files that sit on its path or above it.
- **Agent 3, opus, diff only bugs.** Scan for obvious bugs, reading the diff
  itself without pulling in extra context. Flag only significant bugs and skip
  anything that cannot be validated from the diff alone.
- **Agent 4, opus, introduced defects.** Look for problems inside the code this
  pull request introduces: incorrect logic, a data race, a missing `@MainActor`
  isolation, a `Sendable` violation, a state change that redraws nothing because
  it neither requests a frame nor registers an activity with `RenderLoopPacing`,
  a new `.metal` file or resource directory missing from `resources:` in
  `Package.swift`, a new in source `README.md` missing from `exclude:`, an
  unintended break of the public API surface, or a credential committed to this
  public repository.

**Only high signal issues count.** Flag an issue when one of these holds:

- the code fails to compile or parse: a syntax error, a type error, a missing
  import, an unresolved reference
- the code produces a wrong result regardless of input, meaning a clear logic
  error
- a clear and unambiguous violation of a rule you can quote from `CLAUDE.md` or
  from the folder `README.md` that governs the file

Do not flag:

- code style or code quality preferences
- an issue that depends on a specific input or a specific state
- a subjective suggestion or a refactor idea

When you are not certain an issue is real, drop it. A false positive erodes trust
and costs the author a round trip.

### 5. Validate every finding

For each issue that agents 3 and 4 returned, launch a subagent in parallel to
validate it. Give the subagent the pull request title, the description and the
issue. Its job is to confirm with high confidence that the issue is real: if the
issue says a variable is not defined, it checks that this is true in the code.
Use opus subagents for bugs and logic issues.

Validate the findings of agents 1 and 2 the same way with sonnet subagents: the
validator confirms that the quoted rule governs this file and that the change
truly violates it.

### 6. Filter

Drop every issue the validators did not confirm. What survives is the list of
high signal findings.

Treat the following as false positives and drop them even when they survive:

- a pre-existing issue the pull request does not introduce
- something that looks like a bug and is in fact correct
- a pedantic nitpick a senior engineer would not raise
- an issue a linter catches, and do not run the linter to check
- a general code quality concern, such as thin test coverage, unless a rule in
  `CLAUDE.md` or a folder `README.md` demands it
- an issue that `CLAUDE.md` mentions but the code explicitly silences

### 7. Post the findings

Post one inline comment per surviving finding with
`mcp__github_inline_comment__create_inline_comment` and `confirmed: true`. Post
one comment per unique issue and never a duplicate.

For each comment:

- describe the issue briefly and cite the rule it breaks, with a link when the
  rule comes from a `CLAUDE.md` or a `README.md`
- for a small self-contained fix, include a committable suggestion block, but
  only when committing that block fixes the issue completely
- for a larger fix, meaning six lines or more, a structural change, or a change
  spanning several locations, describe the fix instead of suggesting it

When linking to code, use the full commit sha and the exact form
`https://github.com/<owner>/<repo>/blob/<full sha>/<path>#L4-L7`, centred on the
line you discuss with at least one line of context on each side. A shell
substitution inside the link does not work, because the comment renders as
markdown.

### 8. Return the verdict

Finish with the structured verdict:

- `request_changes` when at least one finding survived step 6
- `approve` when none did

The summary states what was checked and lists the surviving findings, or reports
that none were found. Keep the remarks that did not survive out of the verdict:
they are noise on a blocking check.
