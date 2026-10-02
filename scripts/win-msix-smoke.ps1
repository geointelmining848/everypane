param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$UpgradePackage,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$WslDistro
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($path in @($Package, $UpgradePackage)) {
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $path).ProviderPath)
    try {
        $reader = [IO.StreamReader]::new($archive.GetEntry('AppxManifest.xml').Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($manifest.Package.Identity.Name -cne 'Everypane.MsixTest' -or
            $manifest.Package.Identity.Publisher -cne 'CN=Everypane MSIX Test, OID.2.25.311729368913984317654407730594956997722=1') {
            throw 'Only the unsigned Everypane test identity is allowed.'
        }
    } finally { $archive.Dispose() }
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'The report directory already exists.' }
if (Get-AppxPackage -Name Everypane.MsixTest) { throw 'An existing test package must be removed before this check.' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$runId = [guid]::NewGuid().ToString('N')
$fixture = Join-Path $env:LOCALAPPDATA "Everypane\msix-smoke\$runId"
$checks = [Collections.Generic.List[string]]::new()
$failure = $null
$initialHash = $null
$family = $null
$packageHash = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant()
$upgradeHash = (Get-FileHash -LiteralPath $UpgradePackage -Algorithm SHA256).Hash.ToLowerInvariant()

# Activation through the package AUMID proves that the process receives package identity.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EverypanePackageActivation {
    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IApplicationActivationManager {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string app,
            [MarshalAs(UnmanagedType.LPWStr)] string args, uint options, out uint processId);
    }
    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    class ApplicationActivationManager {}
    public static uint Start(string app, string args) {
        var manager = (IApplicationActivationManager)new ApplicationActivationManager();
        try {
            uint processId;
            Marshal.ThrowExceptionForHR(manager.ActivateApplication(app, args, 2, out processId));
            return processId;
        } finally { Marshal.ReleaseComObject(manager); }
    }
}
'@
function Invoke-PackagedApp([string]$Arguments) {
    $appProcessId = [EverypanePackageActivation]::Start("${script:family}!Everypane", $Arguments)
    $process = Get-Process -Id $appProcessId -ErrorAction SilentlyContinue
    if ($process -and -not $process.WaitForExit(60000)) {
        Stop-Process -Id $appProcessId -Force
        throw 'The packaged app did not finish within 60 seconds.'
    }
}
function Read-SmokeReport([string]$Name) {
    $path = Join-Path $fixture 'report.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'The app wrote no report visible outside its package.' }
    Copy-Item -LiteralPath $path -Destination (Join-Path $OutputDirectory "$Name.json")
    $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($report.status -ne 'passed') { throw $report.failure }
    if (-not $report.package.StartsWith('Everypane.MsixTest_')) { throw 'Missing process package identity.' }
    return $report
}
try {
    Add-AppxPackage -Path $Package -AllowUnsigned
    $installed = Get-AppxPackage -Name Everypane.MsixTest
    if (-not $installed) { throw 'MSIX registration is missing.' }
    $family = $installed.PackageFamilyName
    $firstVersion = $installed.Version
    $checks.Add('clean-install')
    $arguments = "--package-smoke $runId"
    if ($WslDistro) {
        if ($WslDistro -match '["\r\n]') { throw 'Invalid distribution name.' }
        $arguments += " `"$WslDistro`""
    }
    Invoke-PackagedApp $arguments
    $first = Read-SmokeReport 'first-launch'
    $checks.Add('packaged-functional-checks')
    if ($first.checks -notcontains 'settings-saved') { throw 'The first install did not create settings.' }
    $initialHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'settings.json') -Algorithm SHA256).Hash
    $checks.Add('appdata-visible-outside-package')

    $image = Join-Path $OutputDirectory 'zip-window.png'
    $zip = Join-Path $fixture 'sample.zip'
    $zipPath = 'zip:' + [Uri]::EscapeDataString($zip) + '!/'
    Invoke-PackagedApp "--screenshot `"$image`" --left `"$zipPath`" --right `"$fixture`" --preview off --sidebar off --screenshot-delay 2000"
    if (-not (Test-Path -LiteralPath $image) -or (Get-Item -LiteralPath $image).Length -lt 1000) { throw 'The installed UI produced no screenshot.' }
    $checks.Add('installed-ui-and-zip-view')

    Add-AppxPackage -Path $UpgradePackage -AllowUnsigned
    $updated = Get-AppxPackage -Name Everypane.MsixTest
    if ([version]$updated.Version -le [version]$firstVersion) { throw 'Package version did not increase.' }
    if ($updated.PackageFamilyName -ne $family) { throw 'Upgrade changed package identity.' }
    $checks.Add('msix-upgrade')
    Remove-Item -LiteralPath (Join-Path $fixture 'report.json')
    Invoke-PackagedApp $arguments
    $after = Read-SmokeReport 'after-upgrade'
    if ($after.checks -notcontains 'settings-retained') { throw 'Upgrade did not retain settings.' }
    if ((Get-FileHash -LiteralPath (Join-Path $fixture 'settings.json') -Algorithm SHA256).Hash -ne $initialHash) { throw 'Upgrade changed settings bytes.' }
    $checks.Add('upgrade-retains-settings')
    Remove-AppxPackage -Package $updated.PackageFullName
    if (Get-AppxPackage -Name Everypane.MsixTest) { throw 'MSIX registration remains after removal.' }
    if ((Get-FileHash -LiteralPath (Join-Path $fixture 'settings.json') -Algorithm SHA256).Hash -ne $initialHash) { throw 'Removal deleted or changed real user files.' }
    if (-not (Test-Path -LiteralPath $zip)) { throw 'Removal deleted the user ZIP file.' }
    $checks.Add('uninstall-retains-user-files')
} catch {
    $failure = $_.Exception.ToString()
} finally {
    # Only the test identity created by this script can be removed here.
    Get-AppxPackage -Name Everypane.MsixTest | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -ErrorAction Continue }
    $report = [ordered]@{
        status = $(if ($failure) { 'failed' } else { 'passed' })
        packageSha256 = $packageHash
        upgradeSha256 = $upgradeHash
        packageFamily = $family
        checks = @($checks)
        wsl = $(if ($WslDistro) { $WslDistro } else { 'not-tested' })
        fixture = $fixture
        failure = $failure
        os = [Environment]::OSVersion.VersionString
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'smoke-results.json') -Encoding utf8
    $report | ConvertTo-Json -Depth 6
}
if ($failure) { throw $failure }
