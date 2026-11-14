# Nodyssey → SwiftUI 全功能迁移清单（静态审阅）

- **交付基线**：`/home/hermes/projects/nodyssey-swiftui`，`feat/ios-swiftui-liquid-glass`，`ca98c21c47ddee7b3704417442d60e90bc828596`。先检查 `main@4959979`，随后比对实际工作树差异；导航/数据契约未变，已补入既有 IME 与 SVG 优化约束。
- 已读 `AGENTS.md`；只读应用仓库，无应用修改/网络写入。此文件和同名 `.json` 写在仓库外 scratch。
- **51 个 NavKey 全部与实际 entry 注册交叉匹配；10 个实施域覆盖全部路由且无重复。** 路由并非全部功能：另列回复/2FA/引导/报告/投票/离线等非路由组件。
- 下列 `[ ]` 是**待迁移/待验收**，不是已通过。未编译、未运行 app、未登录真实服务。Linux 缺 Java/Swift/Xcode；Mac 离线及 GitHub OAuth 状态为父任务提供，不是本轮测量。
- 本清单以实际源码为准：当前 **3 Tab**，不是注释的“4 个”；图床协议现已在 `shared`，不是 AGENTS 中较旧的“仍在 app”。原作者/GPL-3.0/Android/shared 数据层必须保留。

- **并行变更提示**：收尾只读检查时 HEAD 已由其他任务推进至 `d3c76a8548f7558935a912534b5ebdc07cb61c9b`，并出现 NativeCore/native 桥接等未跟踪文件。本清单仍是 `ca98c21` 迁移基线，不对这些正在编写的新实现给出完成/缺失判定；B01–B09 描述基线风险。

## 1. 全路由矩阵

`N` = `ui/src/commonMain/kotlin/io/github/nodyssey/NavigationKeys.kt`；entry 文件位于该目录，页面在 `ui/` 子目录。Compose 页面是函数而非 Swift 类。JSON 提供精确参数、页面路径、ViewModel 与域。

