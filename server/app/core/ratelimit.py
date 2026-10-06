"""内存滑动窗口限流（单进程部署足够；多实例时换 Redis 即可）。"""
from __future__ import annotations

import time
from collections import deque

from ..config import get_settings


class RateLimiter:
    def __init__(self, max_calls: int, window_seconds: float = 60.0) -> None:
        self.max_calls = max_calls
        self.window_seconds = window_seconds
        self._hits: dict[str, deque[float]] = {}

    def check(self, key: str) -> bool:
        """是否放行：False 表示超限（调用方自行抛 429）。"""
        now = time.monotonic()
        hits = self._hits.setdefault(key, deque())
        while hits and now - hits[0] > self.window_seconds:
            hits.popleft()
        if len(hits) >= self.max_calls:
            return False
        hits.append(now)
        return True


login_limiter = RateLimiter(max_calls=get_settings().login_rate_limit)
