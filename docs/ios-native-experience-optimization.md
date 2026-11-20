# iOS 原生体验优化：源码对照与验证记录

## 范围与版本

本报告区分源码比较、实际改动和运行验收；源码相似或编译成功不等于真机体验通过。

交付状态：首批是已验证的阶段性批次，不是整个全局优化任务完成。保留已通过验证的滚动/投影、返回判定、发帖层级和测试夹具改进；旧私信计数候选已撤回，其余未完成项目见第 6 节。

第二批正在进行：私信计数最终八文件已通过独立逻辑、安全与测试工具复审，父端和独立审查各运行 15 项 JVM、2 项 Python 检查，均通过；新冻结源码的 Apple main/test 编译已实际通过。历史滚动首轮闭包修复也通过全新独立复审，保留真实 RED/GREEN、66 项 Editor 通过及 iOS 16 SDK 类型检查。父端核对两范围全部 18 份最终源码、954 编译输入及下载产物。历史新字节的 Foundation 正式入口退出 0，已安装 CLT 完整 Content composition 等价回归为 81 通过、2 跳过、0 失败；原 Xcode composition 的匹配基线崩溃记录不变。计数候选随后完成定向 Native 测试，6 项通过、0 失败/错误/跳过，父端独立核对原始 XML、实际模拟器执行进程、954 输入及产物哈希。当前正常 Nodyssey Simulator Debug App 已实际编译并链接，112 份 Swift 输入和真实 Kotlin 静态框架均有原始证据；但监督脚本未保存 Xcode 数字退出码，严格构建门禁仍为 false。整体验收仍未完成，未做归档、App 启动或真机验证；本次 ICU 目标版本警告也不允许推断 iOS 16 运行兼容性通过。

- 目标分支：`feat/ios-original-page-parity`。
- 目标起点：`2f3b8a13e2a04e3882ec6fe15481ab0f61225ed3`；本轮基于已有未提交的滚动工作继续，不覆盖未跟踪的 `scratch/`。
- iNod 源码对照：`098d219b61614919432ec8fce9c6773f6321e7e9`。
- 2026-11-19 查询官方 latest Release 为 `v0.1.5`，其 tag 指向 `e9c4f8eb4c0736412a2be9f9f4c1fa54fa0080cf`，发布时间为 `2026-11-18T18:12:53Z`。对照源码和发布 tag 不是同一个提交。
- iNod 的 `Package.swift` 和 Xcode 配置要求 iOS 26；Nodyssey 继续兼容 iOS 16。没有提高最低系统版本。
- iNod 根许可为 MIT，署名 `Copyright (c) 2026 chentyke`；Nodyssey 根许可为 GPLv3。本轮借鉴信息组织和工程原则，没有复制参考项目源码、素材或配色；没有改动双方许可或原作者署名。

## 1. 十个模块的具体差异

下列引用均为上述固定源码的相对路径；目标路径前缀为 `iosapp/Nodyssey/Native/`。

### 首页

- iNod：`NodeSeek/Features/Posts/Feed/FeedView.swift` 使用稳定帖子身份、分页追加去重；刷新失败保留已加载列表，以局部错误提示重试。
- Nodyssey：`Content/ContentFeed.swift` 已有懒加载、版块和排序、分页窗口、返回位置、owner ticket、保留观察与刷新合并；缺口不是“没有缓存”。
- 选择：保留现有列表和缓存，仅减少重复窗口投影及高频拖动状态发布，不迁移整个 Feed 加载器。

### 帖子、评论与富文本

- iNod：`Posts/Thread/ThreadView.swift`、`ThreadActionBar.swift` 将阅读内容与回复、收藏、分享操作分层，并提供输入跳页。
- Nodyssey：`ContentThread.swift` 已支持楼层跳转、阅读位置、分页、投票、分享与屏蔽；`ContentRichBody.swift` 已按完整身份和内容使用渲染 memo。
- 选择：复用已有 `NativeRenderingMemo` 减少评论行投影；把 first-new 扫描提到逐行闭包外。没有裁减正文、降低图片质量或重写富文本格式。

### 发帖与回复

