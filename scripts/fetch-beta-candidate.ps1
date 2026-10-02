param(
    [Parameter(Mandatory = $true)][string]$ReleaseId,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($ReleaseId -notmatch '^\d+$') { throw 'Use a numeric release ID.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'The output already exists.' }
$repository = 'geointelmining848/everypane'
$releaseText = gh api "repos/$repository/releases/$ReleaseId"
if ($LASTEXITCODE -ne 0) { throw 'Could not read the release.' }
$release = $releaseText | ConvertFrom-Json
if (-not $release.draft -or $release.tag_name -notmatch '^v(\d+\.\d+\.\d+-beta\.\d+)$') {
    throw 'Use an unpublished beta release.'
}
$version = $Matches[1]
$candidate = Join-Path $OutputDirectory 'candidate'
New-Item -ItemType Directory -Path (Join-Path $candidate 'updates') -Force | Out-Null
$files = [ordered]@{
    "Everypane-$version-Setup.exe" = "$candidate\Everypane-$version-Setup.exe"
    "Everypane-$version-full.nupkg" = "$candidate\updates\Everypane-$version-full.nupkg"
    'releases.win.json' = "$candidate\updates\releases.win.json"
    'manifest.json' = "$candidate\manifest.json"
    'SHA256SUMS.txt' = "$candidate\SHA256SUMS.txt"
    'RELEASE-NOTES.md' = "$candidate\RELEASE-NOTES.md"
    'THIRD-PARTY-NOTICES.txt' = "$candidate\THIRD-PARTY-NOTICES.txt"
    'test-previous-setup.exe' = "$OutputDirectory\previous-setup.exe"
}
foreach ($name in $files.Keys) {
    $asset = @($release.assets | Where-Object { $_.name -ceq $name })
    if ($asset.Count -ne 1) { throw "Missing or duplicate draft asset: $name" }
    gh release download $release.tag_name --repo $repository --pattern $name --output $files[$name]
    if ($LASTEXITCODE -ne 0) { throw "Could not download $name" }
    $digest = 'sha256:' + (Get-FileHash -LiteralPath $files[$name] -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -cne $asset[0].digest) { throw "Download hash mismatch: $name" }
}
Write-Output "Downloaded draft $($release.tag_name). All asset hashes match GitHub."
