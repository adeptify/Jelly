# Jelly

Personal productivity app for macOS.

**Now:** calendar and list-style items, structured Block notes, calendar–note relations, and a raw-first inspiration inbox.
**Next (not built yet):** AI-assisted processing, material digests into a personal knowledge base (source → digest → wiki-style notes), and related workflows.

Local-first. Data stays on your Mac.

## Requirements

- Apple silicon Mac (arm64)
- macOS 14+

## Build & run

```bash
cd /path/to/Jelly
swift build -c release --product PersonalCalendar
./Scripts/build-app.sh
open dist/Jelly.app
```

Packaged outputs (gitignored): `dist/Jelly.app`, `dist/Jelly.app.zip`, `dist/Jelly.dmg`.

Install notes for sharing a build: [docs/Jelly-安装说明.md](docs/Jelly-安装说明.md).

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

The Workspace V1 source is under acceptance review. Automated tests and release compilation pass, but this is not yet a release-readiness claim: live GUI checks, Task Block and cross-module navigation paths, and several accessibility/regression checks remain open. The inspiration inbox is implemented; the AI/digest/knowledge-base layer is not.
