# The Cage Setup

Unofficial Windows setup for NieR Reincarnation, through the Lunar Tear private server. It installs MuMu Player, the game files and the client, then starts the server and launches the game.

![The Cage Setup, step 3](docs/screenshot.png)

[![Support on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/claitt)

## Download

1. Open the [latest release](https://github.com/claitt/the-cage-setup/releases/latest).
2. Download the `TheCageSetup-<version>-setup.exe` from that page and run it.
3. Choose the folder where game files may live. It defaults to `%LOCALAPPDATA%\Programs\The Cage Setup`; pick another drive if you need the ~65 GB elsewhere.

The installer adds a Start Menu shortcut and an uninstaller. Installed game files are kept when you uninstall.

The build is not code-signed, so Windows SmartScreen shows an unknown-publisher warning. Choose "More info", then "Run anyway".

A portable `TheCageSetup.exe` is attached to the same release if you prefer no installation. Keep its file name: the single-file build looks up its bundled resources by its own name.

Already have the game files? On step 3, **Choose local files** points the setup at a folder that already holds them, and the page shows where downloads go. The choice is saved in `settings.ini` next to the executable.

## Requirements

- Windows 11, x64, administrator rights (step 1 can restart the setup with elevation)
- Virtualization enabled in firmware
- About 65 GB free for the game assets (15 GB download, 49 GB extracted)

## Build

```powershell
powershell -ExecutionPolicy Bypass -File .\build-winui.ps1
```

The output is a single self-contained executable in `dist\TheCageSetup\`.

## Installer

```powershell
powershell -ExecutionPolicy Bypass -File .\build-installer.ps1
```

Publishes the app and wraps it with [Inno Setup](https://jrsoftware.org/isinfo.php) 6 (`winget install JRSoftware.InnoSetup`). The result is `dist\installer\TheCageSetup-<version>-setup.exe`.

The version comes from `<Version>` in the project file. The installer keeps a fixed `AppId`, so a newer build installs over the previous one and updates the existing entry instead of adding a second one.

## Tests

```powershell
dotnet test CageSetup.Tests\CageSetup.Tests.csproj -c Release -p:Platform=x64
```

## Credits

- [Lunar Tear](https://github.com/Walter-Sparrow/lunar-tear): the private server.
- [lunar-scripts](https://gitlab.com/walter-sparrow-group/lunar-scripts): the patchers used for master data and client.

## Stack

WinUI 3 (Windows App SDK), .NET 9.

## Legacy

The previous PowerShell installer is preserved on the `legacy/1.x` branch.

## License

MIT. See [LICENSE](LICENSE).
