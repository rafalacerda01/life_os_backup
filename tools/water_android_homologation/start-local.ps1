param(
  [Parameter(Mandatory=$true)][ValidateSet('emulators','transport')][string]$Mode,
  [Parameter(Mandatory=$true)][string]$EvidenceRoot
)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$evidence=[IO.Path]::GetFullPath($EvidenceRoot)
$runFile=Join-Path $evidence 'demo-run.json'
$run=Get-Content -Raw -LiteralPath $runFile | ConvertFrom-Json
if($run.projectId -ne 'demo-life-os'){throw 'Demo project required'}
foreach($name in @('GOOGLE_APPLICATION_CREDENTIALS','FIREBASE_TOKEN')) {
  if([Environment]::GetEnvironmentVariable($name)){throw "Credential environment present: $name (value not read or displayed)"}
}
$node='C:\tools\node.exe'
if((& $node --version) -notmatch '^v22\.'){throw 'Node 22 required'}
$env:PATH='C:\tools;'+$env:PATH
$env:JAVA_HOME='C:\Program Files\Android\Android Studio\jbr'
$env:PATH=(Join-Path $env:JAVA_HOME 'bin')+';'+$env:PATH
$env:CI='true'
$env:FIREBASE_CLI_DISABLE_UPDATE_CHECK='true'
$env:GCLOUD_PROJECT='demo-life-os'
$env:GOOGLE_CLOUD_PROJECT='demo-life-os'
$env:FUNCTIONS_EMULATOR='true'
$env:FIRESTORE_EMULATOR_HOST='127.0.0.1:8089'
$env:FIREBASE_AUTH_EMULATOR_HOST='127.0.0.1:9099'
$env:FIREBASE_CONFIG='{"projectId":"demo-life-os"}'
$env:GCE_METADATA_HOST='127.0.0.1:9'
$env:CLOUDSDK_CONFIG=Join-Path $evidence 'empty-cloud-config'
$env:APPDATA=Join-Path $evidence 'empty-app-data'
$env:XDG_CONFIG_HOME=Join-Path $evidence 'empty-cli-config'
foreach($dir in @($env:CLOUDSDK_CONFIG,$env:APPDATA,$env:XDG_CONFIG_HOME)) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$env:LIFE_OS_WATER_DEMO_RUN=$runFile
$env:FIREBASE_FUNCTIONS_DISCOVERY_OUTPUT_PATH=Join-Path $evidence 'discovery'
New-Item -ItemType Directory -Force -Path $env:FIREBASE_FUNCTIONS_DISCOVERY_OUTPUT_PATH | Out-Null
Set-Location -LiteralPath $evidence
if($Mode -eq 'emulators') {
  # Official Emulator environment file; the CLI filters arbitrary parent env
  # variables when it loads Functions. Contains a local path only, no secrets.
  $dotenv=Join-Path $PSScriptRoot 'functions/.env.local'
  [IO.File]::WriteAllText($dotenv, 'LIFE_OS_WATER_DEMO_RUN="'+$runFile.Replace('\','/')+'"'+[Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
  # The CLI forbids rules outside its config directory. Copy the approved file
  # byte-for-byte into this ignored local-only path; never edit production Rules.
  $rules=Join-Path $repoRoot 'firestore.rules'
  $localRules=Join-Path $PSScriptRoot 'emulator.rules'
  if((Test-Path -LiteralPath $localRules) -and
      (Get-FileHash -LiteralPath $localRules).Hash -ne (Get-FileHash -LiteralPath $rules).Hash) {
    throw 'Unexpected local Rules copy; preserve for review'
  }
  Copy-Item -LiteralPath $rules -Destination $localRules
  if((Get-FileHash -LiteralPath $localRules).Hash -ne (Get-FileHash -LiteralPath $rules).Hash) {
    throw 'Rules copy integrity failure'
  }
  $cli=Join-Path $repoRoot 'tools/firestore_rules/node_modules/firebase-tools/lib/bin/firebase.js'
  & $node $cli emulators:start --only 'auth,firestore,functions' --project 'demo-life-os' --config (Join-Path $PSScriptRoot 'firebase.json') --non-interactive
} else {
  & $node (Join-Path $PSScriptRoot 'server.mjs')
}
exit $LASTEXITCODE
