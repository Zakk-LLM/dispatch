# Review gate

The default failure of agent review is optimism. A plausible diff plus a confident summary
reads as finished work, and approving it costs nothing at the moment it happens. Everything
below exists to make that impossible.

## The rule

An agent's report is a claim. A command you ran is evidence. Nothing is accepted on a claim.

Specifically, none of these is a reason to accept:

- the worker's summary says it is done, or says it verified the change
- the diff looks reasonable, or is small
- the tests "should" pass, or passed when the worker ran them
- another agent reviewed it and found nothing
- the task was simple

## Accepting a change

1. **Read the diff, not the summary.** `git diff`, or the files themselves outside a
   repository. Compare it against the spec's Requirements line by line.
2. **Check the scope.** Every changed file must be in the declared `Write:` scope. A file that
   appears from nowhere is a finding even when its content is fine.
3. **Run each acceptance criterion yourself** and record the exit code. A criterion with no
   command behind it was never verified, however obvious it looks.
4. **Run a negative control.** A passing test proves nothing until you have seen it fail:
   revert the change (`git stash`) or break the new code deliberately, confirm the test fails,
   then restore. Tests that pass both ways are the most common way weak work survives review.
5. **Look for silent passing:** assertions weakened, cases skipped, exceptions swallowed,
   features stubbed, a fixture that now returns the expected value.
6. **Write the verdict with its evidence** into `<run>/REVIEW.md`.

`verify.sh` mechanizes steps 2 and 3 and refuses to return `verified` when no check ran:

```sh
"$DISPATCH_SKILL/scripts/verify.sh" "$RUN" auth-cache \
  --check "pytest tests/test_auth.py -q" --check "ruff check src/"
```

It writes `verify.json` with the changed files, the files outside scope, and every command with
its exit code and output tail. Steps 1, 4, and 5 stay manual because they need judgment.

### A worker will claim work it did not do

Measured, not hypothetical: an `inspect` worker asked to run the tests and then edit a file
reported "Pytest exit code: 0. Edited `m.py` successfully." The tests had run; the edit had not.
The event log showed no edit tool call at all, and the file was byte-identical. Nothing in the
report was flagged as uncertain.

This is why the gate compares the report against the diff rather than reading the report.

## Research and data collection

Sources are part of the claim, not the evidence. Agents do fabricate citations, misattribute
numbers, and quote a figure that the linked page does not contain.

- Fetch at least two sources per research agent yourself and confirm the quoted number, the
  publisher, and the date actually appear there.
- Treat `unverified` confidence as unusable for any decision, and check a sample of what the
  agent marked `verified`.
- Separate a measured result from a vendor claim from an opinion; require the agent to do the
  same, then check that it did.
- A missing answer reported as "not found" is a good outcome. An answer that arrives with a
  plausible source and no number is the dangerous one.
- Judge a research deliverable on five items, each answered yes or no: correct, complete for the
  question asked, sources of adequate quality, every number traceable to a source, and no tool
  churn that suggests the agent stopped reading. A model-graded score can propose findings; it
  never approves.

## Delegating verification

A critic agent is useful and cheap: dispatch a `read-only` agent with a fresh context, tell it
to falsify the change against the acceptance criteria, and require each finding to carry a
concrete failure scenario — inputs, then wrong output. Published results show critics catching
real bugs that reviewers miss while also missing deeper ones, so its output is a list of
candidates.

Rules for delegating:

- The critic never approves anything. It produces findings; you confirm or reject each one by
  running something.
- Give different critics different lenses (correctness, boundaries, error paths, security,
  performance) rather than running the same review three times. Redundancy repeats a blind
  spot; diversity does not.
- Vote only on independent discrete questions, and keep the minority's evidence — a lone
  correct finding is exactly what majority voting discards.
- When two agents disagree about a fact, resolve it by running a command, not by asking a
  third agent.

Delegation multiplies opinions. Evidence still comes from execution, and the verdict stays
with the orchestrator.

## What the worker must supply

The task spec makes the worker's own verification checkable rather than rhetorical:

- run the acceptance commands and report each one with its exact invocation and exit code
- list what it could not verify, and why
- report `blocked` instead of inventing a way around a contradiction

A worker that reports "verified" with no command is treated as having reported nothing.

## REVIEW.md

One block per agent, evidence first:

```markdown
## auth-cache — accepted with one fix round
Diff: 3 files, all within scope (verify.json: no files outside scope)
Checks: `pytest tests/test_auth.py -q` exit 0; `ruff check src/` exit 0
Negative control: stashed the change, test_auth failed as expected
Findings: TTL constant duplicated in two modules — fixed in round 1, re-verified
Not verified: behavior under a cold cache; no fixture exists
```

The "Not verified" line is required. A review without one is a review that did not look.
