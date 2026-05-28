[CmdletBinding()]
param(
    [string[]]$Path = @(),
    [string[]]$AllowedPath = @(),
    [string]$BaseRef = "HEAD",
    [switch]$SkipSync,
    [switch]$SkipGit
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$issues = New-Object System.Collections.Generic.List[object]

$excludedDirectoryNames = @(
    ".git",
    "node_modules",
    "dist",
    "build",
    ".pytest_cache",
    "__pycache__"
)

$textExtensions = @(
    ".c",
    ".cc",
    ".cpp",
    ".cs",
    ".css",
    ".go",
    ".h",
    ".hpp",
    ".html",
    ".java",
    ".js",
    ".jsx",
    ".json",
    ".md",
    ".mjs",
    ".ps1",
    ".py",
    ".rs",
    ".scss",
    ".sh",
    ".ts",
    ".tsx",
    ".txt",
    ".yaml",
    ".yml"
)

function Add-Issue {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [string]$Path,
        [Nullable[int]]$Line,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $issues.Add([pscustomobject]@{
        Category = $Category
        Path = $Path
        Line = $Line
        Message = $Message
    })
}

function ConvertTo-RepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $resolvedPath = [System.IO.Path]::GetFullPath($FullPath)
    $resolvedRoot = [System.IO.Path]::GetFullPath($repoRoot)

    if (-not $resolvedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $resolvedRoot = "$resolvedRoot$([System.IO.Path]::DirectorySeparatorChar)"
    }

    if ($resolvedPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedPath.Substring($resolvedRoot.Length).Replace("\", "/")
    }

    return $resolvedPath.Replace("\", "/")
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    if ([System.IO.Path]::IsPathRooted($InputPath)) {
        return [System.IO.Path]::GetFullPath($InputPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $InputPath))
}

function Test-IsExcludedPath {
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $relativePath = ConvertTo-RepoRelativePath $FullPath
    $segments = $relativePath -split "/"

    foreach ($segment in $segments) {
        if ($excludedDirectoryNames -contains $segment) {
            return $true
        }
    }

    return $false
}

function Test-IsTextFile {
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $extension = [System.IO.Path]::GetExtension($FullPath).ToLowerInvariant()
    if ($textExtensions -contains $extension) {
        return $true
    }

    try {
        $stream = [System.IO.File]::OpenRead($FullPath)
        try {
            $buffer = New-Object byte[] ([Math]::Min(4096, [int]$stream.Length))
            $read = $stream.Read($buffer, 0, $buffer.Length)
            for ($index = 0; $index -lt $read; $index++) {
                if ($buffer[$index] -eq 0) {
                    return $false
                }
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $false
    }

    return $true
}

function Get-ScanFiles {
    param([string[]]$InputPaths)

    $files = New-Object System.Collections.Generic.List[string]

    foreach ($inputPath in $InputPaths) {
        $fullPath = Resolve-RepoPath $inputPath

        if (-not (Test-Path -LiteralPath $fullPath)) {
            Add-Issue "scan" $inputPath $null "Path does not exist."
            continue
        }

        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            if ((-not (Test-IsExcludedPath $fullPath)) -and (Test-IsTextFile $fullPath)) {
                $files.Add($fullPath)
            }
            continue
        }

        Get-ChildItem -LiteralPath $fullPath -File -Recurse |
            Where-Object {
                (-not (Test-IsExcludedPath $_.FullName)) -and (Test-IsTextFile $_.FullName)
            } |
            ForEach-Object {
                $files.Add($_.FullName)
            }
    }

    return $files | Sort-Object -Unique
}

function Get-RegexSafeMarkers {
    return @(
        "TO" + "DO",
        "TB" + "D",
        "place" + "holder",
        "stu" + "b"
    )
}

function Test-ContentRules {
    param([Parameter(Mandatory = $true)][string[]]$Files)

    $markerPattern = "\b(" + ((Get-RegexSafeMarkers | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")\b"
    $emptyImplPattern = "throw\s+new\s+Error\s*\(\s*[""']" + "Not " + "implemented" + "[""']\s*\)"
    $typeAnyPattern = ":\s*" + "any" + "\b"
    $castAnyPattern = "\bas\s+" + "any" + "\b"

    foreach ($file in $Files) {
        $relativePath = ConvertTo-RepoRelativePath $file
        $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        $lines = [System.IO.File]::ReadAllLines($file)

        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = $lines[$lineIndex]
            $lineNumber = $lineIndex + 1

            if ($line -match $markerPattern) {
                Add-Issue "unfinished-marker" $relativePath $lineNumber "Contains an unfinished-work marker."
            }

            if ($line -match $emptyImplPattern) {
                Add-Issue "empty-implementation" $relativePath $lineNumber "Contains an obvious empty implementation."
            }

            if ($extension -in @(".ts", ".tsx") -and $line -match $typeAnyPattern) {
                Add-Issue "typescript-any" $relativePath $lineNumber "TypeScript explicit loose annotation is not allowed."
            }

            if ($extension -in @(".ts", ".tsx") -and $line -match $castAnyPattern) {
                Add-Issue "typescript-any" $relativePath $lineNumber "TypeScript loose cast is not allowed."
            }
        }
    }
}

function Resolve-ImportTarget {
    param(
        [Parameter(Mandatory = $true)][string]$ImporterPath,
        [Parameter(Mandatory = $true)][string]$ImportPath
    )

    $baseDirectory = Split-Path -Parent $ImporterPath
    $candidateBase = [System.IO.Path]::GetFullPath((Join-Path $baseDirectory $ImportPath))
    $extensions = @("", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json", ".css", ".scss", ".md")
    $indexFiles = @(
        "index.ts",
        "index.tsx",
        "index.js",
        "index.jsx",
        "index.mjs",
        "index.cjs",
        "index.json"
    )

    foreach ($extension in $extensions) {
        $candidate = "$candidateBase$extension"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $true
        }
    }

    if (Test-Path -LiteralPath $candidateBase -PathType Container) {
        foreach ($indexFile in $indexFiles) {
            $candidate = Join-Path $candidateBase $indexFile
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $true
            }
        }
    }

    return $false
}

function Test-LocalImportRules {
    param([Parameter(Mandatory = $true)][string[]]$Files)

    $importPatterns = @(
        "\bimport\s+(?:type\s+)?(?:[^'"";]+?\s+from\s+)?['""](?<path>\.{1,2}/[^'""]+)['""]",
        "\bexport\s+(?:type\s+)?[^'"";]+?\s+from\s+['""](?<path>\.{1,2}/[^'""]+)['""]",
        "\brequire\s*\(\s*['""](?<path>\.{1,2}/[^'""]+)['""]\s*\)",
        "\bimport\s*\(\s*['""](?<path>\.{1,2}/[^'""]+)['""]\s*\)"
    )

    foreach ($file in $Files) {
        $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($extension -notin @(".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx")) {
            continue
        }

        $relativePath = ConvertTo-RepoRelativePath $file
        $lines = [System.IO.File]::ReadAllLines($file)

        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = $lines[$lineIndex]
            foreach ($pattern in $importPatterns) {
                $matches = [regex]::Matches($line, $pattern)
                foreach ($match in $matches) {
                    $importPath = $match.Groups["path"].Value
                    if (-not (Resolve-ImportTarget $file $importPath)) {
                        Add-Issue "local-import" $relativePath ($lineIndex + 1) "Local import path does not resolve: $importPath"
                    }
                }
            }
        }
    }
}

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
        Add-Issue "git" $null $null "Git checks could not run: $($_.Exception.Message)"
        return $false
    }
}

