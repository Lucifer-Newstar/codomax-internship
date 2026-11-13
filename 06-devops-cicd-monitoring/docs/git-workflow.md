# Git & GitHub workflow used in this repository

## Branching model

```
main ──●────────●──────────────●──────────────●──▶   protected, always deployable, deploy.yml runs here
        \      /  \           /  \           /
         ●──●─●    ●──●──●──●─●    ●──●──●──●         feature/<nn>-<module>  one branch per module
```

- **`main`** is the production branch. Every merge to `main` triggers the CD workflow. It should be
  protected on GitHub: *require a pull request*, *require status checks (CI)*, *no force pushes*.
- **Feature branches** are named `feature/<nn>-<topic>` (`feature/05-docker-containerization`). One
  branch per module / piece of work, short-lived, merged with `--no-ff` so the module's history
  stays visible as a group in `git log --graph`.
- Hotfixes follow the same path (`fix/<topic>`), just faster.

## Day-to-day commands

```bash
git switch main && git pull --ff-only                 # start from the latest main
git switch -c feature/07-capstone                     # feature branch
# … work …
git add -p                                            # stage hunks deliberately (catches stray secrets)
git commit                                            # small, single-purpose commits
git push -u origin feature/07-capstone
# open a pull request on GitHub → CI runs → review → merge
git switch main && git pull --ff-only && git branch -d feature/07-capstone
```

Keeping a branch current without rewriting shared history: `git merge main` (or `git rebase main`
only while the branch is private).

## Commit message convention

`<scope>: <what changed, imperative, lowercase>` — the scope is the module or area:

```
cloud: rds postgres script, private sg-to-sg access, password straight into ssm
docker: multi-stage non-root Dockerfile with healthcheck and .dockerignore
ci: github actions pipeline — lint, pytest with postgres service, docker build and smoke test
monitoring: synthetic health checker with cloudwatch metric publishing
docs: add module 05 (docker) to the roadmap
chore: extend gitignore for python, docker and local cloud state
```

Rules: one logical change per commit; the subject says *why/what*, not "update files"; body (when
needed) explains trade-offs; never commit `.env`, keys, `.deploy-state/`.

## Pull requests

- Title = what the branch delivers; description = checklist of the module deliverables and how it
  was tested (paste the `pytest` / `smoke_test.sh` summary).
- CI must be green: lint → tests → docker build. The `Deploy` workflow does **not** run on PRs.
- Review your own diff on GitHub before asking for review — the *Files changed* tab catches
  leftovers (debug prints, TODOs, large files).
- Merge with a merge commit (keeps module grouping) or squash for tiny branches. Delete the branch.

## Collaboration tips

- `git log --oneline --graph --decorate` to see the module structure.
- `git blame -w -C <file>` to find why a line exists.
- Use GitHub *Environments* (`production`) for the deploy job: required reviewers can be added so a
  human approves each production deployment.
- Secrets go to *Settings → Secrets and variables*; non-secret config (region, URL, instance id) goes
  to *Variables* so they are visible in logs and easy to change.