| 路由 | 实际页面入口 / 注册文件 | 验收功能 |
|---|---|---|
| [ ] `PostListKey` (N:11) | `PostListRoute` · `TabEntries.kt` | 首页：版块列表/排序（新评论、新帖子）、拖排/停用版块、分页跳转/连续加载/刷新、各版块滚动位置、已读/新回复、发帖与搜索入口。 |
| [ ] `SearchKey` (N:18) | `SearchRoute` · `TabEntries.kt` | 帖子/用户搜索；可选初始 query 自动搜索一次；单版块筛选、排序、分目标历史/删除清空、分页与过短词错误。 |
| [ ] `NotificationsKey` (N:21) | `NotificationsRoute` · `TabEntries.kt` | 互动（@/回复合并去重）与私信列表；角标、日期分组、部分失败、打开即读/全部已读、新建会话搜索。 |
| [ ] `ProfileKey` (N:24) | `ProfileRoute` · `TabEntries.kt` | 登录态/个人资料、等级/余额、签到/排行榜；收藏/历史/主题/评论/关注/粉丝/资产/工具/账号/设置入口。 |
| [ ] `SettingsKey` (N:27) | `SettingsRoute` · `SettingsEntries.kt` | 设置总页、站点切换、外观/内容/通知/网络/关于，所有开关必须有实际消费者（详见设置清单）。 |
| [ ] `ThemeSettingsKey` (N:37) | `ThemeSettingsRoute` · `SettingsEntries.kt` | 明暗、预设、取色来源、自定义色/图片取色、保存/删除我的主题、色彩风格与即时预览。 |
| [ ] `DynamicColorKey` (N:41) | `DynamicColorRoute` · `SettingsEntries.kt` | 壁纸候选色、系统调色板、自动更新；现 iOS 不支持壁纸来源，不能伪造候选。 |
| [ ] `NotificationSettingsKey` (N:45) | `NotificationSettingsRoute` · `SettingsEntries.kt` | 总开关/系统授权、轮询周期、仅 Wi-Fi、23–07 静默、互动/私信/关键词/追踪分类。 |
| [ ] `ProxySettingsKey` (N:54) | `ProxySettingsRoute` · `SettingsEntries.kt` | HTTP/SOCKS、地址端口、可选用户名密码、全应用相关请求/仅论坛、保存与真实测试。 |
| [ ] `DohSettingsKey` (N:64) | `DohSettingsRoute` · `SettingsEntries.kt` | 启用、服务增删改、URL/bootstrap 地址、选择/顺序、解析测试；Apple 能力限制见后文。 |
| [ ] `NetworkCheckKey` (N:74) | `NetworkCheckRoute` · `SettingsEntries.kt` | 网络诊断/重跑/结果；目前 iOS container 为 null，属于需补齐的缺口而非已实现。 |
| [ ] `ImageHostKey` (N:85) | `ImageHostRoute` · `AccountEntries.kt` | 六图床配置/校验/断开；有能力者列出已上传图片、刷新、复制/查看/删除确认。 |
| [ ] `StickerManageKey` (N:92) | `StickerManageRoute` · `AccountEntries.kt` | 组排序/隐藏、我的表情、订阅管理、坏链检测、CDN 测速选择、备份导入导出。 |
| [ ] `StickerGroupKey` (N:96) | `StickerGroupRoute` · `AccountEntries.kt` | key=mine/gh:…/site:…；重命名、排序/置顶、单选/批量删除、收藏到我的/撤销、坏链清除、导出链接。 |
| [ ] `StickerSourcesKey` (N:100) | `StickerSourcesRoute` · `AccountEntries.kt` | GitHub 订阅、检查/应用更新、换文件夹/取消订阅，错误保留与恢复。 |
| [ ] `StickerAddKey` (N:107) | `StickerAddRoute` · `AccountEntries.kt` | 初始 tab 与可选 source；链接粘贴/文件导入预览命名、图床多选/GIF筛选、上传原图选项/进度重试、GitHub 文件夹订阅。 |
| [ ] `AboutAppKey` (N:113) | `AboutAppRoute` · `SettingsEntries.kt` | 真实版本/原作者和项目链接、帮助/社区/隐私/更新日志/许可；崩溃日志与更新能力须按平台说明。 |
| [ ] `AboutCommunityKey` (N:116) | `AboutCommunityScreen` · `SettingsEntries.kt` | 社区介绍、实际成员数/重试、官方链接和 RSS。 |
| [ ] `PrivacyKey` (N:119) | `PrivacyRoute` · `SettingsEntries.kt` | 隐私/服务条款真实文档、加载/失败/重试，不用假文本代替 TermsRepository。 |
| [ ] `ChangelogKey` (N:122) | `ChangelogRoute` · `SettingsEntries.kt` | 真实 release notes/刷新/失败；现 iOS NoAppUpdates 返回空列表，需补数据源。 |
| [ ] `HelpKey` (N:130) | `HelpRoute` · `SettingsEntries.kt` | 帮助内容与重新显示新手引导；返回后保留原导航位置。 |
| [ ] `OpenSourceLicensesKey` (N:133) | `OpenSourceLicensesScreen` · `SettingsEntries.kt` | 完整开源依赖许可、原项目 LICENSE/署名；新增 Swift 依赖也纳入。 |
| [ ] `TitleKeywordsKey` (N:137) | `TitleKeywordsRoute` · `SettingsEntries.kt` | alerts=false 屏蔽普通关键词旧入口，true 提醒关键词；增删/规范化/持久化。 |
| [ ] `TrackedThreadsKey` (N:141) | `TrackedThreadsRoute` · `SettingsEntries.kt` | 追踪帖子列表、打开、取消追踪。 |
| [ ] `AccountSettingsKey` (N:151) | `AccountSettingsRoute` · `AccountEntries.kt` | 账号总页/刷新、子页导航、统一退出登录确认与清理。 |
| [ ] `AccountProfileFieldsKey` (N:154) | `ProfileFieldsRoute` · `AccountEntries.kt` | 头像相机/照片选取、简介、签名、Readme、编辑格式、校验/保存。 |
| [ ] `AccountSecurityKey` (N:157) | `SecurityRoute` · `AccountEntries.kt` | 改密码/强度/二次确认；读取 2FA 状态、密码确认后 enrolment URI 打开验证器及无应用错误。 |
| [ ] `AccountContactKey` (N:161) | `ContactRoute` · `AccountEntries.kt` | 邮箱资料/网页改邮箱；Telegram 绑定确认/受限浏览器/回前台刷新、解绑确认。 |
| [ ] `AccountBlockListKey` (N:165) | `BlockListRoute` · `AccountEntries.kt` | titles 初始页；用户屏蔽/解封确认、显示屏蔽内容；标题关键词/正则规则校验与删除。 |
| [ ] `AccountPreferencesKey` (N:169) | `PreferencesRoute` · `AccountEntries.kt` | 远端节日主题、首页版块隐藏；本地镜像与服务端一致。 |
| [ ] `PostComposerKey` (N:179) | `PostComposerRoute` · `ThreadEntries.kt` | edit=null 发新帖；PostEditTarget 编辑主楼/回复，完整编辑器/草稿/权限/附件/投票/收款码，见下。 |
| [ ] `MessageThreadKey` (N:191) | `MessageThreadRoute` · `TabEntries.kt` | uid + userName；会话读取/已读、富文本、引用/移除引用、图片/表情/工具栏、发送中/失败重试及时间分组。 |
| [ ] `PostDetailKey` (N:209) | `PostDetailRoute` · `ThreadEntries.kt` | postId/floor/page/preview；楼层优先、分页/恢复阅读/刷新尾页、新回复定位、收藏/追踪/反应/回复编辑/分享。 |
| [ ] `UserSpaceKey` (N:261) | `UserSpaceRoute` · `SpaceEntries.kt` | uid/isSelf/openCollections；资料/Readme、主题/评论/本人收藏、关注/取消关注、私信、用户备注。 |
| [ ] `FollowKey` (N:281) | `FollowRoute` · `SpaceEntries.kt` | showFollowers 初始页；关注/粉丝、重试、用户空间。 |
| [ ] `BookmarksKey` (N:291) | `BookmarksRoute` · `SpaceEntries.kt` | 本地收藏快照+远端同步、搜索、全部/已离线/新回复筛选、站点/回复数/待下载排序、多选删除/撤销、离线管理。 |
| [ ] `ReadHistoryKey` (N:298) | `ReadHistoryRoute` · `SpaceEntries.kt` | 设备本地日期分组、打开、删除/撤销、清空确认、保留条数（同时处理已读基线和阅读位置）。 |
| [ ] `AssetsKey` (N:308) | `AssetsRoute` · `SpaceEntries.kt` | 账户成长、额度、等级、固定/随机签到与榜单、流水/邀请入口。 |
| [ ] `CreditKey` (N:312) | `CreditRoute` · `SpaceEntries.kt` | 鸡腿余额/等级进度、分页流水。 |
| [ ] `StardustKey` (N:316) | `StardustRoute` · `SpaceEntries.kt` | 星辰余额/分页流水/类型筛选；收款人解析、转账表单/确认/服务器结果。 |
| [ ] `CommunityToolsKey` (N:319) | `CommunityToolsScreen` · `ToolsEntries.kt` | 社区工具导航，不能仅迁移入口而不实现下游。 |
| [ ] `MyTopicsKey` (N:331) | `MyTopicsRoute` · `SpaceEntries.kt` | 本人主题分页、版块筛选、排序、刷新/失败重试。 |
| [ ] `MyCommentsKey` (N:334) | `MyCommentsRoute` · `SpaceEntries.kt` | 本人评论分页、版块筛选、排序、正文预览/楼层定位、刷新/重试。 |
| [ ] `AwardKey` (N:337) | `AwardRoute` · `ToolsEntries.kt` | 精华/推荐列表分页、跳页、打开帖子。 |
| [ ] `LuckyKey` (N:340) | `LuckyRoute` · `ToolsEntries.kt` | 楼层抽奖规则链接生成：帖子、开奖时间、奖数、起始楼层、去重；复制/打开。本来就是本地生成，不是假服务端抽奖。 |
| [ ] `InviteKey` (N:343) | `InviteRoute` · `ToolsEntries.kt` | 鸡腿余额/购买提醒与确认后进入官方购买页；无原生购买 API，不伪造邀请码。 |
| [ ] `RulingKey` (N:346) | `RulingRoute` · `ToolsEntries.kt` | 管理记录分页/跳页与原始操作类型说明（币/星辰/标题/移动/权限/锁/精华/隐藏/置顶/封禁）。 |
| [ ] `ReportCompareKey` (N:350) | `ReportCompareRoute` · `ToolsEntries.kt` | 持久化测评篮、选择/移除、两或三份并排比较，字段对齐/差异。 |
| [ ] `ImageViewerKey` (N:359) | `ImageViewerScreen` · `ThreadEntries.kt` | urls + index；全屏滑动/缩放、保存相册结果、外部浏览器，返回保持帖子位置。 |
| [ ] `SignInKey` (N:372) | `SignInRoute` · `SessionEntries.kt` | 账号邮箱/密码、Turnstile、原生 2FA；网页登录/忘记密码/注册/DeepFlood 一键登录。 |
| [ ] `WebKey` (N:382) | `WebViewRoute` · `SessionEntries.kt` | url/title/goal；SIGN_IN、ONE_TAP_SIGN_IN、CHALLENGE、MANAGE、TELEGRAM_BIND，受限 WKWebView + Cookie 同步。 |