- iNod：`Posts/Editor/ForumEditorView.swift` 突出版块、标题、正文和发布，低频格式集中到菜单；论坛草稿有延迟保存。
- Nodyssey：`Editing/NativeEditorScreens.swift`、`EditorPanels.swift` 已具备完整工具、附件、投票、权限、待恢复草稿、组合输入和受保护的离开流程。
- 选择：仅调整展示层级、工具栏与文案；保留原输入、草稿、附件、发布、确认及关闭所有权。不移植 `TextEditor(selection:)` 或以 `onDisappear` 保存取代现有 awaited teardown。

### 通知

- iNod：`Inbox/NotificationsView.swift` 在大辅助字号使用菜单布局，并只在有未读时突出全读操作。
- Nodyssey：`Content/ContentNotifications.swift` 已有互动/私信分段、分组、独立观察、缓存先展示、全读确认和刷新状态。
- 选择：保留这些机制，不新建轮询或第二份未读计数。私信与未读计数的一致性单独验证，不能因界面上有角标便认定写后同步正确。

### 私信

- iNod：`Inbox/Messages/ConversationView.swift` 在阅读者接近底部时跟随新消息，否则提供显式回到底部的提示。
- Nodyssey 基线：`Editing/EditorMessageThread.swift` 已有会话观察、精确读回、Markdown、引用、草稿与发送；基线末条 ID 变化直接触发到底部。
- 选择：不照搬参考项目的轮询周期、消息草稿存储或网络服务；阅读历史时是否抢位置仍需受控 iOS 回放，不能宣称已解决。

### 个人中心

- iNod：`Account/AccountView.swift` 按身份、资产、社区记录与账号工具分组。
- Nodyssey：`Account/NativeAccountScreens.swift` 已有鸡腿、星尘、等级、签到及历史、收藏、关注、粉丝、设置等入口；自己资料的 Room 观察与网络读回也已分离。
- 选择：只借鉴层级和重复信息降权原则；不迁移账号、凭据或资产业务，不把现有功能误记为缺失。底部安全区和资产密度需要针对当前生产组合做明暗/窄屏验证，不能用另一页截图替代。

### 搜索

- iNod：区分编辑中的 query 与已提交 query，搜索用户等低频操作降为次级入口。
- Nodyssey：`ContentFeed.swift` 的 `ContentSearch` 已分离输入与提交条件，支持帖子、用户、本地目标、历史、分类、排序与分页。
- 选择：保留单一系统搜索输入和完整能力；不新增逐字远程请求，不删除本地搜索。提交条件变化导致结果子树重建，不等于整个搜索页无故重建，需分别验证。

### 设置与主题

- iNod：`Account/Settings/AccountSettingsView.swift` 使用标准列表分组，隔离危险操作。
- Nodyssey：`Settings/NativeSettingsScreens.swift`、`SettingsComponents.swift` 已有 Form 分组、能力控制、设置动作防重及权威读回，主题来源和预设由共享设置 SSOT 管理。
- 选择：不增加 AppStorage 或另一套主题存储，不盲目改写现有颜色解析和持久化。安全、权限及未支持能力的提示保留；当前没有复现的主题故障不能记为已修复。

### 请求、图片与解析

- iNod：`Sources/NodeSeekClient/Website/SiteDataStore.swift`、`NodeSeekCore/Caching/ResponseCache.swift` 提供同 key 请求合并、预算与失效；`ForumImageLoader.swift` 复用任务并按尺寸缩小解码。
- Nodyssey：`Foundation/NativeStore.swift` 已保留页面观察、缓存、刷新合并和代际屏蔽；图片先通过 KMP 认证、代理、Wi-Fi 与离线路径取得原始字节，再由现有有界解码管线处理。
- 选择：不复制缓存时长、并发上限或新建 URLSession 下载栈；本轮性能改动集中在已量化的视图投影和状态提交。

### 设计系统与交互

- iNod：`NodeSeek/DesignSystem/Theme.swift` 集中颜色、画布和卡片样式，并针对辅助字号调整布局。
- Nodyssey：`Foundation/NativeGlassSurface.swift` 已集中原生玻璃、旧系统材质及无障碍不透明降级。
- 选择：保留 Liquid Glass 和现有兼容层，不全局换皮，不把删除玻璃当性能优化；没有增加覆盖网络等待的整页淡入淡出或弹簧动画。

