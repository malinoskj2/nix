---
name: laravel-orchestrator
description: Autonomously build, review and refine Laravel/PHP changes using laravel-builder and laravel-reviewer, with the supervising session choosing fixes and abstractions. Use when the user invokes /laravel-orchestrator or requests an unattended Laravel implementation and review cycle. Ordinary build or review requests use their respective skills.
---

# Laravel orchestrator

Task: $ARGUMENTS

The session executing this skill is the supervisor: either the main Claude
session or the `laravel-orchestrator` coordinator agent. Coordinate `laravel-builder` and
`laravel-reviewer` through implementation, independent review and refinement.
Invoking this workflow authorizes the supervisor to choose and apply fixes and
abstraction options within the requested task, without per-change user approval.

## 1. Establish scope and standards

- Derive the task and acceptance criteria from the arguments and conversation.
  If no task is supplied, ask what to build. Otherwise start without a setup
  questionnaire or plan-approval step.
- Inspect repository instructions and the starting working-tree changes. Record
  the task's boundaries so existing unrelated work does not become review scope.
- Read [the build skill](../laravel-build-jesse/SKILL.md) and
  [the review skill](../laravel-review-jesse/SKILL.md) unless already preloaded.
  Their coding standards apply throughout. This workflow replaces the review
  skill's section 8 approval loop with supervisor decisions; do not call
  AskUserQuestion for review findings or abstraction options.
- Aim for expressive domain APIs, cohesive responsibilities and well-encapsulated
  rules. A meaningful abstraction can justify itself with one caller. Design and
  aesthetics are part of completion, alongside correctness and passing checks.
- Keep a concise decision log in the conversation: accepted/rejected findings,
  selected options, assumptions and reasons. No tracking files are needed.

## 2. Build

Own the architecture before delegating: identify the domain concepts, assign
responsibilities and choose important call-site APIs consistent with the existing
codebase. Record the consequential choices and their reasons. Scale this to the
task; a small fix needs no separate architecture document. Revisit these choices
when implementation or review supplies new evidence.

Delegate to `laravel-builder` with the requested behavior, acceptance criteria,
scope boundaries, architecture decisions and relevant repository context. State
that this is a `laravel-orchestrator` run: the supervisor resolves design questions
and authorizes in-scope implementation choices. Ask for the changed files, verification results
and unresolved issues when the work is finished.

Let the builder complete its edits and checks before starting review. Use one
writer at a time for the affected files. Resolve questions the builder returns
from available evidence and pass the decision back without asking the user to
approve routine implementation choices.

## 3. Review independently

Delegate to a fresh `laravel-reviewer` with the task, acceptance criteria, exact
change scope and applicable settled decisions. Include how to distinguish this
task's edits from pre-existing work; do not let the default whole-branch scope
silently broaden the assignment.

Have the reviewer inspect the actual current code and return its normal findings
and abstraction proposals. Give it access to verification results as evidence,
but don't supply the builder's self-assessment as a verdict. State that the
supervisor will decide on the report under `laravel-orchestrator`; no user approval loop
is needed. The reviewer remains read-only.

## 4. Decide and refine

- Assess each finding against the code, requirements and repository conventions.
  Accept concrete correctness fixes and worthwhile design/aesthetic improvements.
  Resolve uncertain factual claims through inspection or targeted checks.
- Choose the abstraction option that best expresses the domain and improves the
  caller. Consider the reviewer's recommendation, its tradeoffs and the existing
  architecture. Don't automatically choose the smallest diff or dismiss a useful
  abstraction because it has only one caller.
- Reject unsupported findings, redundant layers and changes outside the task;
  record a brief reason. Adjacent code may change when needed for a coherent
  in-scope abstraction, without opening an unrelated cleanup project.
- Send the builder a concrete batch of accepted findings and selected options,
  with reasons and any constraints. Supervisor acceptance is sufficient authority
  to implement them in this workflow; don't request user confirmation again.
- Have the builder verify the revision. Then obtain another independent review
  of the affected behavior and its integration, including possible regressions.
- Preserve settled decisions unless new evidence shows a defect or a material
  improvement. Resolve conflicting preferences yourself; don't alternate between
  equivalent designs just because successive reviewers prefer different shapes.

## 5. Finish or report a blocker

Finish successfully when the acceptance criteria are met, applicable checks pass,
and independent review leaves no unresolved finding the supervisor considers
worth applying within scope. Inspect the final diff and verification evidence
yourself before declaring completion.

Use at most four review rounds by default, including the first review. Stop
earlier if a round repeats an unresolved issue without new evidence or a viable
fix. If an agent fails to return usable work, retry once with a fresh agent.
These limits end the attempt; they do not turn remaining issues into success.
Return an incomplete result with the outstanding issue if the loop cannot finish.

Choose reasonable in-scope assumptions and record them. If essential behavior
cannot be inferred, required verification cannot run after reasonable attempts,
or completion needs authority beyond the task, finish the independent work and
report the specific blocker. Don't invent product requirements or silently skip
a required check to claim completion.

Autonomy covers local implementation, testing and design decisions. It does not
grant additional permission to push, deploy, change shared databases, delete user
data or modify access. Perform such operations only when already authorized by
the user, and respect the environment's execution permissions.

Keep progress updates brief and informational. End with what changed, verification
results, consequential design decisions and any unresolved limitations. No
per-finding approval prompts or request to continue a completed run.
