param([Parameter(Mandatory=$true)][string]$GateDirectory,[Parameter(Mandatory=$true)][string]$CheckinGateDirectory,[string]$SeedGateDirectory=$GateDirectory)
$ErrorActionPreference='Stop'
$out=Join-Path $GateDirectory 'native-results'
$reports=@{};$failures=@();$missing=@();$checks=0
foreach($label in @('study-seed','study-reopen','study-after-reboot')){
  $path=if($label -eq 'study-seed') {
    Join-Path $SeedGateDirectory "native-results/$label.json"
  } else { Join-Path $out "$label.json" }
  if(-not(Test-Path -LiteralPath $path)){$missing+=$label;continue}
  $r=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json;$reports[$label]=$r
  $scenario=if($label -eq 'study-seed'){'seed'}else{'reopen'}
  $expected=if($label -eq 'study-seed'){38}else{33}
  $values=@($r.checks.PSObject.Properties);$checks+=$values.Count
  if($r.module -cne 'study' -or $r.scenario -cne $scenario -or $values.Count -ne $expected -or
    @($values | Where-Object Value -ne $true).Count -or @($r.failureDetails).Count -or
    @($r.testResults.PSObject.Properties).Count -ne 1 -or
    @($r.testResults.PSObject.Properties | Where-Object Value -cne 'success').Count){$failures+="$label/failed-or-incomplete"}
  if($r.audit.package -cne 'com.rafalacerda.lifeos.localdev' -or $r.audit.firebaseApps -ne 0 -or
    @($r.audit.forbiddenPluginsRegistered).Count -or $r.audit.internetPermission -ne $false){$failures+="$label/native-host"}
}
foreach($name in @('study-boot-before','study-boot-after','study-airplane-before','study-airplane-after')){
  if(-not(Test-Path "$out/$name.txt")){$missing+=$name}
}
$prior=Join-Path $CheckinGateDirectory 'native-results/checkin-after-reboot.json'
if(-not(Test-Path -LiteralPath $prior)){$missing+='prior-checkin-proof'}
if(-not $missing.Count){
  $task=Get-Content -LiteralPath $prior -Raw | ConvertFrom-Json
  foreach($field in @('profileId','taskId','transactionId','habitId','goalsFingerprint','checkInId','checkinFingerprint','keyFingerprint')){
    foreach($label in $reports.Keys){if(-not $task.$field -or $reports[$label].$field -cne $task.$field){$failures+="$label/prior-data-changed-$field"}}
  }
  foreach($field in @('checkInId','studyFingerprint','databaseHash')){
    $first=$reports['study-seed'].$field
    foreach($label in @('study-reopen','study-after-reboot')){if(-not $first -or $reports[$label].$field -cne $first){$failures+="$label/changed-$field"}}
  }
  $priorDecision=Join-Path $CheckinGateDirectory 'checkin-decision.json'
  if(-not(Test-Path -LiteralPath $priorDecision)){$missing+='prior-checkin-decision'}
  elseif((Get-Content -LiteralPath $priorDecision -Raw | ConvertFrom-Json).LOCAL_CHECKIN_ANDROID -cne 'PASS'){$failures+='prior-checkin-not-qualified'}
  if($reports['study-seed'].audit.processId -eq $reports['study-reopen'].audit.processId){$failures+='reopen/not-a-new-process'}
  $first=(Get-Content "$out/study-boot-before.txt" -Raw).Trim();$last=(Get-Content "$out/study-boot-after.txt" -Raw).Trim()
  if(-not $first -or -not $last -or $first -eq $last){$failures+='not-a-new-boot'}
  foreach($name in @('study-airplane-before','study-airplane-after')){if((Get-Content "$out/$name.txt" -Raw).Trim() -ne '1'){$failures+="$name/not-enabled"}}
}
$gate=if($failures.Count){'FAIL'}elseif($missing.Count){'BLOCKED'}else{'PASS'}
[pscustomobject]@{LOCAL_STUDY_ANDROID=$gate;assertions=$checks;failures=$failures;missing=$missing;
  seedEvidenceDirectory=[IO.Path]::GetFullPath($SeedGateDirectory);
  reopenEvidenceDirectory=[IO.Path]::GetFullPath($GateDirectory);
  APP_WIDE_OFFLINE='NOT_VERIFIED';PREMIUM_HYBRID='NOT_IMPLEMENTED';ROLLOUT='CLOSED'
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $GateDirectory 'study-decision.json') -Encoding utf8
"LOCAL_STUDY_ANDROID=$gate; assertions=$checks"
if($gate -eq 'FAIL'){exit 1};if($gate -eq 'BLOCKED'){exit 2}
