# Nodyssey iOS 原生客户端 · 交接文档

更新：2026-11-22
工作树：`/home/hermes/projects/nodyssey-ios-interactive-preview`（分支 `feat/ios-interactive-preview`）
远端：`StevenLi-codex/nodyssey`

---

## 1. 目标与边界

长期目标是把 iOS 客户端做成纯 Swift 原生界面（现有 Kotlin Multiplatform 共享层保留为数据/业务层）。

当前阶段只做「修 bug + 指定 UI」，**不以重写替代修复**。

硬约束（用户明确要求，不要违反）：

- 不改业务接口、帖子数据格式、发布逻辑。
- 不擅自删功能或隐藏发布选项。
- 不把未测的性能提升说成已验证。
- 不影响 Android 客户端。
- 不改账号、登录、凭据存储行为。
- 不破坏离线缓存与用户草稿。
- 不新增不必要的第三方依赖。
- 密码/Token 不进聊天，只落目标机受限文件。

---

## 2. 出包流程（已验证可用）

1. 改代码，`bump` `.github/workflows/ios-swiftui.yml` 里的 `CURRENT_PROJECT_VERSION` 与 IPA 文件名。
2. 推到分支 `build/ios-1.2.34-<N>-<date>`。
3. `workflow_dispatch`，inputs：`archive=true, archive_only=true`（只归档，跳过全量测试）。
4. 下载 artifact `nodyssey-swiftui-unsigned`，脚本：`.hermes/cache/scratch/build78/download78.py <run_id>`。
5. 核验：`.hermes/cache/scratch/build78/verify_ipa.py <ipa路径>`，检查 build 号、bundle、arm64、minOS、sha256。
6. 只有核验过的 IPA 才能用 MEDIA 发。

参考产物（均已核验，均**不含**后续提交）：

| build | run | sha256（前 12 位） | 说明 |
|---|---|---|---|
| 82 | 44987215028 | 366ac38d6da6 | 私聊气泡初版 + 图床 UI + 单板块刷新 |
| 83 | 44990470928 | 172ffb986ef0 | 加板块 pager（已被 86 回退） |

---

## 3. 当前状态（build 87 编译中）

build 87 分支 `build/ios-1.2.34-87-20261122`，run 待核验。

包含的改动：

1. **正文返回手势**：修 `ownsHorizontalDrag` 把 contentInset 加进内容宽度的判定错误（见 §4.1）。
2. **主页板块跟手切换**：恢复 82 之前的跟手位移方案；TabView pager 已回退（见 §5.1）。
3. **私聊按 Telegram 风格重做**：主题色实底 + 白字、时间进气泡右下角带勾、一段连续消息只有最后一条带尾巴和头像、日期分隔为居中胶囊、富文本消息保留淡底。
4. **导航栏透明**：`nativeClearNavigationBar()`，iOS 26 用 `toolbarBackgroundVisibility(.hidden)`，旧系统回落 `toolbarBackground(.hidden)`。应用于主页、通知、我的。
5. **单板块下拉真刷新**：板块刷新从 `paging.refresh` 改为强制第一页 `feed` 读取（`forceInitialRefresh=true` + 新 pagerId）。
6. **回复栏底部留白 / 图床页顶部状态与整行主按钮**：早前完成，未回退。

---

## 4. 已定位的根因（重要，别再重复踩）

### 4.1 返回手势在正文失效、标题栏可用

`NativeOwnedNavigation.ownsHorizontalDrag(_:)` 原判定：

```swift
scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right > scroll.bounds.width + 1
```

普通竖向列表内容宽度 = 可视宽度，再加两侧 inset 必然"超宽"，于是整块正文被判定为横向滚动区，`blocks(hit:)` 拒绝返回手势起手。标题栏没有 UIScrollView，所以那里正常。

已改为按可视宽度比较。**这是用户实测反馈后定位的，属高置信修复，但仍需真机确认。**

### 4.2 单板块下拉刷新是假刷新

- 「全部」下拉 → `feed` + `forceInitialRefresh` + 新 pagerId → 服务端真读。
- 板块下拉 → `paging.refresh`（对已持有 pager 重读窗口）→ 列表重绘但无新内容。

Kotlin 侧 `NativeContent.kt:336` 对任意 slug 都支持 `forceInitialRefresh`，所以板块也能走同一路径。

### 4.3 导航栏灰方框

`toolbarBackground(.hidden)` 在 iOS 26 不再清除玻璃底，栏仍铺一条着色带，玻璃岛浮在上面。改用 `toolbarBackgroundVisibility(.hidden, for: .navigationBar)`（iOS 26 有则用）。

