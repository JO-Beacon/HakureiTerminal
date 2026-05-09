"""配置管理"""

# GensokyoAI\core\config.py

import os
from pathlib import Path
from typing import Any, Literal
from msgspec import Struct, field
from enum import Enum
import yaml

from ..utils.logger import setup_logging


class LogLevel(Enum):
    DEBUG = "DEBUG"
    INFO = "INFO"
    WARNING = "WARNING"
    ERROR = "ERROR"


class AuthConfig(Struct):
    """模型 Provider 认证配置。"""

    auth_type: str | None = None
    token_url: str | None = None
    client_id: str | None = None
    client_secret: str | None = None
    scope: str | None = None
    refresh_token: str | None = None
    access_token: str | None = None
    expires_at: float | None = None
    refresh_before_seconds: int = 60
    auth_headers: dict[str, str] = field(default_factory=dict)
    auth_body: dict[str, str] = field(default_factory=dict)
    token_field: str = "access_token"
    expires_in_field: str = "expires_in"
    allow_401_refresh: bool = True


class ModelConfig(Struct):
    """模型配置"""

    provider: str = "ollama"  # LLM Provider: ollama / openai / openrouter / deepseek / gemini / claude
    name: str = "qwen3.5:9b"
    base_url: str | None = None
    api_path: str | None = None
    api_key: str | None = None  # API 密钥（OpenAI/Gemini/Claude 等需要）
    extra_headers: dict[str, str] = field(default_factory=dict)
    auth: AuthConfig | None = None
    model_capabilities_add: list[str] = field(default_factory=list)
    model_capabilities_remove: list[str] = field(default_factory=list)
    web_search_enabled: bool = False
    web_search_strategy: Literal["off", "explicit", "auto"] = "off"
    web_search_context_size: str | None = None
    web_search_user_location: dict[str, Any] = field(default_factory=dict)
    web_search_allow_fallback: bool = True
    web_search_metadata: dict[str, Any] = field(default_factory=dict)
    stream: bool = True
    think: bool = False
    thinking_enabled: bool | None = None
    reasoning_effort: str | None = None
    temperature: float = 0.7
    top_p: float = 0.9
    max_tokens: int = 2048
    timeout: int = 60
    use_proxy: bool = False  # 是否使用代理
    retry_max_attempts: int = 3
    retry_initial_delay: float = 1.0
    retry_backoff_factor: float = 2.0
    retry_status_codes: list[int] = field(default_factory=lambda: [500, 502, 503, 504])


class EmbeddingConfig(Struct):
    """Embedding 模型配置"""

    provider: str | None = None  # 默认复用 model.provider
    name: str | None = None  # 必填；未配置时不再误用聊天模型
    base_url: str | None = None
    api_key: str | None = None
    dimensions: int | None = None
    encoding_format: str | None = None
    timeout: int | None = None
    use_proxy: bool | None = None


class TopicGenerationConfig(Struct):
    """话题生成配置"""

    name_max_length: int = 10
    summary_max_length: int = 100


class MemoryConfig(Struct):
    """记忆配置"""

    working_max_turns: int = 20
    episodic_threshold: int = 50
    episodic_summary_model: str = "qwen3.5:9b"
    episodic_keep_recent: int = 10
    semantic_enabled: bool = True
    semantic_top_k: int = 5
    semantic_similarity_threshold: float = 0.7
    auto_memory_enabled: bool = True
    auto_memory_model: str = "qwen3.5:9b"

    topic_generation: TopicGenerationConfig = field(default_factory=TopicGenerationConfig)


class ThinkEngineConfig(Struct):
    """思考引擎配置"""

    enabled: bool = True  # 是否启用静默思考
    think_interval_minutes: int = 5  # 思考间隔（分钟）
    random_walk_steps_min: int = 2  # 随机游走最少步数
    random_walk_steps_max: int = 5  # 随机游走最多步数
    emotional_trigger_threshold: float = 0.5  # 优先选择高情感话题的阈值
    emotional_priority_probability: float = 0.7  # 优先选择高情感话题的概率
    think_temperature: float = 0.7  # 思考时的温度
    think_max_tokens: int = 200  # 思考最大 token 数
    initiative_temperature: float = 0.8  # 生成主动消息时的温度
    initiative_max_tokens: int = 100  # 生成主动消息最大 token 数


