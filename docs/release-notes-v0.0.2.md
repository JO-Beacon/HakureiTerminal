# HakureiTerminal v0.0.2

HakureiTerminal 是独立部署的 GensokyoAI Runtime 的专用 Flutter 前端。本版本不包含本地聊天运行时，也不直接调用文本模型 Provider 执行生成、Embedding、工具或上下文处理。

## 兼容的 GensokyoAI Runtime

必须连接独立部署的：

- GensokyoAI Runtime `2026.8.8.0`
- Runtime 协议主版本 `2`

客户端不兼容 Runtime v1。请先在客户端之外部署并启动 Runtime，再在 HakureiTerminal 中添加连接、测试连接并执行明确的连接操作。

中文使用指南：[docs/user-guide.md](https://github.com/JO-Beacon/HakureiTerminal/blob/main/docs/user-guide.md)

## 主要内容

- 支持 GensokyoAI Agent v2 的远程角色、会话、分页历史、流式消息、图片、记忆、场景、主动定时器和可恢复事件。
- 支持 GensokyoWorld 能力探测及 World 状态、花名册、共享剧本和存档列表的只读显示。
- 支持 Markdown 消息渲染、代码块复制和独立 TTS Provider 消息朗读。
- 支持用户明确刷新文本模型 Provider 的模型列表，以及把选定模型档案明确委托给目标 Runtime。
- 新增自动轮转的结构化 JSON Lines 日志、敏感信息脱敏、日志清理和诊断 ZIP 导出。
- Runtime 连接表单明确区分 HTTP/HTTPS 根地址与自动派生的 WebSocket 地址，并为 `ws://`、`wss://` 错填提供行内提示。

## 平台说明

- Windows x64 ZIP 未提供代码签名，Windows 可能显示 SmartScreen 提示。
- Android arm64-v8a APK 使用 Android Debug 证书，可直接安装，但不是应用商店签名包。

## 验证

- `flutter analyze` 通过。
- Flutter 完整测试 171 项通过。
- Runtime boundary 源码扫描与扫描器测试通过。
- Windows ZIP 与 Android APK 的 Runtime 产物边界扫描通过。

## SHA-256

- Windows ZIP: `0AF3395B4918349CECA976F1A8392563D6109F8D087AB25C9112AA42CE21BC5D`
- Android APK: `947ACD288EBBD18D950B80A0DBB48C777217FB339A20A874F704D25FAA06B366`
