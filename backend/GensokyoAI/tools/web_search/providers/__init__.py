"""Web search Provider 包。"""

from .api import GenericAPISearchProvider
from .bing import BingSearchProvider

__all__ = ["BingSearchProvider", "GenericAPISearchProvider"]