class WebSearchAPIConfig(Struct):
    """自有 Web search API Provider 配置。"""

    endpoint: str | None = None
    method: str = "POST"
    api_key: str | None = None
    api_key_header: str = "Authorization"
    api_key_prefix: str = "Bearer "
    headers: dict[str, str] = field(default_factory=dict)
    request_template: dict[str, Any] = field(default_factory=lambda: {"query": "{query}", "count": "{max_results}"})
    query_params: dict[str, Any] = field(default_factory=dict)
    results_path: str = "results"
    title_path: str = "title"
    url_path: str = "url"
    snippet_path: str = "content"
    published_at_path: str | None = None


class WebSearchToolConfig(Struct):
    """自有 Web search 工具配置。"""

    enabled: bool = False
    provider: str = "bing"  # bing / api / mixed
    max_results: int = 10
    timeout: int = 10
    cache_ttl_seconds: int = 300
    trigger_strategy: Literal["off", "explicit", "auto"] = "explicit"
    freshness_keywords: list[str] = field(
        default_factory=lambda: [
            "今天",
            "今日",
            "现在",
            "当前",
            "最新",
            "新闻",
            "价格",
            "版本",
            "发布",
            "更新",
            "today",
            "latest",
            "news",
            "price",
            "version",
        ]
    )
    prefer_for_characters: list[str] = field(default_factory=list)
    prefer_for_scenarios: list[str] = field(default_factory=list)
    user_agent: str = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    )
    region: str | None = None
    safe_search: str = "moderate"
    snippet_max_length: int = 200
    api: WebSearchAPIConfig = field(default_factory=WebSearchAPIConfig)


class ToolConfig(Struct):
    """工具配置"""

    enabled: bool = True
    builtin_tools: list[str] = field(default_factory=lambda: ["time", "moon", "memory", "system"])
    custom_tools_path: Path | None = None
    web_search: WebSearchToolConfig = field(default_factory=WebSearchToolConfig)


class SessionConfig(Struct):
    """会话配置"""

    auto_save: bool = True
    save_path: Path = field(default_factory=lambda: Path("./sessions"))
    max_sessions: int = 100

    def __post_init__(self):
        # 强制转换为 Path 对象
        if not isinstance(self.save_path, Path):
            object.__setattr__(self, "save_path", Path(self.save_path))


class CharacterConfig(Struct):
    """角色配置"""

    name: str
    system_prompt: str
    greeting: str = ""
    example_dialogue: list[dict[str, str]] | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


class AppConfig(Struct):
    """应用配置"""

    # 日志配置
    log_level: LogLevel = LogLevel.INFO
    log_console: bool = True
    log_file: Path | None = None

    # 调试配置：开启后才输出静默思考、内心决策、推理内容等默认隐藏信息
    debug_silent_output: bool = False

    # 子配置
    model: ModelConfig = field(default_factory=ModelConfig)
    embedding: EmbeddingConfig = field(default_factory=EmbeddingConfig)
    memory: MemoryConfig = field(default_factory=MemoryConfig)
    tool: ToolConfig = field(default_factory=ToolConfig)
    session: SessionConfig = field(default_factory=SessionConfig)
    think_engine: ThinkEngineConfig = field(default_factory=ThinkEngineConfig)

    # 角色
    character: CharacterConfig | None = None
    character_file: Path | None = None

    def __post_init__(self):
        # 确保保存路径存在
        if self.session.save_path:
            self.session.save_path.mkdir(parents=True, exist_ok=True)

        # 应用日志配置
        self._apply_logging_config()

    def _apply_logging_config(self) -> None:
        """应用日志配置"""
        setup_logging(
            log_level=self.log_level.value,
            log_console=self.log_console,
            log_file=self.log_file,
        )


