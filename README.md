# 桃花源阅读器 · tts_reader

一个用 Flutter 写的**本地朗读阅读器**：把 PDF / EPUB / TXT 变成"能听的书"——
句级高亮、自动跟读滚动、系统 TTS 与本地/云端引擎可切换，还带一个能直接下书的
内置浏览器。

> ## 🤖 本项目由 AI 构建
>
> **代码全部由 AI 编写**：需求、验收和发布由人决定，实现（含测试、排错、打包）
> 由 **DeepSeek Harness 驱动的智能体**在真实设备日志反馈下迭代完成。
> 仓库里的每一次修复都能在提交信息与代码注释里看到对应的真机证据。

---

## 功能

* **三种格式**：PDF（含扫描件文本层）、EPUB、TXT 导入朗读
* **朗读**：系统 TTS / 本地引擎（clonetts、multitts 等）/ OpenAI 兼容的云端 TTS，可热切换
* **跟读体验**：当前句高亮、句级居中滚动、跨页自动接续、点句即读、目录跳转
* **控制**：控制条 + 通知栏媒体控制（播放/暂停/上一句/下一句），退出阅读页仍继续朗读
* **进度**：每本书独立记录朗读位置与视图位置，重开续读
* **下载**：内置浏览器 + Chrome 式下载列表（进度/暂停/继续/重试/打开/删除），
  下载目录可自定义
* **界面**：Material 3，手机/平板自适应（平板换侧边导航），浅色/深色

## 构建

需要 Flutter **3.24.5**（stable，Dart 3.5.4）与 Android SDK 34。

```bash
flutter pub get
flutter analyze                 # 应当 0 issue
flutter test                    # 单元/组件测试
flutter build apk --release     # 产物：build/app/outputs/flutter-apk/app-release.apk
```

* 正式签名：在 `android/` 下放 `key.properties`（`storeFile / storePassword / keyAlias / keyPassword`），
  并把 `android/app/build.gradle` 里的 `signingConfig` 从 `debug` 换成 `release`。
  仓库**不含任何密钥**。
* 出包后建议核对 APK 内资源完整（`assets/flutter_assets/AssetManifest.bin`、字体清单、着色器），
  可参考 `tool/verify_apk_assets.ps1`。

## 目录

```
lib/               产品代码
  features/pdf_reading/   PDF 朗读页、句级居中、滚动收敛
  pages/                 书库 / 阅读页 / 设置 / 浏览器
  services/              存储、下载、解析、位置记录
  tts/                   TTS 引擎与管理器
test/              单元与组件测试
integration_test/  真机端到端用例（需要设备与测试用 PDF）
tool/              构建、打包、快照、校验脚本
```

## 已知限制

* PDF 的"远距离跳转"在极少数情况下需要再跳一次（页高尚未量全时的估算误差）；
* 云端 TTS 需要你自己填 `baseUrl` 与 `apiKey`（设置页里填，只存在本机）；
* 下载功能只访问你自行输入的网址，站点解析规则仅为显示用途；
* 本项目是**个人自用工具**，未做多语言与无障碍适配。

## 免责声明

请仅用本应用阅读你**有权访问**的内容（自有文件、公共领域作品或已授权资源）。
内置浏览器只是一个通用浏览器，作者不对使用者访问的第三方站点及其内容负责。

## 许可

[MIT](LICENSE) © 2026 见 LICENSE
