# 问道 WenDao API 镜像
FROM python:3.11-slim

WORKDIR /srv/wendao

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY requirements.txt .
# 使用国内镜像源（PyPI 官方源在国内网络下易超时），多源兜底 + 超时重试
ARG PIP_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
RUN pip install --no-cache-dir -i ${PIP_INDEX} --timeout 60 --retries 5 -r requirements.txt \
    || pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ --timeout 60 --retries 5 -r requirements.txt \
    || pip install --no-cache-dir -i https://mirrors.cloud.tencent.com/pypi/simple/ --timeout 60 --retries 5 -r requirements.txt

COPY app ./app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://localhost:8000/health', timeout=3)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
