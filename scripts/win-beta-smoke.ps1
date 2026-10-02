# Run in Windows Sandbox or a disposable Windows account. No SDK is required.
# Refuses an existing Everypane installation, shortcut, or settings folder.
param(
    [Parameter(Mandatory = $true)][string]$Bundle,
    [Parameter(Mandatory = $true)][string]$PreviousSetup,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installRoot = Join-Path $env:LOCALAPPDATA 'Everypane'
$settingsRoot = Join-Path $env:APPDATA 'Everypane'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Everypane.lnk'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$exe = Join-Path $installRoot 'current\Everypane.exe'
$updater = Join-Path $installRoot 'Update.exe'

function Get-AppRegistration {
    @(Get-ItemProperty "$uninstallKey\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'Everypane' })
}

foreach ($existing in @($installRoot, $settingsRoot, $shortcut,
        (Join-Path $env:APPDATA 'Causeway'), (Join-Path $env:LOCALAPPDATA 'Programs\Everypane'))) {
    if (Test-Path -LiteralPath $existing) { throw "Use a disposable account. Existing data: $existing" }
}
if (@(Get-AppRegistration).Count -gt 0) { throw 'Use a disposable account. Everypane is registered here.' }
if (Test-Path -LiteralPath $OutputDirectory) {
    if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw 'The output folder must be empty.' }
} else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }

$Bundle = (Resolve-Path -LiteralPath $Bundle).Path
$PreviousSetup = (Resolve-Path -LiteralPath $PreviousSetup).Path
$manifest = Get-Content -LiteralPath (Join-Path $Bundle 'manifest.json') -Raw | ConvertFrom-Json
$candidate = Join-Path $Bundle $manifest.installer.file
$candidateHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
if ($candidateHash -ne $manifest.installer.sha256) { throw 'The installer hash does not match the bundle.' }
$report = [ordered]@{
    schema = 1
    version = $manifest.version
    installerSha256 = $candidateHash
    updatePackageSha256 = $manifest.update.sha256
    previousInstallerSha256 = (Get-FileHash -LiteralPath $PreviousSetup -Algorithm SHA256).Hash.ToLowerInvariant()
    startedUtc = [DateTime]::UtcNow.ToString('o')
    windowsVersion = [Environment]::OSVersion.Version.ToString()
    dotnetOnPath = [bool](Get-Command dotnet -ErrorAction SilentlyContinue)
    elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    checks = [ordered]@{}
    status = 'running'
}
$savedUpdateSource = $env:EVERYPANE_UPDATE_SOURCE
$savedTrace = $env:EVERYPANE_TRACE
$savedRenderer = $env:EXPLORER_RENDER
$processNumber = 0

