# SQL Server Operations Guide — Claude Context

## Purpose

This is a portfolio repository of SQL Server operations standards, governance documents, and runbooks. Claude's role is to write, edit, and maintain standards documents. This project contains no database queries, no PowerShell scripts, and no instance-specific content.

## Document Structure

Entry point: `Index.md`

| Category | Folder | Focus |
|---|---|---|
| Performance | `Performance/` | Query tuning, indexing, wait stats, memory |
| Disaster Recovery | `Disaster-Recovery/` | DR strategy, log shipping, restore procedures |
| Clustering | `Clustering/` | Windows clustering, SQL FCI, AG setup |
| Security | `Security/` | Hardening, permissions, auditing, least privilege |
| Operations | `Operations/` | Backup/restore procedures, monitoring, maintenance |
| Standards | `Standards/` | Development standards, naming conventions, policies |

Each category has an index file (e.g., `Standards/Standards.md`) that links to detail documents in that folder and back to `Index.md`.

## Directives

- **Always confirm before deleting any document** — even when a handoff or sync script explicitly lists files for removal. Show the list and wait for approval before executing any delete.
- Category index files must have YAML frontmatter — see `.claude/rules/obsidian.md`
- Scope is standards and governance only. Do not include server names, IP addresses, or findings from specific instances
- Cross-link related documents using Obsidian wikilinks: `[[../Index|Back to Index]]`
- Do not modify `.git`, `.obsidian`, or other tool-specific folders unless explicitly asked
- Propose changes as patches (Edit) rather than rewriting entire files when updating existing documents

## Rules Files

| File | Covers |
|---|---|
| `.claude/rules/obsidian.md` | Frontmatter schema, body structure, wikilink conventions |
| `.claude/rules/git.md` | Commit message conventions |
