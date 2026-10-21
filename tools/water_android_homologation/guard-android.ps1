param([Parameter(Mandatory=$true)][ValidateSet('global','app')][string]$Mode)
$ErrorActionPreference='Stop'
$adb='C:\Users\Rafa\AppData\Local\Android\Sdk\platform-tools\adb.exe'
$serial='emulator-5580'
function Device([string]$command) {
  $output=& $adb -s $serial shell $command
  if($LASTEXITCODE -ne 0){throw "Android guard command failed: $command"}
  return $output
}
if((Device 'getprop ro.kernel.qemu').Trim() -ne '1' -or
    (Device 'id') -notmatch '^uid=0\(root\)'){throw 'Rooted synthetic emulator required'}
if($Mode -eq 'global') {
  # Applies only inside the disposable emulator. No host firewall is changed.
  Device 'iptables -N WATER_R2'
  Device 'iptables -A WATER_R2 -o lo -j ACCEPT'
  Device 'iptables -A WATER_R2 -d 10.0.2.2/32 -p tcp -m multiport --dports 9099,8089,8789 -j ACCEPT'
  Device 'iptables -A WATER_R2 -j REJECT'
  Device 'ip6tables -N WATER_R2'
  Device 'ip6tables -A WATER_R2 -o lo -j ACCEPT'
  Device 'ip6tables -A WATER_R2 -j REJECT'
  Device 'iptables -I OUTPUT 1 -j WATER_R2'
  Device 'ip6tables -I OUTPUT 1 -j WATER_R2'
} else {
  $package=Device 'cmd package list packages -U com.rafalacerda.lifeos.waterhomologation'
  if($package -notmatch '^package:com\.rafalacerda\.lifeos\.waterhomologation uid:(\d+)\s*$') {
    throw 'Exact synthetic package UID required'
  }
  $appUid=$Matches[1]
  Device 'iptables -N WATER_R2_APP'
  Device 'iptables -A WATER_R2_APP -o lo -j ACCEPT'
  Device 'iptables -A WATER_R2_APP -d 10.0.2.2/32 -p tcp -m multiport --dports 9099,8089,8789 -j ACCEPT'
  Device 'iptables -A WATER_R2_APP -j REJECT'
  Device 'ip6tables -N WATER_R2_APP'
  Device 'ip6tables -A WATER_R2_APP -o lo -j ACCEPT'
  Device 'ip6tables -A WATER_R2_APP -j REJECT'
  Device "iptables -I OUTPUT 1 -m owner --uid-owner $appUid -j WATER_R2_APP"
  Device "ip6tables -I OUTPUT 1 -m owner --uid-owner $appUid -j WATER_R2_APP"
  "Synthetic app UID: $appUid"
}
Device 'iptables -S OUTPUT'
Device 'iptables -S WATER_R2'
Device 'ip6tables -S OUTPUT'
Device 'ip6tables -S WATER_R2'
