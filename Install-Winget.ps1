<#
.SYNOPSIS
    Installs winget (Microsoft App Installer) for the current user from the official GitHub release.

.DESCRIPTION
    1. Looks up the winget release on github.com/microsoft/winget-cli (latest stable unless -Version is given).
    2. Reads DesktopAppInstaller_Dependencies.json from that release and installs any framework
       packages that are missing (VCLibs, Windows App Runtime) from DesktopAppInstaller_Dependencies.zip.
    3. Downloads Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle, checks its SHA256 against the
       hash published with the release and checks it is signed by Microsoft, then registers it with
       Add-AppxPackage.
    4. Runs winget --version to confirm.

    No admin rights needed. Everything printed is also saved to a transcript log next to this script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Winget.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Winget.ps1 -Version v1.29.380
#>
[CmdletBinding()]
param(
    # Release tag such as v1.29.380, or 'latest' for the newest stable release.
    [string]$Version = 'latest',
    # New, empty folder for the downloaded installers. Kept afterwards so it can be copied to an offline machine.
    [string]$DownloadDir = (Join-Path $env:TEMP ('winget-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    # Where the transcript log goes. Defaults to the script's own folder.
    [string]$LogDir,
    # Reinstall even if winget is already on PATH.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest in PowerShell 5.1 is very slow with the progress bar on
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
if (-not $LogDir) { $LogDir = if ($PSScriptRoot) { $PSScriptRoot } else { $DownloadDir } }
$logFile = Join-Path $LogDir ('Install-Winget-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
Start-Transcript -Path $logFile | Out-Null

function Write-Step($message) { Write-Host "`n==> $message" -ForegroundColor Cyan }

function Get-ReleaseAsset($release, $name) {
    $asset = $release.assets | Where-Object name -eq $name
    if (-not $asset) { throw "Release $($release.tag_name) has no asset named $name" }
    $asset
}

# Downloads a release asset and checks it against the SHA256 published in a companion .txt asset.
function Save-VerifiedAsset($release, $name, $hashAssetName) {
    $asset = Get-ReleaseAsset $release $name
    $path = Join-Path $DownloadDir $name
    Write-Host "Downloading $name ($([math]::Round($asset.size / 1MB, 1)) MB)"
    Write-Host "  from $($asset.browser_download_url)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $path -UseBasicParsing
    $expected = ([string](Invoke-RestMethod -Uri (Get-ReleaseAsset $release $hashAssetName).browser_download_url)).Trim()
    $actual = (Get-FileHash $path -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "SHA256 mismatch for $name`n  expected $expected`n  got      $actual" }
    Write-Host "  SHA256 OK: $actual"
    $path
}

try {
    Write-Step 'Checking system'
    $os = [Environment]::OSVersion.Version
    $cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = @{ AMD64 = 'x64'; ARM64 = 'arm64'; x86 = 'x86' }[$cpu]
    Write-Host "Windows $os, CPU $cpu ($arch), PowerShell $($PSVersionTable.PSVersion), user $env:USERNAME"
    if ($os.Build -lt 17763) { throw 'winget needs Windows 10 1809 (build 17763) or later.' }
    if (-not $arch) { throw "Unsupported CPU architecture: $cpu" }

    # winget.exe can be a leftover app execution alias whose package isn't registered for this user (for example
    # after a debloat script). Running it then fails with "The file cannot be accessed by the system", so only
    # count winget as installed if it actually runs.
    $currentVersion = $null
    $current = Get-Command winget -ErrorAction SilentlyContinue
    if ($current) {
        try { $currentVersion = & $current.Source --version }
        catch { Write-Host "Found $($current.Source) but it doesn't run: $($_.Exception.Message)" }
    }
    if ($currentVersion -and -not $Force) {
        Write-Host "winget is already installed: $currentVersion. Use -Force to reinstall."
        return
    }
    $pkg = Get-AppxPackage Microsoft.DesktopAppInstaller
    Write-Host "App Installer for this user: $(if ($pkg) { "$($pkg.PackageFullName), status $($pkg.Status)" } else { 'not installed' })"

    Write-Step 'Looking up the winget release on GitHub'
    $api = if ($Version -eq 'latest') { 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' }
           else { "https://api.github.com/repos/microsoft/winget-cli/releases/tags/$Version" }
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'Install-Winget.ps1' }
    Write-Host "Release $($release.tag_name), published $($release.published_at)"
    Write-Host "Download folder: $DownloadDir"

    Write-Step 'Checking framework dependencies'
    $depList = Invoke-RestMethod -Uri (Get-ReleaseAsset $release 'DesktopAppInstaller_Dependencies.json').browser_download_url
    if ($depList -is [string]) { $depList = $depList.TrimStart([char]0xFEFF) | ConvertFrom-Json }
    $missing = @(foreach ($dep in $depList.Dependencies) {
        $have = Get-AppxPackage -Name $dep.Name |
            Where-Object { "$($_.Architecture)" -eq $arch -and [version]$_.Version -ge [version]$dep.Version } |
            Select-Object -First 1
        if ($have) { Write-Host "  OK       $($dep.Name) $($have.Version) (needs $($dep.Version))" }
        else { Write-Host "  MISSING  $($dep.Name) (needs $($dep.Version))"; $dep }
    })

    if ($missing.Count -gt 0) {
        Write-Step "Installing $($missing.Count) missing dependencies"
        $zip = Save-VerifiedAsset $release 'DesktopAppInstaller_Dependencies.zip' 'DesktopAppInstaller_Dependencies.txt'
        $depDir = Join-Path $DownloadDir 'Dependencies'
        Expand-Archive -Path $zip -DestinationPath $depDir -Force
        foreach ($dep in $missing) {
            # Zip layout: <arch>/<Name>_<Version>_<arch>.appx
            $file = Get-ChildItem (Join-Path $depDir $arch) -Filter "$($dep.Name)_*_$arch.appx" | Select-Object -First 1
            if (-not $file) { throw "Could not find $($dep.Name) for $arch in the dependencies zip" }
            Write-Host "Add-AppxPackage $($file.Name)"
            Add-AppxPackage -Path $file.FullName
        }
    }

    Write-Step 'Downloading App Installer (winget)'
    $bundle = Save-VerifiedAsset $release 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt'
    $sig = Get-AuthenticodeSignature $bundle
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
        throw "The bundle is not validly signed by Microsoft (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject))"
    }
    Write-Host "  Signature OK: $($sig.SignerCertificate.Subject)"

    Write-Step 'Installing App Installer'
    Write-Host "Add-AppxPackage $(Split-Path $bundle -Leaf)"
    Add-AppxPackage -Path $bundle

    Write-Step 'Verifying'
    Write-Host "Installed package: $((Get-AppxPackage Microsoft.DesktopAppInstaller).PackageFullName)"
    $exe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    # The winget.exe execution alias can take a moment to appear after registration.
    for ($i = 0; $i -lt 15 -and -not (Test-Path $exe); $i++) { Start-Sleep -Seconds 1 }
    Write-Host "winget --version: $(& $exe --version)"
    Write-Host "`nDone. Installers kept in $DownloadDir" -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "Log saved to $logFile"
}
