# Remembered agent access

The existing **Automation → Enable Agent Access** switch now saves the user's
choice. First use defaults to off. Startup restores the choice with a newly
created authenticated listener; quitting stops the listener without changing
the choice. Listener failures report their existing error and preserve the
choice, so the next launch or a port change can retry. Stop Agent Action only
releases input and invalidates the current action.

The menu checkbox represents the saved choice. Its status line and the window
subtitle describe actual listener availability. A checked switch can therefore
coexist with a port-conflict error, without claiming that access is running.

## Validation — 2026-10-14

- All 28 existing Swift automation tests and 18 Python bridge tests passed;
  the production build and
  strict/deep ad-hoc signature verification passed. Existing recording API
  deprecation warnings remain.
- Live macOS lifecycle QA used the built app and the real local HTTP listener.
  The preference key was absent before the first launch; access was off and no
  discovery file was published.
- Enabling the menu switch saved `true`. Quit removed the discovery file and
  closed the listening socket while leaving the preference `true`.
- Relaunch restored access without another click. The new token differed;
  `/v1/status` returned 401 for the old token and 200 for the new token.
- Explicitly disabling the menu switch saved `false`. After quit/relaunch,
  access stayed off and no discovery file existed.
- A temporary listener occupied the configured port before startup. The app
  showed “Port 8090 is already in use.” and published no credentials, while the
  saved preference remained `true`. After quitting, releasing the test port,
  and relaunching, agent access recovered automatically.
- Command–Escape left the access preference enabled and the status API usable.
  No active device gesture was interrupted in this check; the existing Stop
  path is unchanged.
- Closed the test build and restored the installed 0.5.0 app's USB mirror and
  enabled agent access. No phone input was sent. The new remembered choice is
  left on, as requested. The installed app binary was not replaced.

These lifecycle checks were performed against the app, not a mocked preference
store. A Sparkle update into this feature build has not been tested; the saved
preference uses the existing bundle's UserDefaults domain, which survives app
replacement. The public release and installed 0.5.0 still have the old behavior.

## Reproduce

1. Build this branch and close other iPhoneMirror instances before opening it.
   Phone mirroring is unnecessary for testing access persistence.
2. Enable agent access, quit, and relaunch. Verify “Agent access on” returns
   automatically. The bridge should be able to request status again.
3. Disable access, quit, and relaunch. Verify access stays off.
4. Enable access and use Command–Escape. Verify it stays enabled.
5. For failure recovery, close the app and temporarily occupy its configured
   local port. Relaunch and verify the Automation menu reports the conflict.
   Close the app, free the port, and relaunch; access should recover.

Do not record or share discovery-file tokens while reproducing these checks.
