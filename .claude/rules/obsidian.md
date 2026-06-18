# Obsidian Document Standards

## Frontmatter Schema

**Frontmatter applies to category index files only** — not to detail documents. Detail documents start directly with the `# Title` H1 heading.

Category index files (e.g., `Standards/Standards.md`, `Operations/Operations.md`, `Index.md`) must have:

```yaml
---
title: "Document Title"
tags:
  - tag1
  - tag2
category: "category-name"   # index | performance | disaster-recovery | clustering | security | operations | standards
summary: "One-sentence description of what this document covers."
---
```

Required fields: `title`, `tags`, `category`, `summary`.

## Body Structure

### Detail Documents

Detail documents have **no frontmatter**. Structure:

1. `# Title` — H1 at the top of the file, no frontmatter above it
2. H2 sections for each major topic
3. Bullet lists for guidance items; numbered steps for sequential procedures
4. Code blocks with `sql` or `powershell` language tags where relevant
5. `## Related Documents` section at the bottom with wikilinks to related content

### Category Index Files (e.g., `Standards/Standards.md`)

Navigation hubs — minimal prose, mostly links:

1. `# Category Name`
2. One-sentence description of the category scope
3. Bulleted wikilinks to all detail documents in the folder
4. Link back to `[[../Index|Back to Index]]`

## Wikilink Conventions

- Use relative paths from the current file: `[[../Index|Back to Index]]`
- Always include display text after `|`: `[[Security-Practices|Security Practices]]`
- Category index files link back to main index; detail docs link to their category index

## Scope Boundary

Standards documents describe **how** things should be done, not **what** is running where. Do not include:

- Specific server names, IP addresses, or instance connection strings
- Instance-specific audit findings or configuration values
- Environment-specific data
