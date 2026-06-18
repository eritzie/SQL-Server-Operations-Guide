# Git Conventions

## Commit Messages

| Scenario | Pattern |
|---|---|
| New document added | `Add {Category}/{Document} — {one-line summary}` |
| Update existing content | `Update {Document} — {what changed}` |
| Fix frontmatter or structure | `Fix {Document} — {what was wrong}` |
| Config / tooling changes | `{Verb} {file or area} — {what changed}` |

## Rules

- Never commit `CLAUDE.local.md` if one exists — keep local config out of the repo
- Never amend published commits — create a new commit
- Stage specific files by name; avoid `git add .`
- Confirm staged changes with `git diff --cached` before committing
