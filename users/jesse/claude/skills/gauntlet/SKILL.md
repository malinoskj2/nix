---
name: gauntlet
description: Run a Gauntlet Loop (Matt Shumer's builder/critic pattern). Asks for the goal, the reference bar, and how the critic checks the work, then fans out builder sub-agents, grades each piece with a separate harsh blind critic against the reference, and keeps iterating until the human stops it. Use when the user invokes /gauntlet or asks for a gauntlet loop.
argument-hint: "[goal] [optional: against REFERENCE] [optional: checked by METHOD]"
---

# Gauntlet Loop

Goal: $ARGUMENTS

## 1. Collect the three components

Always confirm all three with the user using the AskUserQuestion tool, in a single call with three questions. Infer candidate answers from the arguments, the current directory and the conversation, and offer them as options (best guess first, marked "(Recommended)"). Every question also gets a last option, "Help me build this", so the user can draft that component with you. The user can pick "Other" to type their own.

1. **Goal**: what to build or fix. Describe the destination, not the implementation.
2. **Bar**: a concrete reference an agent can actually inspect and compare against side by side. Examples include a shipped product, screenshots, a real page, an exemplary passage, a benchmark or a test suite. Reject abstract bars like "make it amazing" and propose concrete ones instead.
3. **Check**: how the critic inspects the work against the bar. Examples: screenshots in the browser, running the test suite, reading the output next to the exemplar, or benchmarking.

If the user's answer for the bar is vague, ask once more for something concrete.

### Helping build a component

For each component where the user picked "Help me build this", work through it with them in order (goal, then bar, then check, since each depends on the one before). Keep it short: at most a few rounds of AskUserQuestion per component, and stop as soon as the user accepts a draft.

- **Goal**: ask who it's for, what "done" looks like, and what is out of scope. Draft a one or two sentence goal that names the destination and nothing about the implementation, then ask the user to accept or adjust it.
- **Bar**: propose two or three concrete candidates that fit the goal. Where you can, look at them first (search the web, fetch the page, read the file, run the existing tests) so each option is something a critic can actually open. Say in one line what each would push quality toward, and let the user pick or combine.
- **Check**: propose the cheapest way for a critic to put the work next to the bar that still judges what matters, such as one screenshot per view, the relevant test command, or a specific benchmark. Confirm the tools it needs exist here before offering it.

Once all three are settled, state the goal, bar and check in one line each, then start.

## 2. Run the loop

Treat the following as your own instructions. Do not paste it back to the user.

> Build [GOAL] at the level of [BAR]. Every piece should be done at that quality.
>
> Break the work into the smallest separately judgeable pieces and fan out builder sub-agents to tackle each one. For each piece, a separate critic sub-agent checks it [CHECK]. The critic is a harsh, hostile auditor. It receives only the goal, the bar and the artifact itself, never the builder's reasoning, summary or self-assessment. It compares the work with [BAR] side by side, blind, and says which is better and names the single largest gap. If the work does not win or tie, the builder fixes that gap and a fresh critic that has not seen earlier drafts grades the retry.
>
> Don't stop until every critic is wowed when comparing against [BAR]. Keep going until it's utterly perfect.

## Rules

- The builder never grades its own work. Every retry gets a fresh critic.
- Choose the approach, architecture and decomposition yourself. The user supplies only goal, bar and check.
- Never lower the bar, soften the critic, or invent a stop condition ("N rounds", "good enough"). The human is the brake.
- Never ask "want me to continue?" after a cycle. Keep going until the user stops you or an explicit budget runs out.
- Spend the run on the work, not on tooling. No scoreboards, state machines or capture harnesses unless the check truly needs them.
- Hard stops still outrank the loop: destructive or outward-facing actions (pushing, deploying, deleting, spending money) need user approval as usual.
- After each integration step, give a one-line progress update: the piece, the verdict, and the largest remaining gap.
