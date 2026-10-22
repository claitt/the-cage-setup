param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDir
)

$ErrorActionPreference = 'Stop'

# The Windows App SDK self-contained payload ships the AI/ONNX runtime and
# MUI folders for about ninety languages. This app uses neither, so the
# publish output is trimmed here. Only files that the app never loads are
# removed: the XAML runtime and the .NET runtime stay untouched.

$keepLanguages = @('en-us', 'en-GB', 'it-IT', 'de-DE', 'fr-FR', 'ru-RU', 'ja-JP')
$aiPatterns = @(
    'onnxruntime*.dll',
    'DirectML.dll',
    'Microsoft.ML.OnnxRuntime.dll',
    'Microsoft.Windows.AI.*'
)

$removedFiles = 0
foreach ($pattern in $aiPatterns) {
    Get-ChildItem -Path $PublishDir -Filter $pattern -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item $_.FullName -Force
            $removedFiles++
        }
}

$npu = Join-Path $PublishDir 'NpuDetect'
if (Test-Path $npu) {
    $removedFiles += (Get-ChildItem $npu -Recurse -File | Measure-Object).Count
    Remove-Item $npu -Recurse -Force
}

# Language folders hold nothing but .mui resources; anything else in a
# folder (Assets, Microsoft.UI.Xaml) is part of the app and is left alone.
Get-ChildItem $PublishDir -Directory |
    Where-Object { $keepLanguages -notcontains $_.Name } |
    ForEach-Object {
        $files = Get-ChildItem $_.FullName -Recurse -File
        $foreign = $files | Where-Object { $_.Extension -ne '.mui' }
        if ($files.Count -gt 0 -and $foreign.Count -eq 0) {
            Remove-Item $_.FullName -Recurse -Force
            $removedFiles += $files.Count
        }
    }

Write-Host "Trimmed $removedFiles unused files from $PublishDir"
