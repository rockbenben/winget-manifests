param(
  [string]$ConfigPath,
  [string]$PendingFile,
  [string]$Filter = '',
  [string]$Upstream = 'microsoft/winget-pkgs'
)

# Works out which version of every package belongs in winget next and rewrites apps.json with
# that version's installer details.
#
# The published state is read from microsoft/winget-pkgs itself, not from this repository: a
# version only counts as published once its manifests are in the upstream repository. That is
# also what tells a first submission apart from a version bump:
#
#   - the package has no manifests upstream yet -> a new package
#   - the package already has manifests upstream -> an update of it
#
# The version moves on one step at a time. The next version is only picked once the current one
# is in the upstream repository, so a package never has two pull requests in review at the same
# time and an older version can never overtake a newer one.
#
# The sha256 comes from the release asset's own "digest" field (GitHub publishes sha256 there),
# so nothing large is downloaded. The fallback path downloads the asset and hashes it locally,
# for releases whose assets were uploaded before GitHub started filling in digests.

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

function Invoke-GitHubApi([string]$Uri) {
  for ($i = 1; $i -le 4; $i++) {
    try {
      return Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec 60
    } catch {
      $code = 0
      if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode }
      # A request that is answered with a client error will not get better by asking again.
      if ($code -ge 400 -and $code -lt 500) { throw }
      if ($i -eq 4) { throw }
      Start-Sleep -Seconds (3 * $i)
    }
  }
}

# Every release of the app, drafts and pre-releases left out. The list is needed because the
# next version to publish is the one after the published one, not simply the newest release.
function Get-Releases($repo) {
  $all = Invoke-GitHubApi "https://api.github.com/repos/$repo/releases?per_page=100"
  return @($all | Where-Object { -not $_.draft -and -not $_.prerelease })
}

# The versions of the package that are already in microsoft/winget-pkgs. An empty result means
# the package does not exist upstream yet.
function Get-PublishedVersions([string]$folder) {
  $uri = "https://api.github.com/repos/$Upstream/contents/manifests/r/rockbenben/$folder"
  try {
    $items = Invoke-GitHubApi $uri
    return @($items | Where-Object { $_.type -eq 'dir' } | ForEach-Object { $_.name })
  } catch {
    $code = 0
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 404) { return @() }
    throw
  }
}

function Compare-Version([string]$a, [string]$b) {
  $va = $null; $vb = $null
  if ([version]::TryParse($a, [ref]$va) -and [version]::TryParse($b, [ref]$vb)) {
    return [math]::Sign($va.CompareTo($vb))
  }
  return [math]::Sign($a.CompareTo($b))
}

# The version that should be in winget next.
#   $current   - the version this repository is working on
#   $published - the versions already in the upstream repository
#   $releases  - every release version the app has, lowest first
function Select-TargetVersion([string]$current, [string[]]$published, [string[]]$releases) {
  if ($releases.Count -eq 0) { return $null }

  if ($published.Count -eq 0) {
    # The package is not in winget yet, so the version this repository already knows about is
    # the one that establishes the package.
    if ($releases -contains $current) { return $current }
    return $releases[0]
  }

  $maxPublished = $published | Sort-Object -Property @{ Expression = {
      try { [version]$_ } catch { [version]'0.0' } } } -Descending | Select-Object -First 1

  if ($published -contains $current) {
    # The current version is published, move on to the next release.
    return ($releases | Where-Object { (Compare-Version $_ $current) -gt 0 } | Select-Object -First 1)
  }

  if ((Compare-Version $current $maxPublished) -gt 0) {
    # The version was already moved on to, it is just not merged into winget yet.
    return $current
  }

  # The upstream repository is ahead of this repository, catch up with it.
  return ($releases | Where-Object { (Compare-Version $_ $maxPublished) -gt 0 } | Select-Object -First 1)
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
    $rels = Get-Releases $p.repo
  } catch {
    Write-Host "  could not read the releases: $($_.Exception.Message)"
    continue
  }

  # The version of every release that matches the expected tag shape.
  $prefix = ($p.tagPattern -replace '\{version\}', '')
  $candidates = @()
  foreach ($rel in $rels) {
    if (-not $rel.tag_name.StartsWith($prefix)) { continue }
    $v = $rel.tag_name.Substring($prefix.Length)
    if (-not $v) { continue }
    $candidates += [pscustomobject]@{ version = $v; tag = $rel.tag_name; release = $rel }
  }
  $candidates = @($candidates | Sort-Object -Property @{ Expression = {
      try { [version]$_.version } catch { [version]'0.0' } } })
  $releaseVersions = @($candidates | ForEach-Object { $_.version })

  try {
    $published = Get-PublishedVersions $p.folder
  } catch {
    Write-Host "  could not read the published versions from $Upstream : $($_.Exception.Message)"
    continue
  }
  if ($published.Count -gt 0) { Write-Host "  in winget already: $($published -join ', ')" }

  $target = Select-TargetVersion $p.version $published $releaseVersions
  if (-not $target) {
    Write-Host "  nothing to publish"
    continue
  }

  $entry = $candidates | Where-Object { $_.version -eq $target } | Select-Object -First 1
  if (-not $entry) {
    Write-Host "  release $target is not one of the app's releases, skipping"
    continue
  }
  $rel = $entry.release

  $assetName = ($p.assetNamePattern -replace '\{version\}', $target)
  $asset = @($rel.assets) | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
  if (-not $asset) {
    Write-Host "  release $($entry.tag) has no asset named '$assetName' (assets: $((@($rel.assets) | ForEach-Object { $_.name }) -join ', ')), skipping"
    continue
  }

  $sha = Get-AssetSha256 $asset
  $releaseDate = ([datetime]$rel.published_at).ToString('yyyy-MM-dd')

  $p.version = $target
  $p.tag = $entry.tag
  $p.releaseDate = $releaseDate
  $p.installer.assetName = $assetName
  $p.installer.url = $asset.browser_download_url
  $p.installer.sha256 = $sha
  if ($p.arp -and $p.arp.displayNamePattern) {
    $p.arp.displayName = ($p.arp.displayNamePattern -replace '\{version\}', $target)
  }

  Write-Host "  publishing $target -> $assetName"
  $pending += [pscustomobject]@{
    id = $p.id; folder = $p.folder; version = $target; tag = $entry.tag; repo = $p.repo
  }
}

# The generated files are checked out with LF line endings, so they are written that way too
# and a run on Windows does not leave the working tree with different line endings.
$json = ($cfg | ConvertTo-Json -Depth 12) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($ConfigPath, $json, $utf8NoBom)
$pendingJson = ($pending | ConvertTo-Json -Depth 6) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($PendingFile, $pendingJson, $utf8NoBom)

Write-Host ''
if ($pending.Count -eq 0) {
  Write-Host 'no new releases found'
  exit 0
}
Write-Host "$($pending.Count) package(s) need a manifest update:"
$pending | ForEach-Object { Write-Host "  $($_.id) -> $($_.version)" }
exit 0
