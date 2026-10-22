# The Cage Setup

Unofficial Windows setup for NieR Reincarnation, through the Lunar Tear private server. It installs MuMu Player, the game files and the client, then starts the server and launches the game.

The emulator setup uses Walter Sparrow's files.

[![Support on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/claitt)

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

## Stack

WinUI 3 (Windows App SDK), .NET 9.

## Legacy

The previous PowerShell installer is preserved on the `legacy/1.x` branch.

## License

MIT. See [LICENSE](LICENSE).
