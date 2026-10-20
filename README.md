# Cage Setup

An unofficial, guided Windows installer for the **NieR Re[in]carnation** private
server ([Lunar Tear](https://gitlab.com/walter-sparrow-group/lunar-tear), mirrored
on [GitHub](https://github.com/Walter-Sparrow/lunar-tear)).

Double-click **`CageSetup.exe`**, press **Start setup**, and it downloads,
installs and configures everything: MuMu Player, the server, the game data and
the patched client. Every download shows progress, speed and the time left.

![Cage Setup main window](docs/main-window.png)

> This package contains **no game APK, no game assets and no master data**. The
> stock APK comes from APKMirror and is patched on your PC; the game data comes
> from archive.org; the master data is patched locally with `lunar-scripts`.

## Requirements

| Item | Notes |
|---|---|
| Windows 10 / 11 64-bit | |
| Virtualization (VT-x / AMD-V) | Enabled in the BIOS |
| Hyper-V disabled | MuMu needs direct hardware virtualization |
| Free disk space | ~25 GB, ~75 GB with the full game assets, on the drive that holds the game files |
| Administrator rights | Needed to install MuMu Player |
| Internet connection | ~20 GB of downloads |

Step 1 checks all of this and lists what has to be fixed, so the window shows at
a glance whether the PC is ready.

## Usage

1. Download **`CageSetup.exe`** from [Releases](https://github.com/claitt/cage-setup/releases)
   (or [build it yourself](#the-executable)) and put it in a folder you can write to.
2. Run it and accept the UAC prompt. The six steps show **Ready** (green),
   **Waiting** (grey), **Check** (amber) or **Problem** (red).
3. Press **Start setup** (~20 GB of downloads). Steps that are already done are
   skipped, so the same button can be pressed again after a failure.
4. When the button becomes **Launch game**, the server is running: click it.

Everything is kept in the game files folder, which starts next to
`CageSetup.exe`, so the folder is portable: copy it, or delete it to start over.
**Use game files...** points the installer at a folder you already have (a
previous installation on another disk, or the folder where the 14.9 GB archive
is saved) and reuses everything it finds there without copying. The choice is
remembered in `data-folder.txt` next to the executable; **Use installer folder**
in that dialog goes back to the default.

While setup runs, the primary button becomes **Cancel setup**. It stops the
current download or installation and keeps the `.part` files, so the next
**Start setup** resumes. Enter activates the primary button; Esc cancels a
running setup or closes the window.

**Open log** opens `installer-log.txt`. **Copy diagnostics** puts the version,
the Windows build, the component states and the last 40 log lines on the
clipboard, ready for a bug report. **Refresh** re-checks the steps.
**Advanced...** runs a single component. The **Start / Stop / Restart** row
controls the server.

### Version, updates, display

The version is in the window title and on the right of the header; click it to
open the releases page. At startup the installer asks the public GitHub API for
the latest release (one request, nothing about the PC is sent) and the label
becomes **Update: vX.Y.Z** when a newer version exists.

Only one installer runs per executable folder. The window is DPI aware and
scales on 125% and 150% displays; on a screen that is too small it is reduced
and scrolls.

### The six steps

| Step | Download | What it does |
|---|---|---|
| **1. Check your PC** | - | Windows 64-bit, virtualization, Hyper-V, free space, administrator rights. |
| **2. Install the emulator** | ~5 GB | Installs MuMu Player, waits for the Android engine, removes only the NetEase/MuMu bloatware (Google services stay). |
| **3. Get the game files** | ~15.4 GB | Server binaries, master data, patched client and the 14.9 GB game assets. |
| **4. Install the game** | - | Installs the patched APK on MuMu through ADB. |
| **5. Start the server** | - | Starts the private server (gRPC 8003, CDN 8080). |
| **6. Launch the game** | - | Opens the game on the emulator. |

### How the client and the master data are prepared

The client needs a modified APK (server addresses, SSL, encryption, billing
checks), and a modified APK must be signed again. The installer downloads the
stock APK 3.7.1 from APKMirror, fetches the toolchain on demand (JRE 17,
apktool, Android build tools, portable Python; ~140 MB, reused afterwards),
applies `patch_apk.py` from `lunar-scripts`, rebuilds, aligns and signs it with a
local debug key. The result is `apk\out\nier-patched.apk`; the build takes a few
minutes (10-20 on slower PCs).

The master data on archive.org is the original file. `patch_masterdata.py`
extends the content end dates to 2030-12-31, unlocks the Labyrinth event quests
and removes the maintenance notice. The result is byte-identical to the file
used by the reference server, so no pre-patched copy is hosted anywhere.

## The executable

`CageSetup.exe` is **not a separate program**: it is `Cage Setup.ps1` from this
repository packed into one executable with
[ps2exe](https://github.com/MScholtes/PS2EXE). The script stays readable in the
repository, so you can see exactly what runs, and the executable can be rebuilt
byte-for-byte by anyone.

It embeds an administrator manifest (`requireAdministrator`), which is why
Windows shows the UAC prompt.

### Build it yourself

On GitHub: **Actions -> Build CageSetup.exe -> Run workflow**. The build lints
and tests the script, packs it, smoke-tests the executable and uploads
`CageSetup.exe` with its SHA256. Pushing a tag such as `v1.3.0` also publishes
both files on the Releases page; the workflow rejects a tag that does not match
`$Script:AppVersion`.

On your PC (PowerShell 5.1):

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-PS2EXE -InputFile "Cage Setup.ps1" -OutputFile "CageSetup.exe" `
  -noConsole -requireAdmin -STA -iconFile "assets\cage.ico" `
  -title "Cage Setup" -product "Cage Setup" -version "1.4.0.0"
```

The exact command is in [`.github/workflows/build.yml`](.github/workflows/build.yml).

### Verify the download

Every release is built by that workflow and has a
[build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations).
With the GitHub CLI installed:

```
gh attestation verify CageSetup.exe --repo claitt/cage-setup
```

`CageSetup.exe.sha256` contains the SHA256 of the file. Running the script
directly is also possible:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Cage Setup.ps1"
```

It behaves like the executable; only the icon differs and it does not ask for
administrator rights by itself (start PowerShell as administrator to install
MuMu Player). Double-clicking a `.ps1` opens it in an editor instead.

## Where the files come from

| Resource | Host | Size |
|---|---|---|
| Server binaries | [GitHub Releases](https://github.com/Walter-Sparrow/lunar-tear/releases) (pinned release, SHA256) | ~33 MB |
| Game assets | [archive.org: nier_reincarnation_assets](https://archive.org/details/nier_reincarnation_assets) | 14.93 GB (~48.8 GB extracted) |
| Master data | [archive.org: 20240404193219.bin](https://archive.org/details/20240404193219.bin) | 7.4 MB (patched locally) |
| Game client (APK) | [APKMirror: NieR Re[in]carnation 3.7.1](https://www.apkmirror.com/apk/square-enix-co-ltd/nier-reincarnation/nier-reincarnation-3-7-1-release/) | 251 MB (patched locally) |
| Patcher scripts | [lunar-scripts](https://gitlab.com/walter-sparrow-group/lunar-scripts) (pinned commit) | ~64 KB |
| MuMu Player | official NetEase download (signature-checked) | ~5 GB with the engine |
| Toolchain | Adoptium, Apktool, Android SDK Build-Tools, python.org, PyPI | ~140 MB |

Downloads are **resumable**: if the connection drops, press the button again and
the transfer continues from the `.part` file. Every file is pinned by size and
hash before it is unpacked or executed: SHA256 for the toolchain and the stock
APK, SHA1 where the host publishes only that (assets, master data).

## Configuration (for distributors)

Open `Cage Setup.ps1` and edit the `$Config` block at the top. No value has to be
filled in: every source already points to a public host.

| Key | Meaning |
|---|---|
| `ServerUrl` / `ServerBytes` / `ServerSha256` | Pin a specific server build instead of the latest release |
| `MasterUrl` / `MasterBytes` / `MasterSha1` | Different master data host |
| `AssetsUrl` / `AssetsBytes` / `AssetsSha1` | Different game assets host |
| `ApkPageUrl` / `ApkStockBytes` / `ApkStockSha256` | Different APK version on APKMirror |
| `GrpcAddr` / `HttpAddr` / `AuthAddr` | Addresses written into the client (`10.0.2.2` is the host as seen from the emulator) |
| `JreUrl` / `ApktoolUrl` / `BuildToolsUrl` / `PythonUrl` (+ `*Bytes`, `*Sha256`) | Mirrors and pins for the toolchain |
| `ScriptsRaw` | Base URL of the `lunar-scripts` raw files (pin a commit to freeze the patcher) |

### Pinned sources

| What | Where | How to update |
|---|---|---|
| Patcher scripts | `ScriptsRaw` points to a `lunar-scripts` commit, not to `main` | copy the new commit hash into the URL |
| Server binaries | `ServerUrl`, `ServerBytes`, `ServerSha256` | copy size and SHA256 of the new release archive into `$Config` |
| Toolchain and stock APK | `*Bytes`, `*Sha256` | copy size and SHA256 of the new file |

To follow the latest server release again, set `ServerUrl` to an empty string and
clear `ServerSha256`. The MuMu installer is checked with its Authenticode
signature (the publisher must contain "Netease") before it is launched elevated;
if the check fails, the GUI asks for confirmation and the console mode aborts.

## Offline installation

If the files are already on disk, the installer uses them and skips the download.
Put them in the game files folder, or point **Use game files...** at the folder
that contains them; the archive is also found when it sits directly in that
folder instead of `downloads\`.

| File | Expected path |
|---|---|
| Server binaries | `server\wizard.exe` + `server\bin\` |
| Game assets | `server\assets\revisions\` |
| Master data | `server\assets\release\20240404193219.bin.e` (patched or original) |
| Stock APK | `apk\stock\nier-3.7.1-stock.apk` |
| Patched APK | `apk\out\nier-patched.apk` (any previous build is reused) |
| Assets archive | `downloads\resource_dump_android.7z` |
| Toolchain | `tools\jdk*`, `tools\apktool.jar`, `tools\android-sdk\build-tools`, `tools\python` |
| Patcher scripts | `tools\lunar-scripts\` |
| MuMu offline package | `tools\mumu\offline\MuMuNG-offline-setup.exe` |

A master data file that is neither the archive.org original nor a file this
installer patched is left untouched. The only other network request is the
optional update check, which never blocks.

## Development

The installer is a single PowerShell file on purpose: the executable is that
file, so what you read is what runs.

```powershell
# lint
Invoke-ScriptAnalyzer -Path "Cage Setup.ps1" -Settings PSScriptAnalyzerSettings.psd1

# tests (Pester 5.7)
Invoke-Pester -Path tests -Output Detailed

# diagnostics, no GUI
powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1" -Console
```

The workflow runs the same commands, builds the executable and smoke-tests the
packed script. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and
[SECURITY.md](SECURITY.md) to report a problem privately.

## Troubleshooting

**Windows says "Windows protected your PC", or the antivirus flags the file.**
`CageSetup.exe` is not code-signed, and executables packed from PowerShell are a
common source of false positives. Compare its SHA256 with the published one,
[build it yourself](#the-executable), or run `Cage Setup.ps1` directly.

**The executable does not start.**
Accept the UAC prompt: administrator rights are needed for MuMu. For the actual
error, run `powershell -NoProfile -ExecutionPolicy Bypass -File "Cage Setup.ps1"`.

**The installer asks whether to run the MuMu installer.**
Its Authenticode signature is invalid or not from NetEase. Answer **No** unless
the file comes from the official source.

**The MuMu window stays hidden for a long time.**
If no progress is detected for 4 minutes the installer kills the setup and
retries once with the window visible. Windows does not allow one process to
re-show another process' window, hence the restart.

**The emulator step says "Waiting" although MuMu is installed.**
The debloat, client and ARM bridge can only be checked while the emulator runs.
Press **Start setup** (or **Launch game**) and the step turns green when verified.

**The asset download is huge.**
14.93 GB compressed, ~48.8 GB extracted; the installer checks the free space
before downloading and before extracting. The download resumes if interrupted.

**The client build fails.**
The log names the failing tool and its output. Usual causes: no `curl.exe`
(Windows older than 10 1803), an APKMirror outage, or an updated `patch_apk.py`.
The stock APK stays in `apk\stock\`; delete `apk\out\nier-patched.apk` to rebuild.

**APKMirror refuses the connection.**
Its pages are read with `curl.exe` because the site rejects the .NET HTTP stack.
If the layout changes the log says "download link not found": download the APK
manually, save it as `apk\stock\nier-3.7.1-stock.apk` and press the button again.

**Re-enable a removed package.**

```
adb -s 127.0.0.1:7555 shell pm install-existing <package>
adb -s 127.0.0.1:7555 shell pm enable --user 0 <package>
```

## License

The installer code is released under the [MIT License](LICENSE). That covers this
repository only: NieR Re[in]carnation and its assets belong to Square Enix, while
the Lunar Tear server and the lunar-scripts patchers remain their own projects.
No game content is distributed here.

## Credits

- **Lunar Tear** private server - [walter-sparrow-group on GitLab](https://gitlab.com/walter-sparrow-group/lunar-tear) / [Walter-Sparrow on GitHub](https://github.com/Walter-Sparrow/lunar-tear)
- **lunar-scripts** patchers (`patch_apk.py`, `patch_masterdata.py`) - [walter-sparrow-group](https://gitlab.com/walter-sparrow-group/lunar-scripts)

**Without their work this installer would not exist.** The server, the client
patch and the master data patch are built on the Lunar Tear project and the
lunar-scripts tooling; Cage Setup only automates the steps around them.

NieR Re[in]carnation and all related assets are property of Square Enix. This
project is a community preservation effort, not affiliated with Square Enix,
NetEase or the Lunar Tear project.