function Get-ChangedFiles {
    $changed = New-Object System.Collections.Generic.List[string]

    $tracked = Invoke-Git @("diff", "--name-only", $BaseRef, "--")
    $staged = Invoke-Git @("diff", "--name-only", "--cached", "--")
    $untracked = Invoke-Git @("ls-files", "--others", "--exclude-standard")

    foreach ($path in @($tracked + $staged + $untracked)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $changed.Add($path.Replace("\", "/"))
    }

    return $changed | Sort-Object -Unique
}

function Get-ScanTargets {
    if ($Path.Count -gt 0) {
        return $Path
    }

    if ($SkipGit) {
        return @(".")
    }

    if (Test-GitAvailable) {
        return @(Get-ChangedFiles)
    }

    return @(".")
}

function Test-AllowedPathRules {
    param([Parameter(Mandatory = $true)][string[]]$ChangedFiles)

    if ($AllowedPath.Count -eq 0) {
        return
    }

    $allowedPrefixes = @(
        $AllowedPath |
            ForEach-Object {
                $fullPath = Resolve-RepoPath $_
                $relativePath = ConvertTo-RepoRelativePath $fullPath
                $relativePath.TrimEnd("/") + "/"
            }
    )

    $allowedFiles = @(
        $AllowedPath |
            ForEach-Object {
                $fullPath = Resolve-RepoPath $_
                (ConvertTo-RepoRelativePath $fullPath).TrimEnd("/")
            }
    )

    foreach ($changedFile in $ChangedFiles) {
        $normalized = $changedFile.TrimStart("/")
        $isAllowed = $false

        foreach ($allowedFile in $allowedFiles) {
            if ($normalized -ieq $allowedFile) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            foreach ($prefix in $allowedPrefixes) {
                if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isAllowed = $true
                    break
                }
            }
        }

        if (-not $isAllowed) {
            Add-Issue "unauthorized-change" $changedFile $null "Changed file is outside the allowed path list."
        }
    }
}

function Get-JsonObjectFromText {
    param([Parameter(Mandatory = $true)][string[]]$Text)

    if ($Text.Count -eq 0) {
        return $null
    }

    return (($Text -join "`n") | ConvertFrom-Json -ErrorAction Stop)
}

function Get-DependencyMap {
    param([AllowNull()]$PackageJson)

    $result = @{}
    if ($null -eq $PackageJson) {
        return $result
    }

    $sections = @("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")

    foreach ($section in $sections) {
        if (-not ($PackageJson.PSObject.Properties.Name -contains $section)) {
            continue
        }

        $dependencies = $PackageJson.$section
        if ($null -eq $dependencies) {
            continue
        }

        foreach ($property in $dependencies.PSObject.Properties) {
            $result["$section/$($property.Name)"] = [string]$property.Value
        }
    }

    return $result
}

function Test-DependencyRules {
    param([Parameter(Mandatory = $true)][string[]]$ChangedFiles)

    $packageFiles = $ChangedFiles | Where-Object {
        $_ -eq "package.json" -or $_.EndsWith("/package.json", [System.StringComparison]::OrdinalIgnoreCase)
    }

    foreach ($packageFile in $packageFiles) {
        $packagePath = Join-Path $repoRoot $packageFile
        if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
            continue
        }

        try {
            $currentPackage = Get-JsonObjectFromText ([System.IO.File]::ReadAllLines($packagePath))
        }
        catch {
            Add-Issue "dependency" $packageFile $null "Could not parse current package.json: $($_.Exception.Message)"
            continue
        }

        $basePackage = $null
        try {
            $baseText = Invoke-Git @("show", "$($BaseRef):$packageFile")
            $basePackage = Get-JsonObjectFromText $baseText
        }
        catch {
            $basePackage = $null
        }

        $currentDependencies = Get-DependencyMap $currentPackage
        $baseDependencies = Get-DependencyMap $basePackage

        foreach ($key in ($currentDependencies.Keys | Sort-Object)) {
            if (-not $baseDependencies.ContainsKey($key)) {
                Add-Issue "dependency" $packageFile $null "New third-party dependency detected: $key=$($currentDependencies[$key])"
                continue
            }

            if ($baseDependencies[$key] -ne $currentDependencies[$key]) {
                Add-Issue "dependency" $packageFile $null "Dependency version changed: $key $($baseDependencies[$key]) -> $($currentDependencies[$key])"
            }
        }
    }
}

