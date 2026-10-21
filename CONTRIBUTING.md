# Contributing

Thanks for helping. Cage Setup is deliberately small: one main script, a few
modules, one workflow, no runtime dependencies.

## Before you start

- Everything in the repository is in English: UI, log messages, comments, file
  names.
- The installer must keep working on Windows 10/11 with Windows PowerShell 5.1:
  no PowerShell 7-only syntax and no external modules at runtime.
- No game content, toolchain binaries or personal data in the repository:
  everything is downloaded at runtime from its official source.
- Keep the executable single-file: `build.ps1` inlines `lib\*.ps1` before
  ps2exe packs the result.

## Layout

- `Cage Setup.ps1`: the sources and paths, the console output and the GUI.
- `lib\00-paths.ps1` ... `lib\07-engine.ps1`: the logic, grouped by section.
  The numbering is the load order.
- `build.ps1`: assembles the sources into `dist\CageSetup.bundled.ps1` and,
  with `-Pack`, into `dist\CageSetup.exe`.
- `tests\CageSetup.Tests.ps1`: Pester tests. They load the modules directly.

## Run it, check it

```powershell
# diagnostics, no GUI
powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1" -Console

# GUI from source
powershell -ExecutionPolicy Bypass -File "Cage Setup.ps1"

# lint (PSScriptAnalyzer)
Invoke-ScriptAnalyzer -Path 'Cage Setup.ps1' -Settings PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path lib -Settings PSScriptAnalyzerSettings.psd1 -Recurse

# tests (Pester 5.7)
Invoke-Pester -Path tests -Output Detailed

# bundle, and optionally pack the executable
.\build.ps1
.\build.ps1 -Pack
```

The workflow runs the linter, the tests, packs the executable and smoke-tests
it. A pull request that changes the script must keep those green.

## Style

- 4 spaces, no tabs, CRLF in the script (see `.gitattributes`).
- Comments and log messages in English, short and factual.
- Explain **why** a workaround exists, not what the next line obviously does.
  The comments about `ShowWindow`, ADB timings and the `.part` files are the
  model.
- The section banners at the top of each file are the map: keep them in sync when
  you add a section.
- Text shown in the window should also reach the log where that helps support.

## Updating a pinned source

- `lunar-scripts`: copy the full commit hash from GitLab into `ScriptsRaw`.
- Server: copy the release URL, size and SHA256 into `ServerUrl`, `ServerBytes`
  and `ServerSha256` in the `$Config` block at the top of `Cage Setup.ps1`.
- Toolchain and stock APK: copy the new file's size and SHA256 into the matching
  `*Bytes` / `*Sha256` values in `$Config`. The installer verifies the hash before
  it unpacks or runs anything; a mismatch deletes the file and fails the step.
- Assets and master data keep their SHA1 pins: those are the checksums published
  by archive.org.

## Commits and pull requests

- Small commits with a clear message. If a commit closes an issue, say so:
  `Fixes #12`.
- For anything larger than a typo, use a branch and a pull request, even when
  you are the only maintainer. The description should say what changed, why,
  and what you tested.
- The version lives in `Cage Setup.ps1` (`$Script:AppVersion`), not in the
  workflow. A tag must match it: the workflow refuses to build `v1.2.3` when the
  script says something else.

## Releases

- Fewer, more substantial releases. Group related fixes instead of tagging every
  small change.
- Release by pushing a tag: the workflow attaches the executable, its checksum
  and the build provenance attestation.
- Release notes should describe what changed for the user. Do not repeat the
  requirements or the credits from the README, and do not use the same template
  every time: a short paragraph is fine when the release is small.
