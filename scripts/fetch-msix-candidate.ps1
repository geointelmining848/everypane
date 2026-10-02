param(
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($ReleaseId -notmatch '^\d+$') { throw 'Use a numeric release ID.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'The output already exists.' }
$repository = 'geointelmining848/everypane'
$json = gh api "repos/$repository/releases/$ReleaseId"
if ($LASTEXITCODE -ne 0) { throw 'Could not read the release.' }
$release = $json | ConvertFrom-Json
if (-not $release.draft -or $release.tag_name -notlike 'msix-prototype-*') { throw 'Use an unpublished MSIX prototype.' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
foreach ($version in @('0.4.1.0', '0.4.2.0')) {
    $name = "Everypane-$version-x64.msix"
    $asset = @($release.assets | Where-Object { $_.name -ceq $name })
    if ($asset.Count -ne 1) { throw "Missing or duplicate asset: $name" }
    $path = Join-Path $OutputDirectory $name
    gh release download $release.tag_name --repo $repository --pattern $name --output $path
    if ($LASTEXITCODE -ne 0) { throw "Could not download $name" }
    $hash = 'sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $asset[0].digest) { throw "Hash mismatch: $name" }
}
Write-Output 'MSIX prototype downloads match their GitHub SHA-256 hashes.'
