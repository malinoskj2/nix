# Sandbox preview sites

When `AGENT_PREVIEW_PORTS` is set, the sandbox has five ports reserved for preview sites:

- Pick an unused port from `$AGENT_PREVIEW_PORTS` (`8080` through `8084`). If the server reports that the port is in use, try another from the list. Disable automatic fallback to ports outside this list.
- Bind the server to `0.0.0.0`, so the host can reach it through the published port.
- For browser checks inside the sandbox, use `http://127.0.0.1:<sandbox-port>`.
- For links given to the human or opened through Orca's host-side browser, use the corresponding environment variable: `AGENT_PREVIEW_URL_8080` through `AGENT_PREVIEW_URL_8084`. Preserve any required URL path. Host ports are allocated per sandbox; never assume they match the sandbox port.
- Keep the server running while the preview is needed. Links stop working when the server or sandbox exits.

For example, run `python3 -m http.server 8080 --bind 0.0.0.0 --directory /path/to/site` and give the human the URL in `$AGENT_PREVIEW_URL_8080`.
