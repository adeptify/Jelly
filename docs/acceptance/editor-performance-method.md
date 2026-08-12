# Jelly 编辑器性能门禁与测量方法

测量日期：2026-08-13（Asia/Shanghai）

代码分支：`main`（实现提交 `db316c3`）

构建配置：SwiftPM `release`

## 测试机器

- MacBook Pro `Mac17,9`
- Apple M5 Pro，18 核（6 Super + 12 Performance）
- 48 GB 内存
- macOS 26.5.2（25F84）
- Apple Swift 6.3.3，arm64-apple-macosx26.0

## 固定数据集和门槛

| 数据集 | 规模 | Reducer p95 | 投影 p95 | 按键可见 p95 / max | 停顿后完整排版 p95 | 编辑器打开 p95 |
|---|---:|---:|---:|---:|---:|---:|
| Daily | 20 Blocks / 2,000 字符 | 2ms | 8ms | 33ms / 100ms | 33ms | 150ms |
| Long | 200 Blocks / 20,000 字符 | 4ms | 12ms | 50ms / 100ms | 75ms | 300ms |
| Stress | 500 Blocks / 50,000 字符 | 8ms | 16ms | 75ms / 150ms | 150ms | 600ms |

夹具按固定次序混合中文、英文、emoji、标题、列表、Task、引用、代码和分割线。三个规模分别用于日常记录、较长笔记和压力边界，不把压力数据集当成典型用户文档。

## 采样口径

- Reducer、文档投影和原生宿主按键路径：先预热 10 次，再连续记录 100 次。
- 编辑器打开：先预热 3 次，再记录 20 次。
- 每个样本使用 `DispatchTime.now().uptimeNanoseconds` 单调时钟，换算为毫秒；p95 取排序后向上取整的第 95 百分位样本。
- `key-visible` 从 `NSTextView.insertText` 开始，覆盖 reducer、连续文档投影、局部 `NSTextStorage` 更新和当前宿主布局。它不强迫 TextKit 重算整篇内容高度，也不包含显示器刷新等待，因此只能表示“按键产生局部可见更新”的进程内上界。
- `settled-layout` 在相同输入后显式计算完整 TextKit 内容高度，代表输入停顿后的维护成本。产品路径会把高度、Task 复选框位置等全篇维护合并到 250ms 停顿后执行，避免每个按键都支付整篇排版成本。
- “打开”测量进程内新建编辑会话、宿主、投影、布局和内容高度，不等同于 App 冷启动。
- 本表是 Release 二进制和已热 SwiftPM 构建缓存下的进程内暖数据。首次 Release 编译属于构建时间，不计入编辑器产品性能。
- 自动化同时要求连续输入 200 个普通字符全部使用局部投影，不允许每键调用整篇 `setAttributedString`。

## 2026-08-13 最终 Release 结果

命令：`Scripts/test-editor-performance.sh`

| 数据集 | 阶段 | p95 | max | 结果 |
|---|---|---:|---:|---|
| Daily | Reducer | 0.011ms | 0.016ms | PASS |
| Daily | 投影 | 0.215ms | 0.225ms | PASS |
| Daily | 按键可见 | 2.434ms | 2.943ms | PASS |
| Daily | 停顿后完整排版 | 3.821ms | 3.920ms | PASS |
| Daily | 打开 | 7.051ms | 7.192ms | PASS |
| Long | Reducer | 0.093ms | 0.111ms | PASS |
| Long | 投影 | 2.117ms | 2.366ms | PASS |
| Long | 按键可见 | 20.133ms | 25.816ms | PASS |
| Long | 停顿后完整排版 | 33.998ms | 34.303ms | PASS |
| Long | 打开 | 72.830ms | 73.332ms | PASS |
| Stress | Reducer | 0.217ms | 0.235ms | PASS |
| Stress | 投影 | 5.360ms | 5.617ms | PASS |
| Stress | 按键可见 | 48.753ms | 50.364ms | PASS |
| Stress | 停顿后完整排版 | 85.314ms | 85.686ms | PASS |
| Stress | 打开 | 174.547ms | 180.655ms | PASS |

结果只证明这台机器、这个提交和上述测量口径下通过固定门槛。长文滚动手感、输入法候选窗和显示器真实刷新仍由最终打包 App 验收补充，不能由这张表替代。