## 2. 实际借鉴与未采用的方案

实际借鉴的是：内容优先的编辑器层级、低频工具聚合、明确的主要操作，以及将重复投影与无意义发布从高频 UI 路径中移出。

需要适配而不能复制的是：iOS 26 新 API、分页及滚动恢复、消息跟随位置、输入法与表情键盘切换。

没有迁移 iNod 的网络/WebKit 会话、账号/Keychain、缓存仓库、图片下载器、草稿和发布实现；没有移除 KMP 或改写 Android。

## 3. 当前已落地的文件与 UI 变化

- `Content/ContentFeedDragState.swift`：拖动累计保留在独立 owner，只对可见折叠状态变化发布。
- `Content/ContentFeed.swift`：接入上述 owner，复用现有 memo 保存完整快照的分页投影。
- `Content/ContentThread.swift`：复用评论投影、一次计算 first-new ID、等值时不重复提交 viewport 状态。
- `Content/ContentBackSwipe.swift`：放宽边缘与慢拖/快划接纳；保留反向取消、垂直滚动保护、RTL 及既有离开门禁。
- `Editing/NativeEditorScreens.swift`：关闭/预览采用有可访问名称的图标；发布、编辑、私信分别显示“发布”“保存”“发送”；使用紧凑工具栏；草稿恢复保留直接入口，其他草稿操作归入菜单；公开权限显示为“公开”而非重复的“阅读权限：0”；提交中指示放在主操作旁。没有改变动态权限集合或提交门槛。
- `Editing/EditorPanels.swift`：保留既有工具顺序和自定义行为，为更多工具入口补充可访问名称。
- `Editing/Resources/PostComposer.xcstrings`：精简标题/正文提示，补全简中、繁中和英文的新增菜单及权限文案。
- `NativeContentUITests/Tests/ContentFeedDragStateTests.swift`、`ContentBackSwipeTests.swift` 与对应 runner：覆盖实际拖动状态和返回判定行为；没有把外观金图写进仓库测试。
- `NativeAccountUITests/Tests/AttendanceTests.swift`、`IndependentScopeReviewTests.swift`：显式控制回执接收和展示的测试时钟，不再让旧 DTO 随实际日期过期；未改任何签到生产代码或原有断言。
- `NativeSharingTests/stage-floor-entry.py`、`Tests/FloorEntryIntegrationTests.swift`：更新到实际 action sheet 分享入口和真实楼层 reveal 身份，保留原断言并增加屏蔽 helper 行为检查；未改分享业务。

正文最低高度约束已降低；在下述固定容器、键盘隐藏的真实模拟器诊断中，正文区域顶部上移 52pt，可见高度从约 487.3pt 增至 515.7pt。它是这一组受控布局的实测结果，不推断其他屏幕、键盘展开或性能提升。图片、表情、格式、引用、预览、投票、奖励及权限能力仍由原来的动作和面板实现；没有改变发布接口或帖子数据格式。

## 4. 性能原因与已经执行的证据

重复几何回调会读取同一份分页窗口；原实现每次重建投影。评论也会重复 map，first-new 查询位于逐行闭包中。viewport 标题、目标及展开状态存在相同值反复赋值。

使用真实生产代码提取的 Swift `-O` 合成回放，固定输入下记录到：

- 3,600 次窗口读取：构建次数从 3,600 次变为 1 次，语义发布仍为 1 次。
- 3,600 次评论投影读取：map 次数从 3,600 次变为 1 次。
- 120 行 first-new 回放：扫描次数从 120 次变为 1 次。
- 标题/阅读目标各 3,600 次赋值变为各 1 次；已展开状态不再重复赋值。
- 41 项边界检查通过，覆盖完整快照、相同 ID 内容变化、身份/代际变化、错误结果、页码回退、失效 geometry 和原有分页门槛。父端已核对报告中的最终源码 SHA-256 与当前文件一致。

这些数字是源码执行次数，不是 SwiftUI body 次数、网络请求次数或设备帧率。独立解码后的结构相等 JSON 仍可能付出深比较成本；不能声称所有输入都更快，也没有引入哈希缓存来掩盖成本。

另有隔离 iOS 拖动回放：160 次采样从 161 次 body evaluation 变为 3 次，展开/收起轨迹一致。它仍不等于用户设备上的 FPS 测量。