## 2. 非路由及跨页面验收

### navigation · foundation
- [ ] 实际顶层是 HOME/NOTIFICATIONS/PROFILE 三 Tab，不是 NavigationKeys 的陈旧“四个”注释；各自独立栈、重复 Tab 点按/根页滚动、交互返回与取消、状态恢复、大屏双栏。
- [ ] PostDetail 参数 floor 比 page 优先；preview 为首帧快照不是数据真源。UserSpace 的 isSelf/openCollections、Follow.showFollowers、StickerAdd.tab/source、BlockList.titles 必须保真。
- [ ] NodeSeekSite.InternalRoute 五种：Post(postId,page)、Space(uid)、Member(name 需 resolveMemberUid)、Notifications(group)、MessageThread(uid)；保留 floor hash、/jump?to 解包、同帖原地跳转、跨站不混 ID。
- [ ] LaunchRequest 六种 OpenTab/OpenLink/Search/OpenComposer/SignInForToday/ShareToComposer；外部分享文本+图片授权生命周期、通知点击、快捷入口需实际 iOS 接线（原壳尚缺），处理一次而非重进重复提交。
- [ ] OnboardingScreen 不在 NavKey：首次/重播/跳过、保留底层栈。SwiftUI 原生 TabView/NavigationStack/适用时 NavigationSplitView/系统 toolbar/sheet，不能只套 Liquid Glass 壳继续嵌全屏 Compose。

