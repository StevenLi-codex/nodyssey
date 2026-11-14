# 原生编辑器与私信：集成状态

## 可加入 iOS target 的文件

工厂：`NativeEditorScreens.make(destination:)`，真实实现 `PostComposer`（新帖／回复／编辑主楼／编辑回复）与 `MessageThread`。严格按 `swiftui-ui-integration.md` 参数解析，缺少编辑目标不降级成发新帖。没有 Compose、Web 编辑器或通用占位屏幕。

`iosapp/Nodyssey/Native/Editing/`：

- `EditorState.swift`：Foundation 状态、UTF-16 文本/选区、路由、草稿串行队列、附件状态、收款码格式。
- `MarkedTextEditor.swift`：原生 UITextView 输入适配及多输入框 handoff。
- `EditorViewModel.swift`：UI 状态、750ms 草稿去抖、预览、真实上传。
- `NativeEditorScreens.swift`：工厂、发布/回复/编辑页面、版块/最近版块/权限、生命周期。
- `EditorMessageThread.swift`：真实会话观察、显式刷新/已读、消息渲染与引用。
- `EditorPanels.swift`：工具栏及排序/隐藏/重置、链接、提及搜索、图库、只读表情选择、投票创建、收款码生成。
- `EditorPhotoPicker.swift`：PHPicker 文件 URL，最多 8 张、单文件 25 MiB、串行复制；不把原图批量读入 UIImage/Data。
- `EditorRichPreview.swift`：共享原生 RichNode 渲染，投票打开真实只读快照；图片、链接、付款审阅通过平台/路由。
- `Resources/Editor.xcstrings`：83 个 key，简中／繁中／英文齐全。

只修改以上目录、`iosapp/NativeEditorTests/**` 和本文件。未修改 App.swift、工程、桥接或其他域；未 commit。

## 已接线行为

- 新帖、回复、编辑分别使用 `editor.post.publish`、`editor.comment.publish`、`editor.edit.load/save`；编辑加载原始 Markdown，不反推 RichNode。Int64 身份不经 Double。
- 标题/正文使用同一个 UIKit 输入机制。面板、预览、发布、关闭先提交所有 marked text，再捕获文本和选区，再 resign，最后执行一次动作；有 marked text 时 SwiftUI update 不替换 UITextView 的 text/selection。保持输入控件身份，不因首末表情变化重建。
- `draft.post`/`draft.comment` 保存通过单个任务链串行执行；发布和显式离开先 flush。现存草稿有继续、保留当前输入、确认丢弃入口。删除后读回 null。接受发布不会自动删除草稿。
- 迟到加载不能覆盖加载前或加载期间的输入；恢复由用户确认。共享 `NativeMutationState` 加 UI 前置 busy 门保证 flush 期间也不能重复提交。失败不清草稿、不自动重试；成功也不清除提交后输入。已确认接受且未编辑的内容不能再发一次。
- 队列失效会取消正在执行的保存和排队尾部，而不只取消最后一个任务。session generation 更换重建 UI、清敏感状态、拒绝迟到返回。
- 最近版块实际读写 `boards.recent.get/record`，只展示与当前真实 categories 匹配的 slug；不假称全局 MRU 按站点隔离。权限用 `profile.self.rank` → `editor.permissions`。
- 私信只显示真实 `messages.thread.messages`。`messages.send == null` 是 accepted，不制造假 bubble 或 ID。发送/失败状态在编辑区，用户显式刷新核实结果。读状态按钮使用完整 `unreadIds`。消息草稿/引用暂存在按 generation+uid 隔离的内存，不写第二份 Swift 持久库。
- 图片真实调用 `editor.image.upload(id, source:file://, name)`；WAITING/UPLOADING/UPLOADED/FAILED、显式重试、移除。上传后由用户点击“插入”，避免异步完成时抢夺正在进行的中文 composition；未处理附件时禁用提交。不伪造上传进度。
- 工具栏消费对应 surface 的真实 settings；图库/表情管理只通过 `app.open` 跨域。只读表情选择消费 `stickers.get` 的 mine/subscriptions/siteGroups/CDN 后 URL/排序/隐藏，不依赖 Media 私有实现。
- 投票创建需确认；接受后保存真实 ID，读回失败只提供读回重试，不重新 create。收款码使用 `profile.self.uid`，按现有 `StardustReceiveMarkup` 的 encodeURIComponent 格式生成，不发付款请求。

