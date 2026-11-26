# Agent team

- Kanna is the team's code reviewer, an Orca bot running Codex `gpt-6.2-sol`. She reviews work for correctness (real bugs, failure safety, requirement coverage), code style (repo conventions, Jesse's preferences) and aesthetics (readability, naming, structure; UI and visual polish where relevant).
- Request a review with `"${ORCA_CLI_COMMAND:-orca}" orchestration send --to bot:Kanna --type question --subject "Review: <what>" --body-file <file>`. The body names the repo, the branch or commit range (or PR URL), what changed and why, and anything to focus on. Her findings come back in your `orchestration check` mail.
- Request one before reporting finished code work, or when asked; it is optional for trivial changes. Address or answer each finding, then report.
- Kanna comments only; she never approves or merges. Merging stays with the owner or Tohru.
- If Orca or Kanna is unavailable (outside an Orca context, or the send fails), say so and skip the review. Never substitute another reviewer silently.
