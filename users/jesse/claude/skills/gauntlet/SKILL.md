---
name: gauntlet
description: Run a Gauntlet Loop (Matt Shumer's builder/critic pattern). Asks once for the goal, the reference bar, how the critic checks the work, and how many builders to run at once, then runs unattended - fans out builder sub-agents, grades each piece with a separate harsh blind critic against the reference, decides open questions itself, and finishes with one report. Use when the user invokes /gauntlet or asks for a gauntlet loop.
argument-hint: "[goal] [optional: against REFERENCE] [optional: checked by METHOD] [optional: N builders]"
---

# Gauntlet Loop

Goal: $ARGUMENTS

## 1. Collect the components

This is the only point where the user is consulted. Confirm all four with the AskUserQuestion tool, in a single call with four questions. Infer candidate answers from the arguments, the current directory and the conversation, and offer them as options (best guess first, marked "(Recommended)"). Every question except fan-out also gets a last option, "Help me build this", so the user can draft that component with you. The user can pick "Other" to type their own.

1. **Goal**: what to build or fix. Describe the destination, not the implementation.
2. **Bar**: a concrete reference an agent can actually inspect and compare against side by side. Examples include a shipped product, screenshots, a real page, an exemplary passage, a benchmark or a test suite. Reject abstract bars like "make it amazing" and propose concrete ones instead.
3. **Check**: how the critic inspects the work against the bar. Examples: screenshots in the browser, running the test suite, reading the output next to the exemplar, or benchmarking.
4. **Fan-out**: the maximum number of builder sub-agents running at once. Offer 3 (Recommended), 1, 5 and 8. Critics count separately: one per builder.

If the user's answer for the bar is vague, ask once more for something concrete.

### Helping build a component

For each component where the user picked "Help me build this", work through it with them in order (goal, then bar, then check, since each depends on the one before). Keep it short: at most a few rounds of AskUserQuestion per component, and stop as soon as the user accepts a draft.

- **Goal**: ask who it's for, what "done" looks like, and what is out of scope. Draft a one or two sentence goal that names the destination and nothing about the implementation, then ask the user to accept or adjust it.
- **Bar**: propose two or three concrete candidates that fit the goal. Where you can, look at them first (search the web, fetch the page, read the file, run the existing tests) so each option is something a critic can actually open. Say in one line what each would push quality toward, and let the user pick or combine.
- **Check**: propose the cheapest way for a critic to put the work next to the bar that still judges what matters, such as one screenshot per view, the relevant test command, or a specific benchmark. Confirm the tools it needs exist here before offering it.

Once all are settled, state the goal, bar, check and fan-out in one line each, then start. From here on, run unattended.

## 2. Run the loop

Treat the following as your own instructions. Do not paste it back to the user.

> Build [GOAL] at the level of [BAR]. Every piece should be done at that quality.
>
> Break the work into the smallest separately judgeable pieces, with no two pieces editing the same files at the same time. Fan out builder sub-agents, never more than [FAN-OUT] at once. Queue the remaining pieces and start the next one as a slot frees up; a piece that depends on files another piece owns waits for it.
>
> For each piece, a separate critic sub-agent checks it [CHECK]. The critic is a harsh, hostile auditor. It receives only the goal, the bar, the decision log (below) and the artifact itself, never the builder's reasoning, summary or self-assessment. It compares the work with [BAR] side by side, blind, and returns:
> 1. A verdict: WIN, TIE or LOSE.
> 2. Every gap it found, each tagged `blocking` (the work is wrong, broken, or clearly below the bar) or `polish` (taste, minor idiom, wording).
> 3. The single largest blocking gap, if any.
>
> A piece is done when a fresh critic gives WIN or TIE with no blocking gaps. Otherwise the builder fixes the largest blocking gap (and any others it can cheaply) and a fresh critic that has not seen earlier drafts grades the retry.

## Deciding without the user

Never ask the user anything after setup. When a question comes up, decide it and record it in the decision log: one line per item with the decision and the reason. Pass the log to every later critic so it does not re-raise settled items.

- **Clear fixes** (broken, dead, obsolete, or wrong settings; bugs with an unambiguous intent): apply them.
- **Taste or preference changes** that alter what the user sees or how their systems behave, without being bugs: do not apply. Log them as proposals.
- **Security findings**: apply only when the fix cannot lock anyone out or break access (e.g. removing a duplicate). Otherwise log them as proposals, marked security.
- **Destructive or outward-facing actions** (pushing, deploying, deleting user data, spending money, messaging anyone): never do them. Log what would be needed.
- **Ambiguous scope**: pick the reading that best serves the goal, log it, move on.

## Never hang

- **Retry cap**: a piece gets at most 4 critic rounds. If it is still not done, keep the best version, log its remaining blocking gaps, and mark it done-with-gaps.
- **No progress**: if a critic's largest blocking gap is the same issue as the previous round's, or a builder reports it cannot fix it without a logged-as-proposal change, mark the piece done-with-gaps immediately.
- **Flip-flops**: if critics ask to reverse a change an earlier critic asked for, keep the current version, log the conflict, and treat that gap as polish.
- **Failures**: if a builder or critic errors, stalls, or returns nothing usable, retry it once with a fresh agent. If it fails again, mark the piece failed with the reason and continue.
- **Broken shared state**: if the check cannot run because another piece left the tree broken, finish or revert that piece first; never let critics grade a broken tree.
- **Nothing left**: when every piece is done, done-with-gaps, or failed, the loop ends.

## Finish

End with one report, and send it as a push notification too if that tool is available:
- What changed, per piece, with its final verdict (done, done-with-gaps, failed).
- Remaining blocking and notable polish gaps.
- The decision log: fixes applied, proposals not applied (security first), and outward-facing actions that were skipped.
- How the work was verified.

Do not commit, push or deploy unless the user asked for it before the loop started.

## Rules

- The builder never grades its own work. Every retry gets a fresh critic.
- Choose the approach, architecture and decomposition yourself. The user supplies only goal, bar, check and fan-out.
- Never exceed the fan-out cap, even when more pieces are ready.
- Never lower the bar or soften the critic. The retry cap limits effort, not standards: gaps left at the cap are reported, not hidden.
- Never ask "want me to continue?" or any other question after setup.
- Spend the run on the work, not on tooling. No scoreboards, state machines or capture harnesses unless the check truly needs them.
- After each critic verdict, give a one-line progress update: the piece, the round, the verdict, and the largest remaining blocking gap.
