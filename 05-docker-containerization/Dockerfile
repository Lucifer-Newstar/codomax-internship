# syntax=docker/dockerfile:1.7
# CloudOps Notes — production-conscious image.
# Build context is the module 03 app directory:
#   docker build -f 05-docker-containerization/Dockerfile -t cloudops-notes:dev 04-cloud-services/app
#
# Stage 1 installs dependencies into a virtualenv (needs build tools occasionally);
# stage 2 copies only that venv + the source onto a clean slim image and runs as a non-root user.

ARG PYTHON_VERSION=3.12

# ---------- stage 1: build ----------
FROM python:${PYTHON_VERSION}-slim AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install -r requirements.txt

# ---------- stage 2: runtime ----------
FROM python:${PYTHON_VERSION}-slim AS runtime
ARG GIT_SHA=unknown
ARG APP_VERSION=1.0.0
LABEL org.opencontainers.image.title="cloudops-notes" \
      org.opencontainers.image.source="https://github.com/Lucifer-Newstar/codomax-internship" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${APP_VERSION}"

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    APP_PORT=8000 GIT_SHA=${GIT_SHA} APP_VERSION=${APP_VERSION}

# curl only for the HEALTHCHECK. apt versions are not pinned on purpose: Debian point releases
# change them and would break the build; the base image tag pins the distro instead.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 app \
 && useradd  --system --uid 10001 --gid app --home-dir /app --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
# .dockerignore keeps tests, .env, caches out of this copy.
COPY --chown=app:app . .

USER app
EXPOSE 8000

# Liveness only (no DB): if the process is wedged the orchestrator restarts it.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${APP_PORT}/health" || exit 1

CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${APP_PORT} --workers 2 --threads 2 --timeout 30 --error-logfile - wsgi:app"]
