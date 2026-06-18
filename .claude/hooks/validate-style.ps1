$ErrorActionPreference = 'Stop'

$rawInput = [Console]::In.ReadToEnd()
if (-not $rawInput.Trim()) { exit 0 }

$hookInput = $rawInput | ConvertFrom-Json
$toolName  = $hookInput.tool_name
$toolInput = $hookInput.tool_input
$filePath  = $toolInput.file_path

if (-not $filePath) { exit 0 }

$normalizedPath = $filePath -replace '\\', '/'
if ($normalizedPath -notmatch '\.md$') { exit 0 }

# Frontmatter is required only on category index files:
# Index.md at the repo root and <Category>/<Category>.md files
$fileName     = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
$parentFolder = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($filePath))
$isIndexFile  = ($fileName -eq 'Index') -or ($fileName -eq $parentFolder)
if (-not $isIndexFile) { exit 0 }

if ($toolName -eq 'Write') {
    if ($toolInput.content -notmatch '^---') {
        [Console]::Error.WriteLine("BLOCKED: '$filePath' is a category index file but missing YAML frontmatter. File must start with '---'.")
        exit 2
    }
}
elseif ($toolName -eq 'Edit') {
    if ($toolInput.old_string -match '^---' -and $toolInput.new_string -notmatch '^---') {
        [Console]::Error.WriteLine("BLOCKED: Edit would remove YAML frontmatter from '$filePath'.")
        exit 2
    }
}

exit 0