## 5. 编译与测试状态

- 优化前原始基线已实际运行：NativeEditor 56 项、NativeFoundation 96 项、NativeContent 81 项；日志保留原有警告和跳过信息，不当作本轮最终回归。
- 投影回放：41 项边界检查通过；既有 NativeRendering 15 项通过。
- 第一轮当前源码：实际 iPhoneOS SDK、`arm64-apple-ios16.0`、Swift 5 语言模式，全量 105 份应用 Swift 源码类型检查通过；随后读回远端编译输入清单，105 份源码的远端和当前工作树 SHA-256 全部一致。使用既有真实 Kotlin 导出头，未重新链接 Kotlin framework 或归档 App。
- 编译仍报告未修改的 `NativeBrowser.swift` 并发隔离警告；本轮没有借机改动登录浏览器。
- PostComposer 字符串目录经 JSON 解析与三语言键完整性检查通过。
- 第一轮全量回归已实际运行：Foundation 96 项、Editor 56 项、Content（含 composition）83 项且有 2 项跳过、Rendering 15 项、Image 19 项、Media 17 项、Library 33 项的命令均通过；Settings 行为执行脚本退出 0，不将其虚报为 Swift Testing 用例数。
- 第一轮出现的两个旧夹具失败已经闭合：Account 的固定 `2026-11-16` DTO 搭配默认真实时钟，过期后不再满足“今天”的前提；Sharing 的旧提取器查找基线已不存在的 `floor` 方法。只校正接收/展示时钟及实际分享入口后，真实 Mac 重跑 Account 60 项、Sharing 16 项通过，无跳过，并执行实际 PNG 渲染。父端读回远端日志、核对全部 179 个 staged inputs，且 59 个相关生产文件前后哈希完全一致。Account 原 32+2 条断言全部保留；Sharing 原 18 条断言全部保留，现有 20 条。原始失败日志没有覆盖或删除。
- 首轮限定差异的独立代码审阅通过：没有确认的安全或逻辑问题；小高度正文、窄屏草稿菜单和真实返回手势仍需集成验收。此结论不覆盖后续私信 Kotlin 或测试夹具修复，也不等于发帖明暗窄屏检查通过。
- 冻结旧版发帖的真实 iOS 26.5 模拟器诊断已补跑：320/393pt 容器、明暗共四种组合均完成挂载、预览及返回，四份 JSON 和截图已实际导出；远端 23 份 Swift 输入哈希与本地探针一致。使用原 EditorHost/输入与模型源码、仅在临时副本注入模型，网络、导航和 Store 为明确标注的适配边界。这不是当前候选 UI 的验收。
- 上述四种旧版回放中，正文 UITextView 在预览返回后重建，标题输入保持同一实例；正文文字和选择区均保留，未复现丢稿。诊断 JSON 的 `bodyOwnerChanges: true` 表示重现重建现象，不是“连续性通过”。这轮没有据此更换生产输入所有者或修改预览逻辑；键盘/组合输入后果仍未测。
- 当前候选随后使用同一模型注入方式和边界补跑相同四组真实模拟器诊断，全部完成挂载/预览/返回，正文文字和选择区保持；27 个远端文件与本地探针哈希一致，截图和 JSON 已导出。实际检查 320pt 明暗截图：发布主操作、关闭/预览、分类/公开权限、标题正文与工具图标可读，未见相互重叠或主操作折叠消失。该检查不覆盖草稿菜单展开、大辅助字号、实际键盘或完整 App/KMP 联调。
- 两次模拟器诊断均保留编译 warning（旧版 onChange 及独立 swiftc 的 sysroot warning）；执行结果来自实际安装启动的诊断程序，不将 warning 隐去或把它写成正式 App 归档通过。

## 6. 尚未完成的验收

没有测得用户设备的 Instruments/FPS、首屏可用时间、Tab 延迟、主线程阻塞、图片峰值内存或真实键盘切换耗时，也没有给出性能提升百分比。

