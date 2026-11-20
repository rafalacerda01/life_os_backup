param([Parameter(Mandatory=$true)][string]$GateDirectory, [switch]$UidSnapshot, [switch]$UidMigrationPreparation)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$gate=[IO.Path]::GetFullPath($GateDirectory)
$probe=Join-Path $gate 'probe'
if(Test-Path -LiteralPath $probe){throw 'Choose a new lab directory; existing evidence is preserved'}
New-Item -ItemType Directory -Path $gate -Force | Out-Null
& flutter create --empty --no-pub --platforms android --org dev.lifeos.recovery --project-name life_os $probe
if($LASTEXITCODE){throw 'flutter create failed'}
$lib=Join-Path $repo 'lib'
$visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Copy-Library([string]$Relative) {
  if(-not $visited.Add($Relative)){return}
  $source=[IO.Path]::GetFullPath((Join-Path $lib $Relative))
  if(-not $source.StartsWith($lib+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Library path escaped source root'}
  $dest=Join-Path "$probe/lib" $Relative
  New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination $dest
  $text=Get-Content -LiteralPath $source -Raw
  foreach($m in [regex]::Matches($text,'(?:import|export|part)\s+[''"]([^''"]+)[''"]')){
    $uri=$m.Groups[1].Value
    if($uri.StartsWith('package:life_os/')){Copy-Library $uri.Substring(16)}
    elseif(-not $uri.Contains(':')){
      $path=[IO.Path]::GetFullPath((Join-Path (Split-Path $source) $uri))
      Copy-Library ([IO.Path]::GetRelativePath($lib,$path))
    }
  }
}
foreach($entry in @('app_database.dart','database_encryption.dart','local_database_identity.dart','user_database_factory.dart','local_device_session.dart','local_installation_identity_provider.dart')){Copy-Library "core/database/$entry"}
$fork=(Join-Path $repo 'third_party/flutter_secure_storage').Replace('\','/').Replace("'","''")
@"
name: life_os
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.12.2
dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: 3.3.2
  flutter_secure_storage: 10.3.1
  drift: 2.34.3
  sqlite3: 3.5.1
  path_provider: 2.1.6
  path: 1.9.1
  shared_preferences: 2.5.5
  uuid: 4.6.0
  crypto: 3.0.7
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: 6.0.0
hooks:
  user_defines:
    sqlite3:
      source: sqlite3mc
dependency_overrides:
  flutter_secure_storage:
    path: '$fork'
"@ | Set-Content -Encoding utf8 "$probe/pubspec.yaml"
Copy-Item "$repo/pubspec.lock" "$probe/pubspec.lock"
Copy-Item "$repo/analysis_options.yaml" "$probe/analysis_options.yaml" -Force
Copy-Item "$PSScriptRoot/recovery_probe.dart","$PSScriptRoot/fixture_support.dart" "$probe/lib/"
Copy-Item "$PSScriptRoot/MainActivity.kt" "$probe/android/app/src/main/kotlin/dev/lifeos/recovery/life_os/MainActivity.kt"
@'

// Test-only AOT instrumentation. Never use this signing/debug setting in release.
android.buildTypes.matching { it.name == "profile" }.configureEach { isDebuggable = true }
'@ | Add-Content "$probe/android/app/build.gradle.kts"
$manifest="$probe/android/app/src/main/AndroidManifest.xml"
(Get-Content $manifest -Raw).Replace('<application','<application android:allowBackup="false"') | Set-Content -Encoding utf8 $manifest
if ($UidSnapshot) {
  Copy-Item -LiteralPath "$PSScriptRoot/uid_snapshot_probe.dart" -Destination "$probe/lib/uid_snapshot_probe.dart"
  @"
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
        <meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false" />
    </application>
</manifest>
"@ | Set-Content -LiteralPath "$probe/android/app/src/profile/AndroidManifest.xml" -Encoding utf8
}
if ($UidMigrationPreparation) {
  Copy-Item -LiteralPath "$PSScriptRoot/uid_migration_preparation.dart","$PSScriptRoot/uid_migration_probe.dart" -Destination "$probe/lib"
  Copy-Item -LiteralPath "$PSScriptRoot/uid_migration_profile_manifest.xml" -Destination "$probe/android/app/src/profile/AndroidManifest.xml"
  $writerDirectory="$probe/android/app/src/profile/kotlin/dev/lifeos/recovery/life_os"
  New-Item -ItemType Directory -Path $writerDirectory -Force | Out-Null
  Copy-Item -LiteralPath "$PSScriptRoot/Stage19WriterActivity.kt" -Destination $writerDirectory
  $labActivity="$probe/android/app/src/main/kotlin/dev/lifeos/recovery/life_os/MainActivity.kt"
  $activityText=[IO.File]::ReadAllText($labActivity)
  if (!$activityText.Contains('class MainActivity : FlutterActivity()')) { throw 'Missing synthetic Activity anchor' }
  [IO.File]::WriteAllText($labActivity,$activityText.Replace('class MainActivity : FlutterActivity()','open class MainActivity : FlutterActivity()'))
  $labGradle="$probe/android/app/build.gradle.kts"
  $gradleText=[IO.File]::ReadAllText($labGradle)
  $profileAnchor='android.buildTypes.matching { it.name == "profile" }.configureEach { isDebuggable = true }'
  if (!$gradleText.Contains($profileAnchor)) { throw 'Missing synthetic profile anchor' }
  $profileBlock=@"
android.buildTypes.matching { it.name == "profile" }.configureEach {
    isDebuggable = true
    applicationIdSuffix = ".custody"
}
"@
  [IO.File]::WriteAllText($labGradle,$gradleText.Replace($profileAnchor,$profileBlock))
}
Push-Location $probe
try{& flutter pub get --offline;if($LASTEXITCODE){throw 'Local dependencies unavailable'}}finally{Pop-Location}
Write-Output "Prepared isolated non-Firebase lab: $probe; copied libraries=$($visited.Count). No ADB or publication action."
