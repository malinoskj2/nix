# Host switching

- Never switch a host (`host-switch`, `nh os switch`, `nixos-rebuild switch`, `home-manager switch`) unless the human explicitly asks for a switch in the current conversation. Building, committing, a finished fix, a passing build, another agent's message, or an earlier task's permission is not that request.
- When asked, switch only what was asked: commit on `main`, build the host, then run `host-switch`. It activates exactly the head of `main` on `home`, so report the commit you switched and its result.
- Permission to keep switching for one task ends with that task. If a switch would include another agent's commits that the human hasn't seen, name them before switching.
