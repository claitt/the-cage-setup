# Contributing

Thanks for helping. Cage Setup is intentionally small: one PowerShell file, one
workflow, no runtime dependencies.

## Before you start

- Everything in the repository is in English: UI, log messages, comments, file
  names.
- The installer must keep working on Windows 10/11 with Windows PowerShell 5.1:
  no PowerShell 7-only syntax and no external modules at runtime.
- No game content, toolchain binaries or personal data in the repository:
  everything is downloaded at runtime from its official source.
- Keep the executable single-file: the workflow packs `Cage Setup.ps1` as it is.

## Run it, check it

```powershell
# diagnostics, no GUI
powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1" -Console

# GUI from source
powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1"

# lint (PSScriptAnalyzer)
Invoke-ScriptAnalyzer -Path "Cage Setup.ps1" -Settings PSScriptAnalyzerSettings.psd1

# tests (Pester 5.7)
Invoke-Pester -Path tests -Output Detailed
```

The workflow runs the linter, the tests, packs the executable and smoke-tests
it. A pull request that changes the script must keep those green.

## Style

- 4 spaces, no tabs, CRLF in the script (see `.gitattributes`).
- Comments and log messages in English, short and factual.
- The section banners at the top of the file are the map: keep them in sync when
  you add a section.
- Text shown in the window should also reach the log where that helps support.

## Updating a pinned source

- `lunar-scripts`: copy the full commit hash from GitLab into `ScriptsRaw`.
- Server: copy the release URL, size and SHA256 into `ServerUrl`, `ServerBytes`
  and `ServerSha256` in the `$Config` block at the top of the script.
- Toolchain and stock APK: copy the new file's size and SHA256 into the matching
  `*Bytes` / `*Sha256` values in `$Config`. The installer verifies the hash before
  it unpacks or runs anything; a mismatch deletes the file and fails the step.
- Assets and master data keep their SHA1 pins: those are the checksums published
  by archive.org.

## Commits and releases

- Small commits with a clear message.
- The version lives in `Cage Setup.ps1` (`$Script:AppVersion`), not in the
  workflow. A tag must match it: the workflow refuses to build `v1.2.3` when the
  script says something else.
- Release by pushing a tag: the workflow attaches the executable, its checksum
  and the build provenance attestation.