### auth-session · auth
- [ ] SignInCredentials(account,password,verificationToken?) → Signed/TwoFactorRequired(TwoFactorChallenge(account,otpSession))/Refused(reason,detail)。2FA 仅发送 otpSession+六位码，不重发密码/Turnstile；过期回凭证页，错误码保留表单，密码不落盘。
- [ ] Turnstile 验证中/成功/过期/不可用/重试、可信 base origin 与一致 UA；二次请求完成用 syncAwaitingSession，不仅依据成功 JSON 推断 Cookie 已可用。
- [ ] WebKey 五 goal；仅 MANAGE 可手动跳外部浏览器。SIGN_IN/CHALLENGE 必须等待 fingerprint 相对 baseline 改变，不能旧 cf_clearance 立即关闭；500ms Cookie 轮询/500ms settle、Telegram 4000ms 轮询。
- [ ] WKWebView load 前 await bridge.seed→start，所有关闭路径 stop→await drain→session.sync；observer 生命周期、串行拷贝与删除所有权保留；网页登录 XHR/Popup/targetBlank/window.opener/postMessage/window.close 需真实支持。
- [ ] NodeSeek/DeepFlood 各自 hosts，DeepFlood 的 NodeSeek 登录提供方额外白名单不等于内部内容站点。MANAGE/TELEGRAM_BIND 额外允许 Telegram OAuth；拒绝 userInfo/不可信主框架/脚本消息来源。
- [ ] 内存 SessionState generation/fingerprint、换号/签出后其他 Tab 私有内容/离线/草稿失效；本地用户备注/规则/追踪/表情按原设计保留。

### rich-nodes · rich-content
- [ ] 块节点全量：Paragraph(p)、Heading(h)、BlockImage(img)、VotePlaceholder(vote)、StardustReceive(stardust)、CodeBlock(code)、Quote(quote)、Tabs(tabs)、Fold(fold)、ListBlock(list)、Table(table)、Divider(hr)。Tabs.Tab 含 title/children；Fold.open；有序/无序嵌套列表。
- [ ] 行内全量：Text(t)、Link(a)、Sticker(sticker)、Image(iimg)、QuoteRef(qref)、LineBreak(br)；InlineStyle bold/italic/strikethrough/code 组合。表格单元格保留行内节点/可点链接/图片，读取 Table.content 兼容 legacyRows(rows)。
- [ ] 代码 language/code/AnsiSpan/columns、等宽/CJK/emoji 列宽、横向阅读、复制/全文选择；折叠/页签独立状态；正文/回复/签名/Readme/私信/编辑预览一致，不能全部 flatten 为 Text/Markdown。
- [ ] NodeQuality + YABS 报告解析、字段/徽章/表格/脚注/折叠、ADAPTED/SOURCE、全屏原始 ANSI、持久化比较篮与 2–3 份对齐比较。
- [ ] 投票是实时内容：单多选/公开/结果/投票人分页/锁定解锁/删除/创建；登录及服务器拒绝，保留 DynamicSignTransport。星辰收款码 memberId/refId/amount/description/onetime，余额/收款记录/已付/本人/二次付款约束与花费确认。
- [ ] 所有嵌套节点递归提取图集；GIF 动画、SVG、头像缓存、失败重试、原图、缩放/滑动/相册权限/保存失败。不能直接 AsyncImage 丢 Cookie/Referer/代理/缓存/离线来源。
- [ ] ca98c21 既有 SVG 流水线：WKWebView 构造/load/PDF/cleanup 在 Main，PDF→CG 位图→ImageIO PNG 在 worker；锁跨全流程、取消后同步原生操作退出才释放、像素上限/透明/方向正确。保留或等效替换，不倒退到主线程栅格化。

### editing · writing-messages
- [ ] PostComposer 新帖：标题/版块/最近版块/阅读权限（含等级和私有），草稿检测继续/放弃/自动保存，编辑/预览模式、提交校验/错误恢复/提交成功导航。编辑原楼须 PostEditor.load 原始 Markdown，不能从 RichNode 反推；主楼/回复字段与 endpoint 有别，保存成功后刷新失败不能当保存失败重复发。
- [ ] ReplyComposer 是 sheet 非 route：按 postId 独立草稿、@/引用楼层、预览、关闭再开、发布后定位新楼并更新已读基线；被其他页面覆盖不丢内容。
- [ ] 发帖/回复完整格式项 IMAGE/HOSTED_IMAGE/EMOJI/MENTION/BOLD/LINK/QUOTE/CODE/LIST/HEADING/STRIKETHROUGH/ITALIC；三种 surface 各自工具栏排序/隐藏/重置。私信可通过配置启用图片；签名/Readme 保留受限工具集。
- [ ] 投票创建/收款码生成弹窗、图床图库、表情面板、提及选择、链接等输入弹窗、附件 WAITING/UPLOADING/UPLOADED/FAILED、真实进度/单张与批量重试/移除及 Markdown 同步。
- [ ] 保留 ca98c21 的输入交接保障：未提交中文 marked text、选区、光标、首末表情插入删除、面板/预览/发布/回复关闭、多输入框/旋转不丢字、不重复、不抢焦点；SwiftUI 若需 UITextView adapter 仅承担原生编辑，不得将 Compose 编辑器当最终产品。系统与微信输入法都需真机验证。
- [ ] 私信：服务端 thread/markRead/markAllRead/send，引用/多图片/表情、发送中与失败 bubble/retry、临时 ID 与服务端 ID 合并，不能假定 send 完成就有新消息 ID。通知互动来源合并，读一个聚合项需更新全部 sources。

