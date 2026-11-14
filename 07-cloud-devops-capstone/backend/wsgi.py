"""gunicorn entry point:  gunicorn wsgi:app"""

from cloudops_api import create_app

app = create_app()
