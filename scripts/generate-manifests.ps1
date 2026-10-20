param(
  [string]$ConfigPath,
  [string]$OutRoot
)

# Regenerates every winget manifest from apps.json.
# apps.json is the single source of truth: the auto-update workflow only edits the
# version / url / sha256 / releaseDate / arp display name fields there, then calls this
# script and submits the result. Never hand-edit the generated yaml.

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# PSScriptRoot is not populated while the param defaults are evaluated, so the paths are
# resolved here instead of in the param block.
# The parsed config goes into $cfg, not into $ConfigPath: PowerShell variable names are
# case-insensitive, and $ConfigPath is typed as [string], so assigning the parsed object to a
# similarly named variable would silently cast it back to a string.
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot '..\apps.json' }
if (-not $OutRoot)    { $OutRoot    = Join-Path $PSScriptRoot '..\manifests\r\rockbenben' }

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Quote([string]$s) {
  if ($null -eq $s) { return '""' }
  return '"' + ($s -replace '"', '\"') + '"'
}

foreach ($p in $cfg.packages) {
  $pkgDir = Join-Path $OutRoot $p.folder
  $dir = Join-Path $pkgDir $p.version
  New-Item -ItemType Directory -Force -Path $dir | Out-Null

  # One version per package in this repository: the version that is being published. The
  # manifests of the versions that came before it stay in microsoft/winget-pkgs, they are not
  # part of what this repository generates.
  if (Test-Path -LiteralPath $pkgDir) {
    foreach ($stale in Get-ChildItem -LiteralPath $pkgDir -Directory) {
      if ($stale.Name -eq $p.version) { continue }
      Get-ChildItem -LiteralPath $stale.FullName -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
      Remove-Item -LiteralPath $stale.FullName -Force
      Write-Output "removed the manifests of $($p.id) $($stale.Name)"
    }
  }

  $repoName = ($p.repo -split '/')[1]

  # ---------------- installer ----------------
  $il = New-Object System.Collections.Generic.List[string]
  $il.Add('# yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.1.12.0.schema.json')
  $il.Add('')
  $il.Add("PackageIdentifier: $($p.id)")
  $il.Add("PackageVersion: $($p.version)")
  $il.Add('Platform:')
  $il.Add('- Windows.Desktop')
  $il.Add("MinimumOSVersion: $($p.minimumOSVersion)")
  if ($p.installer.type -eq 'zip') {
    $il.Add('InstallerType: zip')
    $il.Add("NestedInstallerType: $($p.installer.nestedInstallerType)")
    $il.Add('NestedInstallerFiles:')
    $il.Add("- RelativeFilePath: $($p.installer.relativeFilePath)")
  } else {
    $il.Add('InstallerType: nullsoft')
    $il.Add('UpgradeBehavior: install')
  }
  $il.Add('Installers:')
  $il.Add('- Architecture: x64')
  if ($p.installer.type -ne 'zip') {
    $il.Add('  Scope: user')
  }
  $il.Add("  InstallerUrl: $($p.installer.url)")
  $il.Add("  InstallerSha256: $($p.installer.sha256)")
  if ($p.arp) {
    $il.Add("  ProductCode: $($p.arp.productCode)")
    $il.Add('  AppsAndFeaturesEntries:')
    $il.Add("  - DisplayName: $($p.arp.displayName)")
    $il.Add("    Publisher: $($p.arp.publisher)")
    $il.Add("    ProductCode: $($p.arp.productCode)")
  }
  $il.Add("ReleaseDate: $($p.releaseDate)")
  $il.Add('ManifestType: installer')
  $il.Add('ManifestVersion: 1.12.0')
  [System.IO.File]::WriteAllText((Join-Path $dir "$($p.id).installer.yaml"), ($il -join "`n") + "`n", $utf8NoBom)

  # ---------------- default locale ----------------
  $ll = New-Object System.Collections.Generic.List[string]
  $ll.Add('# yaml-language-server: $schema=https://aka.ms/winget-manifest.defaultLocale.1.12.0.schema.json')
  $ll.Add('')
  $ll.Add("PackageIdentifier: $($p.id)")
  $ll.Add("PackageVersion: $($p.version)")
  $ll.Add('PackageLocale: en-US')
  $ll.Add('Publisher: rockbenben')
  $ll.Add('PublisherUrl: https://github.com/rockbenben')
  $ll.Add("PublisherSupportUrl: https://github.com/rockbenben/$repoName/issues")
  $ll.Add('Author: rockbenben')
  $ll.Add("PackageName: $($p.name)")
  $ll.Add("PackageUrl: https://github.com/rockbenben/$repoName")
  $ll.Add('License: MIT')
  $ll.Add("ShortDescription: $(Quote $p.shortDescription)")
  $ll.Add('Description: |-')
  foreach ($d in $p.description) { $ll.Add("  $d") }
  $ll.Add("Moniker: $($p.moniker)")
  $ll.Add('Tags:')
  foreach ($t in $p.tags) { $ll.Add("- $t") }
  $ll.Add("ReleaseNotesUrl: https://github.com/rockbenben/$repoName/releases")
  $ll.Add('ManifestType: defaultLocale')
  $ll.Add('ManifestVersion: 1.12.0')
  [System.IO.File]::WriteAllText((Join-Path $dir "$($p.id).locale.en-US.yaml"), ($ll -join "`n") + "`n", $utf8NoBom)

  # ---------------- version ----------------
  $vl = New-Object System.Collections.Generic.List[string]
  $vl.Add('# yaml-language-server: $schema=https://aka.ms/winget-manifest.version.1.12.0.schema.json')
  $vl.Add('')
  $vl.Add("PackageIdentifier: $($p.id)")
  $vl.Add("PackageVersion: $($p.version)")
  $vl.Add('DefaultLocale: en-US')
  $vl.Add('ManifestType: version')
  $vl.Add('ManifestVersion: 1.12.0')
  [System.IO.File]::WriteAllText((Join-Path $dir "$($p.id).yaml"), ($vl -join "`n") + "`n", $utf8NoBom)

  Write-Output ("wrote $($p.id) $($p.version) -> $dir")
}