### offline · collections-offline
- [ ] 收藏从 CollectedPostMetaStore 可离线读，远端分页同步/截断说明/失败保留旧列表；多选全选只按可见项语义；删除/撤销处理部分失败。
- [ ] OfflineLibrary 五态 NotDownloaded/Downloading(progress 可 null 表示队列)/Downloaded(bytes)/Stale(behindReplies,bytes)/Failed；OutOfSpace/Network/Unavailable/Challenge/RateLimited 分开，不对挑战/限流盲目后台重试。
- [ ] 下载全部正文分页/回复及可选图片，增量补新回复、取消保留已下载、容量估算无依据为 null、文本/图片/可用空间；离线读取回退保留 downloadedAtMillis 而非伪装新鲜网络页。
- [ ] OfflineSettings wifiOnly/includeImages/autoSyncReplies/retentionDays=7/30/90/0(永久)；清离线不取消收藏；维护清过期/孤儿文件/队列恢复、退出清全部离线。
- [ ] BGTaskScheduler 启动完成前注册 io.github.nodyssey.offline.drain / io.github.nodyssey.offline.maintenance；前台也 drain、expiration 取消、setTaskCompleted、NWPath Wi-Fi 重查、请求重排，不承诺准点后台执行。
- [ ] 验收必须断网读之前未显示过但已下载的后续页和图片；当前 iOS offline path 未接阅读 loader 是应补缺口，Coil 偶然缓存命中不是证据。

### hosts-stickers · media-stickers
- [ ] ImageHostProvider 全量：NODE_IMAGE(nodeimage)、LSKY_PRO(lsky)、EASY_IMAGE(easyimage)、SMMS(smms)、IMGBB(imgbb)、CUSTOM(custom)。仅 NodeImage/Lsky/SMMS browsable；其他上传成功不能假造图库/删除。
- [ ] CUSTOM 的 siteUrl/fileField/headerName/headerValue/formFields/urlPath(含数组索引)/urlPrefix、Token 校验/保存/断开、secret 掩码；自定义 header/form 也可能是凭证。论坛 Session 与图床第三方 Session 分离，后者无论坛 Cookie/Referer。
- [ ] 平台照片/相机/文件权限；iOS prepare GIF 保留，普通图 2048 边/86 JPEG；original() 保留原格式，Bytes/NSData 内存上限/上传取消/错误分类。
- [ ] 我的/站点/GitHub 组，组/文件夹排序隐藏；链接批量解析、文件导入、预览有效性、命名、坏链清除、批量置顶/删除/收藏/撤销；图床选择 GIF、多图上传/原图与重试。
- [ ] GitHub 仓库 inspect/文件夹全选/订阅/换文件夹/增量更新/退订，JSDELIVR/GITHUB_RAW/CUSTOM CDN 选择测速，JSON 备份导入导出与冲突结果；发帖/回复/私信统一面板，正文图片长按存表情。

### settings-platform · settings-support
- [ ] UserSettings 全字段在 JSON 附录逐项列出。显示：system/light/dark、预设/自定义色/保存主题/5 palette styles/图片取色、字号、单手、墨水屏（浅色灰阶/减动画）、表情统一大小/尺寸。原生风格可重设计，不能静默抹掉用户可用设置。
- [ ] 内容：reportFormat/homePageBar/feedSort/imagesOnWifiOnly/clipboardPostPrompt/标题规则/图片缓存清理；首页隐藏/顺序/parked；post/reply/message 工具栏；searchHistory/recentBoards/readHistoryLimit；onboardingSeen/oneHandTipDismissed。
- [ ] 通知：enabled/pollMinutes/wifiOnly/quietHours/4 分类/关键词与追踪基线、授权状态、去重/角标、点击路由。iOS 现仅请求 UNUserNotificationCenter 权限，无后台 poll，不得把开关当实现。
- [ ] 代理真实 HTTP/SOCKS/可选认证/作用范围/连接测试；DoH 保存/测试；当前 Apple 仅一个服务器、不选 A/AAAA、不回退系统/不顺序尝试，能力开关按真实实现。网络诊断需 NSURLSessionTaskTransactionMetrics 接入，非填充假耗时。
- [ ] 站点 NodeSeek/DeepFlood：启动前安装 ActiveSite，DB/发帖回复草稿使用 storageSuffix，NodeSeek 保持旧名字；iOS 现为下次启动生效。语言简/繁/英及跟系统、WebView/Accept-Language/数字格式一致，Swift 字符串资源不能丢占位符/复数。
- [ ] iOS 现不可用：壁纸取色、自动剪贴板提示、论坛 Universal Links（缺域名 AASA）、Android APK 安装。采用真实原生替代/能力说明，不给空回调按钮；平台受限项不要求伪造与 Android 一样。
- [ ] 关于版本、原作者 5151561/nodyssey 链接、GPL-3.0/第三方许可、帮助/重播引导/社区真实统计/服务条款/RSS/发布日志；NoAppUpdates.releaseNotes 空列表、NoCrashReports 不能算功能已迁移，应明确可用渠道并补真实数据。

