# winget-manifests

Source of truth for every **winget** package published under the `rockbenben` publisher, plus the
automation that keeps those manifests in step with new app releases.

The pull requests themselves live in
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) - this repository only holds the
manifests and the tooling that generates and submits them.

## Why this exists

Every package in winget needs a manifest whose `PackageVersion` matches the app release, and whose
`InstallerSha256` matches the bytes of the release asset. Doing that by hand for every release is
the part that quietly stops happening: the manifest then trails the app by however long it takes
someone to remember.

This repository closes that gap. A scheduled workflow checks each app's latest GitHub release, and
when it is newer than the published version it rewrites `apps.json`, regenerates the manifests and
opens a pull request against `microsoft/winget-pkgs` - the same three files per package that the
upstream repository expects.

## Layout

```
apps.json                      single source of truth: one entry per package
manifests/r/rockbenben/<App>/<version>/
                               the generated manifests, laid out exactly as they land in
                               microsoft/winget-pkgs
scripts/generate-manifests.ps1  reads apps.json and writes the manifests
scripts/update-apps-json.ps1   finds new app releases and rewrites apps.json
scripts/submit-manifest-pr.ps1  pushes the manifests to the fork and opens the pull requests
.github/workflows/winget-auto-update.yml
                               the scheduled job that ties the three together
```

`apps.json` is the only file that should ever be edited by hand. The yaml files are generated -
change the config, not the output.

## One package entry

```json
{
  "id": "rockbenben.Clockwork",
  "repo": "rockbenben/Clockwork",
  "folder": "Clockwork",
  "version": "3.2.0",
  "tag": "v3.2.0",
  "releaseDate": "2026-10-15",
  "moniker": "clockwork",
  "name": "Clockwork",
  "shortDescription": "...",
  "description": ["..."],
  "tags": ["tray", "automation"],
  "minimumOSVersion": "10.0.0.0",
  "installer": {
    "type": "zip",
    "nestedInstallerType": "portable",
    "relativeFilePath": "Clockwork.exe",
    "assetName": "Clockwork-v3.2.0-win-x64.zip",
    "url": "https://github.com/rockbenben/Clockwork/releases/download/v3.2.0/Clockwork-v3.2.0-win-x64.zip",
    "sha256": "CB0216F8F5CCB03681C4CF3DDAA39BF8ECE16319C9F860CF7B0D5C277297E0CE"
  },
  "arp": null,
  "tagPattern": "v{version}",
  "assetNamePattern": "Clockwork-v{version}-win-x64.zip"
}
```

The two `...Pattern` fields are what makes the automation work: given a new release tag, the
workflow expands them to work out which asset to publish and which tag shape to expect.

`arp` carries the uninstall registry facts for the packages that install something, so winget can
correlate an installed program with the package. The two portable packages ship no installer and
therefore have no ARP entry, so their `arp` is `null`.

## Setup

1. Create a GitHub personal access token (classic) with the `public_repo` scope. Fine-grained
   tokens do not work with this tooling.
2. Add it to this repository as a secret named `WINGET_TOKEN`
   (Settings -> Secrets and variables -> Actions -> New repository secret).
3. The workflow needs `gh` on the runner; the `windows-latest` image ships it.

## Running it by hand

```powershell
# find new releases and rewrite apps.json
./scripts/update-apps-json.ps1

# regenerate the manifests from apps.json
./scripts/generate-manifests.ps1

# check them the same way winget does
winget validate --manifest manifests/r/rockbenben/Clockwork/3.2.0

# push and open the pull requests
$env:WINGET_TOKEN = '<your token>'
./scripts/submit-manifest-pr.ps1
```

`update-apps-json.ps1` takes the sha256 straight from the release asset's own `digest` field, so
nothing large is downloaded. It only falls back to downloading and hashing the asset when GitHub
has not published a digest for it.

## Triggers

| Trigger | When |
|---|---|
| `schedule` | every six hours |
| `workflow_dispatch` | run by hand, optionally for a single package |
| `repository_dispatch` with type `app-released` | fire it from an app's release workflow |

To have an app's release workflow wake this one up directly, add a step like this to that app's
release job:

```yaml
- uses: actions/github-script@v7
  with:
    script: |
      await github.rest.repos.createDispatchEvent({
        owner: context.repo.owner,
        repo: 'winget-manifests',
        event_type: 'app-released',
        client_payload: { app_id: 'rockbenben.Clockwork' }
      })
```

## Notes

- The workflow pins no `wingetcreate` dependency on purpose. Generating the manifests here keeps
  the package metadata, the ARP product codes and the descriptions exactly as they were reviewed,
  instead of letting a tool rewrite them.
- The `if:` conditions in the workflow are written without the expression wrapper. The `env:` block
  does use it, and every occurrence is a complete expression - a half-written one anywhere in a
  workflow file makes the whole file fail to parse.
- A pull request only merges once a winget maintainer approves it and runs the publish pipeline, so
  opening the pull request is the last automated step, not the last step.
