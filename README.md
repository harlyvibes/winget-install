# Installing winget on Windows 10 (incl. LTSC)

winget ships inside the **App Installer** package (`Microsoft.DesktopAppInstaller`). Windows 10 LTSC has no
Microsoft Store, so it has to be installed from the official GitHub release:
https://github.com/microsoft/winget-cli/releases

## Repeat on another machine (quick way)

1. Copy `Install-Winget.ps1` to the machine.
2. Sign in as the user who will use winget. The install is per-user and needs no admin rights.
3. Open PowerShell in the folder with the script and run:

   ```powershell
   Unblock-File .\Install-Winget.ps1     # only needed if the file came from a download, email or network share
   powershell -ExecutionPolicy Bypass -File .\Install-Winget.ps1 -Version v1.29.380
   ```

   Leave off `-Version` to get the newest stable release instead of the exact version used here.
   Add `-Force` to reinstall or update when winget is already installed.
4. Open a **new** terminal and run `winget --version`.

The script writes a full transcript (`Install-Winget-<timestamp>.log`) next to itself and keeps the downloaded
installers in `%TEMP%\winget-install-<timestamp>`.

## What the script does (the manual steps)

| # | Step | Command / detail |
|---|------|------------------|
| 1 | Check the OS and CPU | Needs Windows 10 1809 (build 17763) or later. The CPU decides the package architecture: `AMD64` → `x64`, `ARM64` → `arm64`, `x86` → `x86`. |
| 2 | Look up the release | `Invoke-RestMethod https://api.github.com/repos/microsoft/winget-cli/releases/tags/v1.29.380` (or `/releases/latest`) |
| 3 | Check the framework dependencies | Read `DesktopAppInstaller_Dependencies.json` from the release, then check each entry with `Get-AppxPackage -Name <Name>` (same architecture, version ≥ required). |
| 4 | Install any missing dependencies | Download `DesktopAppInstaller_Dependencies.zip`, compare its SHA256 with `DesktopAppInstaller_Dependencies.txt`, extract it, then run `Add-AppxPackage <arch>\<Name>_<Version>_<arch>.appx` for each missing one. |
| 5 | Download App Installer | `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle`. Compare its SHA256 with `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.txt` and check that it's signed by `CN=Microsoft Corporation`. |
| 6 | Install it | `Add-AppxPackage .\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle` |
| 7 | Verify | `winget --version` in a new terminal. The `winget.exe` alias lives in `%LOCALAPPDATA%\Microsoft\WindowsApps`, which is already on the user PATH. |

Dependencies required by v1.29.380:

| Package | Minimum version |
|---------|-----------------|
| Microsoft.VCLibs.140.00 | 14.0.33519.0 |
| Microsoft.VCLibs.140.00.UWPDesktop | 14.0.33728.0 |
| Microsoft.WindowsAppRuntime.1.8 | 8000.616.304.0 |

### Fully manual or offline version

Download these four files from the release page on any machine and copy them over, then run this in PowerShell
from the folder that holds them (the x64 paths are shown):

```powershell
Get-FileHash .\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle   # must equal 65DEA9C01CE08EE7B763366B27C0E651F97DB857C11CA9B9C301826C10092F2E for v1.29.380
Get-FileHash .\DesktopAppInstaller_Dependencies.zip                     # must equal the contents of DesktopAppInstaller_Dependencies.txt
Expand-Archive .\DesktopAppInstaller_Dependencies.zip -DestinationPath .\deps
Get-ChildItem .\deps\x64\*.appx | ForEach-Object { Add-AppxPackage $_.FullName }   # skip any that are already installed at the same or a newer version
Add-AppxPackage .\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
```

If `Add-AppxPackage` fails on a dependency with "a higher version of this package is already installed", that
dependency is already satisfied and the error can be ignored.

## Log from this machine (2026-10-12)

| Item | Result |
|------|--------|
| OS | Windows 10 IoT Enterprise LTSC 2021, build 19044, x64, PowerShell 5.1.19041.7725 |
| Starting point | winget had just been removed (`Remove-AppxPackage Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe`) |
| Dependencies | All already installed, nothing downloaded: VCLibs 14.0.33519.0, VCLibs.UWPDesktop 14.0.33728.0, WindowsAppRuntime.1.8 8000.946.1701.0 |
| Downloaded | `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle`, 207.2 MB, from the v1.29.380 release |
| SHA256 | `65DEA9C01CE08EE7B763366B27C0E651F97DB857C11CA9B9C301826C10092F2E` (matches the published hash) |
| Signature | Valid, `CN=Microsoft Corporation` |
| Installed | `Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe` |
| Verified | New shell: `winget --version` → `v1.29.380`. `winget source list` shows the `msstore`, `winget` and `winget-font` sources |

Full transcript: [Install-Winget-20261012-005839.log](Install-Winget-20261012-005839.log)

Not used: `Downloads\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle` (an older v1.29.290 copy) and
`Downloads\DesktopAppInstaller_Dependencies.zip` (doesn't match the v1.29.380 hash).

## Notes

- **Per-user install.** Every Windows account that needs winget has to run the script. An admin can provision
  it for all accounts with `Add-AppxProvisionedPackage -Online -PackagePath <msixbundle> -LicensePath <..._License1.xml> -DependencyPackagePath <appx files>`,
  using the license XML from the same release. This wasn't tested here.
- **First use.** The first `winget search` or `winget install` asks you to accept the msstore source terms. For
  unattended scripts, add `--accept-source-agreements --accept-package-agreements`.
- **Updates.** LTSC has no Store, so winget won't update itself. To update it, rerun the script with `-Force`
  (without `-Version`).
- **Uninstall.** `Get-AppxPackage Microsoft.DesktopAppInstaller | Remove-AppxPackage`. This leaves the shared
  frameworks and any apps installed through winget in place.
