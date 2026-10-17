"""应用配置：全部经环境变量 / .env 注入。"""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # 数据库（测试用 sqlite+aiosqlite:///./test.db，生产用 postgresql+asyncpg://...）
    database_url: str = "postgresql+asyncpg://wendao:wendao@localhost:5432/wendao"

    # JWT
    jwt_secret: str = "change-me-in-prod"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60
    refresh_token_expire_days: int = 30

    # CORS（逗号分隔；cloudflared 隧道下的域名）
    cors_origins: str = "*"

    # 同步
    push_batch_limit: int = 500
    pull_page_limit: int = 500

    # 登录限流：同一 key 每分钟最大尝试次数
    login_rate_limit: int = 10

    # AI 配置云端加密主密钥（32 字节任意串，建议 openssl rand -hex 32）。
    # 留空时回退到从 jwt_secret 派生：开箱可用，但生产务必单独配置，
    # 否则日后轮换 JWT 密钥会导致历史 AI 配置无法解密。
    ai_settings_key: str = ""

    # 启动时自动建表（生产建议关闭，走 alembic）
    auto_create_tables: bool = True

    log_level: str = "INFO"

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
