"""AI 配置密文存取（AES-256-GCM）。

用户的第三方 API Key 要落到云端数据库，明文落库等于把密钥托管风险转移到我们的数据库：
一旦数据库备份/导出泄漏，用户所有服务商 Key 一并暴露。
因此服务端只存密文（nonce + 密文 + GCM tag 的 base64 串），密钥只存在于环境变量。

密文格式：`v1:` + base64(nonce(12B) || ciphertext || tag(16B))
AAD 绑定 user_id：把 A 用户的密文搬到 B 用户行下也无法解密。
"""
from __future__ import annotations

import base64
import hashlib

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.config import get_settings

_PREFIX = "v1:"
_NONCE_BYTES = 12


def _load_key() -> bytes:
    """取 32 字节主密钥。

    优先用专用环境变量 AI_SETTINGS_KEY；未配置时从 JWT_SECRET 派生，
    保证开发/自部署场景开箱可用，但生产必须单独配置（否则改 JWT 密钥会连带解密失败）。
    """
    settings = get_settings()
    raw = settings.ai_settings_key.strip()
    if not raw:
        raw = settings.jwt_secret
    return hashlib.sha256(raw.encode("utf-8")).digest()


def encrypt_settings(plaintext: str, *, user_id: str) -> str:
    """加密明文；返回带版本前缀的 base64 密文。"""
    nonce = _random_bytes(_NONCE_BYTES)
    ct = AESGCM(_load_key()).encrypt(
        nonce, plaintext.encode("utf-8"), user_id.encode("utf-8")
    )
    return _PREFIX + base64.b64encode(nonce + ct).decode("ascii")


def decrypt_settings(ciphertext: str, *, user_id: str) -> str | None:
    """解密密文；密文被篡改/密钥不匹配/串用户时返回 None（不抛异常，避免打挂读路径）。"""
    if not ciphertext:
        return None
    body = ciphertext.strip()
    if not body.startswith(_PREFIX):
        return None
    try:
        blob = base64.b64decode(body[len(_PREFIX):], validate=True)
    except Exception:  # noqa: BLE001
        return None
    if len(blob) <= _NONCE_BYTES:
        return None
    try:
        plain = AESGCM(_load_key()).decrypt(
            blob[:_NONCE_BYTES], blob[_NONCE_BYTES:], user_id.encode("utf-8")
        )
    except InvalidTag:
        return None
    return plain.decode("utf-8")


def _random_bytes(n: int) -> bytes:
    import os

    return os.urandom(n)
