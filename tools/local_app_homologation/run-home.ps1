param(
  [Parameter(Mandatory=$true)][string]$GateDirectory,
  [Parameter(Mandatory=$true)][ValidateSet('seed','reopen')][string]$Scenario,
  [Parameter(Mandatory=$true)][string]$Label
)
$ErrorActionPreference='Stop'
$adb='C:/Users/Rafa/AppData/Local/Android/Sdk/platform-tools/adb.exe'
$serial='emulator-5584';$package='com.rafalacerda.lifeos.localdev'
if((& $adb -s $serial shell getprop ro.boot.qemu.avd_name).Trim() -cne 'LifeOSRecovery17'){throw 'Wrong disposable AVD'}
if((& $adb -s $serial shell getprop sys.boot_completed).Trim() -ne '1'){throw 'Boot incomplete'}
if($Label -cnotmatch '^[a-z0-9-]+$'){throw 'Invalid evidence label'}
$out=Join-Path $GateDirectory 'native-results'
New-Item -ItemType Directory -Path $out -Force | Out-Null
if(Test-Path -LiteralPath "$out/$Label.json"){throw 'Existing evidence is preserved'}
# No pm clear: this qualification must retain the already qualified modules.
& $adb -s $serial shell am force-stop $package
& $adb -s $serial shell run-as $package rm -f files/local-lab-result.json
if($LASTEXITCODE){throw 'Lab report extraction unavailable'}
& $adb -s $serial shell am start -S -n "$package/com.rafalacerda.lifeos.MainActivity" --es local_lab_scenario $Scenario > "$out/$Label-launch.txt"
$watch=[Diagnostics.Stopwatch]::StartNew()
while($watch.Elapsed.TotalSeconds -lt 200){
  Start-Sleep -Milliseconds 1000
  $raw=& $adb -s $serial shell run-as $package cat files/local-lab-result.json 2>$null
  if($LASTEXITCODE -eq 0 -and $raw){
    $r=$raw | ConvertFrom-Json
    $raw | Set-Content -Encoding utf8 "$out/$Label.json"
    $count=if($Scenario -eq 'seed'){25}else{25}
    $fail=@($r.checks.PSObject.Properties | Where-Object Value -ne $true)
    "$Label checks=$(@($r.checks.PSObject.Properties).Count); failed=$($fail.Count); module=$($r.module)"
    if($r.module -cne 'home' -or $r.scenario -cne $Scenario -or
      @($r.checks.PSObject.Properties).Count -ne $count -or $fail.Count -or
      @($r.testResults.PSObject.Properties).Count -ne 1 -or
      @($r.testResults.PSObject.Properties | Where-Object Value -cne 'success').Count -or
      @($r.failureDetails).Count){throw 'Real Android Home test failed or incomplete'}
    exit 0
  }
}
& $adb -s $serial logcat -d -v threadtime -s flutter AndroidRuntime > "$out/$Label-timeout.log"
throw 'Android Home timeout; never infer PASS'
