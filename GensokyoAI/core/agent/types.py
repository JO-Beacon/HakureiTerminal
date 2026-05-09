"""统一类型系统 - 消除 ollama 类型耦合"""

# GensokyoAI/core/agent/types.py

import msgspec
import msgspec.json
from typing import Any, Sequence
from msgspec import Struct, field


class ToolCallFunction(Struct):
    """工具调用函数"""

    name: str = ""
    arguments: dict = field(default_factory=dict)
    provider: str = "openai"

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "arguments": (
                msgspec.json.encode(self.arguments).decode() 
                if self.provider in ("openai", "openai_responses", "deepseek")
                else self.arguments
            ),
        }


class ToolCall(Struct):
    """工具调用"""

    id: str = ""
    type: str = "function"
    provider: str = "openai"
    function: ToolCallFunction = field(default_factory=ToolCallFunction)

    def to_dict(self) -> dict:
        self.function.provider = self.provider
        return {"id": self.id, "type": self.type, "function": self.function.to_dict()}


class ImageInput(Struct):
    """统一视觉输入。"""

    url: str | None = None
    data: str | None = None
    mime_type: str | None = None
    detail: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class MessageContentPart(Struct):
    """统一多模态消息内容片段。"""

    type: str = "text"
    text: str | None = None
    image: ImageInput | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class UnifiedMessage(Struct):
    """
    统一消息类型 - 替代 ollama.Message

    所有 Provider 返回的消息都转换为此类型
    """

    role: str = "assistant"
    content: str | list[MessageContentPart] = ""
    tool_calls: list[ToolCall] | None = None
    reasoning_content: str | None = None


class WebSearchReference(Struct):
    """统一 Web search 引用信息。"""

    title: str = ""
    url: str = ""
    snippet: str | None = None
    source: str | None = None
    published_at: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class WebSearchDiagnostics(Struct):
    """统一 Web search 执行诊断信息。"""

    enabled: bool = False
    strategy: str = "off"
    provider: str = ""
    status: str = "disabled"
    query: str | None = None
    fallback_reason: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class UnifiedResponse(Struct):
    """
    统一响应类型 - 替代 ollama.ChatResponse

    所有 Provider 的非流式响应都转换为此类型
    """

    message: UnifiedMessage = field(default_factory=UnifiedMessage)
    model: str = ""
    done: bool = True
    thinking: str | None = None
    web_search_references: list[WebSearchReference] = field(default_factory=list)
    web_search_diagnostics: WebSearchDiagnostics | None = None


class ModelCallTiming(Struct):
    """模型调用耗时与推理阶段统计。"""

    context: str = ""
    provider: str = ""
    model: str = ""
    start_time: float = 0.0
    end_time: float | None = None
    duration_ms: float | None = None
    first_chunk_ms: float | None = None
    first_token_ms: float | None = None
    first_reasoning_ms: float | None = None
    reasoning_chunk_count: int = 0
    reasoning_char_count: int = 0
    content_chunk_count: int = 0
    content_char_count: int = 0
    message_count: int | None = None
    prompt_length: int | None = None
    embedding_dimension: int | None = None
    finish_reason: str | None = None
    usage: dict[str, Any] | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class GeneratedImage(Struct):
    """统一生成图片结果项。"""

    url: str | None = None
    data: str | None = None
    mime_type: str | None = None
    revised_prompt: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class ImageGenerationRequest(Struct):
    """统一图片生成请求。"""

    prompt: str
    model: str | None = None
    size: str | None = None
    quality: str | None = None
    style: str | None = None
    n: int = 1
    response_format: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class ImageGenerationResult(Struct):
    """统一图片生成响应。"""

    images: list[GeneratedImage] = field(default_factory=list)
    model: str = ""
    usage: dict[str, Any] | None = None
    timing: ModelCallTiming | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class UnifiedEmbeddingResponse(Struct):
    """
    统一 Embedding 响应类型 - 替代 ollama.EmbeddingsResponse
    """

    embedding: Sequence[float] = field(default_factory=list)
    model: str = ""


class ProviderCapability:
    """Provider 能力常量。"""

    CHAT = "chat"
    STREAM = "stream"
    TOOLS = "tools"
    EMBEDDINGS = "embeddings"
    VISION = "vision"
    REASONING = "reasoning"
    IMAGE = "image"
    IMAGE_GENERATION = "image_generation"
    IMAGE_EDIT = "image_edit"
    RESPONSES_API = "responses_api"
    CUSTOM_ENDPOINT = "custom_endpoint"
    WEB_SEARCH = "web_search"
    STRUCTURED_OUTPUT = "structured_output"


class ModelInfo(Struct):
    """模型元信息。"""

    id: str
    name: str = ""
    context_window: int | None = None
    capabilities: list[str] = field(default_factory=list)
    owned_by: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class StreamChunk(Struct):
    """
    流式响应块

    替代原来在 model_client.py 中定义的 StreamChunk
    """

    type: str = "text"
    content: str = ""
    reasoning_content: str | None = None
    is_tool_call: bool = False
    tool_info: dict | None = None
    status: str | None = None
    error: str | None = None
    error_code: str | None = None
    error_details: dict[str, Any] | None = None
    usage: dict[str, Any] | None = None
    finish_reason: str | None = None
    timing: ModelCallTiming | None = None
    web_search_references: list[WebSearchReference] = field(default_factory=list)
    web_search_diagnostics: WebSearchDiagnostics | None = None
