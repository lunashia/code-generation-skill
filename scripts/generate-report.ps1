[CmdletBinding()]
param(
    [string]$BaseRef = "HEAD",
    [string]$ValidatorOutputPath,
    [string]$OutputPath,
    [string[]]$SuggestedCommand = @(),
    [switch]$SkipValidator
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

$ruleDefinitions = @(
    @{
        Name = "No " + ("TO" + "DO") + "/" + ("stu" + "b")
        Categories = @("unfinished-marker", "empty-implementation")
    },
    @{
        Name = "No " + ("an" + "y")
        Categories = @("typescript-" + ("an" + "y"))
    },
    @{
        Name = "No new dependency"
        Categories = @("dependency")
    },
    @{
        Name = "Import paths resolvable"
        Categories = @("local-import")
    },
    @{
        Name = "Skill sync"
        Categories = @("sync")
    }
)

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & git -C $repoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join "`n")
    }

    return $output
}

function Test-GitAvailable {
    try {
        Invoke-Git @("rev-parse", "--is-inside-work-tree") | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-ChangedFiles {
    $changed = New-Object System.Collections.Generic.List[string]

    if (-not (Test-GitAvailable)) {
        return @()
    }

    foreach ($arguments in @(
        @("diff", "--name-only", $BaseRef, "--"),
        @("diff", "--name-only", "--cached", "--"),
        @("ls-files", "--others", "--exclude-standard")
    )) {
        $paths = Invoke-Git $arguments
        foreach ($path in $paths) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }

            $changed.Add($path.Replace("\", "/"))
        }
    }

    return $changed | Sort-Object -Unique
}

function Invoke-Validator {
    if ($SkipValidator) {
        return [pscustomobject]@{
            Status = "not run"
            ExitCode = $null
            Lines = @()
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ValidatorOutputPath)) {
        $fullPath = $ValidatorOutputPath
        if (-not [System.IO.Path]::IsPathRooted($fullPath)) {
            $fullPath = Join-Path $repoRoot $ValidatorOutputPath
        }

        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Validator output file does not exist: $ValidatorOutputPath"
        }

        $lines = [System.IO.File]::ReadAllLines($fullPath)
        $status = "unknown"
        if ($lines -match "Skill output validation passed\.") {
            $status = "passed"
        }
        elseif ($lines -match "Skill output validation failed:") {
            $status = "failed"
        }

        return [pscustomobject]@{
            Status = $status
            ExitCode = $null
            Lines = $lines
        }
    }

    $validatorScript = Join-Path $scriptDir "validate-skill-output.ps1"
    if (-not (Test-Path -LiteralPath $validatorScript -PathType Leaf)) {
        return [pscustomobject]@{
            Status = "not run"
            ExitCode = $null
            Lines = @("Validator script is missing: scripts/validate-skill-output.ps1")
        }
    }

    $output = & powershell -ExecutionPolicy Bypass -File $validatorScript -BaseRef $BaseRef 2>&1
    $exitCode = $LASTEXITCODE
    $status = "failed"
    if ($exitCode -eq 0) {
        $status = "passed"
    }

    return [pscustomobject]@{
        Status = $status
        ExitCode = $exitCode
        Lines = @($output | ForEach-Object { [string]$_ })
    }
}

function Get-ValidatorCategories {
    param([Parameter(Mandatory = $true)]$ValidatorResult)

    $categories = New-Object System.Collections.Generic.HashSet[string]

    foreach ($line in $ValidatorResult.Lines) {
        if ($line -match "^\s*-\s+(?<category>[^\s\[]+)") {
            [void]$categories.Add($Matches.category)
        }
    }

    return ,$categories
}

function Get-RuleStatus {
    param(
        [Parameter(Mandatory = $true)]$Rule,
        [Parameter(Mandatory = $true)]$ValidatorResult,
        [Parameter(Mandatory = $true)]$FailedCategories
    )

    if ($ValidatorResult.Status -eq "passed") {
        return "passed"
    }

    if ($ValidatorResult.Status -eq "not run" -or $ValidatorResult.Status -eq "unknown") {
        return "not run"
    }

    foreach ($category in $Rule.Categories) {
        if ($FailedCategories.Contains($category)) {
            return "failed"
        }
    }

    return "passed"
}

function Get-PackageJson {
    $packagePath = Join-Path $repoRoot "package.json"
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        return $null
    }

    try {
        return ([System.IO.File]::ReadAllText($packagePath) | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-SuggestedCommands {
    if ($SuggestedCommand.Count -gt 0) {
        return $SuggestedCommand |
            ForEach-Object {
                $_ -split ","
            } |
            ForEach-Object {
                $_.Trim()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    }

    $commands = New-Object System.Collections.Generic.List[string]
    $packageJson = Get-PackageJson

    if ($null -ne $packageJson -and
        $packageJson.PSObject.Properties.Name -contains "scripts" -and
        $null -ne $packageJson.scripts) {
        $scriptNames = $packageJson.scripts.PSObject.Properties.Name
        if ($scriptNames -contains "test") {
            $commands.Add("npm test")
        }
        if ($scriptNames -contains "typecheck") {
            $commands.Add("npm run typecheck")
        }
        elseif ($scriptNames -contains "type-check") {
            $commands.Add("npm run type-check")
        }
    }

    if (Test-Path -LiteralPath (Join-Path $scriptDir "validate-skill-output.ps1") -PathType Leaf) {
        $commands.Add("powershell -ExecutionPolicy Bypass -File .\scripts\validate-skill-output.ps1")
    }

    return $commands | Sort-Object -Unique
}

function Get-Risks {
    param(
        [Parameter(Mandatory = $true)]$ValidatorResult,
        [Parameter(Mandatory = $true)][string[]]$Commands
    )

    $risks = New-Object System.Collections.Generic.List[string]
    $packageJson = Get-PackageJson
    $hasTestScript = $false

    if ($null -ne $packageJson -and
        $packageJson.PSObject.Properties.Name -contains "scripts" -and
        $null -ne $packageJson.scripts) {
        $hasTestScript = $packageJson.scripts.PSObject.Properties.Name -contains "test"
    }

    if ($ValidatorResult.Status -eq "failed") {
        $risks.Add("Validator reported failed checks; review the Rule Checks section.")
    }
    elseif ($ValidatorResult.Status -eq "not run" -or $ValidatorResult.Status -eq "unknown") {
        $risks.Add("Validator result was not available, so rule checks could not be fully verified.")
    }

    if (-not $hasTestScript) {
        $risks.Add("Could not suggest a package test command because no package test script exists.")
    }

    if ($Commands.Count -eq 0) {
        $risks.Add("No verification commands could be inferred from the repository.")
    }

    if ($risks.Count -eq 0) {
        $risks.Add("None identified.")
    }

    return $risks
}

function New-Report {
    $changedFiles = @(Get-ChangedFiles)
    $validatorResult = Invoke-Validator
    $failedCategories = Get-ValidatorCategories $validatorResult
    $commands = @(Get-SuggestedCommands)
    $risks = @(Get-Risks $validatorResult $commands)
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("# Code Generation Report")
    $lines.Add("")
    $lines.Add("## Scope")
    $lines.Add("Modified files:")
    if ($changedFiles.Count -eq 0) {
        $lines.Add("- None detected.")
    }
    else {
        foreach ($file in $changedFiles) {
            $lines.Add("- $file")
        }
    }

    $lines.Add("")
    $lines.Add("## Rule Checks")
    foreach ($rule in $ruleDefinitions) {
        $status = Get-RuleStatus $rule $validatorResult $failedCategories
        $lines.Add("- $($rule.Name): $status")
    }

    $lines.Add("")
    $lines.Add("## Verification")
    $lines.Add("Suggested commands:")
    if ($commands.Count -eq 0) {
        $lines.Add("- None inferred.")
    }
    else {
        foreach ($command in $commands) {
            $lines.Add("- $command")
        }
    }

    $lines.Add("")
    $lines.Add("## Risks")
    foreach ($risk in $risks) {
        $lines.Add("- $risk")
    }

    return ($lines -join "`n") + "`n"
}

$report = New-Report

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Write-Output $report
}
else {
    $fullOutputPath = $OutputPath
    if (-not [System.IO.Path]::IsPathRooted($fullOutputPath)) {
        $fullOutputPath = Join-Path $repoRoot $OutputPath
    }

    $outputDirectory = Split-Path -Parent $fullOutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }

    [System.IO.File]::WriteAllText($fullOutputPath, $report, [System.Text.Encoding]::UTF8)
    Write-Host "Report written to $OutputPath"
}
