# Jelly

Personal productivity app for macOS.

**Now:** calendar and list-style items (the core experience inspired by TickTick’s calendar + lists).  
**Next (not built yet):** AI-assisted inspiration capture, material digests into a personal knowledge base (source → digest → wiki-style notes), and related workflows.

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

Calendar v1/v2 interaction work is in tree and packaging-ready. Inspiration inbox and knowledge-base modules from the original product brief are **not** implemented yet.
