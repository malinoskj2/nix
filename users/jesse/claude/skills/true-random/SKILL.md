---
name: true-random
description: Make unbiased random selections or generate varied creative options when the user asks for a random choice, random variation, or no-preference selection. Use an appropriate random source and disclose limits when randomness matters.
---

# True random choices and variation

Use this skill when the user asks for a random choice, asks you to choose without preference, or wants genuinely varied alternatives. The goal is to avoid substituting your own ranking or taste for the requested random process.

## Selecting from options

- Preserve the user's option set exactly. Remove duplicates only when they are clearly the same option; otherwise treat each listed entry as a separate outcome.
- If the user says "uniformly", "fairly", "equally likely", or makes the result consequential, use an unbiased random integer from a system cryptographic source, such as Python `secrets.randbelow(n)`, and map it to the options. Do not use `random.random()` or model intuition for a fairness claim.
- For casual, low-stakes choices where executing code is unavailable or disproportionate, make a clearly labeled informal random pick. Do not imply it was cryptographically random or statistically audited.
- Do not reroll because the outcome seems boring, inconvenient, or unlike what the user might prefer. Reroll only for a stated reason such as an invalid option or a requested multi-pick rule, and disclose the reason.
- For multiple selections, clarify or apply the user's stated replacement rule. Without replacement, sample distinct entries; with replacement, each draw may repeat. State the method when it affects interpretation.
- Keep the selection auditable when useful: show the numbered options, source/method, and selected index. Never expose secrets or unrelated system state as a random seed.

## Creating random variation

- Separate randomness from quality: first define the dimensions that may vary, then vary them deliberately while preserving the user's fixed constraints.
- For a single creative choice, choose one or more dimensions uniformly from explicit ranges/categories using a proper random source when practical. For many outputs, use code and a recorded seed so the batch can be reproduced; state that a seeded pseudorandom generator is reproducible, not true physical randomness.
- Avoid silently steering toward familiar, safe, popular, or personally favored patterns. If constraints or safety rules exclude outcomes, define the valid set first and sample from that set; mention material exclusions.
- Make results meaningfully distinct rather than applying superficial wording changes. Keep every variant within the user's requested scope and quality bar.
- If the user wants unrepeatable physical randomness or a verifiable public draw, a local software RNG is not proof of that. Use the requested external/public source only when authorized; otherwise explain the limit and offer a reproducible or local alternative.

## Reporting

Be precise about what happened. Distinguish an informal model-generated pick, a system-random draw, a seeded pseudorandom batch, and an externally verifiable draw. Do not claim a process was unbiased, cryptographic, or independently verifiable unless the method supports that claim.
