# syntax=docker/dockerfile:1.10
#
# The parley relay image (relay/): Starlette, uvicorn and httpx from uv.lock,
# nothing else. Built by the PC's runner lane from this file at the merged
# commit (deploy/stack/stack.toml) and pinned in the stack's .env; locally:
# `docker build -t parley .`. The stack runs it read-only, as uid:gid
# 10001:10001, with its data at /data and its secret files at /run/secrets
# (deploy/stack/compose.yaml).

ARG PYTHON_IMAGE=python:3.12-slim@sha256:cb33f7f771ecec2ef1225cf39b159591a040391bd73e4c01f00fdfc4c47611d2
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.12.21@sha256:a7aed3216253ee804de3e2d8afa5073baa1a177335345d43845cd4165e43b711

FROM ${UV_IMAGE} AS uv

FROM ${PYTHON_IMAGE} AS build
COPY --from=uv /uv /usr/local/bin/uv
# The image's own Python, never a download; the locked versions only.
ENV UV_PYTHON=/usr/local/bin/python3.12 UV_PYTHON_DOWNLOADS=never UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_NO_CACHE=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /src/relay
# Dependencies first (cached apart from the code), then the relay itself,
# installed (not editable) into the venv.
COPY relay/pyproject.toml relay/uv.lock relay/.python-version /src/relay/
RUN uv sync --frozen --no-dev --no-install-project
COPY relay/README.md /src/relay/
COPY relay/src/ /src/relay/src/
RUN uv sync --frozen --no-dev --no-editable \
 && /opt/venv/bin/python -I -B -c "import parley_relay.server"

FROM ${PYTHON_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 PYTHONUNBUFFERED=1 HOME=/tmp \
    PATH=/opt/venv/bin:/usr/local/bin:/usr/bin:/bin PARLEY_DATA_DIR=/data
COPY --from=build /opt/venv /opt/venv
# Never root. /data is the stack's state/data bind (owned by this uid).
RUN install -d -o 10001 -g 10001 -m 0700 /data
USER 10001:10001
EXPOSE 8080
# No curl in the image: the probe is the venv's Python.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/opt/venv/bin/python", "-I", "-B", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=3).close()"]
ENTRYPOINT ["/opt/venv/bin/parley-relay"]
CMD ["--host", "127.0.0.1", "--port", "8080"]
