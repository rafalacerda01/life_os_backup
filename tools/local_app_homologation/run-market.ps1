param(
    [Parameter(Mandatory)][string]$GateDirectory,
    [Parameter(Mandatory)][ValidateSet('migrate', 'seed', 'reopen')][string]$Scenario,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Label
)
$ErrorActionPreference = 'Stop'
$adb = 'C:/Users/Rafa/AppData/Local/Android/Sdk/platform-tools/adb.exe'
$serial = 'emulator-5584'
$package = 'com.rafalacerda.lifeos.localdev'
$expected = @{ migrate = 20; seed = 28; reopen = 24 }

if ((& $adb -s $serial shell getprop ro.boot.qemu.avd_name).Trim() -cne 'LifeOSRecovery17') {
    throw 'Wrong isolated AVD.'
}
if ((& $adb -s $serial shell getprop sys.boot_completed).Trim() -ne '1' -or
    (& $adb -s $serial shell settings get global airplane_mode_on).Trim() -ne '1') {
    throw 'The AVD must be booted and offline.'
}
$output = Join-Path $GateDirectory 'native-results'
New-Item -ItemType Directory -Path $output -Force | Out-Null
if (Test-Path -LiteralPath "$output/$Label.json") { throw 'Existing evidence is preserved.' }
& $adb -s $serial shell am force-stop $package
if ($LASTEXITCODE) { throw 'Could not stop the isolated package.' }
& $adb -s $serial shell run-as $package rm -f files/local-lab-result.json files/local-lab-input.json
if ($LASTEXITCODE) { throw 'Synthetic report extraction unavailable.' }
& $adb -s $serial shell am start -S -n "$package/com.rafalacerda.lifeos.MainActivity" --es local_lab_scenario $Scenario > "$output/$Label-launch.txt"
if ($LASTEXITCODE) { throw 'Could not start the isolated package.' }

$timer = [Diagnostics.Stopwatch]::StartNew()
$lastInputSequence = 0
while ($timer.Elapsed.TotalSeconds -lt 180) {
    Start-Sleep -Milliseconds 650
    $nativeInputJson = & $adb -s $serial shell run-as $package cat files/local-lab-input.json 2>$null
    if ($LASTEXITCODE -eq 0 -and $nativeInputJson) {
        $request = $nativeInputJson | ConvertFrom-Json
        if ($request.sequence -gt $lastInputSequence) {
            if ($Scenario -cne 'seed' -or $request.text -cnotmatch '^(?:SYNTHETIC-[A-Z0-9-]{1,80}|[0-9]{1,8}(?:[.,][0-9]{1,2})?)$') {
                throw 'Non-synthetic or unexpected input refused.'
            }
            & $adb -s $serial shell input text $request.text
            if ($LASTEXITCODE) { throw 'Android input failed.' }
            $lastInputSequence = $request.sequence
        }
    }
    $json = & $adb -s $serial shell run-as $package cat files/local-lab-result.json 2>$null
    if ($LASTEXITCODE -ne 0 -or !$json) { continue }
    $result = $json | ConvertFrom-Json
    $json | Set-Content -Encoding UTF8 -LiteralPath "$output/$Label.json"
    $checks = @($result.checks.PSObject.Properties)
    $failed = @($checks | Where-Object Value -ne $true)
    "$Label checks=$($checks.Count); failed=$($failed.Count); module=$($result.module)"
    if ($result.module -cne 'market' -or $result.scenario -cne $Scenario -or
        $checks.Count -ne $expected[$Scenario] -or $failed.Count -or @($result.failureDetails).Count -or
        @($result.testResults.PSObject.Properties).Count -ne 1 -or
        @($result.testResults.PSObject.Properties | Where-Object Value -cne 'success').Count) {
        throw 'Native Market test failed or is incomplete.'
    }
    exit 0
}
& $adb -s $serial logcat -d -v threadtime -s flutter AndroidRuntime > "$output/$Label-timeout.log"
throw 'No native Market report was produced.'
