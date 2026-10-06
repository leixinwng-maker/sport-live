"""统一错误响应：{code, message, detail}。"""
from __future__ import annotations

from typing import Any, Optional

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


class AppError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        status_code: int = 400,
        detail: Optional[Any] = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.detail = detail

    def to_response(self) -> JSONResponse:
        return JSONResponse(
            status_code=self.status_code,
            content={
                "code": self.code,
                "message": self.message,
                "detail": self.detail,
            },
        )

    # 常用错误构造（类方法别名，便于 AppError.unauthorized(...) 调用）
    @classmethod
    def unauthorized(cls, message: str = "未认证或凭证无效") -> "AppError":
        return cls("unauthorized", message, 401)

    @classmethod
    def forbidden(cls, message: str = "无权访问该资源") -> "AppError":
        return cls("forbidden", message, 403)

    @classmethod
    def not_found(cls, message: str = "资源不存在") -> "AppError":
        return cls("not_found", message, 404)

    @classmethod
    def rate_limited(cls, message: str = "请求过于频繁，请稍后再试") -> "AppError":
        return cls("rate_limited", message, 429)


# 常用错误构造
def unauthorized(message: str = "未认证或凭证无效") -> AppError:
    return AppError("unauthorized", message, 401)


def forbidden(message: str = "无权访问该资源") -> AppError:
    return AppError("forbidden", message, 403)


def not_found(message: str = "资源不存在") -> AppError:
    return AppError("not_found", message, 404)


def rate_limited(message: str = "请求过于频繁，请稍后再试") -> AppError:
    return AppError("rate_limited", message, 429)


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error(_: Request, exc: AppError) -> JSONResponse:
        return exc.to_response()

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content={
                "code": "validation_error",
                "message": "请求参数校验失败",
                "detail": exc.errors(),
            },
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={
                "code": "http_error",
                "message": str(exc.detail),
                "detail": None,
            },
        )

    @app.exception_handler(Exception)
    async def _unexpected(_: Request, __: Exception) -> JSONResponse:
        return JSONResponse(
            status_code=500,
            content={
                "code": "internal_error",
                "message": "服务器内部错误",
                "detail": None,
            },
        )
