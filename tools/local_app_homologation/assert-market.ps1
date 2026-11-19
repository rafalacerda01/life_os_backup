param(
    [Parameter(Mandatory)][string]$GateDirectory,
    [Parameter(Mandatory)][string]$PriorHomeDirectory,
    [string]$MigrationDirectory = $GateDirectory,
    [string]$SeedDirectory = $GateDirectory,
    [switch]$RecoverCompletedSeed
)
$ErrorActionPreference = 'Stop'
$failures = @()
$missing = @()
$total = 0
$successful = 0
$profiles = @(
    @{ Label = 'market-migrate'; Scenario = 'migrate'; Expected = 20; Directory = $MigrationDirectory },
    @{ Label = 'market-seed'; Scenario = 'seed'; Expected = 28; Directory = $SeedDirectory },
    @{ Label = 'market-reopen'; Scenario = 'reopen'; Expected = 24; Directory = $GateDirectory },
    @{ Label = 'market-after-reboot'; Scenario = 'reopen'; Expected = 24; Directory = $GateDirectory }
)
$reports = @{}
foreach ($profile in $profiles) {
    $label = $profile.Label
    $name = Join-Path $profile.Directory "native-results/$label.json"
    if (!(Test-Path -LiteralPath $name)) { $missing += $label; continue }
    $result = Get-Content -LiteralPath $name -Raw | ConvertFrom-Json
    $reports[$label] = $result
    $checks = @($result.checks.PSObject.Properties)
    $total += $checks.Count
    $failedChecks = @($checks | Where-Object Value -ne $true)
    $successful += $checks.Count - $failedChecks.Count
    if ($result.module -cne 'market' -or $result.scenario -cne $profile.Scenario) {
        $failures += "$label/wrong-profile"
    } elseif ($label -ceq 'market-seed' -and $RecoverCompletedSeed) {
        # UI input and checkout persisted. The original run then inspected the
        # wrong tab. Reopen must prove the list, receipt and expense unchanged.
        if ($checks.Count -ne 16 -or $failedChecks.Count -ne 1 -or
            $failedChecks[0].Name -cne 'remaining-items-visible' -or
            $result.checks.'market-crud-in-ui' -ne $true -or
            $result.checks.'finance-option-visible' -ne $true -or
            !([string]$result.bodyError).Contains('remaining-items-visible') -or
            $result.uiTextOnFailure -cnotcontains 'Compra salva no histórico.' -or
            $result.uiTextOnFailure -cnotcontains "R$`u{00A0}48,75" -or
            @($result.failureDetails).Count -ne 1) {
            $failures += "$label/recovery-preconditions"
        }
    } elseif ($checks.Count -ne $profile.Expected -or $failedChecks.Count -or
        @($result.failureDetails).Count -or @($result.testResults.PSObject.Properties).Count -ne 1 -or
        @($result.testResults.PSObject.Properties | Where-Object Value -cne 'success').Count) {
        $failures += "$label/failed-or-incomplete"
    }
    if ($result.audit.package -cne 'com.rafalacerda.lifeos.localdev' -or $result.audit.firebaseApps -ne 0 -or
        @($result.audit.forbiddenPluginsRegistered).Count -or $result.audit.internetPermission -ne $false) {
        $failures += "$label/native-host"
    }
}
$output = Join-Path $GateDirectory 'native-results'
$markers = @('market-boot-before', 'market-boot-after', 'market-airplane-before', 'market-airplane-after')
foreach ($marker in $markers) {
    if (!(Test-Path -LiteralPath "$output/$marker.txt")) { $missing += $marker }
}
$priorReport = Join-Path $PriorHomeDirectory 'native-results/home-after-reboot.json'
$priorVerdict = Join-Path $PriorHomeDirectory 'home-decision.json'
foreach ($file in @($priorReport, $priorVerdict)) {
    if (!(Test-Path -LiteralPath $file)) { $missing += [IO.Path]::GetFileName($file) }
}
if (!$missing.Count) {
    $prior = Get-Content -LiteralPath $priorReport -Raw | ConvertFrom-Json
    if ((Get-Content -LiteralPath $priorVerdict -Raw | ConvertFrom-Json).LOCAL_HOME_ANDROID -cne 'PASS') {
        $failures += 'prior-home-proof'
    }
    $migration = $reports['market-migrate']
    $seed = $reports['market-seed']
    if ($migration.sourceVersion -ne 11 -or !$prior.databaseHash -or
        $migration.sourceDatabaseHash -cne $prior.databaseHash -or
        $migration.sourceDatabaseHash -ceq $migration.databaseHash -or
        !$migration.legacyRowsFingerprint -or $migration.legacyRowsFingerprint -cne $migration.sourceRowsFingerprint) {
        $failures += 'schema11-source-or-old-rows'
    }
    if ($seed.sourceVersion -ne 12 -or $seed.sourceDatabaseHash -cne $migration.databaseHash -or
        $seed.sourceDatabaseHash -ceq $seed.databaseHash) {
        $failures += 'seed-source-or-no-commit'
    }
    foreach ($label in $reports.Keys) {
        $r = $reports[$label]
        foreach ($field in @('profileId', 'keyFingerprint')) {
            if (!$prior.$field -or $r.$field -cne $prior.$field) { $failures += "$label/changed-$field" }
        }
        if (!($RecoverCompletedSeed -and $label -ceq 'market-seed') -and
            $r.legacyRowsFingerprint -cne $migration.legacyRowsFingerprint) { $failures += "$label/changed-older-rows" }
    }
    $expectedMarket = if ($RecoverCompletedSeed) { $reports['market-reopen'].marketFingerprint } else { $seed.marketFingerprint }
    foreach ($label in @('market-reopen', 'market-after-reboot')) {
        $r = $reports[$label]
        if ($r.sourceVersion -ne 12 -or $r.sourceDatabaseHash -cne $seed.databaseHash -or
            $r.databaseHash -cne $seed.databaseHash -or !$expectedMarket -or
            $r.marketFingerprint -cne $expectedMarket) { $failures += "$label/changed-market-or-bank" }
    }
    if ($seed.audit.processId -eq $reports['market-reopen'].audit.processId) { $failures += 'not-a-new-process' }
    $before = (Get-Content -LiteralPath "$output/market-boot-before.txt" -Raw).Trim()
    $after = (Get-Content -LiteralPath "$output/market-boot-after.txt" -Raw).Trim()
    if (!$before -or !$after -or $before -ceq $after) { $failures += 'not-a-new-boot' }
    foreach ($marker in @('market-airplane-before', 'market-airplane-after')) {
        if ((Get-Content -LiteralPath "$output/$marker.txt" -Raw).Trim() -ne '1') { $failures += "$marker/not-enabled" }
    }
}
$verdict = if ($failures.Count) { 'FAIL' } elseif ($missing.Count) { 'BLOCKED' } else { 'PASS' }
[pscustomobject]@{
    LOCAL_MARKET_ANDROID = $verdict
    assertions = $total
    successfulAssertions = $successful
    seedRequiredReadOnlyVerification = [bool]$RecoverCompletedSeed
    failures = $failures
    missing = $missing
    migrationDirectory = [IO.Path]::GetFullPath($MigrationDirectory)
    seedDirectory = [IO.Path]::GetFullPath($SeedDirectory)
    reopenDirectory = [IO.Path]::GetFullPath($GateDirectory)
    APP_WIDE_OFFLINE = 'NOT_VERIFIED'
    ROLLOUT = 'CLOSED'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $GateDirectory 'market-decision.json') -Encoding UTF8
"LOCAL_MARKET_ANDROID=$verdict; assertions=$total"
if ($verdict -eq 'FAIL') { exit 1 }
if ($verdict -eq 'BLOCKED') { exit 2 }