class ConfigLoader:
    """配置加载器"""

    def __init__(self):
        self._config: AppConfig | None = None
        self._provided_fields: dict[int, set[str]] = {}

    def load(self, config_file: Path | None = None) -> AppConfig:
        """加载配置"""
        config = AppConfig()

        # 1. 加载默认配置
        default_file = Path(__file__).parent.parent.parent / "config" / "default.yaml"
        if default_file.exists():
            config = self._load_yaml(default_file)

        # 2. 加载用户配置文件
        if config_file and config_file.exists():
            user_config = self._load_yaml(config_file)
            config = self._merge(config, user_config)

        # 3. 环境变量覆盖
        config = self._apply_env(config)

        # 4. 重新应用日志配置（确保使用最终配置）
        config._apply_logging_config()

        self._config = config
        return config

    def _load_yaml(self, path: Path) -> AppConfig:
        """从 YAML 加载配置"""
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        return self._dict_to_config(data)

    def _dict_to_config(self, data: dict[str, Any]) -> AppConfig:
        """字典转配置对象，并记录用户显式提供的字段。"""
        config = AppConfig()

        if "log_level" in data:
            config.log_level = LogLevel(data["log_level"])
        if "log_console" in data:
            config.log_console = data["log_console"]
        if "log_file" in data and data["log_file"]:
            config.log_file = Path(data["log_file"])
        if "debug_silent_output" in data:
            config.debug_silent_output = bool(data["debug_silent_output"])

        if "model" in data:
            model_data = data["model"] or {}
            config.model = ModelConfig(**model_data)
            self._provided_fields[id(config.model)] = set(model_data.keys())
        if "embedding" in data:
            config.embedding = EmbeddingConfig(**data["embedding"])
        if "memory" in data:
            config.memory = MemoryConfig(**data["memory"])
        if "tool" in data:
            tool_data = data["tool"] or {}
            config.tool = self._dict_to_tool_config(tool_data)
        if "session" in data:
            config.session = SessionConfig(**data["session"])

        if "think_engine" in data:
            config.think_engine = ThinkEngineConfig(**data["think_engine"])

        return config

    def _merge(self, base: AppConfig, override: AppConfig) -> AppConfig:
        """合并配置 - override 优先"""
        result = AppConfig()

        # 日志配置 - override 优先
        result.log_level = (
            override.log_level if override.log_level != LogLevel.INFO else base.log_level
        )
        result.log_console = override.log_console
        result.log_file = override.log_file or base.log_file
        result.debug_silent_output = override.debug_silent_output or base.debug_silent_output

        # 其他配置 - override 优先
        result.model = self._merge_model(base.model, override.model)
        result.embedding = self._merge_embedding(base.embedding, override.embedding)
        result.memory = self._merge_memory(base.memory, override.memory)
        result.tool = self._merge_tool(base.tool, override.tool)
        result.session = self._merge_session(base.session, override.session)
        result.think_engine = self._merge_think_engine(base.think_engine, override.think_engine)
        result.character = override.character or base.character
        result.character_file = override.character_file or base.character_file

        return result

    def _merge_model(self, base: ModelConfig, override: ModelConfig) -> ModelConfig:
        """合并模型配置 - override 优先。

        从 YAML 加载的配置会保留字段出现信息，避免用默认值猜测用户是否有意覆盖；
        对直接构造的 ModelConfig 仍保留旧的默认值回退策略以兼容现有调用。
        """
        provided = self._provided_fields.get(id(override))

        def choose(field_name: str, legacy_value: Any) -> Any:
            if provided is not None:
                return getattr(override, field_name) if field_name in provided else getattr(base, field_name)
            return legacy_value

        return ModelConfig(
            provider=choose("provider", override.provider if override.provider != "ollama" else base.provider),
            name=choose("name", override.name if override.name != "qwen3.5:9b" else base.name),
            base_url=choose("base_url", override.base_url or base.base_url),
            api_path=choose("api_path", override.api_path or base.api_path),
            api_key=choose("api_key", override.api_key or base.api_key),
            extra_headers=choose("extra_headers", override.extra_headers or base.extra_headers),
            auth=choose("auth", override.auth or base.auth),
            model_capabilities_add=choose(
                "model_capabilities_add",
                override.model_capabilities_add or base.model_capabilities_add,
            ),
            model_capabilities_remove=choose(
                "model_capabilities_remove",
                override.model_capabilities_remove or base.model_capabilities_remove,
            ),
            web_search_enabled=choose("web_search_enabled", override.web_search_enabled),
            web_search_strategy=choose("web_search_strategy", override.web_search_strategy),
            web_search_context_size=choose(
                "web_search_context_size",
                override.web_search_context_size or base.web_search_context_size,
            ),
            web_search_user_location=choose(
                "web_search_user_location",
                override.web_search_user_location or base.web_search_user_location,
            ),
            web_search_allow_fallback=choose("web_search_allow_fallback", override.web_search_allow_fallback),
            web_search_metadata=choose(
                "web_search_metadata",
                override.web_search_metadata or base.web_search_metadata,
            ),
            stream=choose("stream", override.stream),
            think=choose("think", override.think),
            thinking_enabled=choose(
                "thinking_enabled",
                override.thinking_enabled
                if override.thinking_enabled is not None
                else base.thinking_enabled,
            ),
            reasoning_effort=choose("reasoning_effort", override.reasoning_effort or base.reasoning_effort),
            temperature=choose(
                "temperature",
                override.temperature if override.temperature != 0.7 else base.temperature,
            ),
            top_p=choose("top_p", override.top_p if override.top_p != 0.9 else base.top_p),
            max_tokens=choose(
                "max_tokens",
                override.max_tokens if override.max_tokens != 2048 else base.max_tokens,
            ),
            timeout=choose("timeout", override.timeout if override.timeout != 60 else base.timeout),
            use_proxy=choose(
                "use_proxy",
                override.use_proxy if override.use_proxy != base.use_proxy else base.use_proxy,
            ),
            retry_max_attempts=choose(
                "retry_max_attempts",
                override.retry_max_attempts if override.retry_max_attempts != 3 else base.retry_max_attempts,
            ),
            retry_initial_delay=choose(
                "retry_initial_delay",
                override.retry_initial_delay
                if override.retry_initial_delay != 1.0
                else base.retry_initial_delay,
            ),
            retry_backoff_factor=choose(
                "retry_backoff_factor",
                override.retry_backoff_factor
                if override.retry_backoff_factor != 2.0
                else base.retry_backoff_factor,
            ),
            retry_status_codes=choose(
                "retry_status_codes",
                override.retry_status_codes or base.retry_status_codes,
            ),
        )

    def _merge_embedding(self, base: EmbeddingConfig, override: EmbeddingConfig) -> EmbeddingConfig:
        """合并 Embedding 配置 - override 优先"""
        return EmbeddingConfig(
            provider=override.provider or base.provider,
            name=override.name or base.name,
            base_url=override.base_url or base.base_url,
            api_key=override.api_key or base.api_key,
            dimensions=override.dimensions or base.dimensions,
            encoding_format=override.encoding_format or base.encoding_format,
            timeout=override.timeout or base.timeout,
            use_proxy=override.use_proxy if override.use_proxy is not None else base.use_proxy,
        )

    def _merge_memory(self, base: MemoryConfig, override: MemoryConfig) -> MemoryConfig:
        """合并记忆配置 - override 优先"""
        return MemoryConfig(
            working_max_turns=override.working_max_turns
            if override.working_max_turns != 20
            else base.working_max_turns,
            episodic_threshold=override.episodic_threshold
            if override.episodic_threshold != 50
            else base.episodic_threshold,
            episodic_summary_model=override.episodic_summary_model
            if override.episodic_summary_model != "qwen3.5:9b"
            else base.episodic_summary_model,
            episodic_keep_recent=override.episodic_keep_recent
            if override.episodic_keep_recent != 10
            else base.episodic_keep_recent,
            semantic_enabled=override.semantic_enabled,
            semantic_top_k=override.semantic_top_k
            if override.semantic_top_k != 5
            else base.semantic_top_k,
            semantic_similarity_threshold=override.semantic_similarity_threshold
            if override.semantic_similarity_threshold != 0.7
            else base.semantic_similarity_threshold,
            auto_memory_enabled=override.auto_memory_enabled,
            auto_memory_model=override.auto_memory_model
            if override.auto_memory_model != "qwen3.5:9b"
            else base.auto_memory_model,
        )

    def _dict_to_tool_config(self, data: dict[str, Any]) -> ToolConfig:
        """字典转工具配置，处理嵌套 Web search 配置。"""
        tool_data = dict(data)
        web_search_data = tool_data.pop("web_search", None)
        if isinstance(web_search_data, dict):
            api_data = web_search_data.pop("api", None)
            web_search_config = WebSearchToolConfig(**web_search_data)
            if isinstance(api_data, dict):
                web_search_config.api = WebSearchAPIConfig(**api_data)
            tool_data["web_search"] = web_search_config
        return ToolConfig(**tool_data)

    def _merge_web_search_api(
        self,
        base: WebSearchAPIConfig,
        override: WebSearchAPIConfig,
    ) -> WebSearchAPIConfig:
        """合并 Web search API Provider 配置。"""
        return WebSearchAPIConfig(
            endpoint=override.endpoint or base.endpoint,
            method=override.method if override.method != "POST" else base.method,
            api_key=override.api_key or base.api_key,
            api_key_header=override.api_key_header
            if override.api_key_header != "Authorization"
            else base.api_key_header,
            api_key_prefix=override.api_key_prefix if override.api_key_prefix != "Bearer " else base.api_key_prefix,
            headers=override.headers or base.headers,
            request_template=override.request_template or base.request_template,
            query_params=override.query_params or base.query_params,
            results_path=override.results_path if override.results_path != "results" else base.results_path,
            title_path=override.title_path if override.title_path != "title" else base.title_path,
            url_path=override.url_path if override.url_path != "url" else base.url_path,
            snippet_path=override.snippet_path if override.snippet_path != "content" else base.snippet_path,
            published_at_path=override.published_at_path or base.published_at_path,
        )

    def _merge_web_search_tool(
        self,
        base: WebSearchToolConfig,
        override: WebSearchToolConfig,
    ) -> WebSearchToolConfig:
        """合并自有 Web search 工具配置。"""
        return WebSearchToolConfig(
            enabled=override.enabled if override.enabled != base.enabled else base.enabled,
            provider=override.provider if override.provider != "bing" else base.provider,
            max_results=override.max_results if override.max_results != 10 else base.max_results,
            timeout=override.timeout if override.timeout != 10 else base.timeout,
            cache_ttl_seconds=override.cache_ttl_seconds
            if override.cache_ttl_seconds != 300
            else base.cache_ttl_seconds,
            user_agent=override.user_agent if override.user_agent != WebSearchToolConfig().user_agent else base.user_agent,
            trigger_strategy=override.trigger_strategy
            if override.trigger_strategy != "explicit"
            else base.trigger_strategy,
            freshness_keywords=override.freshness_keywords or base.freshness_keywords,
            prefer_for_characters=override.prefer_for_characters or base.prefer_for_characters,
            prefer_for_scenarios=override.prefer_for_scenarios or base.prefer_for_scenarios,
            region=override.region or base.region,
            safe_search=override.safe_search if override.safe_search != "moderate" else base.safe_search,
            snippet_max_length=override.snippet_max_length
            if override.snippet_max_length != 200
            else base.snippet_max_length,
            api=self._merge_web_search_api(base.api, override.api),
        )

    def _merge_tool(self, base: ToolConfig, override: ToolConfig) -> ToolConfig:
        """合并工具配置 - 修复覆盖逻辑"""
        return ToolConfig(
            enabled=override.enabled if override.enabled != base.enabled else base.enabled,
            builtin_tools=override.builtin_tools
            if override.builtin_tools != base.builtin_tools
            else base.builtin_tools,
            custom_tools_path=override.custom_tools_path or base.custom_tools_path,
            web_search=self._merge_web_search_tool(base.web_search, override.web_search),
        )

    def _merge_session(self, base: SessionConfig, override: SessionConfig) -> SessionConfig:
        """合并会话配置 - 修复覆盖逻辑"""
        default_path = Path("./sessions")
        return SessionConfig(
            auto_save=override.auto_save
            if override.auto_save != base.auto_save
            else base.auto_save,
            save_path=override.save_path if override.save_path != default_path else base.save_path,
            max_sessions=override.max_sessions
            if override.max_sessions != 100
            else base.max_sessions,
        )

    def _merge_think_engine(
        self, base: ThinkEngineConfig, override: ThinkEngineConfig
    ) -> ThinkEngineConfig:
        """合并思考引擎配置"""
        return ThinkEngineConfig(
            enabled=override.enabled if override.enabled != base.enabled else base.enabled,
            think_interval_minutes=override.think_interval_minutes
            if override.think_interval_minutes != 5
            else base.think_interval_minutes,
            random_walk_steps_min=override.random_walk_steps_min
            if override.random_walk_steps_min != 2
            else base.random_walk_steps_min,
            random_walk_steps_max=override.random_walk_steps_max
            if override.random_walk_steps_max != 5
            else base.random_walk_steps_max,
            emotional_trigger_threshold=override.emotional_trigger_threshold
            if override.emotional_trigger_threshold != 0.5
            else base.emotional_trigger_threshold,
            emotional_priority_probability=override.emotional_priority_probability
            if override.emotional_priority_probability != 0.7
            else base.emotional_priority_probability,
            think_temperature=override.think_temperature
            if override.think_temperature != 0.7
            else base.think_temperature,
            think_max_tokens=override.think_max_tokens
            if override.think_max_tokens != 200
            else base.think_max_tokens,
            initiative_temperature=override.initiative_temperature
            if override.initiative_temperature != 0.8
            else base.initiative_temperature,
            initiative_max_tokens=override.initiative_max_tokens
            if override.initiative_max_tokens != 100
            else base.initiative_max_tokens,
        )

    def _apply_env(self, config: AppConfig) -> AppConfig:
        """应用环境变量"""
        if os.getenv("GENSOKYOAI_PROVIDER"):
            config.model.provider = os.getenv("GENSOKYOAI_PROVIDER")  # type: ignore
        if os.getenv("GENSOKYOAI_MODEL"):
            config.model.name = os.getenv("GENSOKYOAI_MODEL")  # type: ignore
        if os.getenv("GENSOKYOAI_API_KEY"):
            config.model.api_key = os.getenv("GENSOKYOAI_API_KEY")  # type: ignore
        if os.getenv("GENSOKYOAI_BASE_URL"):
            config.model.base_url = os.getenv("GENSOKYOAI_BASE_URL")  # type: ignore
        if os.getenv("GENSOKYOAI_API_PATH"):
            config.model.api_path = os.getenv("GENSOKYOAI_API_PATH")  # type: ignore
        if os.getenv("GENSOKYOAI_AUTH_TYPE"):
            config.model.auth = config.model.auth or AuthConfig()
            config.model.auth.auth_type = os.getenv("GENSOKYOAI_AUTH_TYPE")  # type: ignore
        if os.getenv("GENSOKYOAI_TOKEN_URL"):
            config.model.auth = config.model.auth or AuthConfig()
            config.model.auth.token_url = os.getenv("GENSOKYOAI_TOKEN_URL")  # type: ignore
        if os.getenv("GENSOKYOAI_ACCESS_TOKEN"):
            config.model.auth = config.model.auth or AuthConfig()
            config.model.auth.access_token = os.getenv("GENSOKYOAI_ACCESS_TOKEN")  # type: ignore
        if os.getenv("GENSOKYOAI_REFRESH_TOKEN"):
            config.model.auth = config.model.auth or AuthConfig()
            config.model.auth.refresh_token = os.getenv("GENSOKYOAI_REFRESH_TOKEN")  # type: ignore
        if os.getenv("GENSOKYOAI_CLIENT_ID"):
            config.model.auth = config.model.auth or AuthConfig()
            config.model.auth.client_id = os.getenv("GENSOKYOAI_CLIENT_ID")  # type: ignore
        if os.getenv("GENSOKYOAI_CLIENT_SECRET"):
            config.model.auth = config.model.auth or AuthConfig()
            config.model.auth.client_secret = os.getenv("GENSOKYOAI_CLIENT_SECRET")  # type: ignore
        if os.getenv("GENSOKYOAI_RETRY_MAX_ATTEMPTS"):
            config.model.retry_max_attempts = int(os.getenv("GENSOKYOAI_RETRY_MAX_ATTEMPTS"))  # type: ignore
        if os.getenv("GENSOKYOAI_RETRY_INITIAL_DELAY"):
            config.model.retry_initial_delay = float(os.getenv("GENSOKYOAI_RETRY_INITIAL_DELAY"))  # type: ignore
        if os.getenv("GENSOKYOAI_RETRY_BACKOFF_FACTOR"):
            config.model.retry_backoff_factor = float(os.getenv("GENSOKYOAI_RETRY_BACKOFF_FACTOR"))  # type: ignore
        if os.getenv("GENSOKYOAI_RETRY_STATUS_CODES"):
            config.model.retry_status_codes = [
                int(code.strip())
                for code in os.getenv("GENSOKYOAI_RETRY_STATUS_CODES", "").split(",")
                if code.strip()
            ]  # type: ignore
        if os.getenv("GENSOKYOAI_THINKING_ENABLED"):
            config.model.thinking_enabled = os.getenv("GENSOKYOAI_THINKING_ENABLED").lower() == "true"  # type: ignore
        if os.getenv("GENSOKYOAI_REASONING_EFFORT"):
            config.model.reasoning_effort = os.getenv("GENSOKYOAI_REASONING_EFFORT")  # type: ignore
        if os.getenv("GENSOKYOAI_EMBEDDING_PROVIDER"):
            config.embedding.provider = os.getenv("GENSOKYOAI_EMBEDDING_PROVIDER")  # type: ignore
        if os.getenv("GENSOKYOAI_EMBEDDING_MODEL"):
            config.embedding.name = os.getenv("GENSOKYOAI_EMBEDDING_MODEL")  # type: ignore
        if os.getenv("GENSOKYOAI_EMBEDDING_API_KEY"):
            config.embedding.api_key = os.getenv("GENSOKYOAI_EMBEDDING_API_KEY")  # type: ignore
        if os.getenv("GENSOKYOAI_EMBEDDING_BASE_URL"):
            config.embedding.base_url = os.getenv("GENSOKYOAI_EMBEDDING_BASE_URL")  # type: ignore
        if os.getenv("GENSOKYOAI_EMBEDDING_DIMENSIONS"):
            config.embedding.dimensions = int(os.getenv("GENSOKYOAI_EMBEDDING_DIMENSIONS"))  # type: ignore
        if os.getenv("GENSOKYOAI_EMBEDDING_ENCODING_FORMAT"):
            config.embedding.encoding_format = os.getenv("GENSOKYOAI_EMBEDDING_ENCODING_FORMAT")  # type: ignore
        if os.getenv("GENSOKYOAI_EMBEDDING_TIMEOUT"):
            config.embedding.timeout = int(os.getenv("GENSOKYOAI_EMBEDDING_TIMEOUT"))  # type: ignore
        if os.getenv("GENSOKYOAI_EMBEDDING_USE_PROXY"):
            config.embedding.use_proxy = (
                os.getenv("GENSOKYOAI_EMBEDDING_USE_PROXY").lower() == "true"
            )  # type: ignore
        if os.getenv("GENSOKYOAI_LOG_LEVEL"):
            config.log_level = LogLevel(os.getenv("GENSOKYOAI_LOG_LEVEL"))
        if os.getenv("GENSOKYOAI_LOG_CONSOLE"):
            config.log_console = os.getenv("GENSOKYOAI_LOG_CONSOLE").lower() == "true"  # type: ignore
        if os.getenv("GENSOKYOAI_DEBUG_SILENT_OUTPUT"):
            config.debug_silent_output = (
                os.getenv("GENSOKYOAI_DEBUG_SILENT_OUTPUT").lower() == "true"
            )  # type: ignore
        if os.getenv("GENSOKYOAI_MEMORY_WORKING_TURNS"):
            config.memory.working_max_turns = int(
                os.getenv("GENSOKYOAI_MEMORY_WORKING_TURNS")  # type: ignore
            )
        return config

    def load_character(self, path: Path) -> CharacterConfig:
        """加载角色配置"""
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        return CharacterConfig(
            name=data["name"],
            system_prompt=data["system_prompt"],
            greeting=data.get("greeting", ""),
            example_dialogue=data.get("example_dialogue"),
            metadata=data.get("metadata", {}),
        )
