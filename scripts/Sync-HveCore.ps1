<#
.SYNOPSIS
    Syncs the local hve-core mirror from microsoft/hve-core on GitHub.

.DESCRIPTION
    Performs a sparse-checkout of the .github/agents, .github/instructions,
    .github/prompts and .github/skills folders from microsoft/hve-core
    at a specified commit or the latest deployment SHA, and copies them into the
    local hve-core/ mirror directory so that apm.yml can resolve dependencies
    without requiring microsoft org authentication.

    Run this script once to seed the mirror, then the GitHub Actions workflow
    (.github/workflows/sync-hve-core.yml) will keep it up to date automatically.

.PARAMETER Token
    GitHub Personal Access Token with repo read access to microsoft/hve-core.
    Defaults to the GH_TOKEN environment variable or the token from `gh auth token`.
    Not needed if microsoft/hve-core is a public repository.

.PARAMETER Ref
    Commit SHA or branch to check out from microsoft/hve-core.
    Defaults to the commit SHA of the latest deployment.

.PARAMETER Force
    Re-sync even if the mirror already matches the target ref.

.EXAMPLE
    # Seed the mirror from the latest deployment (no token needed for public repos)
    pwsh scripts/Sync-HveCore.ps1

.EXAMPLE
    # Seed from a specific commit or branch
    pwsh scripts/Sync-HveCore.ps1 -Ref main

.EXAMPLE
    # Force re-sync with a PAT (private repo)
    pwsh scripts/Sync-HveCore.ps1 -Token $env:MY_GH_PAT -Force
#>
[CmdletBinding()]
param(
    [string] $Token,
    [string] $Ref,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve repo root ──────────────────────────────────────────────────────
$RepoRoot    = Split-Path $PSScriptRoot -Parent
$MirrorDir   = Join-Path $RepoRoot 'hve-core'
$VersionFile = Join-Path $MirrorDir '.version'
$TempDir     = Join-Path ([System.IO.Path]::GetTempPath()) "hve-core-sync-$([System.IO.Path]::GetRandomFileName())"

# ── Prefer gh CLI for API calls (handles SAML SSO natively) ───────────────
$GhAvailable = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)

function Invoke-GhApi {
    param([string]$Path)
    if ($GhAvailable) {
        $result = gh api $Path --header 'Accept: application/vnd.github+json' 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ($result -match 'SAML') {
                Write-Error (@"
GitHub SAML SSO error. To fix:
  1. Run: gh auth refresh -s read:org
  2. When prompted, authorize the token for the 'microsoft' org at:
     https://github.com/organizations/microsoft/settings/oauth_application_policy
  3. Re-run this script.

If using a PAT (-Token), ensure it has been SSO-authorized:
  https://github.com/settings/tokens → click 'Configure SSO' next to your token
"@)
            }
            throw "gh api $Path failed: $result"
        }
        return $result | ConvertFrom-Json
    }
    # Fallback: Invoke-RestMethod with explicit token
    $headers = @{ Accept = 'application/vnd.github+json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    return Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers
}

# Resolve explicit token override into GH_TOKEN so gh CLI picks it up
if ($Token) {
    $env:GH_TOKEN = $Token
    Write-Host "Using supplied -Token." -ForegroundColor DarkGray
} elseif (-not $GhAvailable) {
    # No gh CLI and no token — check env
    if (-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) {
        Write-Warning "gh CLI not found and no token supplied. API calls may be rate-limited or blocked by SAML SSO."
        Write-Warning "Install gh CLI (https://cli.github.com/) and run 'gh auth login', then retry."
    }
}

# ── Resolve target ref ─────────────────────────────────────────────────────
if (-not $Ref) {
    Write-Host "Fetching latest hve-core deployment..." -ForegroundColor Cyan
    $deployments = Invoke-GhApi 'repos/microsoft/hve-core/deployments?per_page=1'
    $latest = $deployments | Select-Object -First 1
    $Ref = $latest.sha
    Write-Host "Latest deployment: #$($latest.id) ($($latest.environment)) @ $($Ref.Substring(0,7))" -ForegroundColor Green
}

# $Ref is already a full commit SHA (from the deployments API) or a user-supplied ref.
# For user-supplied branch names, resolve to the commit SHA.
$TargetSHA = if ($Ref -match '^[0-9a-f]{40}$') {
    $Ref  # already a full SHA
} else {
    $branchData = Invoke-GhApi "repos/microsoft/hve-core/branches/$Ref"
    $branchData.commit.sha
}

Write-Host "Target commit: $TargetSHA" -ForegroundColor Cyan

# ── Check if mirror is already up to date ────────────────────────────────
if (-not $Force -and (Test-Path $VersionFile)) {
    $current = (Get-Content $VersionFile -Raw).Trim()
    if ($current -eq $TargetSHA) {
        Write-Host "Mirror is already at $Ref ($TargetSHA) — nothing to do." -ForegroundColor Yellow
        Write-Host "Use -Force to re-sync anyway."
        exit 0
    }
    Write-Host "Updating mirror from $current → $TargetSHA" -ForegroundColor Cyan
}

# ── Clone with sparse checkout ────────────────────────────────────────────
Write-Host "Cloning microsoft/hve-core (sparse, .github/ only)..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    # Resolve clone URL — prefer gh CLI credential helper so SAML SSO is handled
    $CloneUrl = if ($GhAvailable) {
        # gh CLI credential helper embeds the SAML-authorized session token automatically
        $ghToken = (gh auth token 2>$null).Trim()
        if ($ghToken) {
            "https://x-access-token:${ghToken}@github.com/microsoft/hve-core.git"
        } else {
            'https://github.com/microsoft/hve-core.git'
        }
    } elseif ($Token) {
        "https://x-access-token:${Token}@github.com/microsoft/hve-core.git"
    } else {
        'https://github.com/microsoft/hve-core.git'
    }

    git -C $TempDir init -q
    git -C $TempDir remote add origin $CloneUrl
    git -C $TempDir sparse-checkout init --cone
    git -C $TempDir sparse-checkout set .github/agents .github/instructions .github/prompts .github/skills
    git -C $TempDir fetch --depth=1 origin $TargetSHA
    git -C $TempDir checkout $TargetSHA

    if ($LASTEXITCODE -ne 0) {
        throw "git checkout failed with exit code $LASTEXITCODE"
    }

    # ── Sync files into hve-core/ mirror ──────────────────────────────────
    Write-Host "Syncing .github/ into hve-core/ mirror..." -ForegroundColor Cyan
    $MirrorGithub = Join-Path $MirrorDir '.github'
    New-Item -ItemType Directory -Path $MirrorGithub -Force | Out-Null

    # Sync only the four subfolders
    foreach ($sub in @('agents', 'instructions', 'prompts', 'skills')) {
        $dest = Join-Path $MirrorGithub $sub
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        $src = Join-Path $TempDir ".github/$sub"
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $MirrorGithub -Recurse -Force
        }
    }

    # Write version file
    Set-Content -Path $VersionFile -Value $TargetSHA -NoNewline

    Write-Host ""
    Write-Host "Mirror updated to $Ref ($TargetSHA)" -ForegroundColor Green
    Write-Host "Location: $MirrorDir" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. git add hve-core/ apm.yml"
    Write-Host "  2. git commit -m 'chore(deps): seed hve-core mirror at $Ref'"
    Write-Host "  3. git push"
    Write-Host "  4. Run 'apm install' — no microsoft org auth required."

} finally {
    # Clean up temp clone
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
