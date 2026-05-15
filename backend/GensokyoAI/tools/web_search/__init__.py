"""自有 Web search 包。"""

from .service import WebSearchService
from .types import ProviderSearchResult, SearchItem, WebSearchResult

__all__ = ["ProviderSearchResult", "SearchItem", "WebSearchResult", "WebSearchService"]
