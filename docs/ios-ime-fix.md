# iOS 输入时整应用卡死：排查与测试

此 fork 基于 [5151561/nodyssey](https://github.com/5151561/nodyssey)；原作者署名、GPL-3.0 许可与应用功能保持不变。上游目前只维护 Android，此处单独验证 iOS 输入相关修复。

## 问题与已确认的缺陷

收到的现象：使用微信输入法时，整个 Nodyssey 界面失去响应，而不只是候选栏卡住。尚未取得故障时的主线程堆栈、手机/iOS/输入法版本，因此不能把任意源码风险等同于这次实际根因。

上游项目固定使用 Compose Multiplatform `1.13.0-alpha01`。Compose 官方的 [CMP-10727](https://youtrack.jetbrains.com/issue/CMP-10727) 将该版本列为受影响版本：输入框聚焦、键盘避让和几何变化可使 `OffsetToFocusedRect` 持续重新测量，造成整应用卡死。官方复现使用屏幕旋转；**尚未证明微信输入法的候选栏变化触发相同路径**。

官方补丁 [compose-multiplatform-core #3406](https://github.com/JetBrains/compose-multiplatform-core/pull/3406) 限制一次普通测量所引发的 settling 重测，避免 settling 再次触发自己。`1.13.0-alpha02` 已包含该补丁，并包含相关键盘几何修复 [#3407](https://github.com/JetBrains/compose-multiplatform-core/pull/3407)。

只升级 iOS 设备与模拟器的依赖图到 `1.13.0-alpha02`，引入官方补丁；Android、桌面 JVM、macOS 的生产依赖保持上游原版。为在无手机的环境验证同一共享布局节点，只有 `:designsys` 的 JVM 测试 classpath 也使用修复版。这不是维护或构建另一个客户端版本。

## 不纳入本次修复的内容

- [Nodyssey #146](https://github.com/5151561/nodyssey/pull/146) 是听写时 tokenizer 越界崩溃的候选修复，不是已经验证的卡死修复；不复制其私有 ivar/runtime hook。
- 不全局切换实验性 native text input：该模式也受 CMP-10727 影响，而且存在 [CMP-10073](https://youtrack.jetbrains.com/issue/CMP-10073) 输出变换问题。
- 不清空草稿、用户数据或登录态，不禁用微信输入法，不添加遥测，不打印输入内容。

## 回归测试

`KeyboardOffsetSettlingTest` 将依赖中的真实 `OffsetToFocusedRectNode` 挂在 headless Compose owner 上，给测量与全局定位两个阶段提供不同的焦点几何。测试限定普通测量最多引发一次 settling，并检查下一次独立布局仍能再次修正。仅用反射构造私有依赖类，不复制布局算法，也不 hook 运行中的应用。

- 原 `alpha01` 依赖：同一测试出现 **5 次测量 / 5 次定位**，在保护上限处停止后按预期失败（期望 2 次）。
- 修复后的 `alpha02`：同一断言通过，每轮 **2 次测量 / 2 次定位**。
- 将最终测试放回原依赖的独立副本再次执行，仍出现上述行为失败；不是依靠类缺失、编译错误或源码文本检查制造 RED。

这是布局循环机制的回归，不是微信输入法真机复现。

```bash
./gradlew spotlessCheck :designsys:jvmTest --tests '*KeyboardOffsetSettlingTest*'
./gradlew :shared:macosArm64Test
./gradlew --stop
```

## 构建与验收边界

`.github/workflows/ios-ime-check.yml` 使用独立 macOS job 跑测试并构建未签名 IPA，不依赖原作者 Android 签名密钥，不向原作者频道发送通知。IPA 的第二轮优化测试版本显示为 `1.2.22-ime.2 (53)`；上一版 `1.2.22-ime.1 (52)` 保留作对照。

源码/依赖回归测试通过仅表示已确认的布局缺陷受到了保护；构建通过仅表示产物可打包。两者都不能替代微信输入法真机测试。

## 第二轮 iOS 优化

- 编辑器：没有应用表情时不启用额外布局监听；表情输出变换对象在编辑期间保持稳定，避免首末表情变化重启输入会话。有表情时保留框架的活布局 getter，避免每次测量发布新回调。保持输入字段的 composition slot，不重建焦点节点。Android/JVM 默认保留原路径。
- SVG：WebKit 初始化、加载、PDF 捕获和清理留在 Main；PDF 数据复制、CoreGraphics 位图绘制、ImageIO PNG 编码放在 Default。一个渲染锁覆盖完整流水线；取消后的原生同步操作须释放资源后才允许下一张图开始。位图上限为 16,777,216 RGBA 像素（位图本身最多 64 MiB），不代表进程总内存上限。
- 输入交接：在离开 iOS 编辑输入时保护当前预编辑字符串和选择范围，再释放焦点、隐藏键盘、切换面板/预览；不会猜测候选词，也不在重组时自动抢回键盘。实际微信输入法的候选词确认仍需真机验收。

本地 JVM 测试用于真实 Compose 状态/布局和协程调度验证；iOS 模拟器测试补充平台选择与实际 SVG→PDF→PNG 像素完整性。两者均不等同于微信输入法真机性能评测，不承诺未经测量的帧率、延迟或耗电改善。`smallBinary` 编译优化开关保持不变。

### iPhone 真机回归清单

请先保留原安装包及必要数据。优先用与原应用相同的签名方式和包标识覆盖安装；若签名或包标识不同，不要为强行覆盖而删除原应用和数据。

记录手机型号、iOS 版本、微信输入法版本和测试包版本。使用相同设备与相同键盘，对原版和测试版各执行：

1. 搜索框、回复框、发帖正文和私信框分别输入中文拼音、选择候选词、连续删除、切换中英文。
2. 展开/收起微信输入法候选栏，切换系统拼音后再切回来；不要打开其他可疑变量。
3. 在拼音尚未确认时点另一输入框、关闭回复框、重新打开；确认草稿未丢失、组词未重复、页面按钮仍可点。
4. 插入一个应用表情，然后在它前后输入、删除、移动光标；确认 Markdown 和发送内容正确。
5. 按官方复现：聚焦输入框 → 旋转 → 点击空白收键盘 → 再聚焦 → 再旋转。确认界面继续响应、输入框不被遮挡。
6. 回复预览/返回、表情面板/键盘切换后再次输入，重复多轮。

若仍卡死，保留触发步骤以及大致发生时间。连接 Xcode 调试时暂停应用并获取 `thread backtrace all`，可区分重复布局与 UIKit/输入法等待。日志可能包含个人路径或内容，分享前请脱敏；不要提供密码、Cookie 或 Token。
