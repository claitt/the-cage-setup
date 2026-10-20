# Debloat MuMu Player - NetEase/MuMu components only.
# The game, Google services (GMS/GSF/Play Store) and the rest of Android are untouched.
# Everything here is reversible:
#   pm install-existing <pkg>        (restore a removed package)
#   pm enable --user 0 <pkg>         (re-enable a disabled package)
param(
  [string]$Adb = "C:\Program Files\Netease\MuMuPlayer\nx_device\15.0\shell\adb.exe",
  [string]$Serial = "127.0.0.1:7555"
)

if (-not (Test-Path $Adb)) { Write-Host "adb not found: $Adb"; exit 1 }
& $Adb connect $Serial | Out-Null

# --- removed for user 0 ---
$remove = @(
  'com.mumu.store',              # MuMu app store
  'com.mumu.shared.sdk',         # MuMu shared SDK
  'com.mumu.acc',                # MuMu account
  'com.nemu.nlp',                # NetEase NLP service
  'com.nemu.oaidmanager',        # OAID / advertising id
  'com.netease.mumu.cloner'      # app cloner
)

# --- disabled (reversible) ---
$disable = @(
  'com.sohu.inputmethod.sogou.chuizi'   # Chinese Sogou keyboard (the only system IME)
)

Write-Host "=== REMOVING (pm uninstall --user 0) ==="
foreach ($p in $remove) {
  $r = (& $Adb -s $Serial shell pm uninstall --user 0 $p 2>&1) -join ' '
  Write-Host ("{0,-40} -> {1}" -f $p, $r.Trim())
}

Write-Host "`n=== DISABLING (pm disable-user --user 0) ==="
foreach ($p in $disable) {
  $r = (& $Adb -s $Serial shell pm disable-user --user 0 $p 2>&1) -join ' '
  Write-Host ("{0,-40} -> {1}" -f $p, $r.Trim())
}

Write-Host "`n=== CHECK ==="
foreach ($p in ($remove + $disable)) {
  $active = (& $Adb -s $Serial shell pm list packages --user 0 $p 2>&1) -join ''
  $off    = (& $Adb -s $Serial shell pm list packages -d $p 2>&1) -join ''
  $state = if (-not $active) { 'REMOVED' } elseif ($off) { 'DISABLED' } else { 'STILL ACTIVE' }
  Write-Host ("{0,-40} {1}" -f $p, $state)
}
