# zsh command suggestions

Type `# describe a command` on a single line and press Enter. Claude generates a
command and replaces the editable buffer; review it and press Enter again to run
it. Ordinary commands and pasted multiline scripts keep normal Enter behavior.

If Claude fails (including missing credentials, exhausted usage, network errors,
and structured error results), the widget tries Codex once. A successful Claude
reply is identified by its JSON result envelope, so command text containing words
such as `quota` cannot accidentally trigger fallback. Empty or multiline command
suggestions leave the original buffer unchanged. Codex failures also leave it
unchanged and show a short provider error; detailed CLI output stays out of the
command buffer. Ctrl-C cancels generation without starting another provider.

Both CLIs use their existing login credentials. Claude runs with tools and
customizations disabled. Codex runs in a private temporary directory with user
config, exec rules, hooks, apps, project instructions, web search and shell
execution disabled, read-only sandboxing and no approval prompts. The original
working directory is included in the shared generation prompt. Neither the
widget nor its providers should execute the suggested command during generation.
Temporary prompts, CLI errors and responses are deleted after each request.

Optional zsh variables (set before or after loading the plugin):

- `ZSH_CLAUDE_COMMAND_MODEL`: override Claude's model.
- `ZSH_CLAUDE_COMMAND_CODEX_MODEL`: override Codex's fallback model.
- `ZSH_CLAUDE_COMMAND_PROMPT_EXTEND`: append instructions to both providers' prompt.

Run the offline widget and provider-invocation tests with
`python3 pkgs/zsh-claude-command/tests/test_plugin.py` (requires zsh and jq), or
build `checks.x86_64-linux.zsh-claude-command`. The tests use fake CLIs and make no
model/API requests; authenticated provider availability remains a runtime concern.
Codex flags and settings follow the installed CLI's help and the
[official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