列出的 Swift 回归脚本及设置行为脚本已经分别通过，不等于正式 App 的完整 Xcode 链接/归档。真实 Mac 的 Xcode 26.6 与 iPhoneOS 26.5 SDK 可用。首轮环境盘点未找到 JDK 21，现有类型检查 framework 只有导出头，没有可链接二进制。第二批已从官方归档准备独立的 Temurin 21.0.13，校验 SHA-256 后在 Mac 实际运行 java/javac，并另行读回运行结果；只使用隔离工具目录，未安装全局工具链。仓库原版 Gradle 9.8.0 wrapper 已实际启动成功，仅使用构建配置及 build-logic 的 `gradlew help` 也已成功。随后冻结的 Kotlin 候选在实际 Mac/iOS Simulator 26.5 SDK 上完成 `:iosapp:compileKotlinIosSimulatorArm64` 和 `:iosapp:compileTestKotlinIosSimulatorArm64`，退出码为 0；954 份输入哈希无漂移。另行读回 main/test 两套未打包 KLIB 目录及 manifest，确认目标为 `ios_simulator_arm64`，并在两套产物中找到新 owner 的符号证据。该候选独立审查未通过，结果已隔离，不能用于验收修复后的源码；新候选须另行冻结、审查和编译。此处只有 main/test 编译，没有执行 Native 测试，也没有正式 App 链接/归档或真机验收；未触发 CI，也不把前置条件不足写成产品编译失败。

候选发帖仍需草稿菜单/辅助字号、组合输入、键盘/表情切换和实际触控验收。旧版和当前候选的预览输入重建均在模拟器重现，但文字和选择区没有丢失，重建本身尚未证明是缺陷，不能据此重写输入所有者或宣称输入连续性已修复。个人中心资产密度、搜索加载闪烁、主题菜单与持久化不因通用类型检查而自动通过。

私信历史位置被新消息强拉到底已在真实 iOS 26.5 模拟器复现：同一生产 ScrollView 从 700pt 历史位置跳到末尾。首次候选因返回动作诊断捕获旧 render、后续 SSH 超时而撤回，其 62 项 Editor 结果不覆盖新代码。接续候选的原始日志已由父端核查：Editor 65 个独立用例通过；程序化当前动作 seam 的 11 项断言全部为 true，包括历史追加保留 700pt、返回实际末条 61、随后继续跟随 62、清除提示及再上读停止跟随。父端另看实际系统截图：返回后 61 完整可见且无按钮遮挡；历史帧蓝色浮动按钮确实局部遮盖一条正文，但单帧不足以证明永久不可读。完整独立审查随后判定不通过：旧按钮闭包从复用 StateObject 读取计算属性 observation，可能在 disappear/reappear 后借新 UUID 通过校验并操作旧末条。该只读审查没有执行实际旧闭包反例；已交独立修复者先补真实闭包 RED，再最小冻结 render 值。前述 65 项及 11 断言只覆盖被拒绝的冻结版本，不覆盖待修复字节。视觉签核及真实触控仍未通过；公开 XCTest 尝试 210 秒超时，无完成 leaf，不算触控通过。

旧闭包的首轮定向修复已返回：先以按钮直接调用的共享 action 工厂保留旧版动态读取 observation 的语义，保存旧 action、复用 owner 并 revoke→activate 后执行，实际出现滚旧 ID、清新提示及错误重启 follow 的 4 条失败断言；再将工厂参数改为构建时固定的 UUID/scope/target。最终 Editor 66 项通过、无失败或跳过，保留原测试并加强当前 render 正向。父端核对 14 份证据摘要、59 份 SDK 输入及原始 RED/GREEN；实际 iPhoneOS 26.5 SDK / iOS 16 的 Core、ContentUI、Editor 三项检查退出 0。只改三份允许文件，runner 未改；新十文件快照 `9fdd83bbfbaa` 的全新只读复审已通过，未发现阻断性安全或逻辑问题，但这不是整体验收通过。真实 touch、FPS、原 Xcode Content composition 和视觉遮挡签核仍缺；新字节的 CLT 等价可执行组合回归已独立补跑，结果见下文，不复用旧 CLT 81/2。

