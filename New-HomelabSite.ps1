<#
.SYNOPSIS
  Converts a flat homelab-deploy install into a site instance (in place).

.DESCRIPTION
  Default: transform THIS folder (where the script lives) into:

    ./upstream/                 # git submodule → opendevtools-org/homelab-deploy
    ./data/                     # your volumes (kept)
    ./.env                      # your secrets (kept, never committed)
    ./docker-compose.config.yml # one-time PKM data ownership
    ./docker-compose.custom.yml  # Hub/PKM image overlay
    ./docker-compose.apps.yml   # extra apps / Market plugins
    ./.gitignore                # generated from .gitignore.upstream + .gitignore.custom
    ./README.md

  The old flat product files at the root (docker-compose.yml, etc.) are removed
  because they now live inside upstream/. Optionally links the folder to -SiteRepo
  on an orphan branch and pushes.

.PARAMETER SiteRepo
  Your git remote (e.g. company repo). Required unless -SkipGit.

.PARAMETER Branch
  Orphan branch name on SiteRepo. Default: homelab

.PARAMETER TargetDir
  Folder to convert. Default: directory containing this script (the flat install).

.PARAMETER UpstreamUrl
  Product submodule URL.

.PARAMETER Ports
  lan | local. Default: lan

.PARAMETER SkipGit
  Only restructure files + submodule; do not rebind remotes / push.

.PARAMETER Push
  Push the orphan branch to SiteRepo.

.PARAMETER Start
  docker compose up -d after conversion.

.EXAMPLE
  cd C:\Projects\homelab-deploy
  .\New-HomelabSite.ps1 -SiteRepo https://github.com/org/tools.git -Push -Start
#>
[CmdletBinding()]
param(
  [string]$SiteRepo = "",
  [string]$Branch = "homelab",
  [string]$TargetDir = "",
  [string]$UpstreamUrl = "https://github.com/opendevtools-org/homelab-deploy.git",

  [ValidateSet("lan", "local")]
  [string]$Ports = "lan",

  [switch]$SkipGit,
  [switch]$Push,
  [switch]$Start,
  [switch]$SkipCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & git @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    throw ("git {0} failed (exit {1}): {2}" -f ($GitArgs -join " "), $code, (($output | Out-String).Trim()))
  }
  return $output
}

function Invoke-GitQuiet {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $null = & git @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return $code
}

# Docker Desktop on locked/RDP/corporate Windows sessions often cannot
# unlock the credential store. Public pulls can proceed with an empty
# Docker config and the desktop helper removed from PATH.
$script:UseAnonymousDockerConfig = $false
$script:AnonymousDockerConfig = $null

function Test-DockerCredentialHelperError {
  param($Output)
  $text = ($Output | ForEach-Object { [string]$_ }) -join "`n"
  return [bool]($text -match '(?i)error getting credentials|logon session does not exist|sessione di accesso')
}

function Initialize-AnonymousDockerConfig {
  if ($script:AnonymousDockerConfig) { return }
  $script:UseAnonymousDockerConfig = $true
  $script:AnonymousDockerConfig = Join-Path ([IO.Path]::GetTempPath()) ("homelab-docker-anonymous-" + [guid]::NewGuid().ToString("n"))
  [IO.Directory]::CreateDirectory($script:AnonymousDockerConfig) | Out-Null
  [IO.File]::WriteAllText((Join-Path $script:AnonymousDockerConfig "config.json"), "{}", [Text.UTF8Encoding]::new($false))
}

function Clear-AnonymousDockerConfig {
  if ($script:AnonymousDockerConfig -and (Test-Path -LiteralPath $script:AnonymousDockerConfig)) {
    Remove-Item -LiteralPath $script:AnonymousDockerConfig -Recurse -Force -ErrorAction SilentlyContinue
  }
  $script:AnonymousDockerConfig = $null
  $script:UseAnonymousDockerConfig = $false
}

function Get-DotEnvValue {
  param([string]$Path, [string]$Key)
  if (-not (Test-Path -LiteralPath $Path)) { return "" }
  $found = ""
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    if ($line -match ("^\s*{0}=(.*)$" -f [regex]::Escape($Key))) {
      $found = $Matches[1].Trim().Trim('"').Trim("'")
    }
  }
  return $found
}

function Test-HttpsOverlayEnabled {
  param([string]$Root)
  $envPath = Join-Path $Root ".env"
  $overlay = Join-Path $Root "docker-compose.https.yml"
  if (-not (Test-Path -LiteralPath $envPath) -or -not (Test-Path -LiteralPath $overlay)) {
    return $false
  }
  $hub = Get-DotEnvValue $envPath "HUB_HOSTNAME"
  $pkm = Get-DotEnvValue $envPath "PKM_HOSTNAME"
  return -not [string]::IsNullOrWhiteSpace($hub) -and -not [string]::IsNullOrWhiteSpace($pkm)
}

