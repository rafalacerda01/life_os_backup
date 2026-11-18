param(
  [Parameter(Mandatory=$true)][string]$GateDirectory,
  [Parameter(Mandatory=$true)][ValidateSet('seed','reopen')][string]$Scenario,
  [Parameter(Mandatory=$true)][string]$Label,
  [switch]$Fresh
)
$ErrorActionPreference='Stop'
$adb='C:/Users/Rafa/AppData/Local/Android/Sdk/platform-tools/adb.exe'
$serial='emulator-5584';$package='com.rafalacerda.lifeos.localdev'
if((& $adb -s $serial shell getprop ro.boot.qemu.avd_name).Trim() -cne 'LifeOSRecovery17'){throw 'Wrong disposable AVD'}
if((& $adb -s $serial shell getprop sys.boot_completed).Trim() -ne '1'){throw 'Boot incomplete'}
if($Label -cnotmatch '^[a-z0-9-]+$'){throw 'Invalid evidence label'}
$out=Join-Path $GateDirectory 'native-results'
New-Item -ItemType Directory -Path $out -Force | Out-Null
if(Test-Path -LiteralPath "$out/$Label.json"){throw 'Existing evidence is preserved; choose a new label'}
& $adb -s $serial shell am force-stop $package
if($Fresh){
  if($Scenario -cne 'seed'){throw 'Only the synthetic seed can clear the localdev package'}
  $clear=& $adb -s $serial shell pm clear $package
  if($LASTEXITCODE -ne 0 -or ($clear -join [Environment]::NewLine) -notmatch '^Success\s*$'){throw 'Disposable package clear failed'}
  Start-Sleep -Milliseconds 750
}
& $adb -s $serial shell run-as $package rm -f files/local-lab-result.json files/local-lab-input.json
if($LASTEXITCODE){throw 'Test-only profile APK must be debuggable for report extraction'}
& $adb -s $serial shell am start -S -n "$package/com.rafalacerda.lifeos.MainActivity" --es local_lab_scenario $Scenario > "$out/$Label-launch.txt"
$watch=[Diagnostics.Stopwatch]::StartNew()
$lastInputSequence=0
while($watch.Elapsed.TotalSeconds -lt 120){
  Start-Sleep -Milliseconds 1000
  $inputRaw=& $adb -s $serial shell run-as $package cat files/local-lab-input.json 2>$null
  if($LASTEXITCODE -eq 0 -and $inputRaw){
    $request=$inputRaw | ConvertFrom-Json
    if($request.sequence -gt $lastInputSequence){
      if($request.text -cnotmatch '^SYNTHETIC-[A-Z0-9-]{1,80}$'){throw 'Non-synthetic input refused'}
      & $adb -s $serial shell input text $request.text
      if($LASTEXITCODE){throw 'Android input failed'}
      $lastInputSequence=$request.sequence
    }
  }
  $raw=& $adb -s $serial shell run-as $package cat files/local-lab-result.json 2>$null
  if($LASTEXITCODE -eq 0 -and $raw){
    $report=$raw | ConvertFrom-Json
    $raw | Set-Content -Encoding utf8 "$out/$Label.json"
    $failed=@($report.checks.PSObject.Properties | Where-Object Value -ne $true)
    $results=@($report.testResults.PSObject.Properties)
    $testFailures=@($results | Where-Object Value -cne 'success')
    $required=if($Scenario -eq 'seed'){18}else{15}
    Write-Output "$Label checks=$(@($report.checks.PSObject.Properties).Count); failed=$($failed.Count); test-failures=$($testFailures.Count)"
    if($report.scenario -cne $Scenario -or @($report.checks.PSObject.Properties).Count -ne $required -or
      $failed.Count -or $results.Count -ne 1 -or $testFailures.Count -or @($report.failureDetails).Count){throw 'Real Android widget test failed or evidence incomplete'}
    exit 0
  }
}
& $adb -s $serial logcat -d -v threadtime -s flutter AndroidRuntime > "$out/$Label-timeout.log"
throw 'Android UI test timed out; no positive result may be inferred'