两处补 helper 的正式入口已完成独立 Mac 验证，父端核对 49 项证据摘要和原始结果：Foundation 正式类型检查退出 0；Content 原 Xcode Swift 6.3.3 composition 命令仍退出 1、未执行测试。精确 pre-history 对照保留 98 份相同输入，仅还原历史线程并移除 helper 及 staging 条目，在相同工具链/SDK下复现同一 EditorBuffer IRGen thunk 的 SmallVector 信号 6 崩溃；现有证据不支持归因于新历史实现，也不证明完整 App 编译会有相同结果。补充正式默认 Content 为 79 通过、2 跳过，Editor 为 65 通过；已安装 CLT Swift 6.4.2 的等价隔离 composition 诊断为 81 通过、2 跳过，包含两项 composition 测试，但不是原 Xcode 正式命令通过。测试计数按注册测试和 xUnit 核对，参数执行行不重复累计。实际 iPhoneOS 26.5 SDK、最低 iOS 16 的 Editor/Content 类型检查通过；没有 App 链接/归档或设备验证。以上均绑定旧十文件冻结范围，修复后的源码仍须新验证。原绝对 maxOffset 两项失败原封保留，最后行 anchor/viewport 门禁与其分开记录；模拟器滚动由公开 setContentOffset 驱动、消息为本地 JSON 注入，不是在线 Kotlin 联调或真机 FPS 证据。

历史 fix1 最终快照 `9fdd83bbfbaa` 已完成新一轮限定回归：checked-in Foundation 正式入口退出 0，使用 Xcode Swift 6.3.3 编译器与脚本指定的 CLT macOS 26.5 SDK，包含严格签名检查与真实 Editor 路由类型检查，不是运行时测试。已安装 CLT Swift 6.4.2 启用完整 `CONTENT_COMPOSITION=1` 的等价可执行回归退出 0，83 个注册方法中 81 通过、2 跳过、0 失败，两项 composition 方法均通过；仍保留既有平台/桥接和终端叶子夹具边界，不证明 UIKit、Kotlin 链接或在线后端。71 项包输入相对旧等价输入只有历史线程及 follow helper 两份改变。首次采集器路径误指 `scratch` 而非 `scratch/content`，在执行 Content 编译前退出 1；保留原始失败，仅修正临时取证路径后使用同一批源完成回归。父端实际重算 261 项证据摘要，核对 189 份 live/归档/远端前后源、十份复审文件、编译器源闭包与 xUnit 计数，并验证锁可用、独立暂存已删除且无本轮残留进程。原 Xcode composition 崩溃对照未重跑，阻塞结论不变；CLT 通过不替代原 Xcode 门禁。报告：`nodyssey-history-final-regression-9fdd83bbfbaa/report.json`；父端核验：同目录 `parent-verification.json`。

审计另复现私信标已读后计数滞后：权威列表已读而计数仍旧。曾制作非阻塞后台刷新候选并通过隔离 JVM 探针，但独立静态复核发现同一身份下旧计数响应可能迟到覆盖新计数，且该候选没有持久化 iosTest 或 Apple Kotlin/Native 编译结果，未予交付。首批收束时已撤回候选，并核对当时的 `NativeContent.kt` 与基线 HEAD 逐字一致（SHA-256 `6879467459d0c9749d66b780501282e1ac9294654c405c2d8e09ba9800ece9c1`）；失败审阅和候选 diff 均保留。私信计数仍是未解决项，后续须用现有所有者实现有序合并，并验证被挂起的 A/B 倒序响应，不能让计数网络成为消息展示的等待条件。

针对 COUNT-01/02/03 的第一轮最小修复已返回 JVM 证据，七份最终文件已按修复者报告的 SHA-256 核对并冻结。独立复审确认 COUNT-01/02 的排序与合并修复成立，逐案核查了 15 个既有 JVM case 的日志及输入哈希，但未重跑这些 case；另外两项 dispatch 测试仅有 JVM 通过记录。第一轮当时两份原 JVM runner 虽补入 owner 源文件，仍分别被 categoryRepository 夹具提取错误及缺少实际 ui-jvm.jar 阻塞，不能称为通过。复审同时确认新增 dispatch 测试放在真实 iosTest 下，却引用 JVM 专用 API 与不存在于生产图的夹具构造，判定不通过（IOS-TEST-JVM-API-01）。

