---
name: laravel-orchestrator
description: Autonomously build, review and refine Laravel/PHP changes using laravel-builder and laravel-reviewer, with the supervising session choosing fixes and abstractions. Use when the user invokes $laravel-orchestrator or /laravel-orchestrator, or requests an unattended Laravel implementation and review cycle. Ordinary build or review requests use their respective skills.
---

# Laravel orchestrator

Task: $ARGUMENTS

If `$ARGUMENTS` is unresolved, use the task from the user's request or delegation.

The session executing this skill is the supervisor: either the main session or
the `laravel-orchestrator` coordinator agent. Coordinate `laravel-builder` and
`laravel-reviewer` through implementation, independent review and refinement.
Invoking this workflow authorizes the supervisor to choose and apply fixes and
abstraction options within the requested task, without per-change user approval.

## 1. Establish scope and standards

- Derive the task and acceptance criteria from the arguments and conversation.
  If no task is supplied, ask what to build. Otherwise start without a setup
  questionnaire or plan-approval step.
- Give criteria stable IDs and retain their source in the request/spec, separately
  from architecture decisions and assumptions. Pass the same criteria to builder
  and reviewer. Update them for user changes or evidence-backed clarification,
  never merely to make the current implementation count as complete.
- Inspect repository instructions and the starting working-tree changes. Record
  the task's boundaries so existing unrelated work does not become review scope.
- Read [the build skill](../laravel-build-jesse/SKILL.md) and
  [the review skill](../laravel-review-jesse/SKILL.md) unless already preloaded.
  Their coding standards apply throughout. This workflow replaces the review
  skill's section 8 approval loop with supervisor decisions; do not ask the user
  about review findings or abstraction options.
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

For each substantial abstraction, specify the knowledge it removes from callers
and the obligations that remain. Keep invariants and coordinating mechanics with
their owner; judge a design by how safely and simply callers can use it and where
future rule changes belong. A compact signature that leaves callers coordinating
the same complexity is not sufficient.

Delegate to `laravel-builder` with the requested behavior, acceptance criteria,
scope boundaries, architecture decisions and relevant repository context. State
that this is a `laravel-orchestrator` run: the supervisor resolves design questions
and authorizes in-scope implementation choices. Ask for the changed files, a
criterion-by-criterion map of implementation and verification evidence, and any
unresolved issues when the work is finished.

Let the builder complete its edits and checks before starting review. Use one
writer at a time for the affected files. Resolve questions the builder returns
from available evidence and pass the decision back without asking the user to
approve routine implementation choices.

## 3. Review independently

Obtain two distinct assessments using `laravel-reviewer`:

- **Requirements:** give the original request/spec, criterion IDs and exact change
  scope. Request a check of every criterion against implementation and verification
  evidence, identifying missing/partial/incorrect behavior and unrequested additions.
- **Standards:** give the same change scope, repository standards sources and
  applicable architecture decisions. Request correctness/security, design,
  abstraction and aesthetics findings, identifying what callers must still know.

For substantial or cross-cutting changes, assign the axes to separate fresh
reviewers, in parallel when possible, so neither starts with the other's verdict.
For a small localized change, one fresh reviewer may perform both assessments and
report them separately. Each round assesses the same stable revision: wait for
all reviews before allowing further edits. Both reviews together count as one
round toward the retry limit.

Include how to distinguish task edits from pre-existing work. Have reviewers
inspect the code and verification evidence themselves; the builder's coverage
map is a navigation aid, not a verdict. State that the supervisor decides on the
reports under `laravel-orchestrator`; no user approval loop is needed. Reviewers
remain read-only.

## 4. Decide and refine

- Assess each finding against the code, requirements and repository conventions.
  Accept concrete correctness fixes and worthwhile design/aesthetic improvements.
  Resolve uncertain factual claims through inspection or targeted checks.
- Track Requirements and Standards decisions separately. A clean Standards report
  cannot close a requirement gap, and full requirement coverage cannot close an
  accepted Standards finding. Give the builder criterion IDs and rule references
  with the accepted changes; return verification gaps for targeted checking.
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

Finish successfully when every acceptance criterion has implementation and
sufficient verification evidence, applicable checks pass, and both review axes
are resolved. Requirements must have no gaps, unverified criteria or unresolved
scope additions. Standards must have no unresolved accepted findings; retain
reasons for rejected judgments. Inspect the final diff and evidence yourself.
An absent Requirements source or an unassessed axis cannot count as success.

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

Keep progress updates brief and informational. End with what changed, separate
Requirements and Standards results, verification evidence, consequential design
decisions and any unresolved limitations. No per-finding approval prompts or
request to continue a completed run.