### common-quality · foundation
- [ ] 所有可见页面/弹窗具备 loading/empty/error/stale/refresh/retry；SiteError Cloudflare/LoginRequired/SessionUnrecognised/LevelRequired/PrivatePost/QueryTooShort/RateLimited/Http/Unparsable/Network/NotWired/Unknown 各自恢复路径，服务器 detail 原样适当显示。
- [ ] 关注/收藏等乐观更新保留 rollback；不可撤回货币反应/转账/支付/邀请先确认且只在服务器确认后改变余额/计数；不能网络失败后报成功。
- [ ] 原生 Liquid Glass 使用系统控件和支持 API，而非自绘玻璃贴图；动态字体/VoiceOver/Reduce Motion/Reduce Transparency/对比度、iPad/横屏、安全区、键盘/手势冲突。
- [ ] 保留原作者、LICENSE、提交历史/包标识与既有数据兼容；不重写 shared parser/Room/DataStore/签名协议，不用 mock repositories 替代产品功能。原来有意的受限官方 WebView（邀请购买/改邮箱等）仍是合法功能，不需要猜未公开 API。
- [ ] 迁移验收分层：解析/状态机 fixture 回归、Kotlin bridge 真编译、Swift 单元/集成、模拟器真实导航/数据持久、真机输入法/登录/相册/后台；自动测试的 fake 不可进入生产。无凭证或无 Mac 时标为未验证。

## 3. Kotlin → Swift 精确风险与阻塞

### B01 [blocker] Swift 可调用 API 尚未建立

- 证据：`iosapp/build.gradle.kts:31-39,83-106`；`iosapp/Nodyssey/App.swift:57-59`；`iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/NodysseyApp.kt:107-147`。
- 现状/风险：NodysseyShell 为静态 ObjC framework，implementation(:ui)，未声明 export(:shared/:richtext)。现 Swift 仅 start 回调接 UIViewController；没有已验证的 Swift repository facade。ensureContainer 返回 Kotlin IosAppContainer 不等于其所有跨模块类型均可用。
- [ ] 先做显式 API/export 或 iOS facade；检查真实生成头文件、Swift 导入及 arm64 device/simulator 编译。不能猜 Swift 名称或把 shared 的 api 依赖当 framework export。

### B02 [blocker] suspend/异常/Flow/生命周期不能直接交给 SwiftUI

- 证据：`shared/src/commonMain/kotlin/io/github/nodyssey/data/PostRepository.kt:120-220`；`shared/src/commonMain/kotlin/io/github/plaza/core/net/SiteError.kt`；`shared/src/commonMain/kotlin/io/github/nodyssey/data/dns/DnsResolutionTester.kt:10-11`。
- 现状/风险：源 Kotlin 扫描未见 @Throws/ObjCName/NativeCoroutines/SKIE。Repository 普遍抛 SiteException/ImageHostException；非取消异常越过默认 ObjC suspend 边界有终止进程风险。Flow/StateFlow 不是 Swift AsyncSequence；Result<T> 不是 Swift.Result。
- [ ] 边界显式错误 DTO 或 @Throws（以编译产物确认）、订阅句柄/close、任务取消传入 Kotlin Job、主线程状态交付；保留 SiteError 精确分类和服务端 detail。避免消失页面留下 collector 或吞 CancellationException。

### B03 [blocker] Paging 不是一次数组请求

- 证据：`shared/src/commonMain/kotlin/io/github/nodyssey/data/PostRepository.kt:120-167`；`shared/src/commonMain/kotlin/io/github/nodyssey/data/FeedRemoteMediator.kt`。
- 现状/风险：feed(categorySlug,sort,startPage) 与 searchFeed 返回 Flow<PagingData<FeedPost>>；另有 feedTotalPages、feedRowIndexOfPage。页面窗口/placeholder/append/prepend/loadState/refresh/retry 均有语义。
- [ ] 用 Kotlin paging presenter/适配层输出可观察快照和访问提示，或保留同等 Room+Mediator 行为的显式分页 facade；不能 first() 后 List 化或绕过 Room 直接抓网络。

### B04 [blocker] 现有 ViewModel 并非无 UI 的共享业务层

- 证据：`ui/src/commonMain/kotlin/io/github/nodyssey/di/AppContainer.kt`；`ui/src/commonMain/kotlin/io/github/nodyssey/ui/composer/PostComposerViewModel.kt`；`ui/src/commonMain/kotlin/io/github/nodyssey/ui/composer/ComposerFocusHandoff.kt`。
- 现状/风险：AppContainer 本身在 :ui；ViewModel 使用 androidx.lifecycle、TextFieldState、snapshotFlow、MarkdownEditorState、Compose 字符串/导航类型。删除 :ui 依赖会同时断图/后台/ActiveSite 初始化。
- [ ] 原生 Observable 状态/编辑器消费 shared repository；可只在 iOS 新建 facade 抽取非视觉用例，不把 TextFieldState、Composable 或 NavKey 当 SwiftUI API；安卓 UI/数据契约保持原样。

### B05 [high] 跨语言值模型/序列化陷阱