function Invoke-DockerCommand {
  param([string[]]$DockerArgs)

  if (-not $script:UseAnonymousDockerConfig) {
    $output = & docker @DockerArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Host $line }
    if ($code -eq 0) { return 0 }
    if (-not (Test-DockerCredentialHelperError $output)) { return $code }

    Write-Warning "Docker Desktop credential helper is unavailable in this Windows session; retrying public image access without a credential store."
    Initialize-AnonymousDockerConfig
  }

  $dockerPath = (Get-Command docker.exe -ErrorAction Stop).Source
  $dockerBin = (Split-Path -Parent $dockerPath).TrimEnd("\")
  $previousPath = $env:PATH
  try {
    $env:PATH = (($previousPath -split ";" | Where-Object {
      $_ -and -not [string]::Equals($_.Trim().Trim('"').TrimEnd("\"), $dockerBin, [StringComparison]::OrdinalIgnoreCase)
    }) -join ";")
    & $dockerPath --config $script:AnonymousDockerConfig @DockerArgs 2>&1 | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
  } finally {
    $env:PATH = $previousPath
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $text = $Content.TrimEnd() + "`n"
  [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Test-TcpPortBusy([int]$Port) {
  foreach ($ip in @([Net.IPAddress]::Any, [Net.IPAddress]::Loopback)) {
    $listener = $null
    try {
      $listener = New-Object System.Net.Sockets.TcpListener ($ip, $Port)
      $listener.Start()
    } catch {
      return $true
    } finally {
      if ($null -ne $listener) {
        try { $listener.Stop() } catch {}
      }
    }
  }
  return $false
}

function Get-FreeTcpPort([int]$Preferred, [System.Collections.Generic.HashSet[int]]$Taken) {
  for ($p = $Preferred; $p -lt ($Preferred + 400); $p++) {
    if ($Taken.Contains($p)) { continue }
    if (Test-TcpPortBusy $p) { continue }
    [void]$Taken.Add($p)
    return $p
  }
  throw "No free TCP port from $Preferred"
}

function Write-SitePortFiles([string]$Root, [string]$Mode) {
  $backend = Join-Path $Root "docker-compose.ports.yml"
  $frontend = Join-Path $Root "docker-compose.frontend.ports.yml"
  if ((Test-Path -LiteralPath $backend) -or (Test-Path -LiteralPath $frontend)) {
    Write-Host "Ports      : kept from the site compose files"
    return
  }
  $taken = New-Object 'System.Collections.Generic.HashSet[int]'
  $hubApi = Get-FreeTcpPort 8090 $taken
  $hubUi = Get-FreeTcpPort 3080 $taken
  $pkmApi = Get-FreeTcpPort 8001 $taken
  $pkmUi = Get-FreeTcpPort 3030 $taken
  $publish = {
    param([int]$HostPort, [int]$ContainerPort)
    if ($Mode -eq "local") { return "127.0.0.1:${HostPort}:${ContainerPort}" }
    return "${HostPort}:${ContainerPort}"
  }
  $hubApiPub = & $publish $hubApi 8090
  $hubUiPub = & $publish $hubUi 80
  $pkmApiPub = & $publish $pkmApi 8000
  $pkmUiPub = & $publish $pkmUi 80
  $origin = if ($Mode -eq "local") {
    "http://127.0.0.1:$hubUi"
  } else {
    '${HUB_PUBLIC_URL:-http://127.0.0.1:' + $hubUi + '}'
  }
  $be = @(
    "# Site ports. Chosen once from free host ports. Update keeps this file.",
    "services:",
    "  hub-platform:",
    "    ports: !override",
    "      - `"$hubApiPub`"",
    "    environment:",
    "      PUBLIC_PKM_URL: `"http://127.0.0.1:$pkmUi/`"",
    "      BUILTIN_PKM_PORT: `"$pkmUi`"",
    "  pkm-backend:",
    "    ports: !override",
    "      - `"$pkmApiPub`""
  ) -join "`n"
  $feHead = @(
    "# Site web ports. Chosen once from free host ports. Update keeps this file.",
    "services:",
    "  hub:",
    "    ports: !override",
    "      - `"$hubUiPub`"",
    "    environment:",
    "      HUB_BROWSER_ORIGIN: `"$origin`""
  ) -join "`n"
  $feCmd = @'
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        if [ -n "$$HUB_BROWSER_ORIGIN" ]; then
          sed -i "s#http://127.0.0.1:8092#$$HUB_BROWSER_ORIGIN#g" /usr/share/nginx/html/main.dart.js
        fi
        exec /docker-entrypoint.sh nginx -g "daemon off;"
  pkm-frontend:
    ports: !override
'@
  $fe = $feHead + "`n" + $feCmd + "`n      - `"$pkmUiPub`"`n"
  Write-Utf8NoBom $backend $be
  Write-Utf8NoBom $frontend $fe
  Write-Host ("Ports      : hub {0}  api {1}  pkm {2}  pkm-api {3}" -f $hubUi, $hubApi, $pkmUi, $pkmApi)
}

function Get-GitIgnoreExtras([string]$ExistingText, [string]$ProductText) {
  $productLines = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($line in ($ProductText -split "`r?`n")) {
    $t = $line.TrimEnd()
    if ($t) { [void]$productLines.Add($t) }
  }
  $extras = New-Object System.Collections.Generic.List[string]
  foreach ($line in ($ExistingText -split "`r?`n")) {
    $t = $line.TrimEnd()
    if (-not $t) { continue }
    if ($t.StartsWith("# Generated")) { continue }
    if ($t.StartsWith("# Site-specific")) { continue }
    if ($t.StartsWith("# Site extras")) { continue }
    if ($t.StartsWith("# Product rules")) { continue }
    if ($productLines.Contains($t)) { continue }
    $extras.Add($t)
  }
  return $extras
}

function Write-LayeredGitIgnore {
  param(
    [string]$ProductPath,
    [string]$SnapshotPath,
    [string]$CustomPath,
    [string]$EffectivePath,
    [string]$BakCustom = "",
    [string]$BakIgnore = ""
  )
  $placeholder = "# Site-specific ignore rules go here. Product rules are in .gitignore.upstream."
  $product = ""
  if (Test-Path $ProductPath) {
    Copy-Item $ProductPath $SnapshotPath -Force
    $product = [System.IO.File]::ReadAllText($ProductPath).TrimEnd()
  }
  if (-not (Test-Path $CustomPath)) {
    if ($BakCustom -and (Test-Path $BakCustom)) {
      Copy-Item $BakCustom $CustomPath -Force
    } else {
      $extras = @()
      if ($BakIgnore -and (Test-Path $BakIgnore) -and $product) {
        $extras = @(Get-GitIgnoreExtras ([System.IO.File]::ReadAllText($BakIgnore)) $product)
      }
      if ($extras.Count -gt 0) {
        Write-Utf8NoBom $CustomPath (($extras -join "`n") + "`n")
      } else {
        Write-Utf8NoBom $CustomPath $placeholder
      }
    }
  }
  $custom = if (Test-Path $CustomPath) { [System.IO.File]::ReadAllText($CustomPath).Trim() } else { $placeholder }
  if (-not $product) {
    Write-Utf8NoBom $EffectivePath $(if ($custom) { $custom } else { $placeholder })
    return
  }
  $header = @"
# Generated. Do not edit this file.
# Product rules: .gitignore.upstream (refreshed by Update-HomelabUpstream).
# Site extras: .gitignore.custom
"@
  $content = "$header`n$product`n"
  if ($custom) { $content += "`n# Site extras from .gitignore.custom.`n$custom`n" }
  Write-Utf8NoBom $EffectivePath $content
}

Assert-Command git
if ($Start) { Assert-Command docker }
if (-not $SkipGit -and -not $SiteRepo) {
  throw "Pass -SiteRepo <url> (your repo) or -SkipGit for local-only conversion."
}

$scriptRoot = $PSScriptRoot
if (-not $TargetDir) { $TargetDir = $scriptRoot }
$TargetDir = [System.IO.Path]::GetFullPath($TargetDir)
$portsFile = if ($Ports -eq "local") { "docker-compose.local.yml" } else { "docker-compose.lan.yml" }
$frontendPortsFile = if ($Ports -eq "local") { "docker-compose.frontend.local.yml" } else { "docker-compose.frontend.lan.yml" }

if (-not (Test-Path $TargetDir)) {
  throw ("TargetDir not found: {0}" -f $TargetDir)
}

$alreadySite = (Test-Path (Join-Path $TargetDir "upstream\docker-compose.yml")) -or
  (Test-Path (Join-Path $TargetDir "upstream\docker-compose.backend.yml"))
$isFlat = (Test-Path (Join-Path $TargetDir "docker-compose.yml")) -or
  (Test-Path (Join-Path $TargetDir "docker-compose.backend.yml"))
if (-not $alreadySite -and -not $isFlat) {
  throw "TargetDir is neither a flat homelab-deploy install nor an existing site (missing docker-compose.yml and upstream/)."
}

Write-Host ("Mode       : in-place convert")
Write-Host ("TargetDir  : {0}" -f $TargetDir)
Write-Host ("SiteRepo   : {0}" -f $(if ($SiteRepo) { $SiteRepo } else { "(skip git remote)" }))
Write-Host ("Branch     : {0}" -f $Branch)
Write-Host ("Upstream   : {0}" -f $UpstreamUrl)
Write-Host ("Ports      : {0}" -f $portsFile)

# --- backup site-owned files ---
$bak = Join-Path $env:TEMP ("homelab-inplace-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Write-Host ("Backup     : {0}" -f $bak)

$dataSrc = Join-Path $TargetDir "data"
if (Test-Path $dataSrc) {
  robocopy $dataSrc (Join-Path $bak "data") /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  if ($LASTEXITCODE -ge 8) { throw ("robocopy data backup failed (exit {0})" -f $LASTEXITCODE) }
}
foreach ($name in @(".env", "docker-compose.custom.yml", "docker-compose.apps.yml", ".env.example", ".gitignore", ".gitignore.custom")) {
  $p = Join-Path $TargetDir $name
  if (Test-Path $p) { Copy-Item $p (Join-Path $bak $name) -Force }
}
foreach ($name in @("site-plugins.json")) {
  $p = Join-Path $TargetDir $name
  if (Test-Path $p) { Copy-Item $p (Join-Path $bak $name) -Force }
}
foreach ($dir in @("docker", "cli", "plugins", "site-catalog")) {
  $p = Join-Path $TargetDir $dir
  if (Test-Path $p) {
    robocopy $p (Join-Path $bak $dir) /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ("robocopy {0} backup failed (exit {1})" -f $dir, $LASTEXITCODE) }
  }
}
$siteNotes = Join-Path $TargetDir "agent-context\site"
if (Test-Path $siteNotes) {
  robocopy $siteNotes (Join-Path $bak "agent-context\site") /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  if ($LASTEXITCODE -ge 8) { throw ("robocopy agent-context/site backup failed (exit {0})" -f $LASTEXITCODE) }
}

Set-Location $TargetDir

# --- detach product git (flat clone of homelab-deploy) ---
$gitDir = Join-Path $TargetDir ".git"
if (Test-Path $gitDir) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $remotes = @(& git remote -v 2>&1)
  $ErrorActionPreference = $prev
  $isProductClone = ($remotes -join "`n") -match "homelab-deploy"
  $hasUpstreamSub = Test-Path (Join-Path $TargetDir ".gitmodules")

  if ($isProductClone -and -not $alreadySite) {
    Write-Host "Detaching product .git (was a homelab-deploy clone)..."
    Remove-Item $gitDir -Recurse -Force
  } elseif ($alreadySite -and -not $SkipGit -and $SiteRepo) {
    # Re-bind site remote if needed
    $null = Invoke-GitQuiet remote remove origin
    Invoke-Git remote add origin $SiteRepo | Out-Null
  }
}

# --- remove flat product files from root (they will live under upstream/) ---
if (-not $alreadySite) {
  $productFiles = @(
    "docker-compose.yml",
    "docker-compose.backend.yml",
    "docker-compose.frontend.yml",
    "docker-compose.lan.yml",
    "docker-compose.local.yml",
    "docker-compose.frontend.lan.yml",
    "docker-compose.frontend.local.yml",
    "docker-compose.frontend.remote.yml",
    "docker-compose.https.yml",
    "Caddyfile",
    "docker-compose.apps.example.yml",
    "docker-compose.custom.yml",
    "docker-compose.custom.example.yml",
    "LICENSE",
    "README.md",
    "New-HomelabSite.ps1",
    "New-HomelabSite.sh",
    "Update-HomelabUpstream.ps1",
    "Update-HomelabUpstream.sh",
    "Backup-DataGit.ps1",
    "Backup-DataGit.sh",
    "Register-DataGitBackupTask.ps1",
    "Register-DataGitBackup.sh",
    "Pull-DataGit.ps1",
    "Pull-DataGit.sh",
    "Pull.ps1",
    "Pull.sh",
    "Start-MarketPlugins.ps1",
    "Start-MarketPlugins.sh",
    "Run-HomelabSite.ps1",
    "Run-HomelabSite.sh",
    "Pull-PkmDataKeepScripts.ps1",
    "Pull-PkmDataKeepScripts.sh",
    "Collect-HomelabDiag.ps1",
    "Collect-HomelabDiag.sh",
    "Dump-PkmSidebar.py",
    "Register-DataGitPullTask.ps1",
    "Register-DataGitPull.sh",
    "Reindex-PkmFromDisk.ps1",
    "Reindex-PkmFromDisk.sh",
    "Merge-SqliteGitConflict.py",
    "Normalize-PkmDuplicatePaths.py",
    "docker-compose.config.yml",
    "Refresh-SiteProductTrees.sh",
    "Refresh-SiteProductTrees.ps1"
  )
  foreach ($f in $productFiles) {
    $p = Join-Path $TargetDir $f
    if (Test-Path $p) {
      Remove-Item $p -Force
    }
  }
  # keep data/, .env for now; will refresh from backup after submodule
}

# --- git site repo (orphan branch) ---
if (-not $SkipGit) {
  if (-not (Test-Path (Join-Path $TargetDir ".git"))) {
    Write-Host "Initializing site git repo..."
    Invoke-Git init -b main | Out-Null
    Invoke-Git remote add origin $SiteRepo | Out-Null
    if ((Invoke-GitQuiet config user.name) -ne 0) { Invoke-Git config user.name "Homelab Setup" | Out-Null }
    if ((Invoke-GitQuiet config user.email) -ne 0) { Invoke-Git config user.email "homelab@localhost" | Out-Null }
  } else {
    $null = Invoke-GitQuiet remote remove origin
    $null = Invoke-GitQuiet remote add origin $SiteRepo
  }

  $null = Invoke-GitQuiet fetch origin

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $existsRemote = @(& git ls-remote --heads origin $Branch 2>&1)
  $ErrorActionPreference = $prev
  $branchExists = ($existsRemote -join "`n") -match ("refs/heads/{0}\b" -f [regex]::Escape($Branch))

  $cur = ""
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $curOut = & git rev-parse --abbrev-ref HEAD 2>&1
  if ($LASTEXITCODE -eq 0) { $cur = "$curOut".Trim() }
  $ErrorActionPreference = $prev

  if ($branchExists) {
    Write-Host ("Checking out site branch {0}" -f $Branch)
    Invoke-Git fetch origin $Branch | Out-Null
    # Don't wipe data: we already backed up. Reset index to branch then rebuild files.
    Invoke-Git checkout -B $Branch ("origin/{0}" -f $Branch) | Out-Null
  } elseif ($cur -eq $Branch) {
    Write-Host ("Already on orphan/site branch {0}" -f $Branch)
  } else {
    Write-Host ("Creating orphan branch {0}" -f $Branch)
    # Ensure at least one commit exists for orphan, or checkout --orphan on unborn repo
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $null = & git rev-parse HEAD 2>&1
    $hasHead = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if ($hasHead) {
      Invoke-Git checkout --orphan $Branch | Out-Null
    } else {
      Invoke-Git checkout -B $Branch | Out-Null
    }
    $null = Invoke-GitQuiet rm -rf --ignore-unmatch .
  }
}

# --- ensure submodule upstream ---
Set-Location $TargetDir
if (Test-Path (Join-Path $TargetDir "upstream\.git")) {
  Write-Host "upstream/ submodule already present."
} elseif (Test-Path (Join-Path $TargetDir "upstream")) {
  Remove-Item (Join-Path $TargetDir "upstream") -Recurse -Force
  Write-Host "Adding upstream submodule..."
  if (-not $SkipGit -and (Test-Path (Join-Path $TargetDir ".git"))) {
    Invoke-Git submodule add --force $UpstreamUrl upstream | Out-Null
  } else {
    Invoke-Git clone $UpstreamUrl (Join-Path $TargetDir "upstream") | Out-Null
  }
} else {
  Write-Host "Adding upstream submodule..."
  if (-not $SkipGit -and (Test-Path (Join-Path $TargetDir ".git"))) {
    # Clear stale gitmodule entries
    $null = Invoke-GitQuiet submodule deinit -f upstream
    $null = Invoke-GitQuiet rm -f upstream
    if (Test-Path (Join-Path $TargetDir ".gitmodules")) {
      Remove-Item (Join-Path $TargetDir ".gitmodules") -Force -ErrorAction SilentlyContinue
    }
    Invoke-Git submodule add --force $UpstreamUrl upstream | Out-Null
  } else {
    Invoke-Git clone $UpstreamUrl (Join-Path $TargetDir "upstream") | Out-Null
  }
}

# --- restore site files ---
Write-Host "Restoring data/ and site overlay..."
if (Test-Path (Join-Path $bak "data")) {
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir "data") | Out-Null
  robocopy (Join-Path $bak "data") (Join-Path $TargetDir "data") /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  if ($LASTEXITCODE -ge 8) { throw ("robocopy data restore failed (exit {0})" -f $LASTEXITCODE) }
} else {
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir "data\hub"), (Join-Path $TargetDir "data\pkm") | Out-Null
}

foreach ($dir in @("plugins", "site-catalog")) {
  $saved = Join-Path $bak $dir
  if (-not (Test-Path -LiteralPath $saved)) { continue }
  $dest = Join-Path $TargetDir $dir
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  robocopy $saved $dest /E /XO /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  if ($LASTEXITCODE -ge 8) { throw ("robocopy {0} restore failed (exit {1})" -f $dir, $LASTEXITCODE) }
}
if ((Test-Path (Join-Path $bak "site-plugins.json")) -and -not (Test-Path (Join-Path $TargetDir "site-plugins.json"))) {
  Copy-Item (Join-Path $bak "site-plugins.json") (Join-Path $TargetDir "site-plugins.json") -Force
}
if (Test-Path (Join-Path $bak ".env")) {
  Copy-Item (Join-Path $bak ".env") (Join-Path $TargetDir ".env") -Force
} elseif (Test-Path (Join-Path $TargetDir "upstream\.env.example")) {
  Copy-Item (Join-Path $TargetDir "upstream\.env.example") (Join-Path $TargetDir ".env") -Force
  Write-Host "Created .env from upstream/.env.example - edit secrets if needed."
}

if (Test-Path (Join-Path $bak "docker-compose.apps.yml")) {
  Copy-Item (Join-Path $bak "docker-compose.apps.yml") (Join-Path $TargetDir "docker-compose.apps.yml") -Force
} elseif (Test-Path (Join-Path $TargetDir "upstream\docker-compose.apps.yml")) {
  Copy-Item (Join-Path $TargetDir "upstream\docker-compose.apps.yml") (Join-Path $TargetDir "docker-compose.apps.yml") -Force
} else {
  Write-Utf8NoBom (Join-Path $TargetDir "docker-compose.apps.yml") @"
# Optional extra backends for this host.
services: {}
"@
}
if (-not (Test-Path (Join-Path $TargetDir "docker-compose.frontend.apps.yml"))) {
  if (Test-Path (Join-Path $bak "docker-compose.frontend.apps.yml")) {
    Copy-Item (Join-Path $bak "docker-compose.frontend.apps.yml") (Join-Path $TargetDir "docker-compose.frontend.apps.yml") -Force
  } elseif (Test-Path (Join-Path $TargetDir "upstream\docker-compose.frontend.apps.yml")) {
    Copy-Item (Join-Path $TargetDir "upstream\docker-compose.frontend.apps.yml") (Join-Path $TargetDir "docker-compose.frontend.apps.yml") -Force
  } else {
    Write-Utf8NoBom (Join-Path $TargetDir "docker-compose.frontend.apps.yml") @"
# Optional extra frontends for this host.
services: {}
"@
  }
}
if (Test-Path (Join-Path $bak "docker-compose.custom.yml")) {
  Copy-Item (Join-Path $bak "docker-compose.custom.yml") (Join-Path $TargetDir "docker-compose.custom.yml") -Force
} elseif (Test-Path (Join-Path $TargetDir "upstream\docker-compose.custom.yml")) {
  Copy-Item (Join-Path $TargetDir "upstream\docker-compose.custom.yml") (Join-Path $TargetDir "docker-compose.custom.yml") -Force
} else {
  Write-Utf8NoBom (Join-Path $TargetDir "docker-compose.custom.yml") @"
# Site Hub/PKM overlay.
services: {}
"@
}

@(
  "hub-platform",
  "pkm-backend",
  "hub-frontend",
  "pkm-frontend"
) | ForEach-Object {
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir "overrides\$_") | Out-Null
}
if (Test-Path (Join-Path $bak "overrides")) {
  robocopy (Join-Path $bak "overrides") (Join-Path $TargetDir "overrides") /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  if ($LASTEXITCODE -ge 8) { throw ("robocopy overrides restore failed (exit {0})" -f $LASTEXITCODE) }
}
$upstreamOverrideReadme = Join-Path $TargetDir "upstream\overrides\README.md"
$siteOverrideReadme = Join-Path $TargetDir "overrides\README.md"
if ((Test-Path $upstreamOverrideReadme) -and -not (Test-Path $siteOverrideReadme)) {
  Copy-Item $upstreamOverrideReadme $siteOverrideReadme -Force
}

if (Test-Path (Join-Path $TargetDir "upstream\.env.example")) {
  Copy-Item (Join-Path $TargetDir "upstream\.env.example") (Join-Path $TargetDir ".env.example") -Force
}

$gitignoreSrc = Join-Path $TargetDir "upstream\.gitignore"
Write-LayeredGitIgnore `
  -ProductPath $gitignoreSrc `
  -SnapshotPath (Join-Path $TargetDir ".gitignore.upstream") `
  -CustomPath (Join-Path $TargetDir ".gitignore.custom") `
  -EffectivePath (Join-Path $TargetDir ".gitignore") `
  -BakCustom (Join-Path $bak ".gitignore.custom") `
  -BakIgnore (Join-Path $bak ".gitignore")

$readme = @"
# Homelab site instance

Converted from a flat ``homelab-deploy`` install.

- ``upstream/`` — git submodule ($UpstreamUrl) — product package
- ``data/`` — your Hub + PKM volumes
- ``docker-compose.config.yml`` — one-shot ownership (``data/pkm`` + CLI volumes)
- ``docker-compose.custom.yml`` — Hub/PKM image + cli mounts (site-owned)
- ``docker-compose.apps.yml`` — extra apps / Market plugins (site-owned)
- ``docker/`` — optional site Dockerfile (FROM published images)
- ``cli/`` — ``lib/`` + ``homelab/`` (product); all site CLIs under ``cli/custom/`` (not overwritten)
- ``scriptkit/`` — Python library for PKM launchers (refreshed from upstream)
- ``agent-context/`` — Hub/PKM notes for agents; extras in ``agent-context/site/``
- ``overrides/`` — optional code patches (see ``overrides/README.md``)
- ``.env`` — secrets (not committed)
- ``.gitignore`` — generated; edit ``.gitignore.custom`` for site extras
- ``Update-HomelabUpstream.ps1`` / ``.sh`` — pull product updates
- ``Backup-DataGit.ps1`` / ``.sh`` — primary server: commit/push site data
- ``Pull-DataGit.ps1`` / ``.sh`` — standby server: sync from origin
- ``Reindex-PkmFromDisk.ps1`` / ``.sh`` — after git sync, import PKM items from disk
- ``Caddyfile`` / ``docker-compose.https.yml`` — optional LAN HTTPS (clipboard paste)
- ``Register-DataGitBackup*`` / ``Register-DataGitPull*`` — daily schedules

## Start

``````bash
docker compose --project-directory . \\
  -f upstream/docker-compose.backend.yml \\
  -f upstream/$portsFile \\
  -f docker-compose.ports.yml \\
  -f docker-compose.custom.yml \\
  -f docker-compose.apps.yml \\
  -f docker-compose.config.yml up -d
docker compose --project-directory . \\
  -f upstream/docker-compose.frontend.yml \\
  -f upstream/$frontendPortsFile \\
  -f docker-compose.frontend.ports.yml up -d
# LAN HTTPS: add -f docker-compose.https.yml when HUB_HOSTNAME and PKM_HOSTNAME are set
``````

## Update product

``````bash
./Update-HomelabUpstream.sh --commit --push --start
# Windows: .\\Update-HomelabUpstream.ps1 -Commit -Push -Start
``````

## Git sync

Optional HTTPS auth in ``.env`` (not committed): ``HOMELAB_GIT_USERNAME`` and ``HOMELAB_GIT_PAT``.

Two servers with the same data:

- primary: ``Backup-DataGit`` (default 00:05)
- standby: ``Pull-DataGit`` (default 00:10)

If the same file changed on both sides, the remote copy stays canonical and the local copy is saved as ``name.local-conflict.HOST.TIMESTAMP.ext``.

After each sync, PKM restarts briefly and imports pages, files, PDFs, and bookmarks from disk (same as Import from disk in the UI). Set ``HOMELAB_PKM_REINDEX_AFTER_SYNC=false`` in ``.env`` to skip.

``````powershell
.\Register-DataGitBackupTask.ps1 -Time 00:05
.\Backup-DataGit.ps1
.\Register-DataGitPullTask.ps1 -Time 00:10
.\Pull-DataGit.ps1
``````

``````bash
./Register-DataGitBackup.sh --time 00:05
./Backup-DataGit.sh
./Register-DataGitPull.sh --time 00:10
./Pull-DataGit.sh
``````
"@
Write-Utf8NoBom (Join-Path $TargetDir "README.md") $readme

# Launchers at site root (from upstream product package)
foreach ($name in @(
  "Update-HomelabUpstream.ps1",
  "Update-HomelabUpstream.sh",
  "Backup-DataGit.ps1",
  "Backup-DataGit.sh",
  "Register-DataGitBackupTask.ps1",
  "Register-DataGitBackup.sh",
  "Pull-DataGit.ps1",
  "Pull-DataGit.sh",
  "Pull.ps1",
  "Pull.sh",
  "Start-MarketPlugins.ps1",
  "Start-MarketPlugins.sh",
  "Run-HomelabSite.ps1",
  "Run-HomelabSite.sh",
  "Pull-PkmDataKeepScripts.ps1",
  "Pull-PkmDataKeepScripts.sh",
  "Collect-HomelabDiag.ps1",
  "Collect-HomelabDiag.sh",
  "Dump-PkmSidebar.py",
  "Register-DataGitPullTask.ps1",
  "Register-DataGitPull.sh",
  "Reindex-PkmFromDisk.ps1",
  "Reindex-PkmFromDisk.sh",
  "Merge-SqliteGitConflict.py",
  "Normalize-PkmDuplicatePaths.py",
  "Refresh-SiteProductTrees.ps1",
  "Refresh-SiteProductTrees.sh",
  "docker-compose.config.yml",
  "docker-compose.https.yml",
  "Caddyfile"
)) {
  $src = Join-Path $TargetDir ("upstream\{0}" -f $name)
  if (Test-Path $src) {
    Copy-Item $src (Join-Path $TargetDir $name) -Force
  } else {
    Write-Host ("Warning: upstream/{0} missing; skip copy to site root." -f $name)
  }
}

$refreshHelper = Join-Path $TargetDir "upstream\Refresh-SiteProductTrees.ps1"
if (Test-Path -LiteralPath $refreshHelper) {
  & $refreshHelper -Upstream (Join-Path $TargetDir "upstream") -SiteRoot $TargetDir
}
$productOverride = Join-Path $TargetDir "upstream\overrides\hub-platform\sitecustomize.py"
$siteOverride = Join-Path $TargetDir "overrides\hub-platform\sitecustomize.py"
if (Test-Path -LiteralPath $productOverride) {
  New-Item -ItemType Directory -Force -Path (Split-Path $siteOverride) | Out-Null
  Copy-Item $productOverride $siteOverride -Force
}
$bakCli = Join-Path $bak "cli"
if (Test-Path -LiteralPath $bakCli) {
  New-Item -ItemType Directory -Path (Join-Path $TargetDir "cli") -Force | Out-Null
  robocopy $bakCli (Join-Path $TargetDir "cli") /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
}
$bakSiteNotes = Join-Path $bak "agent-context\site"
if (Test-Path -LiteralPath $bakSiteNotes) {
  New-Item -ItemType Directory -Path (Join-Path $TargetDir "agent-context\site") -Force | Out-Null
  robocopy $bakSiteNotes (Join-Path $TargetDir "agent-context\site") /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
}
$bakDocker = Join-Path $bak "docker"
if (Test-Path -LiteralPath $bakDocker) {
  Get-ChildItem -LiteralPath $bakDocker -Recurse -File -Force | ForEach-Object {
    $name = $_.Name
    if ($name -eq "README.md" -or $name -eq ".gitkeep" -or $name.EndsWith(".example")) { return }
    $rel = $_.FullName.Substring($bakDocker.Length).TrimStart('\', '/')
    $target = Join-Path (Join-Path $TargetDir "docker") $rel
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}

Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue

# --- commit / push ---
if (-not $SkipGit -and -not $SkipCommit -and (Test-Path (Join-Path $TargetDir ".git"))) {
  Set-Location $TargetDir
  $null = Invoke-GitQuiet rm --cached -f --ignore-unmatch .env
  Invoke-Git add -A | Out-Null
  $null = Invoke-GitQuiet rm --cached -f --ignore-unmatch .env

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $staged = @(& git diff --cached --name-only 2>&1)
  $ErrorActionPreference = $prev
  foreach ($f in $staged) {
    if ($f -eq ".env" -or "$f".EndsWith("/.env")) {
      throw ("Refusing to commit: .env is staged ({0})." -f $f)
    }
  }

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $porcelain = & git status --porcelain 2>&1
  $ErrorActionPreference = $prev
  if ($porcelain) {
    Invoke-Git commit -m "Homelab site instance: upstream submodule + local data/apps." | Out-Null
  } else {
    Write-Host "Nothing new to commit."
  }
}

Write-SitePortFiles $TargetDir $Ports
if (-not $SkipGit -and -not $SkipCommit -and (Test-Path (Join-Path $TargetDir ".git"))) {
  Set-Location $TargetDir
  Invoke-Git add -- docker-compose.ports.yml docker-compose.frontend.ports.yml | Out-Null
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $portStatus = @(& git status --porcelain -- docker-compose.ports.yml docker-compose.frontend.ports.yml 2>&1)
  $ErrorActionPreference = $prev
  if ($portStatus) {
    Invoke-Git commit -m "Record the host ports chosen for this site." | Out-Null
  }
}

if ($Push) {
  if ($SkipGit -or -not $SiteRepo) { throw "-Push requires -SiteRepo (and not -SkipGit)." }
  Set-Location $TargetDir
  Write-Host ("Pushing {0} ..." -f $Branch)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & git push -u origin $Branch 2>&1 | Out-Null
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    Write-Host "Push failed; retrying with --force-with-lease ..."
    Invoke-Git push --force-with-lease -u origin $Branch | Out-Null
  }
}

if ($Start) {
  Set-Location $TargetDir
  if (-not (Test-Path (Join-Path $TargetDir ".env"))) {
    throw "Missing .env"
  }
  # Stop old flat project containers if names conflict
  Write-Host "Starting Compose (backend then frontend)..."
  $prev = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    foreach ($n in @("pkm-backend", "pkm-frontend", "home-hub", "home-hub-platform", "pkm-https")) {
      & docker rm -f $n 2>&1 | Out-Null
    }
    $backendComposeArgs = @(
      "compose", "--project-directory", ".",
      "-f", "upstream/docker-compose.backend.yml",
      "-f", ("upstream/{0}" -f $portsFile)
    )
    if (Test-Path -LiteralPath (Join-Path $TargetDir "docker-compose.ports.yml")) {
      $backendComposeArgs += @("-f", "docker-compose.ports.yml")
    }
    $backendComposeArgs += @(
      "-f", "docker-compose.custom.yml",
      "-f", "docker-compose.apps.yml",
      "-f", "docker-compose.config.yml"
    )
    $code = Invoke-DockerCommand ($backendComposeArgs + @("pull"))
    if ($code -ne 0) { throw "docker compose pull failed" }
    $code = Invoke-DockerCommand ($backendComposeArgs + @("up", "-d"))
    if ($code -ne 0) { throw "docker compose up failed" }
    $null = Invoke-DockerCommand ($backendComposeArgs + @("rm", "--force"))
    $gone = & docker ps -aq --filter "label=homelab.config-job=true" --filter "status=exited" 2>$null
    if ($gone) { $null = & docker rm -f @gone 2>$null }
    $frontendComposeArgs = @(
      "compose", "--project-directory", ".",
      "-f", "upstream/docker-compose.frontend.yml",
      "-f", ("upstream/{0}" -f $frontendPortsFile)
    )
    if (Test-Path -LiteralPath (Join-Path $TargetDir "docker-compose.frontend.ports.yml")) {
      $frontendComposeArgs += @("-f", "docker-compose.frontend.ports.yml")
    }
    if (Test-HttpsOverlayEnabled $TargetDir) {
      Write-Host "LAN HTTPS overlay (Caddy) enabled."
      $frontendComposeArgs += @("-f", "docker-compose.https.yml")
    }
    $code = Invoke-DockerCommand ($frontendComposeArgs + @("pull"))
    if ($code -ne 0) { throw "docker compose frontend pull failed" }
    $code = Invoke-DockerCommand ($frontendComposeArgs + @("up", "-d"))
    if ($code -ne 0) { throw "docker compose frontend up failed" }
  } finally {
    $ErrorActionPreference = $prev
    Clear-AnonymousDockerConfig
  }
}

Write-Host ""
Write-Host "Done. Flat install converted in place:"
Write-Host ("  {0}" -f $TargetDir)
Write-Host "  upstream/  = product submodule (git pull inside to update)"
Write-Host "  data/      = your volumes"
Write-Host ("  Backend   : docker compose --project-directory . -f upstream/docker-compose.backend.yml -f upstream/{0} -f docker-compose.ports.yml -f docker-compose.custom.yml -f docker-compose.apps.yml -f docker-compose.config.yml up -d" -f $portsFile)
Write-Host ("  Frontend  : docker compose --project-directory . -f upstream/docker-compose.frontend.yml -f upstream/{0} -f docker-compose.frontend.ports.yml up -d" -f $frontendPortsFile)
