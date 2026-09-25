# MCP and agent access

iPhoneMirror exposes the connected physical iPhone to local agents through a
small authenticated HTTP API and a Python stdio MCP bridge. It uses the same
screen stream and native input session as the window; it needs no additional
iPhone app or WebDriverAgent installation.

## Connect Codex

1. Build and open iPhoneMirror, then connect your unlocked USB iPhone normally.
2. Choose **Automation → Enable Agent Access**. Access starts disabled each time
   the app launches. The visible banner includes **Stop Access**.
3. From the repository root, register the bridge:

   ```sh
   codex mcp add iphonemirror -- python3 "$PWD/scripts/iphonemirror_mcp.py"
   codex mcp list
   ```

4. Start a fresh Codex task, or restart its MCP connection if your client offers
   that control. Ask it to use `iphone_status` and `iphone_screenshot` first.

The bridge requires Python 3.9 or later and only the standard library. Use an
absolute Python executable path in the command if `python3` is not available to
your Codex process. It can initialize and list tools while the app is closed;
tool calls explain when agent access needs enabling.

The registration command was checked against local `codex mcp add --help` and
[official Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
No Codex configuration is changed by building the app or running bridge tests.
The native HTTP API is a REST API; configure the **stdio bridge**, not a direct
HTTP MCP connection to the app's ephemeral port.

Other local MCP clients can launch the same command with this configuration
shape, substituting their actual absolute paths:

```json
{
  "mcpServers": {
    "iphonemirror": {
      "command": "/absolute/path/to/python3",
      "args": ["/absolute/path/to/PhoneMirror/scripts/iphonemirror_mcp.py"]
    }
  }
}
```

## Tools

| Tool | Arguments / result |
| --- | --- |
| `iphone_status` | Connection, readiness and frame status. |
| `iphone_screenshot` | Actual MCP PNG image content plus dimensions, `sessionID`, `observationID`, `frameID` and `ageSeconds`. |
| `iphone_tap` | `x`, `y`; optional `duration` for a long press (default 0.06 seconds). |
| `iphone_swipe` | `x`, `y`, `toX`, `toY`; optional `duration` (default 0.35 seconds). |
| `iphone_type` | `text` for the focused field; may replace the phone clipboard. |
| `iphone_key` | `key`: `enter`, `backspace`, `tab`, `escape`, `left`, `right`, `up`, `down`, `space`. |
| `iphone_home` | Go Home. |
| `iphone_button` | `button`: `home`, `lock`, `volume_up`, `volume_down`. `lock` ends control until the phone is unlocked by hand. |
| `iphone_app_switcher` | Open the app switcher. |
| `iphone_spotlight` | Open Spotlight search. |
| `iphone_control_center` | Open Control Center. |
| `iphone_rotate` | `direction`: `left` or `right`. |
| `iphone_release` | Release held input. |

All action tools accept optional `sessionID` and `observationID` from the latest
observation. Use both: they reject a changed connection or screen geometry before
executing coordinates. An observation ID does not detect arbitrary UI changes.
All coordinates are normalized from 0 to 1 relative to the upright screenshot,
with `(0, 0)` at its top-left. For a screenshot of size `width × height`, use
`x = pixelX / width`, `y = pixelY / height`. The PNG's longest edge is limited to
1280 pixels; use its returned dimensions, not the physical phone resolution.

Tap/swipe durations must be between 0.03 and 2 seconds. Text is limited to 16,000
characters by the bridge and must contain valid Unicode without NUL characters.

Suggested agent workflow:

1. Read status and screenshot; check that the phone is ready and the frame is
   suitable for the next action.
2. Perform one action or a short sequence whose results do not depend on unseen UI.
3. Take another screenshot and verify the expected state before continuing.

`accepted: true` means the app queued the input. It does not establish that a tap
hit the expected control, text was entered, an app opened, or a test passed.
After a timeout, observe before retrying: the action may already have happened.

## Local API and discovery

While agent access is enabled, the app writes a local discovery file:

```text
~/Library/Application Support/iPhoneMirror/automation.json
```

It contains a loopback `url` and bearer `token`. The bridge reads it afresh for
every request, so restarting access can rotate the token and port. Do not copy
this token into client configuration or logs. Requests use
`Authorization: Bearer <token>`.

| Request | Purpose |
| --- | --- |
| `GET /v1/status` | Return JSON connection and observation metadata. |
| `GET /v1/screenshot` | Return JSON with base64 `image`, PNG `mimeType`, dimensions and observation metadata. |
| `POST /v1/actions` | Send JSON such as `{"op":"tap","x":0.5,"y":0.5,"sessionID":"…","observationID":"…"}`. |

Actions use the names in the tool table without the `iphone_` prefix, except
`iphone_status` and `iphone_screenshot`, which are GET requests. HTTP failures
return `{"error":"…"}`. A stale session or observation returns HTTP 409.

The bridge accepts only numeric loopback HTTP origins with an explicit port;
it rejects credentials, remote hosts, URL paths, queries and fragments. It does
not use environment HTTP proxies or follow redirects. Requests have a 15-second
socket timeout and no automatic retries. Discovery, input messages and response
sizes are bounded. Screenshots are sent only through the calling MCP client;
whether that client sends them to a model provider depends on its configuration.

Use **Stop Access** to revoke access. **Automation → Stop Agent Action** cancels
an active gesture; Command-Escape also releases input and cancels the current
action. These controls cannot undo an action already delivered to iOS.

## Smoke tests and limitations

Read status without an MCP client:

```sh
python3 scripts/iphonemirror_mcp.py --status
```

Explicitly save the current screen when useful for QA (the path must not exist):

```sh
python3 scripts/iphonemirror_mcp.py --screenshot /tmp/iphone-test.png
```

Add `--full` to keep the stream resolution instead of a 1280-pixel long edge.

Run the automated bridge checks without contacting a phone:

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_mcp.py' -v
```

The bridge implements newline-delimited stdio JSON-RPC, MCP initialization,
ping, tool discovery and tool calls. It supports protocol versions `2025-11-25`
and `2025-06-18`; an unsupported version negotiates `2025-11-25`. Unknown tools
and malformed requests return protocol errors; action, connection and argument
failures return MCP tool errors. It advertises no task, resource, prompt,
subscription, or sampling capability.

This first version controls the already-connected iPhone. It does not connect a
device, launch an app by bundle ID, expose a native accessibility tree, or provide
OCR. A vision-capable agent can inspect the screenshot and navigate with touch,
keyboard and Spotlight. MCP registration and automated transport tests do not
by themselves verify physical-device behavior.

Protocol references:
[MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle),
[MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools),
[MCP stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports).
