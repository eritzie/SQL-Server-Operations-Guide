#!/bin/bash
input=$(cat)
command=$(printf '%s' "$input" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

# Only act on git commit commands
if ! echo "$command" | grep -qE 'git[[:space:]]+commit'; then
    exit 0
fi

# Check staged *.md files for frontmatter.
# Only index files require frontmatter: root Index.md and files where
# the filename (sans extension) matches the parent folder name (e.g. Clustering/Clustering.md).
staged_files=$(git diff --cached --name-only 2>/dev/null | grep -E '\.md$' || true)

if [[ -z "$staged_files" ]]; then
    exit 0
fi

missing=()
while IFS= read -r file; do
    basename_no_ext=$(basename "$file" .md)
    parent_folder=$(basename "$(dirname "$file")")

    # Only enforce frontmatter on index files
    if [[ "$basename_no_ext" != "$parent_folder" && "$basename_no_ext" != "Index" ]]; then
        continue
    fi

    if [[ -f "$file" ]] && ! head -1 "$file" | grep -q '^---'; then
        missing+=("$file")
    fi
done <<< "$staged_files"

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "BLOCKED: Staged index files missing YAML frontmatter:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 2
fi

exit 0