- 证据：`richtext/src/commonMain/kotlin/io/github/plaza/core/richtext/RichNode.kt`；`shared/src/commonMain/kotlin/io/github/nodyssey/data/AssetsRepository.kt`；`shared/src/commonMain/kotlin/io/github/nodyssey/data/composer/ImageUploader.kt`。
- 现状/风险：sealed interface/data object 不自动成为可穷举 Swift enum；Long?、Map<Long,…>、泛型 SpacePage<T>、IntRange、ByteArray、kotlinx.datetime.LocalDate、回调与 Kotlin Unit 均需确认桥接形态。普通 Kotlin data class 也不直接等于 Swift Identifiable/Codable/Sendable。
- [ ] 稳定 ID=site+实体 ID；Int64/nullable wrapper/NSData 有界转换；日期用服务器时区；明确 DTO 或完整 discriminator JSON。RichNode @SerialName、legacy table rows、OfflineFailure ordinal 和磁盘名称不得改。

### B06 [blocker] 会话/缓存安全不能随 UI 重写丢失

- 证据：`shared/src/appleMain/kotlin/io/github/plaza/core/net/WebKitCookieBridge.kt`；`shared/src/commonMain/kotlin/io/github/nodyssey/data/session/AccountSignOut.kt`；`ui/src/commonMain/kotlin/io/github/nodyssey/ui/login/WebViewScreen.kt:111-183`；`iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/NodysseyApp.kt:46-127`。
- 现状/风险：单例 Room/DataStore、ActiveSite 启动安装、真实 WebKit UA、Cookie jar 互拷/删除所有权、session generation/reconcile、退出顺序均承担安全与一致性。
- [ ] 后台与场景共用一次构造；读取私有缓存前 reconcileSession；退出清帖子/资料/离线/草稿/通知基线再发布签出；站点切换不可热改全局常量。

### B07 [high] 原 iOS 已有功能缺口，不能误当迁移完成

- 证据：`iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosImageLoader.kt`；`iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosOfflineFileStore.kt:33-36`；`ui/src/iosMain/kotlin/io/github/nodyssey/ui/login/WebViewScreen.ios.kt`；`ui/src/iosMain/kotlin/io/github/nodyssey/ui/settings/NotificationPermission.ios.kt`；`iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/Unavailable.kt`。
- 现状/风险：静态发现：iOS 图片 loader 未读 imagesOnWifiOnly；IosOfflineFileStore.pathOf 只被 hasStored 调用，未发现阅读 loader 接入；WebView.ios 未传/执行 policy.onPageReadyScript，自动一键点击缺失。没有通知后台轮询；网络诊断 null；更新/日志/崩溃为 No*。
- [ ] 逐项补齐并实测，不以设置开关/空列表/网络图片缓存代替真实功能。以上为源码调用链缺口，不是本轮实机复现。

### B08 [high] 系统限制与产品范围需明确

- 证据：`iosapp/Nodyssey.xcodeproj/project.pbxproj:165,185`；`ui/src/iosMain/kotlin/io/github/nodyssey/ui/settings/AppLinkHandling.ios.kt`；`ui/src/iosMain/kotlin/io/github/nodyssey/ui/settings/theme/WallpaperPalette.ios.kt`；`iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosAppContainer.kt:318-344`。
- 现状/风险：现 deployment target=16.0、SWIFT_VERSION=5.0；原生 Liquid Glass 需新 SDK/availability。站点域名无 AASA 控制；iOS 无壁纸取色；DoH 不支持 AAAA 开关/明文回退/顺序链。iOS 后台任务不能承诺 Android 固定轮询频率。
- [ ] 系统原生控件且 iOS 26 availability/旧版本回退，或经批准升级最低版本；Universal Links 需站点合作，否则提供真实显式入口而非假关联；如实隐藏不可用能力。

### B09 [blocker] 当前不能作 Apple 执行验收

- 证据：`AGENTS.md:89-102`；`docs/ios-ime-fix.md:37-64`。
- 现状/风险：本轮 Linux 无 java/swift/xcodebuild；父任务告知 Mac/Xcode 离线、GitHub 授权 401/OAuth 处理中。
- [ ] Mac 恢复后真实生成头文件、链接、Simulator/Device/IME/SVG/网络/后台回归。静态清点、旧文档中的通过记录不算本轮执行结果。

### 边界最小 API 验收（实现前冻结，名称为设计任务而非已存在接口）

- [ ] 为 `PostRepository.feed/searchFeed/feedTotalPages/feedRowIndexOfPage/thread/refreshThread/extendThread` 建立真正可取消、可观察的 Swift paging/thread adapter。
- [ ] 对 `SignInRepository.signIn/verifyTwoFactor`、`AccountSignOut.signOut`、`PostEditor.load/save`、`ImageUploader.upload(attachment,onProgress)`、`VoteRepository.*`、`StardustRepository.*` 等所有写路径建立统一 typed result；区分“写已成功但后续刷新失败”。
- [ ] `SessionRepository.state`、`SettingsRepository.settings`、`OfflineLibrary.states/usage/settings`、`StickerLibrary` flows、`ProfileRepository.selfUid`、本地各 Store flows：初值/取消/错误/主线程/注销测试，不通过定时轮询假装流。
- [ ] `ProxyConnectionTester.test(): Result<Unit>`、`DnsResolutionTester.resolve(): Result<DnsResolution>` 由 Kotlin 展开为稳定 DTO；不要假设 Swift 直接得到相同 Result 形态。
- [ ] 图床 `ByteArray`/progress block、账户 `AvatarUpload`、`PostEditTarget`、`PostPermission`、各 sealed 错误/离线/富文本类型需真实生成头文件确认；所有 Long ID 不降成 Double/Int32。
- [ ] `webViewPolicy`、`IosActiveSite.store`、`IosAppContainer.urlSession/forumSession` 是 internal；Swift 需要受控 public facade，不能假设可以直接调用。
- [ ] 保留网络链 `RetryingTransport(DynamicSignTransport(CookieScrubbingTransport(NSUrlSessionTransport)))`；论坛图片 UA/Referer/Cookie/代理一致，图床无论坛凭证；当前 secretStore 用 `PlaintextSecretCipher` + 旧 Keychain 迁移，不可误称现有 Token 全在 Keychain。若改善安全存储必须独立兼容迁移。