第二轮仅修测试源集归属与 checked-in runner：dispatch 测试逐字迁至 `iosapp/tests/delivery/`，父端核对迁移前后字节及八份修复者报告哈希，生产计数逻辑和 portable iosTest 均未改。父端另外恢复了 runner 改写时漏掉的既有 manifest `results` 字段；契约先失败，恢复后重跑三个真实模式，dispatch 8 项、默认 delivery 6 项、scratch interval 1 项均通过，另有源集 Python 检查 2 项通过，JVM 无失败或忽略。默认 delivery 的原夹具提取阻塞现已在测试工具内解除，session-security 缺少实际 ui-jvm.jar 的阻塞保留。interval 是 scratch-only 挂起插桩，不是生产同步回调会挂起的证据。最终八份文件（快照 `ebf8493d2411`）通过新一轮独立复审；审查者重新执行相同三组 JVM 检查及 Python 源集检查，父端已和原始 JVM 日志、输入 SHA 对照。新 Apple 输入保留 portable iosTest 并排除 JVM 夹具；独立执行者在新目录实际完成 `compileKotlinIosSimulatorArm64` 和 `compileTestKotlinIosSimulatorArm64`，两任务均非缓存、跳过或无源，退出 0。父端核对 954 项冻结输入、1,046 份下载证据文件、main/test unpacked modules 的 `ios_simulator_arm64` 目标、非空 IR/linkdata 和 owner/六个测试方法符号；最终读回锁已释放，无本轮进程残留。该编译门禁本身只证明六方法可编译，不证明测试运行；后续独立 Native 执行结果见下段。未链接 App，旧隔离结果未复用，整体验收仍未完成。

计数 cycle2 同一冻结快照 `ebf8493d2411` 的定向 Native 执行门禁现已通过：实际运行一次 `:iosapp:iosSimulatorArm64Test --tests '*NativeCountRefreshOwnerTest*'`，六个源码测试方法与 JUnit XML 逐项一致，6 通过、0 失败、0 错误、0 跳过，Gradle 退出 0。使用已存在的 `BackSwipe-diagnostic` / iOS 26.5，由 `simctl spawn --standalone` 指定 UDID 执行真实 arm64 测试可执行文件，不需要启动模拟器；没有新建设备，全部设备状态不变。父端独立核对 954 份冻结输入（其中 953 份是仓库输入，另一份为既有编译驱动）、八份复审文件、126 份下载文件与 102 项产物摘要、日志、归档校验和及实际测试进程；验证脚本退出 0。两次预检误判及取证报告校验修正均保留，实际测试未因此重跑。远端最终读回确认锁释放后可重新获取，无残留构建进程，原编译 stage 哈希未变。报告：`nodyssey-count-native-tests-ebf8493d2411/report.json`；父端核验：同目录 `parent-verification.json`。该门禁不证明全 App 链接/归档、在线消息集成、UI、真机或 CI 验收。

首个成功 `JSON null` 与未响应状态在实现中有区分：`NativeRequestState.value` 的 nil 与 `.some(.null)` 不同，非分页 `hasValue` 依据 Optional 是否存在；测试覆盖已有私有值后发出 null，以及首次成功空数组，但未覆盖首次响应直接为 null。静态路径未发现产品缺陷；后续可补窄回归，不据此改生产逻辑。历史滚动当前动作的程序化门禁及闭包生命周期代码复审已通过，修复后 CLT 等价组合运行已通过，原 Xcode composition 与真实触控门禁尚未闭合，不据此改动全局 DTO。上述已验收首批没有改动 Kotlin、Android、业务接口、帖子数据格式、发布、登录/凭据存储或草稿持久化，也没有新增应用第三方依赖；第二批候选不得套用该首批验收结论。没有 commit、push 或触发 CI。

Kotlin framework 的 iOS 16 静态兼容性待验已做只读二进制归因：仅解析已保留的 `NodysseyShell` 静态 archive，按原始 `ar` 成员边界检查 2,326 个 Mach-O object 的 `LC_BUILD_VERSION`，并以 archive SHA-256 `83753e63215bf65972b1a39038945826b0c8521630d1003479198feed401f0a1` 固定输入。仅一个成员 `libicu.icudtl_dat.o` 标记 iOS Simulator 最低 18.5；其余成员标记 14/15。App 最低目标仍为 iOS 16。此结论将链接警告收窄至 ICU 数据对象，但不证明设备上必然崩溃，也不证明 iOS 16 兼容；未运行/安装 App 或 iOS 16 模拟器，不修改 ICU、Kotlin 工具链、依赖、deployment target 或任何生产代码。待通过支持 iOS 16 的 ICU 构建产物检查或实际 iOS 16 运行验证后再关闭。静态审计报告：`nodyssey-fullapp-link-current/icu-compatibility-static-audit.json`。

