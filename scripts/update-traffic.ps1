[CmdletBinding()]
param(
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Token = $env:TRAFFIC_TOKEN,
    [string]$OutputSvg = "assets/traffic.svg",
    [string]$OutputJson = "assets/traffic.json",
    [switch]$Pending
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

function Join-RepoPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return Join-Path $repoRoot $RelativePath
}

function ConvertTo-SvgText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    return [System.Security.SecurityElement]::Escape($Text)
}

function Write-TrafficFiles {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Traffic,
        [Parameter(Mandatory = $true)][string]$SvgPath,
        [Parameter(Mandatory = $true)][string]$JsonPath
    )

    $svgFullPath = Join-RepoPath $SvgPath
    $jsonFullPath = Join-RepoPath $JsonPath
    $svgDir = Split-Path -Parent $svgFullPath
    $jsonDir = Split-Path -Parent $jsonFullPath

    New-Item -ItemType Directory -Force -Path $svgDir | Out-Null
    New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null

    $updatedAt = ConvertTo-SvgText $Traffic.updated_at
    $status = ConvertTo-SvgText $Traffic.status
    $cloneCount = ConvertTo-SvgText $Traffic.clones.count
    $cloneUnique = ConvertTo-SvgText $Traffic.clones.uniques
    $viewCount = ConvertTo-SvgText $Traffic.views.count
    $viewUnique = ConvertTo-SvgText $Traffic.views.uniques

    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="620" height="150" viewBox="0 0 620 150" role="img" aria-labelledby="title desc">
  <title id="title">GitHub Traffic</title>
  <desc id="desc">Repository traffic for clones and visitors over the last 14 days.</desc>
  <rect width="620" height="150" rx="8" fill="#0d1117"/>
  <rect x="1" y="1" width="618" height="148" rx="7" fill="none" stroke="#30363d"/>
  <text x="28" y="34" fill="#f0f6fc" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="18" font-weight="600">GitHub Traffic</text>
  <text x="28" y="58" fill="#8b949e" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="12">Last 14 days - $updatedAt</text>
  <g transform="translate(28 82)">
    <text fill="#8b949e" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="12">Git clones</text>
    <text y="32" fill="#f0f6fc" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="26" font-weight="700">$cloneCount</text>
    <text x="110" y="31" fill="#8b949e" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="13">$cloneUnique unique</text>
  </g>
  <g transform="translate(330 82)">
    <text fill="#8b949e" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="12">Visitors</text>
    <text y="32" fill="#f0f6fc" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="26" font-weight="700">$viewCount</text>
    <text x="110" y="31" fill="#8b949e" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="13">$viewUnique unique</text>
  </g>
  <text x="28" y="133" fill="#6e7681" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="11">$status</text>
</svg>
"@

    $json = $Traffic | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($svgFullPath, $svg, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($jsonFullPath, "$json`n", [System.Text.Encoding]::UTF8)
}

if ($Pending) {
    $traffic = @{
        updated_at = "pending first update"
        status = "Run the GitHub Actions workflow to publish live repository traffic."
        repository = $Repository
        window = "last 14 days"
        clones = @{
            count = "-"
            uniques = "-"
            days = @()
        }
        views = @{
            count = "-"
            uniques = "-"
            days = @()
        }
    }

    Write-TrafficFiles -Traffic $traffic -SvgPath $OutputSvg -JsonPath $OutputJson
    return
}

if ([string]::IsNullOrWhiteSpace($Repository)) {
    throw "Repository is required. Set GITHUB_REPOSITORY or pass -Repository owner/name."
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = $env:GITHUB_TOKEN
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "Token is required. Set TRAFFIC_TOKEN or GITHUB_TOKEN."
}

$headers = @{
    Accept = "application/vnd.github+json"
    Authorization = "Bearer $Token"
    "X-GitHub-Api-Version" = "2022-11-28"
}

$apiBase = "https://api.github.com/repos/$Repository/traffic"
$clones = Invoke-RestMethod -Method Get -Uri "$apiBase/clones" -Headers $headers
$views = Invoke-RestMethod -Method Get -Uri "$apiBase/views" -Headers $headers

$traffic = @{
    updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
    status = "Updated automatically from GitHub repository traffic."
    repository = $Repository
    window = "last 14 days"
    clones = @{
        count = $clones.count
        uniques = $clones.uniques
        days = $clones.clones
    }
    views = @{
        count = $views.count
        uniques = $views.uniques
        days = $views.views
    }
}

Write-TrafficFiles -Traffic $traffic -SvgPath $OutputSvg -JsonPath $OutputJson
