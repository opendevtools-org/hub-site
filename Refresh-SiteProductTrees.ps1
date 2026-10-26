<#
.SYNOPSIS
  Copy product trees onto a site root without touching site-owned files.

.PARAMETER Upstream
  Product / submodule directory.

.PARAMETER SiteRoot
  Site instance root (parent of upstream/).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Upstream,
  [Parameter(Mandatory = $true)][string]$SiteRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Copy-ProductTree {
  param(
    [string]$Source,
    [string]$Destination,
    [string]$SkipPrefix = ""
  )
  if (-not (Test-Path -LiteralPath $Source)) { return }
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  Get-ChildItem -LiteralPath $Source -Recurse -File -Force | Where-Object {
    $_.Name -notlike '*.pyc' -and $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and $_.FullName -notmatch '[\\/]\.pytest_cache[\\/]'
  } | ForEach-Object {
    $rel = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
    $posix = $rel -replace '\\', '/'
    if ($SkipPrefix) {
      if ($posix -eq $SkipPrefix -or $posix.StartsWith("$SkipPrefix/")) { return }
    }
    $target = Join-Path $Destination $rel
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}

function Copy-DockerExamples {
  param([string]$Source, [string]$Destination)
  if (-not (Test-Path -LiteralPath $Source)) { return }
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  Get-ChildItem -LiteralPath $Source -Recurse -File -Force | ForEach-Object {
    $name = $_.Name
    if ($name -ne "README.md" -and $name -ne ".gitkeep" -and -not $name.EndsWith(".example")) {
      return
    }
    $rel = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $rel
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}

function Copy-MissingTree {
  param([string]$Source, [string]$Destination)
  if (-not (Test-Path -LiteralPath $Source)) { return }
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  Get-ChildItem -LiteralPath $Source -Recurse -File -Force | Where-Object {
    $_.Name -notlike '*.pyc' -and $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and $_.FullName -notmatch '[\\/]\.pytest_cache[\\/]'
  } | ForEach-Object {
    $rel = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
    $target = Join-Path $Destination $rel
    if (Test-Path -LiteralPath $target) { return }
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $target
  }
}

Copy-MissingTree -Source (Join-Path $Upstream "plugins") -Destination (Join-Path $SiteRoot "plugins")
Copy-MissingTree -Source (Join-Path $Upstream "site-catalog") -Destination (Join-Path $SiteRoot "site-catalog")
$sitePlugins = Join-Path $SiteRoot "site-plugins.json"
if (-not (Test-Path -LiteralPath $sitePlugins)) {
  $fromCatalog = Join-Path $Upstream "site-catalog\site-plugins.json"
  $fromRoot = Join-Path $Upstream "site-plugins.json"
  if (Test-Path -LiteralPath $fromRoot) {
    Copy-Item -LiteralPath $fromRoot -Destination $sitePlugins
  } elseif (Test-Path -LiteralPath $fromCatalog) {
    Copy-Item -LiteralPath $fromCatalog -Destination $sitePlugins
  }
}

Copy-ProductTree -Source (Join-Path $Upstream "scriptkit") -Destination (Join-Path $SiteRoot "scriptkit")
Copy-ProductTree -Source (Join-Path $Upstream "agent-context") -Destination (Join-Path $SiteRoot "agent-context") -SkipPrefix "site"
Copy-DockerExamples -Source (Join-Path $Upstream "docker") -Destination (Join-Path $SiteRoot "docker")

$pkmScripts = Join-Path $Upstream "pkm-scripts"
$pkmDestRoot = Join-Path $SiteRoot "data\pkm\scripts"
if (Test-Path -LiteralPath $pkmScripts) {
  New-Item -ItemType Directory -Path $pkmDestRoot -Force | Out-Null
  Get-ChildItem -LiteralPath $pkmScripts -Directory -Force | ForEach-Object {
    $dest = Join-Path $pkmDestRoot $_.Name
    if (Test-Path -LiteralPath (Join-Path $dest "manifest.json")) { return }
    Copy-ProductTree -Source $_.FullName -Destination $dest
  }
}

$exampleApps = Join-Path $Upstream "docker-compose.apps.example.yml"
if (Test-Path -LiteralPath $exampleApps) {
  Copy-Item -LiteralPath $exampleApps -Destination (Join-Path $SiteRoot "docker-compose.apps.example.yml") -Force
}
$exampleCustom = Join-Path $Upstream "docker-compose.custom.example.yml"
if (Test-Path -LiteralPath $exampleCustom) {
  Copy-Item -LiteralPath $exampleCustom -Destination (Join-Path $SiteRoot "docker-compose.custom.example.yml") -Force
}

New-Item -ItemType Directory -Path (Join-Path $SiteRoot "cli") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SiteRoot "agent-context\site") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SiteRoot "docker\pkm-backend") -Force | Out-Null

$cliReadmeSrc = Join-Path $Upstream "cli\README.md"
$cliReadmeDst = Join-Path $SiteRoot "cli\README.md"
if ((Test-Path -LiteralPath $cliReadmeSrc) -and -not (Test-Path -LiteralPath $cliReadmeDst)) {
  Copy-Item -LiteralPath $cliReadmeSrc -Destination $cliReadmeDst
}

$siteReadmeSrc = Join-Path $Upstream "agent-context\site\README.md"
$siteReadmeDst = Join-Path $SiteRoot "agent-context\site\README.md"
if ((Test-Path -LiteralPath $siteReadmeSrc) -and -not (Test-Path -LiteralPath $siteReadmeDst)) {
  Copy-Item -LiteralPath $siteReadmeSrc -Destination $siteReadmeDst
}
