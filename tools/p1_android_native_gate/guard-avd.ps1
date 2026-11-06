param([ValidateSet('global','app','offline','online','inspect')][string]$Mode='inspect')
$ErrorActionPreference='Stop'; $gateAdb='C:/Users/Rafa/AppData/Local/Android/Sdk/platform-tools/adb.exe'; $gateSerial='emulator-5582'
function Device([string]$Command){$value=& $gateAdb -s $gateSerial shell $Command;if($LASTEXITCODE -ne 0){throw "Native gate device command failed: $Command"};return $value}
if((Device 'getprop ro.kernel.qemu').Trim() -ne '1' -or (Device 'id') -notmatch '^uid=0\(root\)'){throw 'Disposable rooted emulator required'}
if($Mode -eq 'global'){
  Device 'iptables -N P1_NATIVE_GATE'; Device 'iptables -A P1_NATIVE_GATE -o lo -j ACCEPT'
  Device 'iptables -A P1_NATIVE_GATE -j REJECT'; Device 'iptables -I OUTPUT 1 -j P1_NATIVE_GATE'
  Device 'ip6tables -N P1_NATIVE_GATE'; Device 'ip6tables -A P1_NATIVE_GATE -o lo -j ACCEPT'
  Device 'ip6tables -A P1_NATIVE_GATE -j REJECT'; Device 'ip6tables -I OUTPUT 1 -j P1_NATIVE_GATE'
}elseif($Mode -eq 'app'){
  $gatePackage=Device 'cmd package list packages -U com.rafalacerda.lifeos.p1nativegate'
  if($gatePackage -notmatch '^package:com\.rafalacerda\.lifeos\.p1nativegate uid:(\d+)\s*$'){throw 'Exact isolated package required'}
  $gateUid=$Matches[1]
  Device 'iptables -N P1_NATIVE_APP'; Device 'iptables -A P1_NATIVE_APP -o lo -j ACCEPT'; Device 'iptables -A P1_NATIVE_APP -j REJECT'
  Device "iptables -I OUTPUT 1 -m owner --uid-owner $gateUid -j P1_NATIVE_APP"
  Device 'ip6tables -N P1_NATIVE_APP'; Device 'ip6tables -A P1_NATIVE_APP -o lo -j ACCEPT'; Device 'ip6tables -A P1_NATIVE_APP -j REJECT'
  Device "ip6tables -I OUTPUT 1 -m owner --uid-owner $gateUid -j P1_NATIVE_APP"
}elseif($Mode -eq 'offline'){
  Device 'iptables -I OUTPUT 1 -d 127.0.0.1/32 -p tcp -m multiport --dports 45099,45089,45789 -j REJECT'
}elseif($Mode -eq 'online'){
  Device 'iptables -D OUTPUT -d 127.0.0.1/32 -p tcp -m multiport --dports 45099,45089,45789 -j REJECT'
}
Device 'iptables -S OUTPUT'; Device 'iptables -nvxL P1_NATIVE_GATE'; Device 'ip6tables -S OUTPUT'; Device 'ip6tables -nvxL P1_NATIVE_GATE'
