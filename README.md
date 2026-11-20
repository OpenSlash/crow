# Crow

English | [简体中文](README.zh-CN.md)

> ⚠️ **Experimental / Work in Progress** — This project is in early development. Features are incomplete, and APIs and structure may change at any time.

Crow is a personal AI execution hub for macOS. It understands intent through voice and text, calls tools and AI agents (such as Codex) to complete real tasks, and asks for confirmation before sensitive actions.

> Crow turns intent into action.

## Structure

| Directory | Description |
| --- | --- |
| `apps/daemon` | Local Go daemon (ConnectRPC) |
| `apps/macos` | Native macOS client (Swift) |
| `apps/island-native` | Notch / Dynamic Island–style UI (Swift) |
| `apps/status-native` | Menu bar status component (Swift) |
| `server` | Crow Cloud backend (Go, deployable to Cloud Run) |
| `proto` | Protocol definitions |
| `docs` | Product and technical design docs |
| `scripts` | Development scripts |

## Quick Start

```bash
cp .env.example .env   # fill in required config, e.g. CROW_OPENAI_API_KEY
./scripts/run-crow-server.sh
./scripts/run-crow-mac.sh
```

Requirements: macOS, Go 1.24+, Swift toolchain.

## Docs

See [`docs/`](docs/). Good starting points: [`product-blueprint.md`](docs/product-blueprint.md) and [`system-design.md`](docs/system-design.md).

## License

[MIT](LICENSE). `apps/*/Sources/CRNNoise/rnnoise` is from [RNNoise](https://github.com/xiph/rnnoise) (BSD-3-Clause).