## 实际验证

```sh
python3 iosapp/NativeEditorTests/run-mac-tests.py
python3 iosapp/NativeEditorTests/run-mac-tests.py --typecheck-ui
```

批准的嵌套 SSH 路径，仅在 `/Users/steven/.cache/hermes-build/nodyssey-editor` staging。实际生产 `EditorState.swift` + 实际 NativeCore，Swift Testing 合成传输测试；不调用真实仓库写操作。

测试覆盖：UTF-16 中文/emoji 选区、引用移除保护、新帖/回复/编辑 payload 与保存先后、异步加载保护、队列串行/flush、active+queued 取消、账户迟到结果隔离、共享提交 single-flight、失败不自动重试/null accepted 不造消息、成功不清更新输入、已接受防重复发、回复上下文、附件本地来源与移除后迟到结果、marked-text handoff 的 commit/snapshot/blur/action 顺序。

最终执行：**15 个 Swift Testing 测试通过**；macOS SwiftUI 签名 typecheck 通过；`git diff --check` 通过；83 个本地化 key 三语言完整。执行环境：Apple Swift 6.4.2、arm64 macOS 27.3。已有真实行为 RED→GREEN：UTF-16 插入、回复上下文遗漏、较新输入被 accepted 标记误锁、已接受重复提交、只取消队尾、load 启动前输入被覆盖。新 API 的首次 RED 有编译期缺失符号；不将其称为行为 RED。另有补充回归测试在实现之后添加。

`--typecheck-ui` 对生产 SwiftUI/renderer/Foundation store 源码进行 Swift 6 macOS SDK 26.5 签名检查；仅 UIKit picker/input、NativeAppModel、平台图像/错误 view 用明确标记的签名 stand-in。保留 macOS 14 onChange 弃用警告（生产仍支持 iOS 16）。测试构建保留 CLT 不存在 Xcode-style framework 搜索路径警告。SSH 偶有 banner timeout，runner 只重试 SSH exit 255，不重试任何应用 mutation。

## 仍需验收／明确差异

1. **不声称完整 iOS 验收**：父任务必须加入源码/xcstrings 并执行 Kotlin/Native + Xcode build；`UIKit/MarkedEditorTests.swift` 两个真实 UITextView 测试已写，但 CLT 无 UIKit，尚未执行。还需系统/微信输入法、旋转、首末表情、键盘/面板 handoff 真机测试。
2. 私信与编辑原文没有 shared 持久草稿 API；私信是进程内保存，编辑关闭会确认丢弃未提交更改，不能保证进程终止后恢复。如需持久化，需新增真实 Kotlin repository/bridge 能力，不能用 Swift 私有数据库替代。
3. 上传 ABI 没有进度流，故只显示不定进度；当前附件是逐张显式上传/重试/插入，没有批量重试或自动 Markdown 占位同步。没有调用真实上传验证。
4. 私信目前逐条显示服务端时间，尚未实现原版按日期分组/诈骗提示。没有乐观临时 bubble；这是避免 null accepted 虚构结果的安全选择，非原版 pending bubble 完整复刻。
5. 原生纯文本编辑保留 shortcode/Markdown，但没有 Compose 的原子贴图 token 退格/行内贴图覆层。选区与 raw text 保留机制不等于已经验证所有 IME 候选行为。
6. 预览中的 poll 是只读真快照，正式帖子域负责投票管理；代码默认使用原生源码展开/复制，尚未接报告 adapted/compare 回调。不是 Web fallback。
7. 回复成功按真实 floor（若返回）打开 PostDetail；刷新/已读基线、sheet 退场及新楼定位的端到端行为需父任务联合 Content/Foundation 验证。未发送真实帖子、私信、投票或图片。

以上是**可集成实现 + 已执行核心测试**，不是给 baseline inventory 全部打勾的声明。
