param([Parameter(Mandatory=$true)][string]$GateDirectory)
$ErrorActionPreference='Stop'
$root=Join-Path $GateDirectory 'native-results'
$required=@{
 'secondary-guard'='secondary-guard'; 'local-profile-before'='local-profile';
 'local-profile-reopen'='local-profile'; 'local-profile-after'='local-profile';
 'local-policy-historical'='local-policy-historical'
}
$missing=@();$failures=@();$checks=0;$reports=@{}
foreach($label in $required.Keys){
  $file=Join-Path $root "$label.json"
  if(-not(Test-Path -LiteralPath $file)){$missing+=$label;continue}
  $r=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  $reports[$label]=$r
  if($r.scenario -ne $required[$label] -or $r.fatal){$failures+="$label/scenario-or-fatal"}
  $assertions=@($r.checks.PSObject.Properties)
  if(-not $assertions.Count){$failures+="$label/no-assertions"}
  foreach($p in $assertions){$checks++;if($p.Value -ne $true){$failures+="$label/$($p.Name)"}}
}
foreach($name in @('profile-boot-before','profile-boot-after','boot-after','airplane-after','profile-airplane-after')){
  if(-not(Test-Path "$root/$name.txt")){$missing+=$name}
}
if(-not $missing.Count){
  $first=(Get-Content "$root/profile-boot-before.txt" -Raw).Trim()
  $last=(Get-Content "$root/profile-boot-after.txt" -Raw).Trim()
  if(-not $first -or -not $last -or $first -eq $last){$failures+='profile/not-a-new-boot'}
  # The core run starts in the boot whose airplane state the storage gate saved.
  if($first -ne (Get-Content "$root/boot-after.txt" -Raw).Trim()){$failures+='profile/before-boot-provenance'}
  foreach($name in @('airplane-after','profile-airplane-after')){
    if((Get-Content "$root/$name.txt" -Raw).Trim() -ne '1'){$failures+="$name/not-enabled"}
  }
  $id=$reports['local-profile-before'].profileId
  if($id -cnotmatch '^local-v1-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'){$failures+='profile/invalid-id'}
  foreach($label in @('local-profile-reopen','local-profile-after')){
    if($reports[$label].profileId -cne $id){$failures+="$label/identity-changed"}
  }
  $start=$reports['local-profile-before'].after
  $end=$reports['local-profile-after'].before
  foreach($kind in @('files','aliases')){
    if(-not @($start.$kind.PSObject.Properties).Count -or -not @($end.$kind.PSObject.Properties).Count){$failures+="profile/empty-$kind-snapshot";continue}
    $names=@($start.$kind.PSObject.Properties.Name)+@($end.$kind.PSObject.Properties.Name) | Sort-Object -Unique
    foreach($name in $names){
      if($kind -eq 'files' -and ($name -like 'app_flutter/flutter_assets/*' -or $name -like 'app_flutter/res_timestamp-*')){continue}
      if($start.$kind.PSObject.Properties[$name].Value -cne $end.$kind.PSObject.Properties[$name].Value){$failures+="profile/changed-$kind/$name"}
    }
  }
}
$decision=if($failures.Count){'FAIL'}elseif($missing.Count){'BLOCKED'}else{'PASS'}
[pscustomobject]@{
 LOCAL_PROFILE_CORE=$decision;assertions=$checks;failures=$failures;missing=$missing
 APP_WIDE_OFFLINE='NOT_VERIFIED';LOCAL_IDENTITY_GATE='BLOCKED';ROLLOUT='CLOSED'
} | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $GateDirectory 'local-profile-core-decision.json')
Write-Output "LOCAL_PROFILE_CORE=$decision; assertions=$checks"
$failures | Write-Output
if($decision -eq 'FAIL'){exit 1};if($decision -eq 'BLOCKED'){exit 2}
