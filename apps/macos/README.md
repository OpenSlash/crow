# Crow macOS

Native macOS client for Crow.

Current scope:

- Launch and supervise the Go daemon in `apps/daemon`.
- Read `~/Library/Application Support/Crow/runtime/session.json`.
- Call daemon ConnectRPC endpoints with JSON over HTTP.
- Show a compact native history/control window.
- Keep a status bar entry for background operation.

Run during development:

```bash
cd apps/macos
swift run CrowMac
```

