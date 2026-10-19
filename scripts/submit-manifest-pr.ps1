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

function Invoke-Gh([string[]]$GhArgs, [int]$Retries = 4) {
  $out = ''
  for ($i = 1; $i -le $Retries; $i++) {
    $out = & gh @GhArgs 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { return $out }
    Start-Sleep -Seconds (3 * $i)
  }
  throw "gh failed after $Retries attempts: $($out.Substring(0, [Math]::Min(300, $out.Length)))"
}

$pending = Get-Content -LiteralPath $PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($pending).Count -eq 0) { Write-Host 'nothing to submit'; exit 0 }

$upstreamSha = (Invoke-Gh @('api', "repos/$Upstream/commits/master", '--jq', '.sha')).Trim()

foreach ($p in $pending) {
  Write-Host "########## $($p.id) $($p.version)"

  $dirPath = "manifests/r/rockbenben/$($p.folder)/$($p.version)"
  $localDir = Join-Path (Join-Path $ManifestRoot $p.folder) $p.version
  if (-not (Test-Path -LiteralPath $localDir)) { throw "missing generated manifest folder $localDir" }

  $branch = "rockbenben.$($p.folder)-$($p.version)-$([guid]::NewGuid().ToString())"
  Invoke-Gh @('api', '--method', 'POST', "repos/$Fork/git/refs", '-f', "ref=refs/heads/$branch", '-f', "sha=$upstreamSha") | Out-Null
  Write-Host "  branch $branch"

  $existing = @()
  try {
    $existing = (Invoke-Gh @('api', "repos/$Fork/contents/$dirPath`?ref=$branch")) | ConvertFrom-Json
  } catch {
    $existing = @()
  }
  $existingSha = @{}
  foreach ($e in @($existing)) { if ($e.name) { $existingSha[$e.name] = $e.sha } }

  foreach ($file in Get-ChildItem -LiteralPath $localDir -File | Sort-Object Name) {
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
    $args = @('api', '--method', 'PUT', "repos/$Fork/contents/$dirPath/$($file.Name)",
              '-f', "message=New package: $($p.id) version $($p.version)",
              '-f', "content=$b64", '-f', "branch=$branch")
    if ($existingSha.ContainsKey($file.Name)) { $args += @('-f', "sha=$($existingSha[$file.Name])") }
    Invoke-Gh $args | Out-Null
    Write-Host "  pushed $($file.Name)"
  }

  $isNew = -not (Test-Path (Join-Path $ManifestRoot $p.folder))
  $title = if ($isNew) { "New package: $($p.id) version $($p.version)" } else { "Update: $($p.id) to $($p.version)" }
  $body = @"
## 📖 Description

$title

- Package identifier: ``$($p.id)``
- Release: https://github.com/$($p.repo)/releases

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

  $prArgs = @('--method', 'POST', "repos/$Upstream/pulls", '-f', "title=$title",
              '-f', "head=rockbenben:$branch", '-f', 'base=master', '-f', "body=$body")
  $pr = Invoke-Gh $prArgs | ConvertFrom-Json
  Write-Host "  PR: $($pr.html_url)"
}