function Test-SyncRules {
    if ($SkipSync) {
        return
    }

    $syncScript = Join-Path $scriptDir "check-sync.ps1"
    if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
        Add-Issue "sync" "scripts/check-sync.ps1" $null "Sync check script is missing."
        return
    }

    $output = & powershell -ExecutionPolicy Bypass -File $syncScript 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-Issue "sync" "scripts/check-sync.ps1" $null ($output -join " ")
    }
}

$scanTargets = @(Get-ScanTargets)
$scanFiles = @(Get-ScanFiles $scanTargets)
Test-ContentRules $scanFiles
Test-LocalImportRules $scanFiles
Test-SyncRules

if (-not $SkipGit) {
    if (Test-GitAvailable) {
        $changedFiles = @(Get-ChangedFiles)
        Test-AllowedPathRules $changedFiles
        Test-DependencyRules $changedFiles
    }
}

if ($issues.Count -gt 0) {
    Write-Host "Skill output validation failed:"
    foreach ($issue in ($issues | Sort-Object Category, Path, Line, Message)) {
        $location = ""
        if (-not [string]::IsNullOrWhiteSpace($issue.Path)) {
            $location = $issue.Path
            if ($null -ne $issue.Line) {
                $location = "$location`:$($issue.Line)"
            }
            $location = " [$location]"
        }

        Write-Host " - $($issue.Category)$location $($issue.Message)"
    }
    exit 1
}

Write-Host "Skill output validation passed."