本轮进一步构建了正常 `Nodyssey` scheme 的 iOS Simulator Debug App，而非预览替代目标：当前工作树冻结 1,525 份输入，包含计数 cycle2 的八份与历史 fix1 的十份已审查文件；源码清单 SHA-256 为 `1e8f98376f676ab2db9486f9a922ff191e478d3ddf496e4f7ab8671beb69572a`。只执行一次 xcodebuild，原始日志含 `** BUILD SUCCEEDED **`，原始 xcresult 的 build status 为 succeeded、0 错误、12 警告。父端验证脚本实际退出 0，重新核对 live/冻结归档的全部输入、18 份审查文件、81 项证据摘要、实际 SwiftCompile 和模块匹配的 driver response files，确认 App 106 份与 NativeCore 6 份共 112 份 Swift 源实际编译。原 Kotlin framework 集成阶段保留；实际 Debug dylib 链接命令与原始静态库/产物的六个已定义 ObjC 符号共同证明 `NodysseyShell` 已链接。三个 Mach-O 均为 arm64、iOS Simulator platform 7、最低目标 16.0；产物元数据为 `io.github.nodyssey` 1.2.33 (75)，不是可交付设备 IPA。父端同时核对独立清理记录：锁释放后可非阻塞重获，无残留构建进程，模拟器状态不变。随后只更新本文及外部状态记录，不改变上述冻结源码证据。

该次构建的严格报告仍为 `pass=false`：监督脚本的 settings 变量覆盖了锁句柄，最终释放阶段异常，未保存原始 xcodebuild 数字退出码。监督脚本退出 1 不是 Xcode 的退出码；没有从 succeeded 字样推造 0，也没有为此重跑构建。证据恢复、独立清理和父端证据验证通过不改变这个严格缺口。12 条警告中 11 条来自未修改的 NativeBrowser 并发隔离代码，另 1 条为 `libicu.icudtl_dat.o` 按 iOS Simulator 18.5 构建、而 App 链接最低目标为 16.0。后者是必须保留的兼容性待验项，不等于已证明 iOS 16 运行失败，也不允许用 App 的 MinimumOSVersion 字段宣称运行兼容性通过；未借机提高最低系统、改依赖或改登录代码。报告：`nodyssey-fullapp-link-current/report.json`；父端核验：同目录 `parent-verification.json`，其 `verification_pass=true` 与 `strict_build_gate_pass=false` 分别记录。未测试、签名、归档、安装或启动 App，未触发 CI；原 Xcode Content composition 崩溃阻塞与触控/IME/FPS/历史按钮遮挡待验项不变。

个人中心、搜索与设置另行完成当前源码只读复核，父端核对报告涉及的 17 份文件哈希，未发现已确认的产品缺陷，未改生产源码。个人中心的缓存快照、独立刷新、代际隔离及签到时钟夹具有已有测试；搜索的提交态/编辑态分离、清空、空结果及 owner/generation 防旧回调路径只有静态证据，不作真实 UI 时序或闪烁通过声明；设置沿用现有重复动作禁用、主题 SSOT 与 `settings.set` 后 `settings.get` 权威读回路径。旧“资产密度”等主观条目不是复现缺陷；iOS 16 视觉、Menu tint、VoiceOver、搜索专项交互及设备端到端仍未验收。首次成功 `profile.self` 直接返回 null 仍是缺测，不改全局 Store。报告：`nodyssey-remaining-pages-audit-current-20261120/report.json`。本轮仅收束构建/审计证据，不代表整体交付或原始正式 composition 门禁通过。

## 7. 证据位置

完整对照、回放、原始基线、iOS 编译日志与独立审阅保存在运行环境外部 scratch，未将临时夹具、账号数据或凭据放入生产源码。稳定的核心结果已概括于本文；后续最终结果应以同一份合并源码的日志和 SHA-256 对照为准。
