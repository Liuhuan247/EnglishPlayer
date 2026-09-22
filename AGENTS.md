# AGENTS.md — 英语视频学习播放器（macOS）

本文件是 Cursor 在本项目中开发时的强制规范。**开工前必须先读本节「文档基线」列出的全部文档，再动手写代码。**

## 项目一句话

macOS 原生英语精听播放器：把本地或百度网盘里的英语视频/音频，变成可逐句精听的学习材料（按句播放、单句/A-B 循环、变速不变调、句级波形、点击查词、断点续播）。

## 文档基线（必须先读，再动工）

| 文件 | 作用 |
|---|---|
| `docs/需求文档.md` | **做什么**：V1 功能清单、已确认决策、非功能需求、V1/V2/V3 边界 |
| `docs/技术方案.md` | **怎么实现**：技术选型、四层架构、六大核心模块方案、数据模型、风险、里程碑 |
| `docs/测试用例.md` | **怎么验收**：M1–M6 共 41 条测试用例，每条开发完必须对照通过 |
| `docs/design/设计稿.html` | 可交互高保真设计稿（浏览器打开，顶部 6 个视图 tab 切换） |
| `docs/design/screens/*.png` | 关键界面截图（01 主播放器 / 02 查词 / 03 百度网盘 / 05 设置），实现 UI 时逐一对照 |
| `docs/widgets/总体架构.html` | 四层架构图（UI / 服务 / 媒体核心 / 基础设施） |
| `docs/widgets/需求功能架构.html` | V1 功能架构全景图 |
| `docs/widgets/测试用例导图.svg` | 测试用例思维导图（PDF 导出用） |

## 已锁定的技术决策（不可更改）

- **技术栈**：Swift + SwiftUI + Swift Concurrency，macOS 原生；目标系统 **macOS 14+（Sonoma）**，优先适配 Apple Silicon
- **播放**：AVPlayer（AVFoundation）；倍速用 `player.rate` + `audioTimePitchAlgorithm = .timeDomain`（0.5–2.0x 不变调）；句边界 seek 用 `seek(to:toleranceBefore:toleranceAfter:)` 传 `CMTime.zero`
- **波形提取**：AVAssetReader 读 PCM + Accelerate vDSP 峰值包络，按句切分落盘缓存；UI 用 SwiftUI Canvas 画对称波形 + 播放头
- **持久化**：SQLite（媒体/句子/进度/缓存/设置）；网盘 Token 只存 **Keychain**，禁止明文落盘
- **查词**：只唤起本地欧陆词典 `eudic://dict/<单词>`（`NSWorkspace.shared.open`），**不内置词典、不用系统词典**
- **网盘（V1）**：百度网盘开放平台 —— OAuth 2.0 设备码授权（扫码）→ xpan API（list/search）→ `filemetas` 取 dlink（约 8h 有效）→ URLSession Range 断点下载 → 本地缓存播放；**V1 不做在线流式**
- **字幕**：自研轻量 SRT/LRC 解析器；视频配 SRT、音频配 LRC；双语配对、偏移校正（±N 秒持久化）
- **依赖管理**：Swift Package Manager

## 架构红线

```
界面层 SwiftUI（PlayerView / SentenceList / NetdiskView / SettingsView）
   ↓ ObservableObject 单向状态流（不得反向调用）
应用服务层（PlaybackSession / SubtitleEngine / SentenceEngine / WaveformService / DictionaryService / NetdiskService / LibraryService）
   ↓ 只面向 MediaCore 协议
媒体核心层（MediaCoreProtocol + AVPlayerKit 实现 + WaveformExtractor + Recorder(V2)）
   ↓ 依赖
基础设施（SQLite Store / Keychain / URLSession NetworkLayer / CacheManager）
```

- 业务代码**不得直接触碰 AVFoundation 细节**，一律走 `MediaCore` 协议（未来 Windows/Linux/移动端换实现不影响上层）
- 界面层只消费应用服务层的状态；服务之间互相独立，不循环依赖
- 详细分层见 `docs/技术方案.md`「总体架构」与 `docs/widgets/总体架构.html`

## 编码规范

- 命名清晰、Swift 惯例（`PascalCase` 类型 / `camelCase` 变量）；注释解释"为什么"而非复述代码
- 并发用 Swift Concurrency（async/await、Actor）；播放器时间回调等主线程 UI 更新必须回主线程
- 错误处理：损坏文件、字幕缺失、网盘断线、波形提取失败都必须有**用户可读的提示与兜底**，禁止崩溃
- UI 与 `docs/design/` 设计稿**零偏差**：系统蓝 `#0A84FF` 主色、侧栏 `#F2F2F7`、圆角 8–10px、系统字体、SF Symbols 风格图标
- 凭据（access_token / refresh_token）只进 Keychain；网络请求统一走 NetworkLayer

## 禁止项

- 不引入跨端框架（Flutter / React Native / Tauri 等）；不做 web 套壳
- 不内置词典、不调用系统词典框架
- 不把 Token / SecretKey 写进代码或配置文件
- 不擅自扩展 V1 范围（无字幕 ASR、生词本、跟读评分、云同步、AI 翻译均为 V2/V3，本期不做）
- 不跳过测试用例直接宣称完成

## 开发流程与验收

按里程碑顺序开发，**每完成一个里程碑必须跑通该阶段全部测试用例（`docs/测试用例.md`）再进入下一个**：

- M1 播放核心 → M2 字幕与按句 → M3 句级波形 → M4 查词与播放列表 → M5 百度网盘 → M6 打磨验收
- 每次改动后：`swift build` 无错误；涉及逻辑的改动补充/更新单元测试
- 完成一个模块时，对照 `docs/design/screens/` 对应截图检查 UI 一致性
- 全部完成后：逐条跑 `docs/测试用例.md` 41 条用例，全部通过才算交付
