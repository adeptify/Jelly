# Workspace V1 验收记录 — 2026-08-11

## 结论

Workspace V1 已关闭本轮代码审查和真实使用测试中发现的发布阻塞项，可以合入 `main` 作为内部可用版本。

这不等于公开发行：当前包使用临时签名，尚未做 Apple Developer ID 签名、公证和更新分发。

## 本轮关闭的阻塞项

- Task Block 已接到真实 Block 编辑器，可安排到日历、完成、重开、取消关联和打开日历事项；取消关联会保留两端对象。
- 笔记可直接安排到日历，日历关系可反向打开准确笔记；灵感转笔记后会导航到创建或已有的准确笔记。
- 灵感补齐快捷新建、待处理数量、共享分类、搜索、归档和转笔记入口。
- Notes 与 Inspiration 搜索接入可重建的共享索引。
- 启动目录失败不再 `fatalError`，改为可读错误页和重试。
- 深色模式下原生 Block 编辑器文字可见；根因是自建 TextKit 容器高度为 0。
- 标题先保存、正文后保存时，会按重基后的真实差异重新计算修改字段，不再丢正文。
- 无变化的原生输入收尾不会制造草稿、阻塞新建或跨模块导航。
- 旧版本留下的“内容已在主文件、版本未增加”的保护草稿会被精确清理，不再启动递归卡死。
- 编辑会话切换由父级身份重建；新建笔记不会继续显示上一条笔记的标题。
- 已关联待办删除和主笔记解除关联均要求明确选择处置方式。

## 自动化证据

| 门禁 | 结果 |
|---|---|
| `git diff --check` | PASS |
| `swift test` | **1040 tests / 87 suites PASS** |
| `swift test -c release --filter AppEnvironmentWorkspaceCutoverTests` | **3 tests / 1 suite PASS** |
| `swift build -c release --product PersonalCalendar` | PASS |
| `./Scripts/build-app.sh` | PASS |
| `./Scripts/test-build-app-archive.sh` | PASS，ZIP 与只读 DMG 内应用严格签名一致 |
| `./Scripts/test-build-app-failures.sh` | PASS |
| `./Scripts/test-build-app-symlink.sh` | PASS |
| 解压 ZIP 后 `codesign --verify --deep --strict` | PASS |
| `hdiutil verify dist/Jelly.dmg` | PASS |

当前产物：

- `dist/Jelly.app`
- `dist/Jelly.app.zip` — SHA-256 `1fc1c9f62bb834ab4e4540dc691dd26794b206960915943d0b1e4fd042c94c8d`
- `dist/Jelly.dmg` — SHA-256 `2170e8b82c287442b403f9d8072cc852792e26bcd2fbc2efe2188864c3c644ea`

## Computer Use 真实产品测试

测试均启动复制到 `/private/tmp` 的准确应用路径，并把数据指向专用目录，没有用应用名模糊启动验收包。

### 全新数据闭环

隔离数据：`~/Library/Application Support/JellyFreshAcceptance.5o9Dmt/data`

- 连续新建两篇未修改笔记，第二次新建未被无变化收尾阻塞。
- 在原生编辑器实际输入 `[ ] task block acceptance`，自动转换为 Task Block，深色模式文字可见。
- 从 Task Block 创建日历事项，完成与重开双向同步。
- 取消关联后，Task Block 与独立日历事项均保留。

### 输入、重启、导航与灵感闭环

隔离数据：`~/Library/Application Support/JellyMainAcceptance.xeQwaZ/data`

- 创建并输入标题、正文，重启后正文仍可见，笔记到日历的安排和反向导航落到准确对象。
- `Command-N` 在灵感页聚焦快捷输入；捕获后待处理数量、分类、搜索过滤均正常。
- 灵感转笔记后打开准确笔记，标题与正文一致。
- 用旧版遗留的无变化保护草稿启动：应用不再卡死，草稿被精确清理，已有笔记可打开并可继续新建。
- 从已有笔记新建后，标题框恢复为空，不再残留上一条笔记标题。

## 数据隔离核对

- 所有有意写入均发生在上述隔离目录。
- 一次复验把环境变量名写错，只读启动默认目录后产生两个 0 字节锁文件；发现后确认无进程持有并精确移除。
- 默认主文件 `~/Library/Application Support/PersonalCalendar/calendar-v1.json` 仍为 8421 字节，修改时间仍为 `1786171076`；原有两个 Rollback 文件的大小与修改时间也未变化。

## 与设计文档的对应

| 设计意图 | 当前证据 |
|---|---|
| 日历 / 笔记 / 灵感三入口 | 真实界面可切换，快捷新建按当前模块路由 |
| 笔记独立于日期，同时可显式关联日历 | 双向导航和笔记安排日历已实测 |
| Task Block 单一完成状态 | 领域测试、集成测试和真实完成/重开均通过 |
| 灵感 raw-first 捕获再整理 | 快捷捕获、分类、搜索、转笔记已实测 |
| 草稿先保护，主文件保存后再清理 | Store/Journal 回归、重启和旧数据升级通过 |
| 搜索索引可丢弃重建 | Notes/Inspiration 共用索引并保留派生回退 |
| 第一阶段不引入 AI 自动决策 | 保持不变 |

## 仍需人工或发行环境验证

- VoiceOver 连续朗读、中文输入法组合态、hover 和多显示器属于设备/辅助功能专项，本轮没有声称已完成真人验收；已有 AppKit、可访问性和输入生命周期自动化覆盖。
- 永久删除只验证到确认边界与自动化合同；Computer Use 没有点击最终不可恢复按钮。
- 公开发行前仍需 Developer ID 签名、公证、安装与升级演练。
