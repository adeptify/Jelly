# Workspace V3 Visual / GUI Checklist

复验日期：2026-08-12

最终应用：`/private/tmp/Jelly-0.2.1-3-final.bOOELP/Jelly.app`

隔离数据：`~/Library/Application Support/JellyAcceptanceData.FtKKJX`

状态说明：`PASS` 为本轮最终应用真实点击通过；`AUTO` 为自动化通过但本轮未做真实点击；`UNVERIFIED` 为仍需真人或设备专项。

| Area | Check | Result |
|---|---|---|
| Shell | Rail shows 日历 / 笔记 / 灵感 | PASS |
| Shell | Command-1/2/3 switches modules | AUTO |
| Shell | Min width ≥ 1044pt; compact workspace layout is deterministic | AUTO |
| Notes | Create note; title/body entry points are visible | PASS |
| Notes | Body search, save, restart persistence | PASS |
| Notes | Draft recovery sheet on bare Journal | AUTO |
| Notes | Archive and restore in final packaged app | PASS |
| Notes | Permanent-delete model transition and menu entry | AUTO；最终删除未执行 |
| Calendar | Note schedules an item and opens exact relationship | PASS |
| Calendar | Primary / reference attach & detach | AUTO |
| Task | Schedule task block; complete both sides | AUTO |
| Inspiration | Capture text; convert; reopen exact note | PASS |
| Inspiration | Capture URL; search; copy; retry metadata | PASS |
| Inspiration | Archive and restore | PASS |
| Inspiration | Permanent-delete confirmation boundary | PASS；最终删除未执行 |
| Recovery | Recovery center lists candidates when present | AUTO |
| Search | Note body and Inspiration domain filter | PASS |
| A11y | Rail/list labels and full-row activation | PASS |
| A11y | Continuous VoiceOver reading | UNVERIFIED |
| Input | Chinese IME composition with hardware keyboard | UNVERIFIED |
| Calendar | Existing drag/resize/swipe regressions | AUTO |

## 隔离启动命令

```bash
acceptance_root="$(mktemp -d "$TMPDIR/jelly-v3-acceptance.XXXXXX")"
JELLY_ACCEPTANCE_DATA_DIRECTORY="$acceptance_root/data" open -n dist/Jelly.app
```
