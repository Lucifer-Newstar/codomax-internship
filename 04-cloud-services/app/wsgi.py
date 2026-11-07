"""WSGI entry point used by gunicorn:  gunicorn wsgi:app"""

from cloudops import create_app

app = create_app()
