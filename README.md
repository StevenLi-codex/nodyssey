<div align="center">

# Nodyssey

**NodeSeek 非官方开源客户端 · iOS 原生 SwiftUI 开发分支**

基于 [5151561/nodyssey](https://github.com/5151561/nodyssey) 继续开发，保留 Android 基础，专注 iOS 原生界面、阅读与互动体验。

[![iOS](https://img.shields.io/badge/iOS-16%2B-111111?logo=apple&logoColor=white)](https://github.com/StevenLi-codex/nodyssey/tree/feat/ios-original-page-parity)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-FA7343?logo=swift&logoColor=white)](https://github.com/StevenLi-codex/nodyssey/tree/feat/ios-original-page-parity/iosapp/Nodyssey/Native)
[![Kotlin](https://img.shields.io/badge/Shared-Kotlin_Multiplatform-7F52FF?logo=kotlin&logoColor=white)](https://kotlinlang.org/)
[![Status](https://img.shields.io/badge/iOS-开发中-2C6E7F)](#当前进展)
[![License](https://img.shields.io/badge/License-GPL--3.0-blue)](LICENSE)

[查看 iOS 源码](https://github.com/StevenLi-codex/nodyssey/tree/feat/ios-original-page-parity) · [获取测试构建](https://github.com/StevenLi-codex/nodyssey/actions/runs/43815446060) · [上游 Android 下载](https://github.com/5151561/nodyssey/releases)

</div>

## 关于这个分支

这是由 [StevenLi-codex](https://github.com/StevenLi-codex) 维护的二次开发仓库，当前重点是将 Nodyssey 的论坛体验带到 iPhone：以 **SwiftUI 构建原生页面**，复用 Kotlin Multiplatform 业务与数据层，并使用 UIKit / WebKit 处理输入、图片及网页验证等平台能力。

- **iOS**：原生客户端持续开发中，已产出可供自行签名的完整应用 IPA，并非仅展示页面的预览壳。
- **Android**：保留上游 Kotlin + Jetpack Compose 实现；公开 APK 请前往上游 Releases。
- **分支入口**：默认 `main` 保留上游代码基础与本仓库介绍；当前 iOS 开发代码位于 [`feat/ios-original-page-parity`](https://github.com/StevenLi-codex/nodyssey/tree/feat/ios-original-page-parity)，尚未合并到 `main`。

## 当前进展

**已交付内部测试构建：1.2.27（build 69）**，最低 iOS 16.0，arm64 iPhoneOS，未签名 Debug IPA。

目前已接入原生页面与业务流程：

- **浏览与阅读**：首页帖子流、版块与分页、帖子详情、富文本与代码块、图片查看。
- **发帖与互动**：发帖、评论与回复编辑器、引用、表情和图片上传，以及点赞、收藏、投票等操作。
- **消息与账号**：通知、私信、个人中心、用户空间、签到及登录／网页验证衔接。
- **个人资料与工具**：收藏、历史记录、离线内容、资产与报告相关页面。
- **外观与设置**：明暗主题、配色预设与自定义颜色、语言、网络和图床设置；部分操作控件在 iOS 26 使用系统玻璃效果，较旧系统保留兼容样式。

近期迭代集中在首页卡片点击与间距、回复面板与键盘、签到状态、通知和个人中心缓存，以及主题色应用。

**正在完善**：主题预设的全局即时生效、个人中心底部背景一致性、首页／通知 Tab 切换和缓存刷新时的闪烁，以及原页面交互细节与真机体验。

> 以上为已接入的功能范围，不代表所有场景都已完成真机验收。build 69 已通过归档与 IPA 包装校验；该构建流程不运行测试，不能视作完整测试通过或稳定版发布。

## 获取与安装

### iOS 内部测试版

1. 打开 [build 69 构建记录](https://github.com/StevenLi-codex/nodyssey/actions/runs/43815446060)。
2. 登录 GitHub，在页面底部 **Artifacts** 下载 `nodyssey-swiftui-full-unsigned`，解压取得 IPA。
3. 使用自己的签名方式安装。**未签名 IPA 不能直接安装**；构建产物有保留期限，过期后需重新构建。

本仓库目前未发布 GitHub Release 版 iOS 安装包。后续构建可在 [Actions](https://github.com/StevenLi-codex/nodyssey/actions) 查看，请以对应分支、版本及构建结果为准。

升级时尽量沿用原签名覆盖安装，**不要先卸载或清除应用数据**。不同开发分支可能使用不同的数据目录，版本号更高不代表会自动迁移旧数据；覆盖安装与数据保留仍取决于签名及安装工具。

### Android

前往 [原作者 Releases](https://github.com/5151561/nodyssey/releases) 下载 APK。上游版本记录见 [CHANGELOG.md](CHANGELOG.md)；它不代表本分支 iOS 构建的版本记录。

<details>
<summary>上游 Android 界面预览（非 iOS 截图）</summary>

<p align="center">
<img src="docs/screenshots/post-list-light.png" width="200" alt="Android 帖子列表" />
<img src="docs/screenshots/post-detail-dark.png" width="200" alt="Android 帖子详情" />
<img src="docs/screenshots/notifications-light.png" width="200" alt="Android 消息通知" />
<img src="docs/screenshots/profile-light.png" width="200" alt="Android 个人中心" />
</p>

</details>

## 开发入口

### iOS

请先切换到 [`feat/ios-original-page-parity`](https://github.com/StevenLi-codex/nodyssey/tree/feat/ios-original-page-parity)。使用 macOS、Xcode 与 JDK 21，并按仓库工作流准备 Android SDK 等共享构建依赖。

- 原生工程：[`iosapp/Nodyssey.xcodeproj`](https://github.com/StevenLi-codex/nodyssey/tree/feat/ios-original-page-parity/iosapp/Nodyssey.xcodeproj)
- 原生 UI：[`iosapp/Nodyssey/Native`](https://github.com/StevenLi-codex/nodyssey/tree/feat/ios-original-page-parity/iosapp/Nodyssey/Native)
- 共享业务层：[`shared`](https://github.com/StevenLi-codex/nodyssey/tree/feat/ios-original-page-parity/shared)
- IPA 构建步骤：[`.github/workflows/ios-ipa.yml`](https://github.com/StevenLi-codex/nodyssey/blob/feat/ios-original-page-parity/.github/workflows/ios-ipa.yml)
- 页面迁移说明：[build 66](https://github.com/StevenLi-codex/nodyssey/blob/feat/ios-original-page-parity/docs/swiftui-original-page-build66.md) · [回复与主题迭代](https://github.com/StevenLi-codex/nodyssey/blob/feat/ios-original-page-parity/docs/swiftui-reply-theme-build67.md)

### Android

需要 JDK 21 和 Android SDK 37：

```bash
./gradlew :app:assembleDebug
```

上游模块划分见 [docs/architecture.md](docs/architecture.md) 与 [docs/README.md](docs/README.md)。

## 反馈与参与

反馈本分支问题时，请注明 **iOS / Android、版本与 build、设备和系统版本**，附复现步骤及必要截图。请勿提交 Cookie、密码、Token 或其他账号凭据。

本分支的反馈与改进请留在[本仓库](https://github.com/StevenLi-codex/nodyssey)，不要将本分支 iOS 问题提交给上游作者。提交 PR 前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，并选择对应开发分支。

## 致谢与许可

- **原项目与作者**：[5151561/nodyssey](https://github.com/5151561/nodyssey) —— 本仓库基于其源码继续开发，保留原作者署名与许可。
- **本分支维护**：[StevenLi-codex](https://github.com/StevenLi-codex) —— iOS 原生 SwiftUI 开发与体验迭代。
- **上游参考项目**：[tyrad/nodeseek](https://github.com/tyrad/nodeseek)（MIT，站点结构逆向参考）、[mrzhiin/seekmate](https://github.com/mrzhiin/seekmate)（MIT，部分 JSON 端点发现来源）。

本项目与 [NodeSeek](https://www.nodeseek.com/) 官方无关，是社区自制客户端。请遵守站点规则、合理控制请求频率，不用于自动化刷分。

沿用 [GPL-3.0](LICENSE) 开源许可。
