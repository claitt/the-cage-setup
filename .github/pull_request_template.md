<!--
  Thanks for the pull request. Keep it small and say what you tested.
-->

## What changed

## Why

<!-- Link the issue this closes, if there is one: Fixes #12 -->

## How I tested it

- [ ] `Invoke-Pester -Path tests -Output Detailed`
- [ ] `Invoke-ScriptAnalyzer -Path 'Cage Setup.ps1' -Settings PSScriptAnalyzerSettings.psd1`
- [ ] `Invoke-ScriptAnalyzer -Path lib -Settings PSScriptAnalyzerSettings.psd1 -Recurse`
- [ ] launched the GUI from source
- [ ] `.\build.ps1 -Pack` and launched the executable

## Notes for the reviewer

<!-- Anything that is not obvious from the diff: tradeoffs, things you tried
     and dropped, parts you are unsure about. -->
