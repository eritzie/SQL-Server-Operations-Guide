#!/bin/bash
input=$(cat)
command=$(printf '%s' "$input" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

if [[ -z "$command" ]]; then exit 0; fi

patterns=(
    'git[[:space:]]+push.*--force'
    'git[[:space:]]+push.*[[:space:]]-f[[:space:]]'
    'git[[:space:]]+push.*[[:space:]]-f$'
    'git[[:space:]]+reset.*--hard'
    'git[[:space:]]+checkout.*[[:space:]]--[[:space:]]'
    'git[[:space:]]+clean.*-[fd]'
    'git[[:space:]]+branch.*-[Dd][[:space:]]'
)

for pattern in "${patterns[@]}"; do
    if echo "$command" | grep -qE "$pattern"; then
        echo "BLOCKED: Destructive git operation detected. Command: $command" >&2
        exit 2
    fi
done

exit 0
