# SillyTavern 输入输出功能分析

## 报告范围

本文仅依据 SillyTavern 1.18.0 快照自带的 Markdown 文件，以及其 README 指向的官方文档整理。分析日期为 2026-07-19。本文描述产品能力和用户可观察行为，不涉及源码、内部模块、算法或实现方式。

## 整体模型

SillyTavern 将对话处理设计为一条可配置流程：

> 用户输入 -> 输入预处理 -> 上下文与提示词组装 -> 模型生成 -> 输出截断与解析 -> 显示、翻译或朗读

## 输入处理

- **输入正则**：用户发送消息后，可按规则查找、替换、删除或格式化文本。
- **输入翻译**：支持手动翻译当前输入，也可在发送前自动翻译成模型使用的语言。
- **空消息替换**：输入为空时，可发送预先配置的替代内容。
- **多模态附件**：消息可附加图片、视频或文档；文档可作为检索资料使用。
- **上下文可见性**：消息可以保留在聊天记录中，但排除在发送给模型的上下文之外。
- **输入辅助**：支持语音识别、快捷命令和让 AI 代写用户消息。

## 提示词与上下文编排

### 基础提示词

- **Main/System Prompt**：位于上下文前部，定义模型身份、任务、语气和总体规则。
- **Post-History Instructions**：位于聊天历史之后，是生成前最后收到的指令，通常比前部提示词影响更直接。
- **自定义提示词**：可指定为 System、User 或 Assistant 角色，并可启用、停用和调整顺序。
- **条件触发**：提示词可仅在普通回复、继续、重新生成、Swipe、用户代写或后台生成时发送。
- **历史内插入**：提示词既可按整体顺序排列，也可插入聊天历史的指定深度。

### 动态上下文来源

- **角色卡与 Persona**：角色描述、性格、场景、用户身份和示例对话均可加入请求。
- **Author's Note**：用于临时强化写作要求或当前状态，可设置插入位置、历史深度和生效频率。
- **World Info/Lorebook**：根据关键词、正则、固定规则或向量相似度动态注入资料；支持优先级、概率、预算、递归、角色过滤和多种插入位置。
- **自动摘要**：定期总结较早的聊天内容，允许人工修改、暂停或回退，再将摘要注入后续请求。
- **Data Bank/RAG**：从记事本、文件、网页等资料中检索相关内容并加入上下文。
- **宏系统**：在提示词中引用角色名、用户名称、当前输入、最近消息、摘要、日期时间和运行状态；还提供条件、随机选择及变量能力。

### 模型格式适配

Chat Completion 模型使用按角色和顺序组织的 Prompt Manager。Text Completion 模型则可配置 Story String、示例分隔符、聊天起始标记、角色名称，以及 User、Assistant、System 消息的前后缀。系统还可对消息做兼容性整理，例如合并相同角色、限制为单个系统消息、要求用户消息开场，或合并成单条用户消息。

## 输出控制与后处理

- **回复预填充**：在模型生成前指定回答的开头，引导输出格式或内容方向。
- **停止字符串**：模型生成指定文本时结束输出，并可从最终回复中移除停止标记。
- **Continue**：继续扩写最后一条回复，并可配置继续指令、预填内容和拼接字符。
- **输出正则**：对 AI 回复进行替换、删除、提取或 Markdown 样式处理。
- **推理内容分离**：将 reasoning/thinking 内容作为独立折叠区块展示、编辑或隐藏，并决定是否在后续请求中再次发送。
- **翻译与朗读**：AI 回复可自动翻译成目标语言，也可按角色映射语音进行 TTS 朗读。
- **候选与修订**：支持 Swipe 获取其他回复、重新生成、继续、编辑、复制、删除、创建分支或检查点。
- **生成检查**：可以查看某条回复对应的最终提示词、token 使用量，以及部分后端提供的候选 token 概率。

## 正则规则的产品能力

正则规则支持全局范围和角色专用范围，可排序、启停、导入、导出，并提供实时输入/输出测试。规则可配置查找表达式、替换文本、捕获组、裁剪内容、消息深度、宏替换方式以及是否在编辑消息后重新运行。

规则可以分别作用于用户输入、AI 回复、命令产生的文本、World Info 和推理内容。处理结果还有三种可见性策略：永久修改聊天记录；只改变界面显示；只改变发送给模型的内容。后两种策略允许用户看到的文本与模型收到的文本不同。

## 适合独立实现的小功能

优先级较高且边界清晰的功能包括：

1. Main/System Prompt 与 Post-History Instructions。
2. 单条消息是否纳入模型上下文。
3. 回复预填充与自定义停止字符串。
4. 输入和输出正则，以及规则实时测试。
5. 可设置位置、深度和频率的 Author's Note。
6. 最终 Prompt 预览与 token 统计。
7. 输入/回复自动翻译与 Continue 操作。

World Info、宏系统、RAG 和自动摘要价值更高，但属于相对独立的大型功能模块，适合后续分阶段加入。

## 文档来源

- [Prompts](https://docs.sillytavern.app/usage/prompts/)
- [Prompt Manager](https://docs.sillytavern.app/usage/prompts/prompt-manager/)
- [Advanced Formatting](https://docs.sillytavern.app/usage/core-concepts/advancedformatting/)
- [Regex](https://docs.sillytavern.app/extensions/regex/)
- [Author's Note](https://docs.sillytavern.app/usage/core-concepts/authors-note/)
- [World Info](https://docs.sillytavern.app/usage/core-concepts/worldinfo/)
- [Summarize](https://docs.sillytavern.app/extensions/summarize/)
- [Chat Translation](https://docs.sillytavern.app/extensions/translation/)
- [Reasoning](https://docs.sillytavern.app/usage/prompts/reasoning/)
- [Chatting](https://docs.sillytavern.app/usage/chatting/)