### 4.4 板块 pager（TabView 方案）失败

`TabView(.page)` 的横向手势被页内 `List`（UICollectionView）自己的 pan 抢走，板块切换完全失效。要在 pager 内可用，必须让列表 pan 只处理纵向起手（改 scrollView.panGestureRecognizer 的代理），风险高、且当时无真机验证手段。**已回退**，见 §5.1。

---

## 5. 待办

### 5.1 板块双页同时可见（用户明确要求，未完成）

要求：横滑时左右两页真实内容同时可见、过渡平滑、松手落整页。

推荐实现（不碰列表手势代理）：

- 保留现有 `ContentFeedBoardMotion` 跟手位移与 `ContentFeedBoardOffset`。
- 在位移容器里额外挂载相邻板块的 `ContentPagedList`（`allowsHitTesting(false)`），按其偏移量定位到 `±containerWidth`，跟随同一 progress。
- 提交后 `selectHomeBoard` 已能把邻居变成当前页，容器随之重组。
- 注意：`ContentPagedList` 的 `isHome` 依赖 `replacePage != nil`，邻居页应传 `nil`，避免多页争抢 Home 保位租约。

### 5.2 手势真机回归

未验证项（务必真机确认）：

- 正文中段起手返回、回复区长按后返回、横向微斜起手。
- 主页板块横滑跟手与落页。
- 通知列表、我的页面列表上的返回手势。

### 5.3 私聊后续

- 参考对象已确认为 Telegram；当前是首版对齐，用户尚未确认视觉细节。
- 输入栏未改为 TG 的「附件在左 / 发送在右」布局，仍是原编辑器工具条（功能未动）。
- 富文本消息用淡底，因为其文字颜色不可安全反转。

### 5.4 图床

用户已自行更新 API 地址并确认可用。UI 只做了顶部状态 + 主按钮，用户提到「很多 UI 都很简陋需要重做」，剩余页面（选择/测试/删除确认流程）尚未逐页重做。

---

## 6. 验证能力现状（关键限制）

- **Mac 通道已丢失**：唯一被批准的 wrapper `~/.hermes/cache/scratch/nodyssey-mac-light-20261120/mac_light.py` 已被 scratch 的 24h 清理删除，当前无法连 Mac 跑模拟器/类型检查。
- 因此现在只能：tree-sitter 语法检查（`.../local-parsers`，注意 `ContentNotifications.swift` 有既有 parser 不兼容）、CI 编译、用户真机反馈。
- 之前记录的 XCUITest 阻塞：DTServiceHub/Instruments lockdown，300s 超时、0 test leaves，**不是断言失败**。
- JVM `feed_initial_refresh` default/search 仍 5s 超时（历史遗留，未修）。

若恢复 Mac 通道，优先做：模拟器截图核对导航栏透明度、板块横滑首帧、返回手势首帧。

---

## 7. 关键文件

| 文件 | 作用 |
|---|---|
| `iosapp/Nodyssey/Native/Content/ContentFeed.swift` | 主页：板块 rail、跟手位移、分页刷新、跳页 |
| `iosapp/Nodyssey/Native/Content/ContentBoardPager.swift` | TabView 版 pager（已停用，保留参考） |
| `iosapp/Nodyssey/Native/Content/ContentFeedDragState.swift` | 板块拖拽状态机（38 项测试） |
| `iosapp/Nodyssey/Native/Foundation/NativeOwnedNavigation.swift` | 返回手势、pop settle、Home 保位 |
| `iosapp/Nodyssey/Native/Foundation/HomeEndRetention.swift` | Home 列表保位租约（多页挂载时会 ambiguous → fail closed） |
| `iosapp/Nodyssey/Native/Foundation/NativePageCanvas.swift` | 画布与 `nativeClearNavigationBar()` |
| `iosapp/Nodyssey/Native/Editing/EditorMessageThread.swift` | 私聊气泡（TG 风格） |
| `iosapp/Nodyssey/Native/Media/NativeMediaScreens.swift` | 图床设置 |
| `.github/workflows/ios-swiftui.yml` | 归档构建，版本号在此 bump |

---

## 8. 交接提示

- 每次改 UI 都先问「这块的 iOS 26 行为有没有换 API」——本轮的灰方框就是旧 API 失效。
- 判定"某个手势没生效"时，先查准入谓词（`blocks`/`ownsHorizontalDrag`/`admitsStart`），再看手势竞争。
- Home 保位租约要求唯一锚点；任何让多个 List 同时挂载的改动都会让它 fail closed（不跳位，但也失效）。
- 不要在无法真机验证的情况下把「已修复」写进交付说明；用户对这一点很敏感。