function Save-Report {
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'smoke-results.json') -Encoding UTF8
}
function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Run-AppProcess([string]$Path, [string]$Arguments, [string]$Label) {
    $script:processNumber++
    $prefix = Join-Path $OutputDirectory ('{0:00}-{1}' -f $script:processNumber, $Label)
    $run = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$prefix.stdout.txt" -RedirectStandardError "$prefix.stderr.txt"
    if (-not $run.WaitForExit(90000)) {
        $run.Kill()
        throw "$Label timed out."
    }
    $run.WaitForExit()
    Assert-That ($run.ExitCode -eq 0) "$Label failed with exit code $($run.ExitCode)."
}
function Installed-Version {
    $path = Join-Path $installRoot 'current\sq.version'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    ([xml](Get-Content -LiteralPath $path -Raw)).package.metadata.version
}
function Assert-Installed([string]$Version) {
    Assert-That (Test-Path -LiteralPath $exe) 'The installed app is missing.'
    Assert-That ((Installed-Version) -eq $Version) 'The installed version does not match.'
    Assert-That (Test-Path -LiteralPath $shortcut) 'The Start menu shortcut is missing.'
    Assert-That (@(Get-AppRegistration).Count -eq 1) 'The Apps registration is missing or duplicated.'
    foreach ($file in @('coreclr.dll', 'hostfxr.dll', 'agent\everypane-agent', 'THIRD-PARTY-NOTICES.txt')) {
        Assert-That (Test-Path -LiteralPath (Join-Path $installRoot "current\$file")) "Missing packaged file: $file"
    }
}
function Assert-Settings {
    foreach ($name in $savedHashes.Keys) {
        $path = Join-Path $settingsRoot $name
        Assert-That (Test-Path -LiteralPath $path) "Settings were removed: $name"
        Assert-That ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $savedHashes[$name]) "Settings changed: $name"
    }
}
function Uninstall-TestApp {
    Run-AppProcess $updater '--silent uninstall' 'uninstall'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    # Velopack removes its own directory through delayed cleanup after Update.exe exits.
    # Reinstalling before that finishes lets the old cleanup remove the new installation.
    while ((Test-Path -LiteralPath $installRoot) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
    Assert-That (-not (Test-Path -LiteralPath $installRoot)) 'Uninstall did not finish removing the installation directory.'
    Assert-That (-not (Test-Path -LiteralPath $exe)) 'Uninstall left the application installed.'
    Assert-That (-not (Test-Path -LiteralPath $shortcut)) 'Uninstall left the Start menu shortcut.'
    Assert-That (@(Get-AppRegistration).Count -eq 0) 'Uninstall left the Apps registration.'
    Assert-Settings
}

try {
    $env:EVERYPANE_UPDATE_SOURCE = Join-Path $Bundle 'updates'
    $env:EVERYPANE_TRACE = '1'
    $env:EXPLORER_RENDER = 'software'
    $updatePath = Join-Path $Bundle $manifest.update.file
    Assert-That ((Get-FileHash -LiteralPath $updatePath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $manifest.update.sha256) 'Update package hash mismatch.'
    Run-AppProcess $candidate '--silent' 'clean-install'
    Assert-Installed $manifest.version
    $report.checks.cleanInstall = 'passed'
    Save-Report

    # Launch the actual Start menu shortcut and let the app close normally before seeding settings.
    Start-Process -FilePath $shortcut | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    $launched = $null
    while (-not $launched -and [DateTime]::UtcNow -lt $deadline) {
        $launched = Get-Process -Name Everypane -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $exe -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $launched) { Start-Sleep -Milliseconds 250 }
    }
    Assert-That ($null -ne $launched) 'Start menu launch did not create the application window.'
    $runtime = @($launched.Modules | Where-Object { $_.ModuleName -eq 'coreclr.dll' })
    Assert-That ($runtime.Count -eq 1) 'The runtime module was not found.'
    Assert-That ($runtime[0].FileName -eq (Join-Path $installRoot 'current\coreclr.dll')) 'The app used a system runtime instead of its bundled runtime.'
    $report.checks.bundledRuntime = 'passed'
    Assert-That ($launched.CloseMainWindow()) 'The application window would not close.'
    Assert-That ($launched.WaitForExit(15000)) 'The application did not exit after closing its window.'
    $report.checks.startMenuLaunch = 'passed'

    $fixture = Join-Path $OutputDirectory 'fixture'
    New-Item -ItemType Directory -Path $fixture | Out-Null
    'Everypane beta test' | Set-Content -LiteralPath (Join-Path $fixture 'note.txt') -Encoding UTF8
    $archive = Join-Path $OutputDirectory 'sample.zip'
    Compress-Archive -LiteralPath (Join-Path $fixture 'note.txt') -DestinationPath $archive
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $zipPath = 'zip:' + [Uri]::EscapeDataString($archive) + '!/'
    $screenshot = Join-Path $OutputDirectory 'installed-zip.png'
    Run-AppProcess $exe "--left `"$zipPath`" --right `"$fixture`" --screenshot `"$screenshot`" --screenshot-delay 2200" 'zip-launch'
    Assert-That (Test-Path -LiteralPath $screenshot) 'The ZIP view screenshot was not created.'
    Assert-That ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -eq $archiveHash) 'ZIP browsing changed the archive.'
    $report.checks.zipLaunch = 'passed'

    New-Item -ItemType Directory -Path $settingsRoot -Force | Out-Null
    $tabs = @{ Paths = @($fixture, 'computer:'); ActiveIndex = 0 }
    @{ Theme = 'Light'; CheckForUpdates = $false; LeftTabs = $tabs; RightPath = $fixture } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $settingsRoot 'settings.json') -Encoding UTF8
    @{ Favorites = @(@{ Path = $fixture; Name = 'Beta fixture'; Group = 'Test' }) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $settingsRoot 'favorites.json') -Encoding UTF8
    @{ Workspaces = @(@{ Name = 'Beta workspace'; LeftTabs = $tabs; RightTabs = $tabs; PaneCount = 2 }) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $settingsRoot 'workspaces.json') -Encoding UTF8
    $savedHashes = @{}
    foreach ($name in @('settings.json', 'favorites.json', 'workspaces.json')) {
        $savedHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $settingsRoot $name) -Algorithm SHA256).Hash
    }

    Uninstall-TestApp
    $report.checks.uninstall = 'passed'
    Run-AppProcess $PreviousSetup '--silent' 'install-previous'
    Assert-That ((Installed-Version) -ne $manifest.version) 'The previous installer must have an older version.'
    Assert-Settings
    Run-AppProcess $exe '--update-now' 'automatic-upgrade'
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ((Installed-Version) -ne $manifest.version -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
    Assert-Installed $manifest.version
    Run-AppProcess $exe '--update-now' 'check-current-version'
    Assert-Settings
    $report.checks.localUpdateFeed = 'passed'
    $report.checks.upgrade = 'passed'
    Save-Report

    Uninstall-TestApp
    Run-AppProcess $PreviousSetup '--silent' 'install-previous-again'
    Run-AppProcess $candidate '--silent' 'setup-upgrade'
    Assert-Installed $manifest.version
    Assert-Settings
    $report.checks.setupUpgrade = 'passed'
    Uninstall-TestApp
    $report.status = 'passed'
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    throw
} finally {
    $env:EVERYPANE_UPDATE_SOURCE = $savedUpdateSource
    $env:EVERYPANE_TRACE = $savedTrace
    $env:EXPLORER_RENDER = $savedRenderer
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    Save-Report
    Write-Output "Result: $(Join-Path $OutputDirectory 'smoke-results.json')"
}