## 4. 并行实施边界

先冻结 foundation 的桥接/导航/错误/图片/富文本协议；其余域可据此并行开发，但未通过真实 bridge 的模块不能算集成完成。只有 foundation 集成者改公共桥接、Gradle、Xcode project/资源登记；其他人交付独立 Swift 目录，避免多人同时改工程文件。共享业务改动需附 Android 回归，禁止为便于桥接破坏公共 API。

| 域 | 路由数 | 前置 | 独占职责 |
|---|---:|---|---|
| `foundation` 原生壳/桥接/构建集成 | 0 | 无 | iosapp 桥接 API、单例容器、Swift App/导航/通用 DTO、Gradle/Xcode；仅此负责人改工程与桥接公共接口 |
| `auth` 登录/会话/受限浏览器 | 2 | foundation | Swift Auth/Browser；共享 Cookie/会话策略改动先由 foundation 审核 |
| `rich-content` 富文本/报告/图片渲染公共组件 | 2 | foundation | Swift RichContent/Images/Reports；公共渲染协议先冻结，其他域消费不复制 |
| `reading` 首页/搜索/帖子阅读 | 3 | foundation, rich-content | Swift Feed/Search/Thread；消费 paging bridge、回复 sheet 和认证回调 |
| `writing-messages` 编辑器/回复/通知/私信 | 3 | foundation, rich-content, auth | Swift Composer/Reply/Messages/Notifications；不修改其他域页面 |
| `identity` 个人/空间/账号 | 11 | foundation, auth, rich-content | Swift Profile/Account/Space；统一 SignOut 与用户备注组件 |
| `collections-offline` 收藏/历史/离线 | 2 | foundation, rich-content | Swift Library/History/Offline；后台实现由本域与 foundation 一次性对接 |
| `community-economy` 资产/社区工具 | 8 | foundation, auth, rich-content | Swift Assets/Tools；投票/收款业务组件输出给 reading/writing |
| `media-stickers` 图床/表情管理 | 5 | foundation, rich-content | Swift ImageHost/Stickers；共享上传与表情选择组件 |
| `settings-support` 设置/网络/帮助/合规 | 15 | foundation | Swift Settings/Support/Localizations；网络实现改动先协调 foundation |

## 5. 最终验收门槛（本轮均未执行）

- [ ] Mac 上生成并检查 `NodysseyShell` 头文件与真实 Swift 调用；iOS device arm64 + simulator arm64 编译链接，不能把 Linux skip/native disabled 当通过。现无 iosX64 slice，Intel runner 上 cross-build 与可运行测试明确区分。
- [ ] 旧数据覆盖升级：Room schema/序列化/站点分区/各 DataStore/会话/草稿/表情/CDN/离线/阅读位置不丢，账号切换不泄漏。
- [ ] 保留并跑 parser fixture、缓存/分页/会话注销/草稿/上传/投票/离线测试；补 Swift bridge 的取消/错误/订阅释放、真实 UI 导航与 native editor 回归。
- [ ] `./gradlew testDebugUnitTest testAndroidHostTest jvmTest`、`:app:assembleDebug`、`:app:lintDebug`、`spotlessCheck` 等 Android/shared 门槛；Mac 的 `:shared:macosArm64Test` 和新增 iOS/Swift 测试；按 AGENTS 完成后 `./gradlew --stop`。
- [ ] 真机：系统/微信输入法、登录+2FA+CF+DeepFlood 弹窗、图片/相册、全页离线、后台过期取消、真实交易拒绝与确认、三语言/VoiceOver/Reduce Motion/Reduce Transparency、iOS 26 Liquid Glass 和旧版回退。
- [ ] 最终生产业务画面无 Compose 页面嵌套、无 fake/mock 产品功能/按钮；WKWebView 只保留真实网页登录/验证/官方管理与必要 SVG 捕获。保留 Android 原 UI；shared 中仅稳定性注解依赖不等于仍使用 Compose 画 iOS。

## 6. 机器清单说明

同目录 `nodyssey-swiftui-inventory.json`：`routes`（精确参数/源码/入口/事件 ViewModel/验收/域）、`migration_domains`、`cross_cutting_features`、`bridge_and_platform_risks`、`app_container_contracts`、`settings_fields`、`view_model_event_inventory`、`rich_content`、`image_host_providers`。所有记录默认静态证据、无运行验收；不是实现完成清单。
