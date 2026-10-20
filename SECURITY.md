# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately
through GitHub:

<https://github.com/claitt/cage-setup/security/advisories/new>

Include what you found and how to reproduce it. If the problem shows up while
the installer runs, attach the log (`installer-log.txt`, next to the
executable). You will get an answer as soon as possible, usually within a few
days.

## Scope

This repository contains the installer only: a PowerShell script and the
workflow that packs it into `CageSetup.exe`.

In scope:

- the script and the build workflow;
- the download and verification logic (pinned versions, checksums, signatures);
- anything that could run code on a user's PC with the installer's privileges.

Out of scope (report these to their authors):

- NieR Re[in]carnation and its assets, which belong to Square Enix;
- the Lunar Tear server: <https://github.com/Walter-Sparrow/lunar-tear>;
- the lunar-scripts patchers: <https://gitlab.com/walter-sparrow-group/lunar-scripts>;
- MuMu Player and the Android toolchain, which are downloaded at runtime.

## What the installer verifies

- The server archive comes from a pinned release and is checked against a
  SHA256 before it is extracted.
- The toolchain (JRE, apktool, build tools, Python) and the stock APK are pinned
  by size and SHA256; a mismatch deletes the file and fails the step.
- The game assets and the master data use the SHA1 published by archive.org.
- The patcher scripts are pinned to a commit of `lunar-scripts`.
- The MuMu installer must have a valid Authenticode signature from NetEase
  before it is launched with administrator rights.
- Releases are built by GitHub Actions with a build provenance attestation:

  ```
  gh attestation verify CageSetup.exe --repo claitt/cage-setup
  ```

- `CageSetup.exe.sha256` contains the SHA256 of the executable.

The executable itself is not code-signed: SmartScreen may warn about it. You can
build it yourself from the source, or run `Cage Setup.ps1` directly, and you can
always compare the checksum and the attestation.
