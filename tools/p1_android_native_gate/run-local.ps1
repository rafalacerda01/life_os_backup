param([Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
$gateEvidence=(Resolve-Path -LiteralPath $EvidenceRoot).Path
$gateRepo=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
if($gateEvidence.StartsWith($gateRepo,[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence must stay outside repositories'}
# Inspection must succeed before any install/start. No project or production flag.
& C:/tools/node.exe (Join-Path $gateEvidence 'verify-apk.cjs')
if($LASTEXITCODE -ne 0){throw 'APK verification failed; install refused'}
$gateApk=Get-Content (Join-Path $gateEvidence 'apk-verification.json') -Raw | ConvertFrom-Json
if($gateApk.package -ne 'com.rafalacerda.lifeos.p1nativegate' -or $gateApk.project -ne 'demo-life-os' -or !$gateApk.debuggable -or $gateApk.distributable -or (Get-FileHash -LiteralPath $gateApk.apk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $gateApk.sha256){throw 'Exact demo APK required'}
$gateReady=Get-Content (Join-Path $gateEvidence 'services/ready.json') -Raw | ConvertFrom-Json
if(($gateReady.hosts -join ',') -ne '127.0.0.1:45089,127.0.0.1:45099,127.0.0.1:45789'){throw 'Local services required'}
$gateAdb='C:/Users/Rafa/AppData/Local/Android/Sdk/platform-tools/adb.exe'
if((& $gateAdb -s emulator-5582 shell getprop ro.kernel.qemu).Trim() -ne '1'){throw 'Disposable emulator required'}
if((& $gateAdb -s emulator-5582 shell pm list packages com.rafalacerda.lifeos.p1nativegate)){throw 'Fresh synthetic disks required; existing package will not be reset'}
& $gateAdb -s emulator-5582 root
& $gateAdb -s emulator-5582 wait-for-device
& (Join-Path $PSScriptRoot 'guard-avd.ps1') -Mode global
if($LASTEXITCODE -ne 0){throw 'Global device guard failed'}
& $gateAdb -s emulator-5582 install $gateApk.apk
if($LASTEXITCODE -ne 0){throw 'Isolated install failed'}
& (Join-Path $PSScriptRoot 'guard-avd.ps1') -Mode app
if($LASTEXITCODE -ne 0){throw 'App device guard failed'}
foreach($gatePort in @(45099,45089,45789)){& $gateAdb -s emulator-5582 reverse "tcp:$gatePort" "tcp:$gatePort";if($LASTEXITCODE -ne 0){throw 'Local reverse failed'}}
& $gateAdb -s emulator-5582 shell am start -W -n com.rafalacerda.lifeos.p1nativegate/com.rafalacerda.lifeos.nativegate.NativeGateActivity --es phase initial
if($LASTEXITCODE -ne 0){throw 'Native probe launch failed'}
