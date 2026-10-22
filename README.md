# The Cage Setup

Unofficial Windows setup for NieR Reincarnation, through the Lunar Tear private server. It installs MuMu Player, the game files and the client, then starts the server and launches the game.

![The Cage Setup, step 3](docs/screenshot.png)

[![Support on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/claitt)

## Download

Grab `CageSetup2-2.0.0-win-x64.zip` from the [latest release](https://github.com/claitt/the-cage-setup/releases/latest) and extract it anywhere. Run `CageSetup2.exe` from the extracted folder and keep the folder in place: game files and server data are created next to it.

Windows SmartScreen will warn about an unknown publisher, since the build is not code-signed. Choosing "More info" then "Run anyway" is expected.

## Requirements

- Windows 11, x64, administrator rights
- Virtualization enabled in firmware
- About 65 GB free for the game assets (15 GB download, 49 GB extracted)

## Build

```powershell
powershell -ExecutionPolicy Bypass -File .\build-winui.ps1
```

The output is a self-contained build in `dist\CageSetup2\`. Run `CageSetup2.exe` from there.

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
