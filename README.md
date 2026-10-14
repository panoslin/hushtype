# Hushtype

原生 macOS 语音输入法：按住快捷键说话，松开后把整理好的文字插入到任何 App 的光标处。

## 为什么是 Hushtype

| | |
|---|---|
| 🪶 **体积小** | 安装包约 26 MB，App 本体约 76 MB。原生 Swift + AppKit/SwiftUI 编写，没有打包浏览器内核（Electron）。语音模型首次使用时下载（约 850 MB，固定版本 + SHA-256 校验）。 |
| 🧠 **内存占用低** | 模型全部加载时约 600 MB（App 118 MB + 识别引擎 480 MB），仍低于实测约 675 MB 的同类 Electron 听写应用，而后者还不在本地跑任何模型。模型闲置 30 分钟或系统内存紧张时自动释放，之后只占约 118 MB。空闲时 CPU 0%，不占用 GPU。 |
| 🔒 **识别全在本地** | SenseVoice（sherpa-onnx）+ Whisper large-v3-turbo（WhisperKit，跑在神经引擎上）在本机并行识别。录音从不上传，默认也不保存。 |
| ✨ **可选 AI 整理** | 识别出的文字可以交给 Claude Sonnet 5.5 整理：删口头禅、处理改口、加标点和排版、按上下文纠正专有名词。只发送文字，不发送录音；可以关掉，完全离线使用。 |

<sub>内存为作者 Apple 芯片 Mac 上的实测值（2026-10），随模型和系统而变。</sub>

## 安装

1. 从 [Releases](https://github.com/panoslin/hushtype/releases) 下载 `Hushtype-<版本>.dmg`，把 Hushtype 拖进「应用程序」。
2. 目前没有 Apple 公证，第一次打开会被拦下：到「系统设置 › 隐私与安全性」，在页面下方点「仍要打开」。
3. 按引导授予麦克风和辅助功能权限，等语音模型下载完成。

需要 macOS 14+、Apple 芯片。

## 使用

| 操作 | 效果 |
|---|---|
| 按一下 fn（可改成右 ⌥ / 右 ⌘ / 右 ⌃），说话，再按一下 | 插入整理后的文字 |
| 按住 fn 说话，松开 | 同上（按住说话） |
| 选中文字，按 fn+⇧ 说指令 | 按指令改写选中文字；没选中时按指令生成并插入 |
| 说话时按 Esc | 取消 |
| 菜单栏 › 复制上一条 | 插入失败时兜底 |

## 构建

需要 macOS 14+、Apple 芯片、Swift 6（Command Line Tools 即可，不需要 Xcode）。

```bash
Scripts/build_app.sh          # → dist/Hushtype.app
Scripts/test.sh               # 单元测试
Scripts/package_dmg.sh        # → dist/Hushtype-<版本>.dmg
```

签名：设置 `HUSHTYPE_SIGN_IDENTITY="Developer ID Application: …"` 后构建，再运行
`Scripts/notarize.sh` 公证。没有 Developer ID 时，构建脚本会用本机的「Hushtype Local Dev」自签名证书
（权限在重新构建后保持有效），再没有就用临时签名。

## 目录

```
Sources/HushtypeCore/   引擎（无 UI，可单独嵌入其他产品）
  ASR/                SenseVoice（sherpa-onnx C API）、WhisperKit
  Rewrite/            提示词、Claude 调用、输出防护
  Engine/             识别 + 整理流水线；EngineHost 负责模型按需加载 / 释放
  System/             辅助功能：读取光标上下文、插入文字
  Storage/            设置、钥匙串、本地历史（SQLite）
  Models/             模型下载（固定版本 + SHA-256 校验）
Sources/Hushtype/       菜单栏 App：快捷键、HUD、引导、设置
Sources/hushtype-cli/   开发工具：transcribe / eval / install-models
server/               Hushtype Cloud 参考实现（Cloudflare Worker 代理）
docs/                 隐私说明
```

## 整理服务

三种来源，在设置里切换：
1. **自带 Anthropic API key**：存在钥匙串里，直连 api.anthropic.com。
2. **Hushtype Cloud / 自建代理**：用户不需要 key，见 `server/README.md`。
3. **离线**：不整理，只插入本地识别结果。

## 第三方组件

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Apache-2.0）与 SenseVoice 模型
- [WhisperKit](https://github.com/argmaxinc/WhisperKit)（MIT）与 whisperkit-coreml 模型
- 许可证随 App 放在 `Contents/Resources/Licenses/`
