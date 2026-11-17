param([Parameter(Mandatory=$true)][string]$GateDirectory)
$ErrorActionPreference='Stop'
$root=Join-Path $GateDirectory 'native-results'
$required=@{
 'fresh-read'='fresh-read'; 'gcm-seed'='seed-gcm'; 'gcm-order-and-concurrent'='healthy';
 'gcm-corrupt-old-first'='corrupt-readAll'; 'gcm-missing-wrap'='missing-wrapped-key';
 'gcm-explicit-write-delete'='explicit-writes'; 'esp-seed'='seed-esp';
 'esp-order-and-concurrent'='healthy'; 'esp-explicit-write-delete'='explicit-writes';
 'esp-missing-master'='missing-esp-master'; 'cbc-unmarked-seed'='seed-cbc';
 'cbc-order-and-concurrent'='healthy'; 'cbc-explicit-write-delete'='explicit-writes';
 'biometric-refused'='biometric-refused'; 'cold-seed'='seed-gcm';
 'cold-before'='healthy'; 'cold-after'='healthy'
}
$missing=@();$failures=@();$checks=0;$reports=@{}
foreach($label in ($required.Keys | Sort-Object)){
  $file=Join-Path $root "$label.json"
  if(-not (Test-Path -LiteralPath $file)){$missing+=$label;continue}
  $r=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  $reports[$label]=$r
  if($r.scenario -ne $required[$label] -or $r.fatal){$failures+="$label/scenario-or-fatal"}
  $assertions=@($r.checks.PSObject.Properties)
  if(-not $assertions.Count){$failures+="$label/no-assertions"}
  foreach($p in $assertions){$checks++;if($p.Value -ne $true){$failures+="$label/$($p.Name)"}}
}
foreach($name in @('boot-before','boot-after','airplane-before','airplane-after')){
  $file=Join-Path $root "$name.txt"
  if(-not(Test-Path $file)){$missing+=$name}
}
if(-not ($missing | Where-Object {$_ -match 'boot-|airplane-'})){
  $first=(Get-Content "$root/boot-before.txt" -Raw).Trim()
  $last=(Get-Content "$root/boot-after.txt" -Raw).Trim()
  if(-not $first -or -not $last -or $first -eq $last){$failures+='cold-boot/not-a-new-boot'}
  foreach($name in @('airplane-before','airplane-after')){if((Get-Content "$root/$name.txt" -Raw).Trim() -ne '1'){$failures+="$name/not-enabled"}}
}
if($reports.ContainsKey('cold-before') -and $reports.ContainsKey('cold-after')){
  $start=$reports['cold-before'].after
  $end=$reports['cold-after'].before
  if($null -eq $start -or $null -eq $end){$failures+='cold-boot/missing-snapshots'}
  else{
    foreach($kind in @('files','aliases')){
      $names=@($start.$kind.PSObject.Properties.Name)+@($end.$kind.PSObject.Properties.Name) | Sort-Object -Unique
      foreach($name in $names){
        if($kind -eq 'files' -and ($name -like 'app_flutter/flutter_assets/*' -or $name -like 'app_flutter/res_timestamp-*')){continue}
        if($start.$kind.PSObject.Properties[$name].Value -cne $end.$kind.PSObject.Properties[$name].Value){$failures+="cold-boot/changed-$kind/$name"}
      }
    }
  }
}
$decision=if($failures.Count){'FAIL'}elseif($missing.Count){'BLOCKED'}else{'PASS'}
[pscustomobject]@{
 LOCAL_NATIVE_STORAGE_GATE=$decision
 scope='Android 14 API34 x86_64; current app RSA/ESP/GCM/CBC formats; synthetic only'
 cases=$reports.Count;assertions=$checks;failures=$failures;missing=$missing
 qualificationLimits=@('No physical hardware/StrongBox proof','No other Android API levels','No multi-process writers','No real user data or UID adoption','No app-wide Local-First startup qualification')
} | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $GateDirectory 'native-decision.json')
Write-Output "LOCAL_NATIVE_STORAGE_GATE=$decision; cases=$($reports.Count); assertions=$checks"
$failures | Write-Output
if($decision -eq 'FAIL'){exit 1};if($decision -eq 'BLOCKED'){exit 2}
