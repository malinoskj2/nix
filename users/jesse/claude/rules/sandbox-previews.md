# Sandbox preview sites

When `AGENT_PREVIEW_PORTS` is set, the sandbox has five ports reserved for preview sites:

- Pick an unused port from `$AGENT_PREVIEW_PORTS` (`8080` through `8084`). If the server reports that the port is in use, try another from the list. Disable automatic fallback to ports outside this list.
- Bind the server to `0.0.0.0`, so the host can reach it through the published port.
- Use the corresponding environment variable, `AGENT_PREVIEW_URL_8080` through `AGENT_PREVIEW_URL_8084`, for every link: browser checks inside the sandbox, links given to the human and pages opened through Orca's host-side browser. It points at the host's LAN address, so the same link also opens on the human's phone or other devices on the network. Preserve any required URL path. Host ports are allocated per sandbox; never assume they match the sandbox port.
- If the URL is on `127.0.0.1`, the sandbox predates LAN publishing or started without a network, and the link only opens on the host. If it doesn't load inside the sandbox, check with `http://127.0.0.1:<sandbox-port>` there and still give the human the variable's URL.
- Keep the server running while the preview is needed. Links stop working when the server or sandbox exits.

For example, run `python3 -m http.server 8080 --bind 0.0.0.0 --directory /path/to/site` and give the human the URL in `$AGENT_PREVIEW_URL_8080`.
