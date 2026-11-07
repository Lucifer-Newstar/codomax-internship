import pytest

from cloudops.config import ConfigError, load_settings


def _clean(monkeypatch):
    for k in (
        "DATABASE_URL",
        "DB_HOST",
        "DB_PASSWORD",
        "DB_PASSWORD_FILE",
        "NOTES_STORE",
        "APP_ENV",
        "SECRET_KEY",
        "LOG_LEVEL",
        "APP_PORT",
    ):
        monkeypatch.delenv(k, raising=False)


def test_requires_database(monkeypatch, tmp_path):
    _clean(monkeypatch)
    with pytest.raises(ConfigError, match="No database configured"):
        load_settings(dotenv_path=tmp_path / ".env")


def test_builds_url_from_parts(monkeypatch, tmp_path):
    _clean(monkeypatch)
    monkeypatch.setenv("DB_HOST", "db.internal")
    monkeypatch.setenv("DB_USER", "app")
    monkeypatch.setenv("DB_PASSWORD", "p@ss/word")
    s = load_settings(dotenv_path=tmp_path / ".env")
    assert s.database_url == "postgresql://app:p%40ss%2Fword@db.internal:5432/cloudops"


def test_password_from_file(monkeypatch, tmp_path):
    _clean(monkeypatch)
    secret = tmp_path / "db_password"
    secret.write_text("fromfile\n")
    monkeypatch.setenv("DB_HOST", "db")
    monkeypatch.setenv("DB_PASSWORD_FILE", str(secret))
    assert "fromfile@db" in load_settings(dotenv_path=tmp_path / ".env").database_url


def test_production_rejects_default_secret(monkeypatch, tmp_path):
    _clean(monkeypatch)
    monkeypatch.setenv("APP_ENV", "production")
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@h/db")
    with pytest.raises(ConfigError, match="SECRET_KEY"):
        load_settings(dotenv_path=tmp_path / ".env")


def test_invalid_values(monkeypatch, tmp_path):
    _clean(monkeypatch)
    monkeypatch.setenv("NOTES_STORE", "memory")
    monkeypatch.setenv("LOG_LEVEL", "LOUD")
    with pytest.raises(ConfigError, match="LOG_LEVEL"):
        load_settings(dotenv_path=tmp_path / ".env")
    monkeypatch.setenv("LOG_LEVEL", "INFO")
    monkeypatch.setenv("APP_PORT", "99999")
    with pytest.raises(ConfigError, match="APP_PORT"):
        load_settings(dotenv_path=tmp_path / ".env")


def test_dotenv_file_is_loaded(monkeypatch, tmp_path):
    _clean(monkeypatch)
    (tmp_path / ".env").write_text("NOTES_STORE=memory\nAPP_VERSION=9.9.9\n")
    s = load_settings(dotenv_path=tmp_path / ".env")
    assert s.version == "9.9.9"
    assert s.notes_store == "memory"
    assert s.safe_dict()["database_configured"] is False
