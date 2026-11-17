param([string]$Scenario='', [string]$Label='', [switch]$Fresh, [string]$GateDirectory=$PSScriptRoot)
$ErrorActionPreference='Stop'
$adb='C:/Users/Rafa/AppData/Local/Android/Sdk/platform-tools/adb.exe'
$serial='emulator-5584'; $package='dev.lifeos.recovery.life_os'
$avd=(& $adb -s $serial shell getprop ro.boot.qemu.avd_name).Trim()
if($avd -ne 'LifeOSRecovery17'){throw "Wrong AVD: $avd"}
$out=Join-Path $GateDirectory 'native-results'
New-Item -ItemType Directory -Path $out -Force | Out-Null
function Run([string]$Name,[string]$Case,[bool]$Clear) {
  & $adb -s $serial shell timeout 15 am force-stop $package | Out-Null
  if($Clear){$result=& $adb -s $serial shell pm clear $package; if($result -notmatch 'Success'){throw 'Cannot clear synthetic package'}; Start-Sleep -Milliseconds 750}
  & $adb -s $serial shell run-as $package rm -f files/gate-result.json | Out-Null
  & $adb -s $serial shell timeout 20 am start -S -n "$package/.MainActivity" --es gate_scenario $Name > "$out/$Case-launch.txt"
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt 100){
    Start-Sleep -Milliseconds 1000
    $raw=& $adb -s $serial shell run-as $package cat files/gate-result.json 2>$null
    if($LASTEXITCODE -eq 0 -and $raw){
      $r=$raw | ConvertFrom-Json
      if($r.scenario -ne $Name){throw "Scenario mismatch: expected $Name, got $($r.scenario)"}
      $raw | Set-Content -Encoding utf8 "$out/$Case.json"
      $failed=@($r.checks.PSObject.Properties | Where-Object Value -ne $true)
      Write-Output "$Case complete; assertions=$(@($r.checks.PSObject.Properties).Count); failed=$($failed.Count); fatal=$($r.fatal)"
      return
    }
  }
  & $adb -s $serial logcat -d -v threadtime -s flutter AndroidRuntime > "$out/$Case-timeout.log"
  throw "Native timeout: $Name"
}
if($Scenario){if(-not $Label){$Label=$Scenario}; Run $Scenario $Label $Fresh.IsPresent; exit}
Run 'fresh-read' 'fresh-read' $true
Run 'seed-gcm' 'gcm-seed' $true
Run 'healthy' 'gcm-order-and-concurrent' $false
Run 'corrupt-readAll' 'gcm-corrupt-old-first' $false
Run 'missing-wrapped-key' 'gcm-missing-wrap' $false
Run 'explicit-writes' 'gcm-explicit-write-delete' $false
Run 'seed-esp' 'esp-seed' $true
Run 'healthy' 'esp-order-and-concurrent' $false
Run 'explicit-writes' 'esp-explicit-write-delete' $false
Run 'missing-esp-master' 'esp-missing-master' $false
Run 'seed-cbc' 'cbc-unmarked-seed' $true
Run 'healthy' 'cbc-order-and-concurrent' $false
Run 'explicit-writes' 'cbc-explicit-write-delete' $false
Run 'biometric-refused' 'biometric-refused' $false
Run 'seed-gcm' 'cold-seed' $true
Run 'healthy' 'cold-before' $false
& $adb -s $serial shell cat /proc/sys/kernel/random/boot_id > "$out/boot-before.txt"
& $adb -s $serial shell sync
& $adb -s $serial logcat -d -v threadtime -s flutter AndroidRuntime > "$out/logcat-before-reboot.txt"
