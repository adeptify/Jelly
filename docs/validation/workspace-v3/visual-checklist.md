# Workspace V3 Visual / GUI Checklist

Use with an isolated data directory only:

```bash
acceptance_root="$(mktemp -d "$TMPDIR/jelly-v3-acceptance.XXXXXX")"
JELLY_ACCEPTANCE_DATA_DIRECTORY="$acceptance_root/data" open -n dist/Jelly.app
```

Mark each row PASS / FAIL / UNVERIFIED.

| Area | Check | Result |
|---|---|---|
| Shell | Rail shows 日历 / 笔记 / 灵感 | |
| Shell | Command-1/2/3 switches modules | |
| Shell | Min width ≥ 1044pt; calendar keeps 980pt | |
| Notes | Create note, type Chinese (Pinyin), save, restart | |
| Notes | Draft recovery sheet on bare Journal | |
| Calendar | Item detail shows 笔记 section | |
| Calendar | Primary / reference attach & detach | |
| Task | Schedule task block; complete both sides | |
| Inspiration | Capture text/URL; convert; archive | |
| Recovery | Recovery center lists candidates when present | |
| Search | Chinese title/body filter | |
| A11y | VoiceOver labels on rail + notes list | |
| Calendar | Existing drag/resize/swipe still work | |
