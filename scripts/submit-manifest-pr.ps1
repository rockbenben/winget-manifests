param(
  [string]$ConfigPath,
  [string]$PendingFile,
  [string]$ManifestRoot,
  [string]$Fork = 'rockbenben/winget-pkgs',
  [string]$Upstream = 'microsoft/winget-pkgs'
)

# Pushes the regenerated manifests for every package listed in pending.json to the winget-pkgs
# fork and opens one pull request per package against microsoft/winget-pkgs.
#
# Whether a version is a new package or an update of an existing one is decided by looking at
# microsoft/winget-pkgs itself: a package that has no manifests upstream is a new package, a
# package that already has manifests upstream is an update of it. The local manifests folder says
# nothing about that, it only holds what this repository generated.
#
# Only one pull request per package is ever in review: a version that already has an open pull
# request is left alone, and a version whose pull request was closed is not submitted again
# unless the package appeared in winget after that pull request was closed.
#
# Needs a GitHub personal access token (classic, "public_repo" scope) in the WINGET_TOKEN
# environment variable. gh reads it from GH_TOKEN, so that is what gets set here.

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# PSScriptRoot is not populated while the param defaults are evaluated, so the paths are
# resolved here instead of in the param block.
if (-not $ConfigPath)   { $ConfigPath   = Join-Path $PSScriptRoot '..\apps.json' }
if (-not $PendingFile)  { $PendingFile  = Join-Path $PSScriptRoot '..\pending.json' }
if (-not $ManifestRoot) { $ManifestRoot = Join-Path $PSScriptRoot '..\manifests\r\rockbenben' }

if (-not $env:WINGET_TOKEN) { throw 'WINGET_TOKEN is not set' }
$env:GH_TOKEN = $env:WINGET_TOKEN
$env:GITHUB_TOKEN = $env:WINGET_TOKEN

$owner = ($Fork -split '/')[0]

function Invoke-Gh([string[]]$GhArgs, [int]$Retries = 4) {
  $out = ''
  for ($i = 1; $i -le $Retries; $i++) {
    # gh writes progress to stderr, which under Stop becomes a terminating error, so the
    # preference is relaxed for the call and the exit code decides the outcome.
    $ErrorActionPreference = 'Continue'
    $out = & gh @GhArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -eq 0) { return $out }
    Start-Sleep -Seconds (3 * $i)
  }
  throw "gh failed after $Retries attempts: $($out.Substring(0, [Math]::Min(300, $out.Length)))"
}

# The same call, but a failure is an answer rather than an error: the caller asks about
# something that is simply not there.
function Invoke-GhOptional([string[]]$GhArgs) {
  $ErrorActionPreference = 'Continue'
  $out = & gh @GhArgs 2>&1 | Out-String
  $code = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($code -ne 0) { return $null }
  return $out
}

# The versions of the package that are already in microsoft/winget-pkgs. An empty result means
# the package does not exist upstream yet.
function Get-PublishedVersions([string]$folder) {
  $out = Invoke-GhOptional @('api', "repos/$Upstream/contents/manifests/r/rockbenben/$folder")
  if (-not $out) { return @() }
  $items = $out | ConvertFrom-Json
  return @($items | Where-Object { $_.type -eq 'dir' } | ForEach-Object { $_.name })
}

# When the package first appeared in microsoft/winget-pkgs, or $null when it is not there.
function Get-FirstUpstreamAppearance([string]$folder) {
  $out = Invoke-GhOptional @('api', "repos/$Upstream/commits?path=manifests/r/rockbenben/$folder&per_page=100")
  if (-not $out) { return $null }
  $commits = @($out | ConvertFrom-Json)
  if ($commits.Count -eq 0) { return $null }
  # The list comes back newest first, so the last entry is the commit that added the package.
  return $commits[-1].commit.committer.date
}

function Compare-Version([string]$a, [string]$b) {
  $va = $null; $vb = $null
  if ([version]::TryParse($a, [ref]$va) -and [version]::TryParse($b, [ref]$vb)) {
    return [math]::Sign($va.CompareTo($vb))
  }
  return [math]::Sign($a.CompareTo($b))
}

$pending = Get-Content -LiteralPath $PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($pending).Count -eq 0) { Write-Host 'nothing to submit'; exit 0 }

$upstreamSha = (Invoke-Gh @('api', "repos/$Upstream/commits/master", '--jq', '.sha')).Trim()

# The pull requests this account already opened against winget-pkgs, so a version that is
# already in review is not submitted a second time.
$myPrs = @((Invoke-Gh @('pr', 'list', '--repo', $Upstream, '--author', $owner, '--state', 'all',
  '--limit', '200', '--json', 'number,state,headRefName,closedAt')) | ConvertFrom-Json)

