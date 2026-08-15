# Contributing to HakureiTerminal

感谢你考虑为 HakureiTerminal 提交反馈。本仓库只通过 GitHub Issue 接收问题报告、改进建议和需求讨论，不接受 Pull Request。

> 本文件不是法律意见。如反馈包含第三方素材、代码或其他受限制内容，请先确认你有权公开提交。

## 许可证与反馈范围

- 仓库根项目 HakureiTerminal 采用 Apache License 2.0，见 `LICENSE`。
- GensokyoAI `2026.8.8.0` 是独立部署的唯一执行、会话、消息和上下文权威；HakureiTerminal 仅是其专用网络前端。许可证说明见 `THIRD_PARTY_LICENSES.md`。
- 本仓库默认不接受 GensokyoAI 本体源码修改；相关贡献应提交到 GensokyoAI 上游项目。
- 不得通过依赖、生成脚本、Flutter/Android assets、安装器或构建步骤把 GensokyoAI 本体、角色、场景、配置、文档、品牌素材、Python runtime 或 bridge 预置到 HakureiTerminal 源码和默认分发包。允许提交的互操作代码只能依赖文档化的公开网络契约。
- 不得增加本地聊天运行时、直接文本模型 Provider 执行、本地权威会话/消息/上下文或断线执行 fallback。断线客户端只能管理配置、非可执行角色草稿和一次性展示缓存，不能聊天。独立 TTS Provider 只可用于明确触发的客户端媒体功能，不得成为文本生成 fallback。
- 角色草稿的编辑、导入、恢复和应用启动不得联网或上传。当前不接受角色上传实现；未来只有存在文档化公开网络 API，并提供明确目标连接和 payload 范围确认时才可设计。

## Issue 内容建议

提交 Issue 前，请尽量提供：

- 使用的平台和版本。
- 可复现的操作步骤、实际结果和预期结果。
- 复现后通过“设置 -> 数据管理 -> 日志管理 -> 导出诊断日志”生成的诊断 ZIP；公开前仍需检查其中的服务器地址和运行信息。
- 相关第三方来源或许可证信息（如适用）。
- 不要提交真实 API Key、Token、Cookie、密码、个人存档、私有服务地址或其他敏感数据；诊断导出已经过程序脱敏，但不能替代提交者的人工检查。

安全漏洞请按照 `SECURITY.md` 的私密报告流程处理，不要在公开 Issue 中披露可利用细节。
