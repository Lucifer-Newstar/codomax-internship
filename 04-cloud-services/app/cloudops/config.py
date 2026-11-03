"""Configuration loaded from environment variables.

Rules followed here:
- Nothing sensitive is hardcoded. Defaults only exist for non-secret, local-dev values.
- A `.env` file is loaded only if present (local development). On EC2 the values come from the
  systemd EnvironmentFile; in Docker they come from `environment:` / `env_file:`.
- The database password can come from (in order): DB_PASSWORD, DB_PASSWORD_FILE (Docker secrets),
  or DB_PASSWORD_SSM_PARAMETER (AWS SSM Parameter Store SecureString via boto3).
- Invalid values fail fast at startup with a readable error instead of a confusing crash later.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

VALID_ENVS = ("development", "production", "test")
VALID_LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")


class ConfigError(RuntimeError):
    """Raised when the environment is missing or has an invalid value."""


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    return value.strip()


def _int_env(name: str, default: int, lo: int, hi: int) -> int:
    raw = _env(name, str(default))
    try:
        value = int(raw)  # type: ignore[arg-type]
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer, got {raw!r}") from exc
    if not lo <= value <= hi:
        raise ConfigError(f"{name} must be between {lo} and {hi}, got {value}")
    return value


def _read_password_file(path: str) -> str:
    p = Path(path)
    if not p.is_file():
        raise ConfigError(f"DB_PASSWORD_FILE points to a missing file: {path}")
    return p.read_text(encoding="utf-8").strip()


def _read_ssm_parameter(name: str) -> str:
    """Fetch a SecureString from AWS SSM Parameter Store. boto3 is an optional dependency."""
    try:
        import boto3  # noqa: PLC0415 - imported lazily so the app runs without boto3
    except ImportError as exc:
        raise ConfigError(
            "DB_PASSWORD_SSM_PARAMETER is set but boto3 is not installed "
            "(pip install -r requirements-aws.txt)"
        ) from exc
    ssm = boto3.client("ssm")  # region + credentials come from the instance role / env
    resp = ssm.get_parameter(Name=name, WithDecryption=True)
    return resp["Parameter"]["Value"]


def _resolve_db_password() -> str | None:
    if _env("DB_PASSWORD"):
        return _env("DB_PASSWORD")
    if _env("DB_PASSWORD_FILE"):
        return _read_password_file(_env("DB_PASSWORD_FILE"))  # type: ignore[arg-type]
    if _env("DB_PASSWORD_SSM_PARAMETER"):
        return _read_ssm_parameter(_env("DB_PASSWORD_SSM_PARAMETER"))  # type: ignore[arg-type]
    return None


@dataclass(frozen=True)
class Settings:
    app_env: str
    port: int
    version: str
    log_level: str
    log_format: str
    secret_key: str
    notes_store: str  # "postgres" (default) or "memory" (unit tests only)
    database_url: str | None
    db_sslmode: str
    asset_base_url: str | None
    git_sha: str = field(default="unknown")

    @property
    def is_production(self) -> bool:
        return self.app_env == "production"

    def safe_dict(self) -> dict:
        """Settings that are safe to show on /api/info (no secrets, no connection string)."""
        return {
            "app_env": self.app_env,
            "version": self.version,
            "git_sha": self.git_sha,
            "log_level": self.log_level,
            "log_format": self.log_format,
            "notes_store": self.notes_store,
            "database_configured": self.database_url is not None,
            "db_sslmode": self.db_sslmode,
            "asset_base_url": self.asset_base_url,
        }


def build_database_url() -> str | None:
    """Return DATABASE_URL, or assemble one from DB_* parts. None if nothing is configured."""
    url = _env("DATABASE_URL")
    if url:
        if not url.startswith(("postgresql://", "postgres://")):
            raise ConfigError("DATABASE_URL must start with postgresql://")
        return url

    host = _env("DB_HOST")
    if not host:
        return None
    port = _int_env("DB_PORT", 5432, 1, 65535)
    name = _env("DB_NAME", "cloudops")
    user = _env("DB_USER", "cloudops")
    password = _resolve_db_password()
    if password is None:
        raise ConfigError(
            "DB_HOST is set but no password found. Set DB_PASSWORD, DB_PASSWORD_FILE "
            "or DB_PASSWORD_SSM_PARAMETER."
        )
    # psycopg accepts the libpq URL format. Password is URL-escaped to survive special chars.
    from urllib.parse import quote

    return f"postgresql://{quote(user, safe='')}:{quote(password, safe='')}@{host}:{port}/{name}"


def load_settings(dotenv_path: str | os.PathLike | None = None) -> Settings:
    """Load settings. Reads a .env file if one exists (does not override real env vars)."""
    load_dotenv(dotenv_path=dotenv_path, override=False)

    app_env = _env("APP_ENV", "development")
    if app_env not in VALID_ENVS:
        raise ConfigError(f"APP_ENV must be one of {VALID_ENVS}, got {app_env!r}")

    log_level = (_env("LOG_LEVEL", "INFO") or "INFO").upper()
    if log_level not in VALID_LOG_LEVELS:
        raise ConfigError(f"LOG_LEVEL must be one of {VALID_LOG_LEVELS}, got {log_level!r}")

    log_format = _env("LOG_FORMAT", "json")
    if log_format not in ("json", "text"):
        raise ConfigError("LOG_FORMAT must be 'json' or 'text'")

    notes_store = _env("NOTES_STORE", "postgres")
    if notes_store not in ("postgres", "memory"):
        raise ConfigError("NOTES_STORE must be 'postgres' or 'memory'")

    secret_key = _env("SECRET_KEY", "dev-only-not-secret")
    if app_env == "production" and secret_key in ("dev-only-not-secret", "change-me-in-production"):
        raise ConfigError("SECRET_KEY must be set to a real value in production")

    database_url = build_database_url() if notes_store == "postgres" else None
    if notes_store == "postgres" and database_url is None:
        raise ConfigError(
            "No database configured. Set DATABASE_URL or DB_HOST/DB_USER/DB_PASSWORD "
            "(see .env.example), or NOTES_STORE=memory for unit tests."
        )

    return Settings(
        app_env=app_env,  # type: ignore[arg-type]
        port=_int_env("APP_PORT", 8000, 1, 65535),
        version=_env("APP_VERSION", "1.0.0") or "1.0.0",
        log_level=log_level,
        log_format=log_format,  # type: ignore[arg-type]
        secret_key=secret_key,  # type: ignore[arg-type]
        notes_store=notes_store,  # type: ignore[arg-type]
        database_url=database_url,
        db_sslmode=_env("DB_SSLMODE", "prefer") or "prefer",
        asset_base_url=(_env("ASSET_BASE_URL") or None),
        git_sha=_env("GIT_SHA", "unknown") or "unknown",
    )
