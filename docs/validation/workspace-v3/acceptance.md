# Workspace V3 Acceptance — 2026-08-11 overnight delivery

## Codex review correction — 2026-08-11

This file records the overnight run below; it is **not** evidence that Workspace V1 is release-ready. The current review branch has:

- fixed real AppKit window-close and application-termination save protection;
- connected Markdown import to the live Block editor session;
- restricted permanent deletion to archived objects and added an impact confirmation;
- made URL metadata limits stream-enforced, persisted failure state, and exposed retry;
- completed the explicit legacy Markdown preview/merge and create-new-note paths;
- added a permanent Recovery Center window/menu entry;
- added preview-confirmed permanent deletion for archived Inspirations;
- corrected the zsh purity gate so a missing release module directory does not fail a debug test run.

Current automated evidence: `./Scripts/test.sh` → **1023 tests / 86 suites PASS**; `swift build -c release` → **PASS**. Packaging was deliberately not rerun because `Scripts/build-app.sh` replaces the existing ZIP/DMG pair. The artifacts named below therefore remain evidence from the earlier Grok run, not from this review branch.

Release blockers still open:

1. `TaskBlockCalendarBadge` and `TaskBlockScheduleSheet` are not connected to Block editor rows; the shared-completion domain tests do not prove a user can reach the flow.
2. `NoteScheduleSheet` is not connected, and Inspiration conversion discards the returned Note ID instead of navigating to the created/existing Note.
3. Inspiration still lacks the specified quick-input shortcut, rail pending indicator, and shared-category control in its detail surface.
4. startup data-directory failure still terminates through `fatalError` instead of presenting a recoverable error.
5. the live GUI, IME, VoiceOver, hover, multi-monitor, restore, and calendar gesture checks below remain unverified.
6. Notes/Inspiration search has not fully cut over to the rebuildable search index.

Until those gates are closed and the package is rebuilt and checked, the truthful status is **implementation in review**, not “Workspace V1 delivered.”

## Artifact

- App: `dist/Jelly.app`
- Zip: `dist/Jelly.app.zip`
- DMG: `dist/Jelly.dmg`
- Codesign: `codesign --verify --deep --strict dist/Jelly.app` → **PASS**

## Automated gates

| Gate | Result |
|---|---|
| `./Scripts/test.sh` | **1008 tests / 84 suites PASS** |
| `swift build -c release` | **PASS** |
| `./Scripts/build-app.sh` | **PASS** |
| Task 15 E2E (`WorkspaceEndToEndTests`) | **PASS** — V2→note→relation→inspiration→restart |
| Task 10D vertical (`NotesVerticalIntegrationTests`) | **PASS** |

## Isolated data policy

- All automated acceptance used temp directories only.
- No intentional writes to default Application Support/PersonalCalendar during this run.
- Production default-data inventory: **not mutated by acceptance scripts**.

## GUI checklist (plan Task 15)

Automated hosted tests cover contracts; live GUI was not fully exercised in this unattended overnight run. Status for human morning verification:

| # | Check | Status |
|---|---|---|
| 1 | Launch raw V2 isolated copy; calendar intact | **AUTOMATED (E2E load)** / live GUI **UNVERIFIED** |
| 2 | Byte snapshot + RecoveryManifest before V3 | **PASS (automated)** |
| 3 | Command-1/2/3, 1044pt, light/dark, VoiceOver | **UNVERIFIED** (live) |
| 4 | Create Note; Pinyin IME; Block editor keys | **UNVERIFIED** (live) |
| 5 | Main-save fail after Journal; restart recover | **PARTIAL** (unit/integration) / live **UNVERIFIED** |
| 6 | Legacy notes merge / primary attach | **PARTIAL** (integration + UI present) |
| 7 | Series relation scopes | **PARTIAL** (domain; UI scope limited) |
| 8 | Task Block schedule + shared completion | **PASS (automated)** |
| 9 | Inspiration capture/convert/archive | **PASS (automated)** |
| 10 | Chinese search + archive filter | **PASS (projection/index)** |
| 11 | Restore V2 snapshot after rollback | **UNVERIFIED** (live path) |
| 12 | Calendar drag/resize/swipe regressions | **UNVERIFIED** (live) |

## Design-spec alignment (self-review)

Against `docs/superpowers/specs/2026-08-09-workspace-notes-inspiration-design.md`:

| Spec intent | Implementation status |
|---|---|
| Three entries: 日历 / 笔记 / 灵感 | **YES** — production enables all three |
| Notes independent of dates | **YES** |
| Calendar–note explicit relations, one body source | **YES** (domain + item detail UI) |
| Task block single completion truth | **YES** (`setTaskCompletion` shared) |
| Inspiration raw-first capture | **YES** |
| No empty Tab for unfinished modules | **YES** (fatal removed; hosts real) |
| No AI in phase 1 | **YES** |
| V3 migration with snapshot before overwrite | **YES** (persistence + E2E) |
| Draft Journal recovery | **YES** (10A + recovery center) |
| 1044pt min width (64+980) | **YES** (Task 7 layout) |

## Residual limitations (honest)

1. Legacy Markdown merge full planner authorization UI is present as a closed fail-closed path; “预览并合并” still needs the full authorization plumbing pass.
2. Task Block badge is not yet fully wired into every BlockEditor row context menu (helpers + sheets exist).
3. Live VoiceOver / hover / multi-monitor GUI checklist remains **UNVERIFIED** overnight.
4. Recovery Center is not yet linked from a permanent menu item in BackupCommands (view + VM ready).
5. Search index is rebuildable in-process; Notes/Inspiration UI still use derived in-memory filters for list search (index ready for Task 14 full cutover polish).

## Git

- Branch: `main`
- Delivery tip: see `git log --oneline` for Task 10B→15 commits from this session.
- Worktree should be clean after Task 15 commit.

## Handoff for user

1. Open `dist/Jelly.app` with `JELLY_ACCEPTANCE_DATA_DIRECTORY` set to a temp folder.
2. Walk GUI checklist rows marked UNVERIFIED.
3. Confirm default Application Support inventory unchanged after acceptance.
4. Only then install to Desktop if desired.
