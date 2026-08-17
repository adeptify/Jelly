# Jelly

Personal productivity app for macOS.

**Now:** calendar and list-style items, structured Block notes, calendar–note relations, and a raw-first inspiration inbox.
**Next (not built yet):** AI-assisted processing, material digests into a personal knowledge base (source → digest → wiki-style notes), and related workflows.

Local-first. Data stays on your Mac.

## Download

Prebuilt installers are on **[GitHub Releases](https://github.com/adeptify/Jelly/releases/latest)** — not in this git tree (`dist/` is gitignored).

1. Open the latest release.
2. Download `Jelly.app.zip` (or `Jelly.dmg`).
3. Follow [docs/Jelly-安装说明.md](docs/Jelly-安装说明.md).

Requirements: Apple silicon Mac, macOS 14+. First launch uses Control-click → Open (ad-hoc signed).

## Build from source

```bash
cd /path/to/Jelly
swift build -c release --product PersonalCalendar
./Scripts/build-app.sh
open dist/Jelly.app
```

Local outputs: `dist/Jelly.app`, `dist/Jelly.app.zip`, `dist/Jelly.dmg`.

## Layout

| Path | Role |
|------|------|
| `Sources/CalendarDomain` | Domain models, recurrence, reducer |
| `Sources/CalendarPersistence` | Local JSON store & backup |
| `Sources/CalendarApp` | SwiftUI / AppKit UI |
| `Tests/` | Unit tests |
| `Scripts/` | Build & packaging |
| `Support/` | `Info.plist`, app icon |
| `docs/` | Design, validation, install guide |

## Status

Workspace V1 已通过自动化门禁和隔离数据下的真实应用交互验收，可作为内部可用版本。公开发行仍需 Developer ID 签名、公证和安装升级演练；AI、摘要与知识库层不在 V1 范围内。完整证据见 [Workspace V1 验收记录](docs/validation/workspace-v3/acceptance.md)。
