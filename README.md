# Cage Setup

An unofficial, guided Windows installer for the **NieR Re[in]carnation** private server ([Lunar Tear](https://gitlab.com/walter-sparrow-group/lunar-tear), mirrored on [GitHub](https://github.com/Walter-Sparrow/lunar-tear)).

Double-click **`CageSetup.exe`**, press **Start setup**, and it downloads, installs and configures everything: MuMu Player, the server, the game data and the patched client. Every download shows progress, speed and time left.

![Cage Setup main window](docs/main-window.png)

> This package contains **no game APK, no game assets and no master data**. Everything is downloaded at runtime from its original host.

## Requirements

| Item | Notes |
|---|---|
| Windows 10 / 11 64-bit | |
| Virtualization (VT-x / AMD-V) | Enabled in the BIOS |
| Hyper-V disabled | MuMu needs direct hardware virtualization |
| Free disk space | ~25 GB, ~75 GB with full assets, on the drive that holds the game files |
| Administrator rights | Needed to install MuMu Player |
| Internet connection | ~20 GB of downloads |

Step 1 checks all of this at a glance.

## Usage

1. Download **`CageSetup.exe`** from [Releases](https://github.com/claitt/cage-setup/releases) (or [build it yourself](#the-executable)) and put it in a writable folder.
2. Run it and accept the UAC prompt.
3. Press **Start setup**. Steps already done are skipped, so you can press it again after a failure.
4. When the button becomes **Launch game**, the server is running: click it.

Everything is kept in the game files folder (next to `CageSetup.exe` by default); copy the folder to move it, or delete it to start over.

**Use game files...** points the installer at a folder you already have (an earlier install on another disk, or the folder with the 14.9 GB archive) and reuses everything it finds there without copying. Only what is still missing is fetched — for example, a folder with a patched APK needs neither the stock APK nor the build toolchain.

While setup runs, the primary button becomes **Cancel setup**: it stops the current step and keeps `.part` files for resume. Enter activates the primary button; Esc cancels a running setup or closes the window.

**Open log** opens `installer-log.txt`. **Copy diagnostics** puts version, Windows build, component states and last log lines on the clipboard. **Refresh** re-checks the steps. **Advanced...** runs a single component; **Start / Stop / Restart** control the server.

## The executable

`CageSetup.exe` is `Cage Setup.ps1` from this repository packed into one executable with [ps2exe](https://github.com/MScholtes/PS2EXE). It embeds an administrator manifest (hence the UAC prompt) and can be rebuilt byte-for-byte by anyone.

**Build it yourself** (PowerShell 5.1):

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-PS2EXE -InputFile "Cage Setup.ps1" -OutputFile "CageSetup.exe" `
  -noConsole -requireAdmin -STA -iconFile "assets\cage.ico" `
  -title "Cage Setup" -product "Cage Setup" -version "1.4.1.0"
```

The exact command is in [`.github/workflows/build.yml`](.github/workflows/build.yml). Pushing a tag such as `v1.4.1` publishes both files on Releases; the workflow rejects a tag that does not match `$Script:AppVersion`.

**Verify the download** — every release has a build provenance attestation:

```powershell
gh attestation verify CageSetup.exe --repo claitt/cage-setup
```

`CageSetup.exe.sha256` contains the SHA256 of the file. You can also run the script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Cage Setup.ps1"
```

It behaves like the executable; only the icon differs and it does not elevate itself (run PowerShell as administrator to install MuMu).

## Where the files come from

| Resource | Host | Size |
|---|---|---|
| Server binaries | GitHub Releases (Lunar Tear, pinned, SHA256) | ~33 MB |
| Game assets | archive.org (nier_reincarnation_assets) | 14.93 GB (~48.8 GB extracted) |
| Master data | archive.org (20240404193219.bin) | 7.4 MB (patched locally) |
| Game client (APK) | APKMirror (NieR Re[in]carnation 3.7.1) | 251 MB (patched locally) |
| Patcher scripts | lunar-scripts (pinned commit) | ~64 KB |
| MuMu Player | official NetEase download (signature-checked) | ~5 GB with engine |
| Toolchain | Adoptium, Apktool, Android build tools, python.org, PyPI | ~140 MB |

Downloads are resumable (`.part` files). Every file is pinned by size and hash before being unpacked or executed: SHA256 for toolchain and stock APK, SHA1 where the host publishes only that.

## Development

```powershell
# lint
Invoke-ScriptAnalyzer -Path "Cage Setup.ps1" -Settings PSScriptAnalyzerSettings.psd1

# tests (Pester 5.7)
Invoke-Pester -Path tests -Output Detailed

# diagnostics, no GUI
powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1" -Console
```

The workflow runs the same commands, builds and smoke-tests the executable. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## Troubleshooting

**SmartScreen / antivirus flags the file.** `CageSetup.exe` is not code-signed. Compare its SHA256 with the published one, [build it yourself](#the-executable), or run `Cage Setup.ps1` directly.

**The executable does not start.** Accept the UAC prompt (administrator rights are needed for MuMu). For the actual error, run `Cage Setup.ps1` directly.

**The MuMu installer signature warning.** Its Authenticode signature must be from NetEase. Answer **No** unless the file comes from the official source.

**Asset download is huge.** 14.93 GB compressed (~48.8 GB extracted). Free space is checked before downloading and before extracting, and the transfer resumes if interrupted.

**Client build fails.** The log names the failing tool. Common causes: missing `curl.exe` (Windows older than 10 1803), APKMirror outage, or an updated `patch_apk.py`. Delete `apk\out\nier-patched.apk` to rebuild.

**APKMirror refuses the connection.** Download the APK manually, save it as `apk\stock\nier-3.7.1-stock.apk` and press the button again.

**MuMu window stays hidden.** If no progress is detected for 4 minutes the installer retries once with the window visible; Windows does not allow one process to re-show another's window.

**Emulator step stuck on "Waiting".** Press **Start setup** (or **Launch game**); the step turns green once debloat, client and ARM bridge are verified.

## License

The installer code is released under the [MIT License](LICENSE). This covers this repository only: NieR Re[in]carnation and its assets belong to Square Enix; the Lunar Tear server and lunar-scripts patchers remain their own projects. No game content is distributed here. This project is not affiliated with Square Enix, NetEase or Lunar Tear.

## Credits

- **Lunar Tear** private server - [walter-sparrow-group on GitLab](https://gitlab.com/walter-sparrow-group/lunar-tear) / [Walter-Sparrow on GitHub](https://github.com/Walter-Sparrow/lunar-tear)
- **lunar-scripts** patchers (`patch_apk.py`, `patch_masterdata.py`) - [walter-sparrow-group](https://gitlab.com/walter-sparrow-group/lunar-scripts)

Without their work this installer would not exist.
