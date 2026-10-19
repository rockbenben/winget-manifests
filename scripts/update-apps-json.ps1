param(
  [string]$ConfigPath,
  [string]$PendingFile,
  [string]$Filter = ''
)

# Looks at the latest GitHub release of every app listed in apps.json and, when that release is
# newer than the version we already publish, rewrites apps.json with the new version, installer
# url, sha256, release date and ARP display name. Writes the list of changed packages to
# pending.json so the submit script knows what to publish.
#
# The sha256 comes from the release asset's own "digest" field (GitHub publishes sha256 there), so
# nothing large is downloaded. The fallback path downloads the asset and hashes it locally, for
# releases whose assets were uploaded before GitHub started filling in digests.

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# PSScriptRoot is not populated while the param defaults are evaluated, so the paths are
# resolved here instead of in the param block.
# The parsed config goes into $cfg, not into $ConfigPath: PowerShell variable names are
# case-insensitive, and $ConfigPath is typed as [string], so assigning the parsed object to a
# similarly named variable would silently cast it back to a string.
if (-not $ConfigPath)  { $ConfigPath  = Join-Path $PSScriptRoot '..\apps.json' }
if (-not $PendingFile) { $PendingFile = Join-Path $PSScriptRoot '..\pending.json' }

$headers = @{
  'User-Agent' = 'winget-manifest-auto-update'
  'Accept'     = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
}
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }

function Get-Release($repo) {
  $uri = "https://api.github.com/repos/$repo/releases/latest"
  for ($i = 1; $i -le 4; $i++) {
    try {
      return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60
    } catch {
      if ($i -eq 4) { throw }
      Start-Sleep -Seconds (3 * $i)
    }
  }
}

function Test-Newer([string]$candidate, [string]$current) {
  $c = $null; $k = $null
  if ([version]::TryParse($candidate, [ref]$c) -and [version]::TryParse($current, [ref]$k)) {
    return $c -gt $k
  }
  return $candidate -ne $current -and $candidate.CompareTo($current) -gt 0
}

function Get-AssetSha256($asset) {
  if ($asset.digest -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { return $Matches[1].ToUpper() }
  # fallback: download and hash locally
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
  Write-Host "  no digest published, downloading $($asset.name) to hash it locally"
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing -TimeoutSec 900
  $h = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
  Remove-Item -LiteralPath $tmp -Force
  return $h
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pending = @()

foreach ($p in $cfg.packages) {
  if ($Filter -and $p.id -ne $Filter) { continue }
  Write-Host "checking $($p.id) (published $($p.version))"

  try {
    $rel = Get-Release $p.repo
  } catch {
    Write-Host "  could not read the latest release: $($_.Exception.Message)"
    continue
  }
  if ($rel.draft) { Write-Host '  latest release is a draft, skipping'; continue }

  $prefix = ($p.tagPattern -replace '\{version\}', '')
  $tag = $rel.tag_name
  if (-not $tag.StartsWith($prefix)) {
    Write-Host "  tag '$tag' does not match the expected pattern '$($p.tagPattern)', skipping"
    continue
  }
  $version = $tag.Substring($prefix.Length)
  if (-not $version) { Write-Host '  could not derive a version from the tag, skipping'; continue }

  if (-not (Test-Newer $version $p.version)) {
    Write-Host "  published version $($p.version) is already current"
    continue
  }

  $assetName = ($p.assetNamePattern -replace '\{version\}', $version)
  $asset = @($rel.assets) | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
  if (-not $asset) {
    Write-Host "  release $tag has no asset named '$assetName' (assets: $((@($rel.assets) | ForEach-Object { $_.name }) -join ', ')), skipping"
    continue
  }

  $sha = Get-AssetSha256 $asset
  $releaseDate = ([datetime]$rel.published_at).ToString('yyyy-MM-dd')

  $p.version = $version
  $p.tag = $tag
  $p.releaseDate = $releaseDate
  $p.installer.assetName = $assetName
  $p.installer.url = $asset.browser_download_url
  $p.installer.sha256 = $sha
  if ($p.arp -and $p.arp.displayNamePattern) {
    $p.arp.displayName = ($p.arp.displayNamePattern -replace '\{version\}', $version)
  }

  Write-Host "  new version $version -> $assetName"
  $pending += [pscustomobject]@{
    id = $p.id; folder = $p.folder; version = $version; repo = $p.repo
    isNew = -not (Test-Path "manifests\r\rockbenben\$($p.folder)")
  }
}

[System.IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 12), $utf8NoBom)
[System.IO.File]::WriteAllText($PendingFile, ($pending | ConvertTo-Json -Depth 6), $utf8NoBom)

Write-Host ''
if ($pending.Count -eq 0) {
  Write-Host 'no new releases found'
  exit 0
}
Write-Host "$($pending.Count) package(s) need a manifest update:"
$pending | ForEach-Object { Write-Host "  $($_.id) -> $($_.version)" }
