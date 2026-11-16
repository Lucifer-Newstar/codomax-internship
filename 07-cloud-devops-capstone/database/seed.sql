-- Optional demo data:  psql "$DATABASE_URL" -f database/seed.sql
INSERT INTO tasks (title, description, status, priority) VALUES
  ('Launch EC2 instance',          'module 03: ec2_launch.sh',                  'done',  1),
  ('Containerize the app',         'module 04: Dockerfile + compose',           'done',  1),
  ('Wire GitHub Actions CI/CD',    'module 05: ci.yml, deploy.yml, OIDC',       'doing', 1),
  ('Add CloudWatch alarm on 5xx',  'metric filter on the JSON log',             'todo',  2),
  ('Write capstone runbook',       'docs/runbook.md',                           'todo',  3)
ON CONFLICT DO NOTHING;