foreach ($p in $pending) {
  Write-Host "########## $($p.id) $($p.version)"

  $dirPath = "manifests/r/rockbenben/$($p.folder)/$($p.version)"
  $localDir = Join-Path (Join-Path $ManifestRoot $p.folder) $p.version
  if (-not (Test-Path -LiteralPath $localDir)) { throw "missing generated manifest folder $localDir" }

  $published = Get-PublishedVersions $p.folder
  $isNew = $published.Count -eq 0
  $title = if ($isNew) { "New package: $($p.id) version $($p.version)" } else { "Update: $($p.id) to $($p.version)" }
  Write-Host "  $title"

  # Has this version already been submitted?
  $prefix = "$owner.$($p.folder)-$($p.version)-"
  $mine = @($myPrs | Where-Object { $_.headRefName -like "$prefix*" })
  $open = @($mine | Where-Object { $_.state -eq 'OPEN' })
  $closed = @($mine | Where-Object { $_.state -eq 'CLOSED' })

  if ($open.Count -gt 0) {
    Write-Host "  pull request #$($open[0].number) for this version is already open, skipping"
    continue
  }

  if ($closed.Count -gt 0) {
    # The pull request was closed. It is only submitted again when the package turned up in
    # winget after that: the version was a duplicate first submission then, and is a normal
    # update now. A pull request that was closed after the package was already in winget is
    # left alone, so a rejected pull request is not opened again every six hours.
    $appeared = Get-FirstUpstreamAppearance $p.folder
    if ($appeared -and ([datetime]$closed[0].closedAt) -lt ([datetime]$appeared)) {
      Write-Host "  pull request #$($closed[0].number) was closed before the package was in winget, submitting the version again as an update"
    } else {
      Write-Host "  pull request #$($closed[0].number) for this version was closed, leaving it to a human"
      continue
    }
  }

  if (-not $isNew) {
    $maxPublished = $published | Sort-Object -Property @{ Expression = {
        try { [version]$_ } catch { [version]'0.0' } } } -Descending | Select-Object -First 1
    if ((Compare-Version $p.version $maxPublished) -le 0) {
      Write-Host "  version $($p.version) is not newer than the published $maxPublished, skipping"
      continue
    }
  }

  $branch = "$owner.$($p.folder)-$($p.version)-$([guid]::NewGuid().ToString())"
  Invoke-Gh @('api', '--method', 'POST', "repos/$Fork/git/refs", '-f', "ref=refs/heads/$branch", '-f', "sha=$upstreamSha") | Out-Null
  Write-Host "  branch $branch"

  $existing = @()
  $existingOut = Invoke-GhOptional @('api', "repos/$Fork/contents/$dirPath`?ref=$branch")
  if ($existingOut) { $existing = $existingOut | ConvertFrom-Json }
  $existingSha = @{}
  foreach ($e in @($existing)) { if ($e.name) { $existingSha[$e.name] = $e.sha } }

  foreach ($file in Get-ChildItem -LiteralPath $localDir -File | Sort-Object Name) {
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
    $args = @('api', '--method', 'PUT', "repos/$Fork/contents/$dirPath/$($file.Name)",
              '-f', "message=$title",
              '-f', "content=$b64", '-f', "branch=$branch")
    if ($existingSha.ContainsKey($file.Name)) { $args += @('-f', "sha=$($existingSha[$file.Name])") }
    Invoke-Gh $args | Out-Null
    Write-Host "  pushed $($file.Name)"
  }

  $body = @"
## 📖 Description

$title

- Package identifier: ``$($p.id)``
- Release: https://github.com/$($p.repo)/releases/tag/$($p.tag)

Generated automatically by the winget manifest auto-update workflow from apps.json.

## ✅ Checklist

- [x] Signed the [Contributor License Agreement](https://cla.opensource.microsoft.com)
- [x] Linked to an issue (if applicable)

## 📦 Manifest Checklist

- [x] Checked that there aren't other open [pull requests](https://github.com/microsoft/winget-pkgs/pulls) for the same manifest update/change
- [x] This PR only modifies one (1) manifest
- [x] Validated manifest locally with ``winget validate --manifest <path>``
- [x] Manifest conforms to the [1.12 schema](https://github.com/microsoft/winget-pkgs/tree/master/doc/manifest/schema/1.12.0)
"@

  $prArgs = @('api', '--method', 'POST', "repos/$Upstream/pulls", '-f', "title=$title",
              '-f', "head=$owner`:$branch", '-f', 'base=master', '-f', "body=$body")
  $pr = Invoke-Gh $prArgs | ConvertFrom-Json
  Write-Host "  PR: $($pr.html_url)"
}

# The runner's pwsh shell turns the script's exit code into the step's exit code, and the last
# gh call leaves LASTEXITCODE behind, so the result is stated explicitly.
exit 0
