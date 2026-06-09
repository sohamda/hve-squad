#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Regenerates dependencies.apm entries in apm.yml from microsoft/hve-core.
.DESCRIPTION
    Queries the GitHub tree API for a repository and ref, filters files under
    selected .github folders, and rewrites only the dependencies.apm list.
.PARAMETER ApmFile
    Path to apm.yml to update.
.PARAMETER RepoSlug
    Repository slug in owner/repo format.
.PARAMETER Ref
    Git ref to read from (branch, tag, or commit).
.PARAMETER IncludeRoots
    Repository-relative roots under which files are discovered.
.PARAMETER IncludeRegex
    Regex used to keep matching file paths.
.PARAMETER DryRun
    If set, prints generated dependencies without updating apm.yml.
.EXAMPLE
    ./scripts/Update-ApmDependencies.ps1 -ApmFile apm.yml
.EXAMPLE
    ./scripts/Update-ApmDependencies.ps1 -Ref main -DryRun
.NOTES
    Intended for use with: apm run sync-deps
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ApmFile = 'apm.yml',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RepoSlug = 'microsoft/hve-core',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Ref = 'main',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]$IncludeRoots = @(
        '.github/agents',
        '.github/prompts',
        '.github/skills',
        '.github/instructions'
    ),

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$IncludeRegex = '\.md$',

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

#region Functions
function Get-LeadingSpaceCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $match = [regex]::Match($Line, '^(\s*)')
    return $match.Groups[1].Value.Length
}

function Get-RepoTreePaths {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$GitRef,

        [Parameter(Mandatory = $true)]
        [string[]]$Roots
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apm-tree-" + [Guid]::NewGuid().ToString('N'))
    $repoUrl = "https://github.com/$Repository.git"

    try {
        $null = & git clone --depth 1 --filter=blob:none --branch $GitRef $repoUrl $tempRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed for '$Repository@$GitRef'."
        }

        Push-Location $tempRoot
        try {
            $null = & git rev-parse --verify HEAD 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw 'git repository is not in a valid state after clone.'
            }

            $result = [System.Collections.Generic.List[string]]::new()
            foreach ($root in $Roots) {
                $entries = & git ls-tree -r --name-only HEAD -- $root 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "git ls-tree failed for root '$root'."
                }

                foreach ($entry in $entries) {
                    if ([string]::IsNullOrWhiteSpace($entry)) {
                        continue
                    }

                    $result.Add($entry.Trim())
                }
            }

            return @($result)
        }
        finally {
            Pop-Location
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Build-DependencyList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string[]]$Roots,

        [Parameter(Mandatory = $true)]
        [string]$PathFilterRegex
    )

    # APM accepts only these file package extensions:
    # .agent.md, .prompt.md, .instructions.md, .chatmode.md
    # Skills should be referenced as subdirectory packages (no file extension).
    $agentDeps = @(
        $Paths | Where-Object {
            $_.StartsWith('.github/agents/', [StringComparison]::OrdinalIgnoreCase) -and
            ($_ -match '\.agent\.md$')
        }
    )

    $promptDeps = @(
        $Paths | Where-Object {
            $_.StartsWith('.github/prompts/', [StringComparison]::OrdinalIgnoreCase) -and
            (($_ -match '\.prompt\.md$') -or ($_ -match '\.chatmode\.md$'))
        }
    )

    $instructionDeps = @(
        $Paths | Where-Object {
            $_.StartsWith('.github/instructions/', [StringComparison]::OrdinalIgnoreCase) -and
            ($_ -match '\.instructions\.md$')
        }
    )

    $skillDeps = @(
        $Paths |
            Where-Object {
                $_.StartsWith('.github/skills/', [StringComparison]::OrdinalIgnoreCase) -and
                ([string]::Equals([System.IO.Path]::GetFileName($_), 'SKILL.md', [StringComparison]::OrdinalIgnoreCase))
            } |
                ForEach-Object { (Split-Path -Path $_ -Parent).Replace('\', '/') } |
            Sort-Object -Unique
    )

    $selected = @($agentDeps + $promptDeps + $instructionDeps + $skillDeps)
    return @($selected | Sort-Object -Unique | ForEach-Object { "$Repository/$_" })
}

function Update-ApmDependencyList {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Dependencies
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "APM file not found: $Path"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $lines.Add($line)
    }

    $apmIndex = -1
    $apmIndent = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)apm:\s*(\[\])?\s*$') {
            $apmIndex = $i
            $apmIndent = $matches[1].Length
            break
        }
    }

    if ($apmIndex -lt 0) {
        throw "Could not find 'dependencies.apm' key in $Path"
    }

    $nextSibling = $lines.Count
    for ($j = $apmIndex + 1; $j -lt $lines.Count; $j++) {
        $line = $lines[$j]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $indent = Get-LeadingSpaceCount -Line $line
        if (($indent -eq $apmIndent) -and ($line.Trim() -match '^[A-Za-z0-9_-]+:\s*')) {
            $nextSibling = $j
            break
        }
    }

    $removeCount = $nextSibling - ($apmIndex + 1)
    if ($removeCount -gt 0) {
        $lines.RemoveRange($apmIndex + 1, $removeCount)
    }

    $itemIndent = ' ' * ($apmIndent + 2)
    $insertion = [System.Collections.Generic.List[string]]::new()
    foreach ($dep in $Dependencies) {
        $insertion.Add("$itemIndent- $dep")
    }

    if ($insertion.Count -eq 0) {
        $insertion.Add("$itemIndent# No matching files were found")
    }

    $lines.InsertRange($apmIndex + 1, $insertion)
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Write-Host "Reading repository tree from $RepoSlug@$Ref..." -ForegroundColor Cyan
        $paths = Get-RepoTreePaths -Repository $RepoSlug -GitRef $Ref -Roots $IncludeRoots

        $deps = Build-DependencyList -Paths $paths -Repository $RepoSlug -Roots $IncludeRoots -PathFilterRegex $IncludeRegex
        if ($null -eq $deps) {
            $deps = @()
        }
        Write-Host "Found $($deps.Count) dependencies." -ForegroundColor Green

        if ($DryRun) {
            $deps | ForEach-Object { Write-Host "- $_" }
            exit 0
        }

        Update-ApmDependencyList -Path $ApmFile -Dependencies $deps
        Write-Host "Updated dependencies.apm in $ApmFile" -ForegroundColor Green
        exit 0
    }
    catch {
        Write-Error -ErrorAction Continue "Update-ApmDependencies failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution
