param([Parameter(Mandatory=$true)][string]$GateDirectory,[Parameter(Mandatory=$true)][string]$TasksGateDirectory)
$ErrorActionPreference='Stop'
$out=Join-Path $GateDirectory 'native-results'
$reports=@{};$failures=@();$missing=@();$checks=0
foreach($label in @('finance-seed','finance-reopen','finance-after-reboot')){
  $path=Join-Path $out "$label.json"
  if(-not(Test-Path -LiteralPath $path)){$missing+=$label;continue}
  $r=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json;$reports[$label]=$r
  $scenario=if($label -eq 'finance-seed'){'seed'}else{'reopen'}
  $expected=if($label -eq 'finance-seed'){22}else{19}
  $values=@($r.checks.PSObject.Properties);$checks+=$values.Count
  if($r.module -cne 'finance' -or $r.scenario -cne $scenario -or $values.Count -ne $expected -or
    @($values | Where-Object Value -ne $true).Count -or @($r.failureDetails).Count -or
    @($r.testResults.PSObject.Properties).Count -ne 1 -or
    @($r.testResults.PSObject.Properties | Where-Object Value -cne 'success').Count){$failures+="$label/failed-or-incomplete"}
  if($r.audit.package -cne 'com.rafalacerda.lifeos.localdev' -or $r.audit.firebaseApps -ne 0 -or
    @($r.audit.forbiddenPluginsRegistered).Count -or $r.audit.internetPermission -ne $false){$failures+="$label/native-host"}
}
foreach($name in @('finance-boot-before','finance-boot-after','finance-airplane-before','finance-airplane-after')){
  if(-not(Test-Path "$out/$name.txt")){$missing+=$name}
}
$prior=Join-Path $TasksGateDirectory 'native-results/tasks-after-reboot.json'
if(-not(Test-Path -LiteralPath $prior)){$missing+='prior-tasks-proof'}
if(-not $missing.Count){
  $task=Get-Content -LiteralPath $prior -Raw | ConvertFrom-Json
  foreach($field in @('profileId','taskId','keyFingerprint')){
    foreach($label in $reports.Keys){if(-not $task.$field -or $reports[$label].$field -cne $task.$field){$failures+="$label/prior-task-changed-$field"}}
  }
  foreach($field in @('transactionId','databaseHash')){
    $first=$reports['finance-seed'].$field
    foreach($label in @('finance-reopen','finance-after-reboot')){if(-not $first -or $reports[$label].$field -cne $first){$failures+="$label/changed-$field"}}
  }
  if($reports['finance-seed'].audit.processId -eq $reports['finance-reopen'].audit.processId){$failures+='reopen/not-a-new-process'}
  $first=(Get-Content "$out/finance-boot-before.txt" -Raw).Trim();$last=(Get-Content "$out/finance-boot-after.txt" -Raw).Trim()
  if(-not $first -or -not $last -or $first -eq $last){$failures+='not-a-new-boot'}
  foreach($name in @('finance-airplane-before','finance-airplane-after')){if((Get-Content "$out/$name.txt" -Raw).Trim() -ne '1'){$failures+="$name/not-enabled"}}
}
$gate=if($failures.Count){'FAIL'}elseif($missing.Count){'BLOCKED'}else{'PASS'}
[pscustomobject]@{LOCAL_FINANCE_ANDROID=$gate;assertions=$checks;failures=$failures;missing=$missing;
  APP_WIDE_OFFLINE='NOT_VERIFIED';PREMIUM_HYBRID='NOT_IMPLEMENTED';ROLLOUT='CLOSED'
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $GateDirectory 'finance-decision.json') -Encoding utf8
"LOCAL_FINANCE_ANDROID=$gate; assertions=$checks"
if($gate -eq 'FAIL'){exit 1};if($gate -eq 'BLOCKED'){exit 2}
