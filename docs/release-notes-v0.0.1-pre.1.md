# HakureiTerminal v0.0.1-pre.1

HakureiTerminal 是 GensokyoAI Runtime 的专用 Flutter 前端。本预发布版本不包含本地聊天运行时。

## 兼容的 GensokyoAI Runtime

必须连接独立部署的：

- GensokyoAI Runtime `2026.8.8.0`
- Runtime 协议主版本 `2`

本版本不兼容 Runtime v1，也不接入 `world.*`。请先在客户端之外部署并启动 Runtime，再在 HakureiTerminal 中添加服务连接、测试连接并执行明确的连接操作。

中文使用指南：[docs/user-guide.md](https://github.com/JO-Beacon/HakureiTerminal/blob/main/docs/user-guide.md)

## 主要内容

- 移除内置 GensokyoAI、Python bridge 与本地聊天执行，改为连接独立部署的 GensokyoAI Runtime。
- 支持多 Runtime 连接档案、显式连接/切换及 Agent v2 会话与消息协议。
- 支持远程角色、会话、媒体、记忆、场景和主动定时器管理，不接入 `world.*`。
- 支持用户显式刷新 Provider 模型列表；客户端不直接调用 Provider 进行生成、Embedding、工具或上下文处理。
- 新会话标题支持固定标题、创建时间和首条用户消息标题。
- 提供 Windows x64 与 Android 通用 APK。

## 平台说明

- Windows 构建未提供代码签名，可能出现 SmartScreen 提示。
- Android APK 使用 Android Debug 证书，仅用于此 Pre-release 测试，不适合正式商店发布。

## 验证

- `flutter analyze` 通过。
- Flutter 完整测试 156 项通过。
- GitHub Runtime boundary 工作流通过。
- Windows ZIP 与 Android APK 的 Runtime 产物边界扫描通过。

## SHA-256

- Windows ZIP: `B97077ACDC3000CB86BB34555A0374212906E96B9939FA05A7AC625612CA5EBB`
- Android APK: `7FFAE6EB2001DCD9AAC749DA079B9F7B94A3F1346BF7B952E3E987AAE5D3E334`
