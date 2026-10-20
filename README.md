# Cage Setup

An unofficial, guided Windows installer for the **NieR Re[in]carnation** private
server ([Lunar Tear](https://gitlab.com/walter-sparrow-group/lunar-tear), mirrored
on [GitHub](https://github.com/Walter-Sparrow/lunar-tear)).

Double-click **`CageSetup.exe`**, press **Start setup**, and it downloads,
installs and configures everything: MuMu Player, the server, the game data and
the patched client. Every download shows progress, speed and the time left.

![Cage Setup main window](docs/main-window.png)

> This package contains **no game APK, no game assets and no master data**. The
> stock APK comes from APKMirror, the game data from archive.org, and both the
> client and the master data are patched locally with `lunar-scripts`.

## Requirements

| Item | Notes |
|---|---|
| Windows 10 / 11 64-bit | |
| Virtualization (VT-x / AMD-V) | Enabled in the BIOS |
| Hyper-V disabled | MuMu needs direct hardware virtualization |
| Free disk space | ~25 GB (~75 GB with the game assets), on the game files drive |
| Administrator rights | Needed to install MuMu Player |
| Internet connection | ~20 GB of downloads |

Step 1 checks all of this and lists what has to be fixed.

## Usage

1. Download **`CageSetup.exe`** from [Releases](https://github.com/claitt/cage-setup/releases)
   and put it in a folder you can write to.
2. Run it and accept the UAC prompt. **Start setup** skips the steps that are
   already done, so the same button can be pressed again after a failure.
3. When the button becomes **Launch game**, the server is running: click it.

Everything is kept in the game files folder, which starts next to
`CageSetup.exe`; delete that folder to start over. **Use game files...** points
the installer at files you already have (a previous installation, another disk,
or the saved 14.9 GB archive) and reuses them without copying, downloading only
what is missing. The choice is remembered in `data-folder.txt` next to the
executable; **Use installer folder** goes back to the default.

While setup runs, the primary button becomes **Cancel setup** and keeps the
`.part` files, so **Start setup** resumes. Enter activates the primary button;
Esc cancels or closes. **Open log** opens `installer-log.txt`, **Copy
diagnostics** copies the state and the last log lines for a bug report,
**Advanced...** runs a single component, and **Start / Stop / Restart** control
the server.

## The executable

`CageSetup.exe` is **not a separate program**: it is `Cage Setup.ps1` from this
repository packed with [ps2exe](https://github.com/MScholtes/PS2EXE). The script
stays readable, the executable can be rebuilt by anyone, and the embedded
administrator manifest is why Windows shows the UAC prompt.

Build it on GitHub with **Actions -> Build CageSetup.exe -> Run workflow**: it
lints and tests the script, packs it, smoke-tests the executable and uploads it
with its SHA256. A tag such as `v1.4.1` also publishes the files; the workflow
rejects a tag that does not match `$Script:AppVersion`. On your PC:

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-PS2EXE -InputFile "Cage Setup.ps1" -OutputFile "CageSetup.exe" `
  -noConsole -requireAdmin -STA -iconFile "assets\cage.ico" `
  -title "Cage Setup" -product "Cage Setup" -version "1.4.1.0"
```

Every release has a
[build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations):

```
gh attestation verify CageSetup.exe --repo claitt/cage-setup
```

`CageSetup.exe.sha256` contains the hash. To run the script directly, use
`powershell -NoProfile -ExecutionPolicy Bypass -File "Cage Setup.ps1"` from an
administrator prompt (the icon is missing).

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
the transfer continues from the `.part` file. Everything is pinned by size and
hash before it is unpacked or executed: SHA256 for the toolchain and the stock
APK, SHA1 where the host publishes only that (assets, master data).

## Development

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

**Windows protects your PC, or the antivirus flags the file.** The executable is
not code-signed and PowerShell-packed files trigger false positives; compare the
SHA256 with the published one, [build it yourself](#the-executable), or run
`Cage Setup.ps1` directly.

**The executable does not start, or MuMu asks for confirmation.** Accept the UAC
prompt and check `installer-log.txt` for the error. The MuMu prompt means its
signature is not from NetEase: answer **No** unless it comes from the official
source.

**The asset download is huge.** 14.9 GB compressed, ~48.8 GB extracted; the free
space is checked first and the download resumes if interrupted.

**The client build fails, or APKMirror refuses the connection.** The log names
the failing tool. If the APK link cannot be read, download it manually as
`apk\stock\nier-3.7.1-stock.apk` and press the button again; delete
`apk\out\nier-patched.apk` to force a rebuild.

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
