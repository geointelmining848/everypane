param(
    [Parameter(Mandatory)][string]$ReleaseId,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -ne 'geointelmining848/everypane') {
    throw 'Run this check only on the disposable Everypane GitHub runner.'
}
if ($ReleaseId -notmatch '^\d+$') { throw 'Use a numeric draft release ID.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Choose a new output directory.' }
$repository = 'geointelmining848/everypane'
$release = gh api "repos/$repository/releases/$ReleaseId" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $release.draft -or $release.tag_name -notlike 'msix-store-candidate-*') {
    throw 'Use an unpublished Store candidate.'
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$inputs = Join-Path $env:RUNNER_TEMP ('everypane-store-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $inputs | Out-Null
function Get-DraftAsset([string]$Name) {
    $asset = @($release.assets | Where-Object name -CEQ $Name)
    if ($asset.Count -ne 1) { throw "Missing or duplicate asset: $Name" }
    $path = Join-Path $inputs $Name
    gh release download $release.tag_name --repo $repository --pattern $Name --output $path
    if ($LASTEXITCODE -ne 0) { throw "Could not download $Name" }
    if ('sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset[0].digest) {
        throw "GitHub asset hash mismatch: $Name"
    }
    return $path
}
$record = Get-Content -LiteralPath (Get-DraftAsset 'store-candidate.json') -Raw | ConvertFrom-Json
if ($record.schema -ne 1 -or $record.identity.Name -cne 'GeoIntelMining.Everypane' -or
    $record.identity.Publisher -cne 'CN=3679457D-8D4A-4560-A10B-6E0078EA4B38' -or
    $record.storeId -cne '9NSRT215V5VL') { throw 'Unexpected Store product.' }
if (@($record.packages).Count -ne 2 -or $record.packages[0].file -cne 'Everypane-1.0.0.0-x64.msix' -or
    $record.packages[1].file -cne 'Everypane-1.0.1.0-x64.msix') { throw 'Unexpected install and upgrade packages.' }
if (Get-AppxPackage -Name $record.identity.Name) { throw 'An existing Everypane package is present.' }
$identityPath = Join-Path $inputs 'identity.json'
$record.identity | ConvertTo-Json | Set-Content -LiteralPath $identityPath -Encoding utf8
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-EntryHash($Entry) {
    $stream = $Entry.Open()
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($stream)) }
    finally { $stream.Dispose(); $hash.Dispose() }
}
function Assert-SigningPreservedPayload([string]$Original, [string]$Signed) {
    $before = [IO.Compression.ZipFile]::OpenRead($Original)
    $after = [IO.Compression.ZipFile]::OpenRead($Signed)
    try {
        foreach ($entry in $before.Entries) {
            if ($entry.FullName -eq '[Content_Types].xml') { continue }
            $copy = $after.GetEntry($entry.FullName)
            if (-not $copy -or (Get-EntryHash $entry) -cne (Get-EntryHash $copy)) {
                throw "Signing changed package content: $($entry.FullName)"
            }
        }
        foreach ($entry in $after.Entries) {
            # SignTool adds the signature and the desktop code-integrity catalog.
            if ($entry.FullName -notin @('AppxSignature.p7x', 'AppxMetadata/CodeIntegrity.cat') -and
                -not $before.GetEntry($entry.FullName)) {
                throw "Signing added an unexpected file: $($entry.FullName)"
            }
        }
        if (-not $after.GetEntry('AppxSignature.p7x')) { throw 'The test signature is missing.' }
    } finally { $before.Dispose(); $after.Dispose() }
}
$sdk = Get-ChildItem -LiteralPath "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
    Where-Object { $_.Name -match '^10\.0\.\d+\.0$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\signtool.exe')) } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdk) { throw 'Windows SDK SignTool is unavailable.' }
$certificate = $null
$trustedCertificate = $null
$failure = $null
$report = [ordered]@{
    schema = 1
    appVersion = $record.appVersion
    buildSourceCommit = $record.buildSourceCommit
    storeId = $record.storeId
    identity = $record.identity
    originalPackages = $record.packages
    testSigning = 'temporary certificate on a disposable runner; no signing key is exported'
    payloadPreserved = $false
    acceptance = 'not-run'
    certificationKit = 'not-run'
    storeCertification = 'not-submitted'
    status = 'running'
}
try {
    $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject $record.identity.Publisher `
        -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddDays(1)
    $publicCertificate = Join-Path $inputs 'test-only.cer'
    Export-Certificate -Cert $certificate -FilePath $publicCertificate | Out-Null
    $trustedCertificate = Import-Certificate -FilePath $publicCertificate -CertStoreLocation Cert:\LocalMachine\TrustedPeople
    $signedPackages = @()
    foreach ($item in $record.packages) {
        if ($item.file -notmatch '^Everypane-1\.0\.[01]\.0-x64\.msix$') { throw 'Unexpected package filename.' }
        $original = Get-DraftAsset $item.file
        if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.sha256) {
            throw 'Package does not match the candidate record.'
        }
        $signed = Join-Path $inputs ('test-signed-' + $item.file)
        Copy-Item -LiteralPath $original -Destination $signed
        & (Join-Path $sdk.FullName 'x64\signtool.exe') sign /fd SHA256 /sha1 $certificate.Thumbprint /s My $signed
        if ($LASTEXITCODE -ne 0) { throw 'Test package signing failed.' }
        Assert-SigningPreservedPayload $original $signed
        $signedPackages += $signed
    }
    if ($signedPackages.Count -ne 2) { throw 'Two packages are required for the upgrade check.' }
    $report.payloadPreserved = $true
    & (Join-Path $PSScriptRoot 'win-msix-smoke.ps1') -Package $signedPackages[0] -UpgradePackage $signedPackages[1] `
        -OutputDirectory (Join-Path $OutputDirectory 'acceptance') -StoreIdentityFile $identityPath
    $report.acceptance = 'passed'

    $appcert = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\App Certification Kit\appcert.exe'
    if (-not (Test-Path -LiteralPath $appcert)) { throw 'Windows App Certification Kit is unavailable on this runner.' }
    & $appcert reset
    if ($LASTEXITCODE -ne 0) { throw 'Windows App Certification Kit reset failed.' }
    $certReport = Join-Path $OutputDirectory 'appcert.xml'
    & $appcert test -appxpackagepath $signedPackages[0] -reportoutputpath $certReport
    $report.certificationKitExitCode = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $certReport)) { throw 'Certification Kit produced no report.' }
    $report.certificationKit = 'report-created-review-required'
    if ($LASTEXITCODE -ne 0) { throw 'Review the Certification Kit report for failures.' }
    $report.status = 'passed'
} catch {
    $failure = $_.Exception.ToString()
    $report.status = 'failed'
} finally {
    Get-AppxPackage -Name $record.identity.Name |
        Where-Object Publisher -CEQ $record.identity.Publisher |
        ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -ErrorAction Continue }
    if ($trustedCertificate) { Remove-Item -LiteralPath $trustedCertificate.PSPath }
    if ($certificate) { Remove-Item -LiteralPath $certificate.PSPath }
    $report.failure = $failure
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'store-validation.json') -Encoding utf8
    $report | ConvertTo-Json -Depth 10
}
if ($failure) { throw $failure }
