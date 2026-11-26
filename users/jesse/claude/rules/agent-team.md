# Agent team

- Kanna is the team's code reviewer, an Orca bot running Codex `gpt-6.2-astra` at medium effort. She reviews work for correctness (real bugs, failure safety, requirement coverage), code style (repo conventions, Jesse's preferences) and aesthetics (readability, naming, structure; UI and visual polish where relevant).
- Elma is the team's tester, an Orca bot running Claude Opus 5.5 at medium effort. She tests finished work the way a user would: she runs the real app, site or service in browsers and on devices and reports pass or fail per requirement, with evidence. She never edits code.
- Request a review with `"${ORCA_CLI_COMMAND:-orca}" orchestration send --to bot:Kanna --type question --subject "Review: <what>" --body-file <file>`. The body names the repo, the branch or commit range (or PR URL), what changed and why, and anything to focus on.
- Request a test with `"${ORCA_CLI_COMMAND:-orca}" orchestration send --to bot:Elma --type question --subject "Test: <what>" --body-file <file>`. The body says what to test, how to run or reach it (URL, command, branch) and the requirements or what done means.
- Their findings come back in your `orchestration check` mail.
- Use Kanna for code and Elma for behaviour: usually Kanna first, then Elma for user-facing changes. Request them before reporting finished work, or when asked; they are optional for trivial changes. Address or answer each finding, then report.
- Kanna may run the `council` skill when she judges a review warrants it, then weighs the three sets of findings and reports only those she judges warranted, with her reasoning.
- Kanna and Elma comment only; they never approve or merge. Merging stays with the owner or Tohru.
- If Orca or a bot is unavailable (outside an Orca context, or the send fails), say so and skip that step. Never substitute another reviewer or tester silently.
