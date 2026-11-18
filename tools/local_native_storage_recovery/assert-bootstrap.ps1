param([Parameter(Mandatory=$true)][string]$GateDirectory)
$ErrorActionPreference='Stop'
$root=Join-Path $GateDirectory 'native-results'
$required=@{
 'admission-concurrent'=@('admission-concurrent',2)
 'admission-hold'=@('admission-hold',2)
 'admission-after-kill'=@('admission-after-kill',2)
 'bootstrap-interrupted'=@('bootstrap-interrupted',5)
 'bootstrap-recovered'=@('bootstrap-recover',7)
 'bootstrap-reopened'=@('bootstrap-recover',7)
 'bootstrap-after-reboot'=@('bootstrap-recover',7)
 'bootstrap-with-content'=@('bootstrap-with-content',5)
 'bootstrap-content-refused'=@('bootstrap-content-refused',3)
}
$missing=@();$failures=@();$checks=0;$reports=@{}
foreach($label in $required.Keys){
  $file=Join-Path $root "$label.json"
  if(-not(Test-Path -LiteralPath $file)){$missing+=$label;continue}
  $r=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  $reports[$label]=$r
  if($r.scenario -cne $required[$label][0] -or $r.fatal){$failures+="$label/scenario-or-fatal"}
  $assertions=@($r.checks.PSObject.Properties)
  if($assertions.Count -ne $required[$label][1]){$failures+="$label/assertion-count"}
  foreach($p in $assertions){$checks++;if($p.Value -ne $true){$failures+="$label/$($p.Name)"}}
}
foreach($name in @('bootstrap-boot-before','bootstrap-boot-after','bootstrap-airplane-before','bootstrap-airplane-after')){
  if(-not(Test-Path "$root/$name.txt")){$missing+=$name}
}
if(-not $missing.Count){
  $first=$reports['bootstrap-interrupted']
  foreach($label in @('bootstrap-recovered','bootstrap-reopened','bootstrap-after-reboot')){
    if($reports[$label].profileId -cne $first.profileId -or
      $reports[$label].keyFingerprint -cne $first.keyFingerprint -or
      $first.keyFingerprint -cnotmatch '^[a-f0-9]{64}$'){$failures+="$label/identity-or-key-changed"}
  }
  foreach($pair in @(@('admission-hold','admission-after-kill'),@('bootstrap-interrupted','bootstrap-recovered'),@('bootstrap-recovered','bootstrap-reopened'))){
    $a=$reports[$pair[0]].processId;$b=$reports[$pair[1]].processId
    if(-not $a -or -not $b -or $a -eq $b){$failures+="$($pair[0])/not-a-new-process"}
  }
  if($reports['bootstrap-with-content'].keyFingerprint -cne $reports['bootstrap-content-refused'].keyFingerprint){$failures+='content/key-changed'}
  $firstBoot=(Get-Content "$root/bootstrap-boot-before.txt" -Raw).Trim()
  $lastBoot=(Get-Content "$root/bootstrap-boot-after.txt" -Raw).Trim()
  if(-not $firstBoot -or -not $lastBoot -or $firstBoot -eq $lastBoot){$failures+='bootstrap/not-a-new-boot'}
  foreach($name in @('bootstrap-airplane-before','bootstrap-airplane-after')){
    if((Get-Content "$root/$name.txt" -Raw).Trim() -ne '1'){$failures+="$name/not-enabled"}
  }
  # Compare closed-state file hashes and KeyStore alias metadata across boot.
  $start=$reports['bootstrap-reopened'].after
  $end=$reports['bootstrap-after-reboot'].before
  foreach($kind in @('files','aliases')){
    if(-not @($start.$kind.PSObject.Properties).Count -or -not @($end.$kind.PSObject.Properties).Count){$failures+="bootstrap/empty-$kind";continue}
    $names=@($start.$kind.PSObject.Properties.Name)+@($end.$kind.PSObject.Properties.Name) | Sort-Object -Unique
    foreach($name in $names){
      if($kind -eq 'files' -and ($name -like 'app_flutter/flutter_assets/*' -or $name -like 'app_flutter/res_timestamp-*')){continue}
      if($start.$kind.PSObject.Properties[$name].Value -cne $end.$kind.PSObject.Properties[$name].Value){$failures+="bootstrap/changed-$kind/$name"}
    }
  }
}
$decision=if($failures.Count){'FAIL'}elseif($missing.Count){'BLOCKED'}else{'PASS'}
[pscustomobject]@{LOCAL_PROFILE_BOOTSTRAP=$decision;assertions=$checks;failures=$failures;missing=$missing;
  MULTI_OS_PROCESS_CONCURRENCY='NOT_VERIFIED';APP_WIDE_OFFLINE='NOT_VERIFIED';ROLLOUT='CLOSED'
} | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $GateDirectory 'bootstrap-decision.json')
Write-Output "LOCAL_PROFILE_BOOTSTRAP=$decision; assertions=$checks"
$failures | Write-Output
if($decision -eq 'FAIL'){exit 1};if($decision -eq 'BLOCKED'){exit 2}
