param([Parameter(Mandatory=$true)][string]$GateDirectory,[Parameter(Mandatory=$true)][string]$FocusGateDirectory,[string]$SeedGateDirectory=$GateDirectory,[string]$GoalGateDirectory,[string]$FirstAttemptDirectory)
$ErrorActionPreference='Stop'
$out=Join-Path $GateDirectory 'native-results'
$reports=@{};$failures=@();$missing=@();$checks=0
foreach($label in @('health-seed','health-reopen','health-after-reboot')){
  $path=if($label -eq 'health-seed') {
    Join-Path $SeedGateDirectory "native-results/$label.json"
  } else { Join-Path $out "$label.json" }
  if(-not(Test-Path -LiteralPath $path)){$missing+=$label;continue}
  $r=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json;$reports[$label]=$r
  $scenario=if($label -eq 'health-seed'){'seed'}else{'reopen'}
  $expected=if($label -eq 'health-seed'){44}else{38}
  $values=@($r.checks.PSObject.Properties);$checks+=$values.Count
  if($r.module -cne 'health' -or $r.scenario -cne $scenario -or $values.Count -ne $expected -or
    @($values | Where-Object Value -ne $true).Count -or @($r.failureDetails).Count -or
    @($r.testResults.PSObject.Properties).Count -ne 1 -or
    @($r.testResults.PSObject.Properties | Where-Object Value -cne 'success').Count){$failures+="$label/failed-or-incomplete"}
  if($r.audit.package -cne 'com.rafalacerda.lifeos.localdev' -or $r.audit.firebaseApps -ne 0 -or
    @($r.audit.forbiddenPluginsRegistered).Count -or $r.audit.internetPermission -ne $false){$failures+="$label/native-host"}
}
foreach($name in @('health-boot-before','health-boot-after','health-airplane-before','health-airplane-after')){
  if(-not(Test-Path "$out/$name.txt")){$missing+=$name}
}
$prior=Join-Path $FocusGateDirectory 'native-results/focus-after-reboot.json'
if(-not(Test-Path -LiteralPath $prior)){$missing+='prior-focus-proof'}
if(-not $missing.Count){
  $task=Get-Content -LiteralPath $prior -Raw | ConvertFrom-Json
  $focusProof = $task
  $originalGoals = $null
  $firstAttempt = $null
  if ($GoalGateDirectory -and $FirstAttemptDirectory) {
    $originalGoals = Get-Content (Join-Path $GoalGateDirectory 'native-results/goals-after-reboot.json') -Raw | ConvertFrom-Json
    $firstAttempt = Get-Content (Join-Path $FirstAttemptDirectory 'native-results/health-seed.json') -Raw | ConvertFrom-Json
    if ($originalGoals.goalsFingerprint -cne $focusProof.goalsFingerprint -or
        $firstAttempt.goalsFingerprint -cne $focusProof.goalsFingerprint) {
      $failures += 'daily-rollover/original-hash-mismatch'
    }
    if ($reports['health-seed'].previousHealthFingerprint -cne $firstAttempt.healthFingerprint -or
        !$firstAttempt.checks.'daily-health-record-persisted' -or
        !$firstAttempt.checks.'two-medications-through-ui' -or
        $firstAttempt.checks.'goal-navigation-preserves-content' -ne $false) {
      $failures += 'retry/first-synthetic-state-mismatch'
    }
  }
  foreach ($label in $reports.Keys) {
    $report = $reports[$label]
    if ($report.goalsFingerprint -ceq $focusProof.goalsFingerprint) { continue }
    if (!$originalGoals -or @($originalGoals.goals).Count -ne 2 -or @($report.goals).Count -ne 2) {
      $failures += "$label/missing-goal-rollover-evidence"
      continue
    }
    foreach ($original in $originalGoals.goals) {
      $matches = @($report.goals | Where-Object id -CEQ $original.id)
      if ($matches.Count -ne 1) { $failures += "$label/prior-goal-id"; continue }
      $current = $matches[0]
      foreach ($field in @('title','period','createdAt','targetValue')) {
        if ($current.$field -cne $original.$field) { $failures += "$label/prior-goal-changed-$field" }
      }
      if ($current.currentValue -eq $original.currentValue -and $current.lastReset -eq $original.lastReset) { continue }
      $oldDay = [DateTimeOffset]::FromUnixTimeMilliseconds($original.lastReset).UtcDateTime.ToString('yyyy-MM-dd')
      $newDay = [DateTimeOffset]::FromUnixTimeMilliseconds($current.lastReset).UtcDateTime.ToString('yyyy-MM-dd')
      if ($original.period -cne 'DIÁRIA' -or $original.currentValue -ne 1 -or $current.currentValue -ne 0 -or
          $current.lastReset -le $original.lastReset -or $newDay -cle $oldDay -or
          $report.dailyGoalLastResetDay -cne $newDay) {
        $failures += "$label/unexpected-goal-transition"
      }
    }
  }

  foreach($field in @('profileId','taskId','transactionId','habitId','checkInId','checkinFingerprint','studyFingerprint','focusFingerprint','keyFingerprint')){
    foreach($label in $reports.Keys){if(-not $task.$field -or $reports[$label].$field -cne $task.$field){$failures+="$label/prior-data-changed-$field"}}
  }
  foreach($field in @('goalsFingerprint','healthFingerprint','databaseHash')){
    $first=$reports['health-seed'].$field
    foreach($label in @('health-reopen','health-after-reboot')){if(-not $first -or $reports[$label].$field -cne $first){$failures+="$label/changed-$field"}}
  }
  $priorDecision=Join-Path $FocusGateDirectory 'focus-decision.json'
  if(-not(Test-Path -LiteralPath $priorDecision)){$missing+='prior-focus-decision'}
  elseif((Get-Content -LiteralPath $priorDecision -Raw | ConvertFrom-Json).LOCAL_FOCUS_ANDROID -cne 'PASS'){$failures+='prior-focus-not-qualified'}
  if($reports['health-seed'].audit.processId -eq $reports['health-reopen'].audit.processId){$failures+='reopen/not-a-new-process'}
  $first=(Get-Content "$out/health-boot-before.txt" -Raw).Trim();$last=(Get-Content "$out/health-boot-after.txt" -Raw).Trim()
  if(-not $first -or -not $last -or $first -eq $last){$failures+='not-a-new-boot'}
  foreach($name in @('health-airplane-before','health-airplane-after')){if((Get-Content "$out/$name.txt" -Raw).Trim() -ne '1'){$failures+="$name/not-enabled"}}
}
$gate=if($failures.Count){'FAIL'}elseif($missing.Count){'BLOCKED'}else{'PASS'}
[pscustomobject]@{LOCAL_HEALTH_ANDROID=$gate;assertions=$checks;failures=$failures;missing=$missing;
  seedEvidenceDirectory=[IO.Path]::GetFullPath($SeedGateDirectory);
  reopenEvidenceDirectory=[IO.Path]::GetFullPath($GateDirectory);
  APP_WIDE_OFFLINE='NOT_VERIFIED';PREMIUM_HYBRID='NOT_IMPLEMENTED';ROLLOUT='CLOSED'
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $GateDirectory 'health-decision.json') -Encoding utf8
"LOCAL_HEALTH_ANDROID=$gate; assertions=$checks"
if($gate -eq 'FAIL'){exit 1};if($gate -eq 'BLOCKED'){exit 2}
