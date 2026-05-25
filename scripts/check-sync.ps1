[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$issues = New-Object System.Collections.Generic.List[string]

function Join-RepoPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return Join-Path $repoRoot $RelativePath
}

function Normalize-Text {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path)
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"
    return $text.TrimEnd("`n")
}

function Get-FirstDifference {
    param(
        [Parameter(Mandatory = $true)][string]$CodexText,
        [Parameter(Mandatory = $true)][string]$ClaudeText
    )

    $codexLines = [regex]::Split($CodexText, "`n")
    $claudeLines = [regex]::Split($ClaudeText, "`n")
    $maxLines = [Math]::Max($codexLines.Count, $claudeLines.Count)

    for ($index = 0; $index -lt $maxLines; $index++) {
        if ($index -ge $codexLines.Count) {
            return "Claude has extra content starting at line $($index + 1)"
        }

        if ($index -ge $claudeLines.Count) {
            return "Codex has extra content starting at line $($index + 1)"
        }

        if ($codexLines[$index] -ne $claudeLines[$index]) {
            return "first differing line: $($index + 1)"
        }
    }

    return "content differs"
}

function Test-FilePair {
    param(
        [Parameter(Mandatory = $true)][string]$CodexRelativePath,
        [Parameter(Mandatory = $true)][string]$ClaudeRelativePath
    )

    $codexPath = Join-RepoPath $CodexRelativePath
    $claudePath = Join-RepoPath $ClaudeRelativePath
    $codexExists = Test-Path -LiteralPath $codexPath -PathType Leaf
    $claudeExists = Test-Path -LiteralPath $claudePath -PathType Leaf

    if (-not $codexExists) {
        $issues.Add("Missing Codex file: $CodexRelativePath")
        return
    }

    if (-not $claudeExists) {
        $issues.Add("Missing Claude file: $ClaudeRelativePath")
        return
    }

    $codexText = Normalize-Text $codexPath
    $claudeText = Normalize-Text $claudePath

    if ($codexText -ne $claudeText) {
        $detail = Get-FirstDifference $codexText $claudeText
        $issues.Add("Content drift: $CodexRelativePath <-> $ClaudeRelativePath ($detail)")
    }
}

function Get-RelativeFiles {
    param([Parameter(Mandatory = $true)][string]$DirectoryPath)

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        return @()
    }

    $basePath = (Resolve-Path -LiteralPath $DirectoryPath).Path
    return Get-ChildItem -LiteralPath $basePath -File -Recurse |
        ForEach-Object {
            $_.FullName.Substring($basePath.Length).TrimStart("\", "/") -replace "\\", "/"
        } |
        Sort-Object
}

Test-FilePair "SKILL.md" ".claude/skills/generate-code/SKILL.md"

$codexReferencesRel = "References"
$claudeReferencesRel = ".claude/skills/generate-code/references"
$codexReferencesPath = Join-RepoPath $codexReferencesRel
$claudeReferencesPath = Join-RepoPath $claudeReferencesRel

if (-not (Test-Path -LiteralPath $codexReferencesPath -PathType Container)) {
    $issues.Add("Missing Codex directory: $codexReferencesRel")
}

if (-not (Test-Path -LiteralPath $claudeReferencesPath -PathType Container)) {
    $issues.Add("Missing Claude directory: $claudeReferencesRel")
}

if ((Test-Path -LiteralPath $codexReferencesPath -PathType Container) -and
    (Test-Path -LiteralPath $claudeReferencesPath -PathType Container)) {
    $codexFiles = Get-RelativeFiles $codexReferencesPath
    $claudeFiles = Get-RelativeFiles $claudeReferencesPath
    $allFiles = @($codexFiles + $claudeFiles) | Sort-Object -Unique

    foreach ($file in $allFiles) {
        if ($codexFiles -notcontains $file) {
            $issues.Add("Extra Claude reference: $claudeReferencesRel/$file")
            continue
        }

        if ($claudeFiles -notcontains $file) {
            $issues.Add("Missing Claude reference: $claudeReferencesRel/$file")
            continue
        }

        Test-FilePair "$codexReferencesRel/$file" "$claudeReferencesRel/$file"
    }
}

if ($issues.Count -gt 0) {
    Write-Host "Codex/Claude sync check failed:"
    foreach ($issue in $issues) {
        Write-Host " - $issue"
    }
    exit 1
}

Write-Host "Codex/Claude sync check passed."
