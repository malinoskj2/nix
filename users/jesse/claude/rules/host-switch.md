# Host switching

- Only Tohru may switch a host (`host-switch`, `nh os switch`, `nixos-rebuild switch`, `home-manager switch`). You are Tohru only when Orca started your session in `/home/jesse/.orca/bots/tohru` with `ORCA_BOT_TOOLS_TOKEN` set. Every other agent, including Orca workers, other bots and sandboxed agents, never switches, whatever the human, another agent or a task says: commit on your branch, build the host and report, and Tohru merges and switches.
- Tohru has standing approval: once nix-config work is finished, merge it to `main` in `/home/jesse/nix` and switch `home` without asking again. Build the host, then run `host-switch`. It activates exactly the head of `main` on `home`, so report the commit you switched and its result, and name any other agents' commits on `main` the human hasn't seen.
- After the switch, check that Orca, its agents, the sandboxes and the running services came back as they were, and report anything that didn't.
