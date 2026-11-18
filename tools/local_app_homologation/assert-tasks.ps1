param([Parameter(Mandatory=$true)][string]$GateDirectory)
$ErrorActionPreference='Stop'
$out=Join-Path $GateDirectory 'native-results'
$reports=@{};$failures=@();$missing=@();$checks=0
foreach($label in @('tasks-seed','tasks-reopen','tasks-after-reboot')){
  $path=Join-Path $out "$label.json"
  if(-not(Test-Path -LiteralPath $path)){$missing+=$label;continue}
  $r=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  $reports[$label]=$r
  $scenario=if($label -eq 'tasks-seed'){'seed'}else{'reopen'}
  $count=if($label -eq 'tasks-seed'){18}else{15}
  $assertions=@($r.checks.PSObject.Properties);$checks+=$assertions.Count
  if($r.scenario -cne $scenario -or $assertions.Count -ne $count -or
    @($assertions | Where-Object Value -ne $true).Count -or @($r.failureDetails).Count -or
    @($r.testResults.PSObject.Properties).Count -ne 1 -or
    @($r.testResults.PSObject.Properties | Where-Object Value -cne 'success').Count){$failures+="$label/failed-or-incomplete"}
  if($r.audit.package -cne 'com.rafalacerda.lifeos.localdev' -or $r.audit.firebaseApps -ne 0 -or
    @($r.audit.forbiddenPluginsRegistered).Count -ne 0 -or $r.audit.internetPermission -ne $false){$failures+="$label/native-host"}
}
foreach($name in @('tasks-boot-before','tasks-boot-after','tasks-airplane-before','tasks-airplane-after')){
  if(-not(Test-Path -LiteralPath "$out/$name.txt")){$missing+=$name}
}
if(-not $missing.Count){
  foreach($field in @('profileId','taskId','keyFingerprint','databaseHash')){
    $first=$reports['tasks-seed'].$field
    if(-not $first){$failures+="seed/missing-$field"}
    foreach($label in @('tasks-reopen','tasks-after-reboot')){if($reports[$label].$field -cne $first){$failures+="$label/changed-$field"}}
  }
  if($reports['tasks-seed'].audit.processId -eq $reports['tasks-reopen'].audit.processId){$failures+='reopen/not-a-new-process'}
  $first=(Get-Content "$out/tasks-boot-before.txt" -Raw).Trim();$last=(Get-Content "$out/tasks-boot-after.txt" -Raw).Trim()
  if(-not $first -or -not $last -or $first -eq $last){$failures+='cold-boot/not-a-new-boot'}
  foreach($name in @('tasks-airplane-before','tasks-airplane-after')){if((Get-Content "$out/$name.txt" -Raw).Trim() -ne '1'){$failures+="$name/not-enabled"}}
}
$gate=if($failures.Count){'FAIL'}elseif($missing.Count){'BLOCKED'}else{'PASS'}
[pscustomobject]@{LOCAL_TASKS_ANDROID=$gate;assertions=$checks;failures=$failures;missing=$missing;
  APP_WIDE_OFFLINE='NOT_VERIFIED';PREMIUM_HYBRID='NOT_IMPLEMENTED';ROLLOUT='CLOSED'
} | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $GateDirectory 'tasks-decision.json')
"LOCAL_TASKS_ANDROID=$gate; assertions=$checks"
if($gate -eq 'FAIL'){exit 1};if($gate -eq 'BLOCKED'){exit 2}
