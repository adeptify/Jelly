# Jelly 编辑器性能门禁与测量方法

测量日期：2026-08-12（Asia/Shanghai）  
代码分支：`codex/jelly-editor-fluidity`  
构建配置：SwiftPM `release`

## 测试机器

- MacBook Pro `Mac17,9`
- Apple M5 Pro，18 核（6 Super + 12 Performance）
- 48 GB 内存
- macOS 26.5.2（25F84）
- Apple Swift 6.3.3，arm64-apple-macosx26.0

## 固定数据集和门槛

| 数据集 | 规模 | Reducer p95 | 投影 p95 | 按键到 TextKit 布局完成 p95 / max | 编辑器打开 p95 |
|---|---:|---:|---:|---:|---:|
| Daily | 20 Blocks / 2,000 字符 | 2ms | 8ms | 33ms / 100ms | 150ms |
| Long | 200 Blocks / 20,000 字符 | 4ms | 12ms | 50ms / 100ms | 300ms |
| Stress | 500 Blocks / 50,000 字符 | 8ms | 16ms | 75ms / 150ms | 600ms |

夹具按固定次序混合中文、英文、emoji、标题、列表、Task、引用、代码和分割线。三个规模分别用于日常记录、较长笔记和压力边界，不把压力数据集当成典型用户文档。

## 采样口径

- Reducer、文档投影和原生宿主按键路径：先预热 10 次，再连续记录 100 次。
- 编辑器打开：先预热 3 次，再记录 20 次。
- 每个样本使用 `DispatchTime.now().uptimeNanoseconds` 单调时钟，换算为毫秒；p95 取排序后向上取整的第 95 百分位样本。
- “按键到可见更新”从 `NSTextView.insertText` 开始，覆盖 reducer、连续文档投影、局部 `NSTextStorage` 更新、宿主布局和 TextKit `usedRect` 计算。它没有包含显示器刷新等待，因此准确名称是“按键到 TextKit 布局完成”，最终打包 App 的主观可见反馈另做真实 GUI 验收。
- “打开”测量进程内新建编辑会话、宿主、投影、布局和内容高度，不等同于 App 冷启动。
- 本表是 Release 二进制和已热 SwiftPM 构建缓存下的进程内暖数据。首次 Release 编译属于构建时间，不计入编辑器产品性能。
- 自动化同时要求连续输入 200 个普通字符全部使用局部投影，不允许每键调用整篇 `setAttributedString`。

## 2026-08-12 Release 结果

命令：`Scripts/test-editor-performance.sh`

| 数据集 | 阶段 | p95 | max | 结果 |
|---|---|---:|---:|---|
| Daily | Reducer | 0.012ms | 0.016ms | PASS |
| Daily | 投影 | 0.215ms | 0.284ms | PASS |
| Daily | 按键到 TextKit 布局完成 | 2.473ms | 2.587ms | PASS |
| Daily | 打开 | 8.192ms | 8.205ms | PASS |
| Long | Reducer | 0.094ms | 0.113ms | PASS |
| Long | 投影 | 2.047ms | 2.072ms | PASS |
| Long | 按键到 TextKit 布局完成 | 22.181ms | 22.441ms | PASS |
| Long | 打开 | 81.932ms | 82.001ms | PASS |
| Stress | Reducer | 0.217ms | 0.240ms | PASS |
| Stress | 投影 | 5.024ms | 5.052ms | PASS |
| Stress | 按键到 TextKit 布局完成 | 55.144ms | 55.598ms | PASS |
| Stress | 打开 | 207.872ms | 211.498ms | PASS |

结果只证明这台机器、这个提交和上述测量口径下通过固定门槛。长文滚动手感、输入法候选窗和显示器真实刷新仍由最终打包 App 验收补充，不能由这张表替代。
