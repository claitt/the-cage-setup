# Cage Setup

An unofficial, guided Windows installer for the **NieR Re[in]carnation** private
server ([Lunar Tear](https://gitlab.com/walter-sparrow-group/lunar-tear), mirrored on
[GitHub](https://github.com/Walter-Sparrow/lunar-tear)).

Double-click **`CageSetup.exe`**, press **Start setup**, and the installer
downloads, installs and configures everything: the MuMu Player emulator, the
server, the game data and the patched client. Every download shows status,
percentage, speed and the estimated time left.

![Cage Setup main window](docs/main-window.png)

> This package contains **no game APK, no game assets and no master data**.
> The stock APK is downloaded from APKMirror and patched on your PC; the game
> data is downloaded from archive.org and the master data is patched locally
> with the official `lunar-scripts` tool.

---

## Requirements

| Item | Notes |
|---|---|
| Windows 10 / 11 64-bit | |
| Virtualization (VT-x / AMD-V) | Must be enabled in the BIOS |
| Hyper-V disabled | MuMu needs direct hardware virtualization |
| Free disk space | ~25 GB, ~75 GB if you install the full game assets |
| Administrator rights | Required to install MuMu Player |
| Internet connection | ~20 GB of downloads in total |

The first step checks these requirements and tells you what to fix if something
is missing, so you can see at a glance whether the PC is ready.

---

## Usage

1. Download **`CageSetup.exe`** from the [Releases](https://github.com/claitt/cage-setup/releases)
   page and put it in a folder you can write to (Desktop, Downloads, ...), or
   [build it yourself](#the-executable).
2. Run it and accept the administrator prompt (it is needed to install MuMu
   Player). The window lists six steps. Each one shows **Ready** (green),
   **Waiting** (grey) or **Problem** (red); step 1 also tells you what to fix,
   if anything.
3. Press **Start setup** (about 20 GB of downloads): the installer runs the
   steps that are not ready yet and skips everything already in place.
4. When the button changes to **Launch game**, the server is running: click it.

Everything the installer downloads (tools, client, assets, server) is kept in
the folder that contains `CageSetup.exe`, so the whole setup is portable: copy
the folder or delete it to start over.

### Version, updates, display

The version is shown in the window title and on the right of the header; click
it to open the releases page. At startup the installer asks the public GitHub
API for the latest release (one request, nothing about the PC is sent) and the
label becomes **Update: vX.Y.Z** when a newer version exists.

Only one installer can run per folder: a second copy tells you that it is
already running and exits. The window is DPI aware and scales on 125% and 150%
displays; on a screen that is too small it is reduced and scrolls.

### The six steps

| Step | Download | What it does |
|---|---|---|
| **1. Check your PC** | - | Windows 64-bit, virtualization, Hyper-V, free space, administrator rights. |
| **2. Install the emulator** | ~5 GB | Downloads and installs MuMu Player, waits for the Android engine, then removes only the NetEase/MuMu bloatware. Google services are left intact. |
| **3. Get the game files** | ~15.4 GB | Downloads the server binaries (GitHub Releases) and the master data, then builds the patched client: the stock APK is taken from APKMirror, patched with the official `lunar-scripts` patcher and signed again. Finally the 14.9 GB game assets are downloaded and extracted (archive.org). |
| **4. Install the game** | - | Installs the APK on MuMu through ADB. |
| **5. Start the server** | - | Starts the private server (gRPC 8003, CDN 8080). |
| **6. Launch the game** | - | Opens the game on the emulator. |

### Building the client

A private server needs a modified client (server addresses, SSL, encryption and
billing checks), and a modified APK must be signed again. The installer does all
of it automatically:

1. downloads the stock APK 3.7.1 from APKMirror;
2. downloads the toolchain on demand - Java (JRE 17), apktool, the Android build
   tools and a portable Python runtime, about 140 MB in total;
3. decompiles the APK, applies `android/patch_apk.py` from the upstream
   `lunar-scripts` repository and rebuilds it;
4. aligns and signs it with a local debug key (`apk/out/debug.keystore`).

The build takes a few minutes (10-20 on slower PCs). The result is
`apk\out\nier-patched.apk`. The toolchain is never committed to the repository:
it is downloaded only when needed and reused afterwards.

### Master data

The master data published on archive.org is the original file. The installer
patches it with the official `patch_masterdata.py`, which extends the content end
dates to 2030-12-31, unlocks the Labyrinth event quests and removes the
maintenance notice. The result is byte-identical to the patched file used by the
reference server (7,763,264 bytes, SHA1 `DF6F4F1A...`), so no pre-patched copy has
to be hosted anywhere.

### Buttons

- **Start setup** - runs the steps that are not ready yet. It is idempotent:
  everything already in place is skipped, so you can press it again after a
  failure. When all six steps are ready it becomes **Launch game**.
- **Launch game** - starts the server and the emulator if needed, then opens the game.
- **Open log** - opens `installer-log.txt`.
- **Refresh** - re-checks the six steps.
- **Advanced...** - runs a single component instead of the whole sequence:
  emulator, game files, client installation, server, ARM check, package inventory.
- **Start / Stop / Restart** (server row) - controls the private server.

---

## The executable

`CageSetup.exe` is **not a separate program**: it is `Cage Setup.ps1` from this
repository packed into a single executable with
[ps2exe](https://github.com/MScholtes/PS2EXE). The script stays in the
repository in plain text, so you can read exactly what the installer does before
running it, and you can build the same executable yourself.

The executable embeds an administrator manifest (`requireAdministrator`), which
is why Windows shows the UAC prompt when it starts.

### Build it yourself

On GitHub: open **Actions -> Build CageSetup.exe -> Run workflow**. The build runs
on a clean Windows runner, checks that the script parses, packs it and uploads
`CageSetup.exe` together with its SHA256 as downloadable artifacts. Pushing a
tag such as `v1.0.0` also publishes both files on the Releases page.

On your PC (PowerShell 5.1):

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-PS2EXE -InputFile "Cage Setup.ps1" -OutputFile "CageSetup.exe" `
  -noConsole -requireAdmin -STA -iconFile "assets\cage.ico" `
  -title "Cage Setup" -product "Cage Setup" -version "1.0.0.0"
```

The exact command used by the automated build is in
[`.github/workflows/build.yml`](.github/workflows/build.yml).

### Verify the download

Every release is built by that workflow and comes with a
[build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations).
With the GitHub CLI installed:

```
gh attestation verify CageSetup.exe --repo claitt/cage-setup
```

`CageSetup.exe.sha256` contains the SHA256 of the file, and the script itself
can always be read in this repository or run directly.

### Or run the script directly

No executable is required. From a PowerShell window in this folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Cage Setup.ps1"
```

The script behaves like the executable; the differences are the window icon and
the fact that it does not ask for administrator rights by itself (start
PowerShell as administrator if you need to install MuMu Player). Double-clicking
the `.ps1` does not run it: Windows opens `.ps1` files in an editor.

---

## Where the files come from

| Resource | Host | Size |
|---|---|---|
| Server binaries | [GitHub Releases](https://github.com/Walter-Sparrow/lunar-tear/releases) (pinned to v1.0.2 and verified with SHA256) | ~33 MB |
| Game assets | [archive.org: nier_reincarnation_assets](https://archive.org/details/nier_reincarnation_assets) | 14.93 GB (~48.8 GB extracted) |
| Master data | [archive.org: 20240404193219.bin](https://archive.org/details/20240404193219.bin) | 7.4 MB (patched locally) |
| Game client (APK) | [APKMirror: NieR Re[in]carnation 3.7.1](https://www.apkmirror.com/apk/square-enix-co-ltd/nier-reincarnation/nier-reincarnation-3-7-1-release/) | 251 MB (patched locally) |
| Patcher scripts | [lunar-scripts](https://gitlab.com/walter-sparrow-group/lunar-scripts) (downloaded on the first run, then cached) | ~64 KB |
| MuMu Player | official NetEase download | ~5 GB with the engine |
| Toolchain | Adoptium, Apktool, Android SDK Build-Tools, python.org, PyPI | ~140 MB |

Downloads are **resumable**: if the connection drops, press the button again and
the transfer continues from where it stopped (a `.part` file is kept until the
download is complete).

The downloaded archives are verified against their SHA1 hash where one is known.

---

## Configuration (for distributors)

Open `Cage Setup.ps1` and edit the `$Config` block at the top.
No value has to be filled in: every source already points to a public host.

Optional overrides:

| Key | Meaning |
|---|---|
| `ServerUrl` | Force a specific server build instead of the latest GitHub release |
| `MasterUrl` / `MasterBytes` / `MasterSha1` | Different master data host (the installer patches it anyway) |
| `AssetsUrl` / `AssetsBytes` / `AssetsSha1` | Different game assets host |
| `ApkPageUrl` / `ApkStockBytes` | Different APK version on APKMirror |
| `GrpcAddr` / `HttpAddr` / `AuthAddr` | Addresses written into the client (default `10.0.2.2`, the host as seen from the emulator) |
| `JreUrl` / `ApktoolUrl` / `BuildToolsUrl` / `PythonUrl` | Mirror for the toolchain |
| `ScriptsRaw` | Base URL of the `lunar-scripts` raw files (pin a commit to freeze the patcher version) |

### Pinned sources

Two things are pinned so that a new build cannot change silently:

| What | Where | How to update |
|---|---|---|
| Patcher scripts | `ScriptsRaw` points to a commit of `lunar-scripts`, not to `main` | copy the new commit hash from GitLab into the URL |
| Server binaries | `ServerUrl`, `ServerBytes`, `ServerSha256` | download the new release archive, copy its size and SHA256 into `$Config` |

The server archive is verified (SHA256) before it is extracted. The MuMu
installer is checked with its Authenticode signature (the publisher must contain
"Netease") before it is launched elevated; if the check fails, the GUI asks for
confirmation and the console mode aborts.

To follow the latest server release again, set `ServerUrl` to an empty string
and clear `ServerSha256`.

### Do not commit these files

`.gitignore` already excludes the APK, the assets, the master data, the
toolchain and the `server/` folder. Keep it that way: the repository must not
contain copyrighted game content.

---

## Offline installation

If the files are already on disk, the installer uses them and skips the download:

| File | Expected path |
|---|---|
| Server binaries | `server\wizard.exe` + `server\bin\` |
| Game assets | `server\assets\revisions\` |
| Master data | `server\assets\release\20240404193219.bin.e` (already patched, or the original to be patched) |
| Stock APK | `apk\stock\nier-3.7.1-stock.apk` |
| Patched APK | `apk\out\nier-patched.apk` (any previously built APK is reused) |
| Assets archive | `downloads\resource_dump_android.7z` |
| Toolchain | `tools\jdk*`, `tools\apktool.jar`, `tools\android-sdk\build-tools`, `tools\python` |
| Patcher scripts | `tools\lunar-scripts\` |
| MuMu offline package | `tools\mumu\offline\MuMuNG-offline-setup.exe` |

A master data file that is neither the archive.org original nor a file this
installer patched is left untouched (it is assumed to be intentional).

The only other network request is the optional update check at startup; when it
fails the installer simply carries on.

---

## Development

The installer is a single PowerShell file on purpose: the executable is that
file, so what you read is what runs.

```
# lint
Invoke-ScriptAnalyzer -Path "Cage Setup.ps1" -Settings PSScriptAnalyzerSettings.psd1

# tests (Pester 5.7)
Invoke-Pester -Path tests -Output Detailed

# diagnostics, no GUI
powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1" -Console
```

The GitHub workflow runs the same commands, then builds the executable and
smoke-tests it: it starts the packed script with `-Console` and checks that the
output is complete and that the script resolves its own folder. On a tag it also
checks that the tag matches `$Script:AppVersion`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and
[SECURITY.md](SECURITY.md) to report a problem privately.

---

## Troubleshooting

**Windows says "Windows protected your PC", or the antivirus flags the executable.**
`CageSetup.exe` is not code-signed, and executables packed from a PowerShell
script are a common source of false positives. The file is built from
`Cage Setup.ps1` in this repository by
[`.github/workflows/build.yml`](.github/workflows/build.yml): compare its
SHA256 with the one published next to the release, or
[build it yourself](#the-executable). You can also run `Cage Setup.ps1`
directly and skip the executable entirely.

**The executable does not start.**
Accept the UAC prompt: administrator rights are needed to install MuMu Player.
To see the actual error, open a PowerShell window in this folder and run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "Cage Setup.ps1"
```

**The installer asks whether to run the MuMu installer.**
Its Authenticode signature is not valid, or it was not signed by NetEase. That
is what happens with a modified or repackaged offline package: answer **No**
unless the file comes from the official source.

**The MuMu window stays hidden for a long time.**
The silent installation hides MuMu's own windows. If no progress is detected for
4 minutes the installer kills the setup and retries once with the window visible.
Windows does not allow one process to re-show another process' window, which is
why it restarts the setup instead.

**The emulator step says "Waiting" even though MuMu is installed.**
The debloat, the client and the ARM bridge can only be checked while the
emulator is running. Press **Start setup** (or *Launch game*) and the installer
starts it; the step turns green when everything is verified.

**The asset download is huge.**
The archive is 14.93 GB and extracts to about 48.8 GB. Make sure you have at
least 75 GB free on `C:`. The download resumes if interrupted.

**The client build fails.**
Check the log: the failing tool and its output are written there. The usual
causes are a missing `curl.exe` (Windows older than 10 version 1803), a
temporary APKMirror outage, or an updated `patch_apk.py` in the upstream
repository. The stock APK is kept in `apk\stock\`, so the download is not
repeated. Delete `apk\out\nier-patched.apk` to force a rebuild.

**APKMirror refuses the connection.**
The APKMirror web pages are fetched with `curl.exe`, because the site rejects
the .NET HTTP stack with a 403. If the page layout changes, the log will say
"download link not found": download the APK manually from the link above, save
it as `apk\stock\nier-3.7.1-stock.apk` and press the button again.

**Re-enable a removed package.**
```
adb -s 127.0.0.1:7555 shell pm install-existing <package>
adb -s 127.0.0.1:7555 shell pm enable --user 0 <package>
```

---

## License

The installer code is released under the [MIT License](LICENSE).

That covers this repository only: NieR Re[in]carnation and its assets belong to
Square Enix, while the Lunar Tear server and the lunar-scripts patchers remain
their own projects with their own authors. No game content is distributed here.

---

## Credits

- **Lunar Tear** private server - [walter-sparrow-group on GitLab](https://gitlab.com/walter-sparrow-group/lunar-tear) / [Walter-Sparrow on GitHub](https://github.com/Walter-Sparrow/lunar-tear)
- **lunar-scripts** patchers (`patch_apk.py`, `patch_masterdata.py`) - [walter-sparrow-group](https://gitlab.com/walter-sparrow-group/lunar-scripts)

**Without their work this installer would not exist.** The server, the client
patch and the master data patch are all built on the Lunar Tear project and on
the lunar-scripts tooling; Cage Setup only automates the steps around them.

NieR Re[in]carnation and all related assets are property of Square Enix.
This project is a community preservation effort and is not affiliated with
Square Enix, NetEase or the Lunar Tear project.
