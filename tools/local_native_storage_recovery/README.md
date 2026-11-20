# Life OS native storage recovery

Android-only fork of flutter_secure_storage 10.3.1, pinned by the app's dependency override. Existing ESP, RSA-OAEP/AES-GCM and legacy RSA-PKCS1/AES-CBC stores select their persisted format. Per-call ESP/migration/reset preferences cannot change the physical format or reset policy. Reads never provision keys, migrate, reset or return raw ciphertext. An explicit write provisions modern custom storage only when the store is unambiguously empty. Missing/invalid/mixed key material fails closed. Explicit bulk delete is refused; captured logical keys can be deleted individually. Biometric/AES-wrapping requests are refused, not downgraded.

Third-party license and original notices are retained in third_party/flutter_secure_storage. Android native implementation is changed; the Dart API and federated non-Android packages remain unchanged. Upstream migration/reset helpers remain only as code used by synthetic fixture setup; the registered production plugin never dispatches storage calls through them.

The local-only identity/session classes are staged and not imported by main.dart. A secondary-store inspector blocks P1 native notification registries, their sidecars, SDK preferences and unqualified existing persistence. This is a guard, not an import/migration mechanism. No Firebase UID data is adopted.

## Reproduction

Use a new path outside the application checkout and its build directory:

```powershell
.\tools\local_native_storage_recovery\prepare.ps1 -GateDirectory <new-absolute-lab-path>
```

This creates a minimal Flutter project with only the actual local database dependency closure, the vendored storage plugin and test instrumentation. It has no Firebase, backend credentials, Billing or remote service. Package is **dev.lifeos.recovery.life_os**. AVD must be a new **LifeOSRecovery17**, serial **emulator-5584**, using the installed Android 34 google_apis x86_64 image and dedicated userdata. The executed mission preserves its creation script outside this checkout. Never target the official package or a personal AVD.

Build AOT profile using the installed Gradle/JBR/Flutter artifacts. The profile is deliberately debuggable for test-only run-as extraction. If public Flutter profile Maven artifacts are absent, use official downloads with validated TLS and a task-local Maven repository; do not modify global trust or disable TLS. The executed mission preserves its exact init script, artifact origin/hashes and build logs.

Install the test APK only on emulator-5584, then:

```powershell
.\tools\local_native_storage_recovery\run-native.ps1 -GateDirectory <lab-path>
```

Each case saves a JSON with the requested scenario checked against the response. Launch is bounded and force-stop is performed atomically after disposable package clearing to avoid the observed PackageManager race. All inputs are synthetic. A runner exit code alone is not approval: inspect every assertion and run assert-native.ps1.

For cold boot, save the pre-boot healthy case/boot ID, enable airplane mode on this AVD, sync, execute adb reboot, wait for sys.boot_completed=1, confirm the package exists and airplane_mode_on=1, then run healthy with label cold-after and save the new boot ID. The guest kernel, Android services, application process and KeyStore service must actually restart; do not substitute an engine/provider recreation. The executed mission has distinct IDs and post-boot reads of three encrypted databases.

```powershell
.\tools\local_native_storage_recovery\assert-native.ps1 -GateDirectory <lab-path>
```

Decision is FAIL if any assertion fails, BLOCKED if evidence is missing, PASS only when required native cases and boot/airplane evidence are present. The qualification is limited to API34 x86_64 and the current app's non-biometric formats. Physical StrongBox, other Android versions, multiple OS processes and real installation migration are not approved.

Additional staged-core cases: secondary-guard refuses a synthetic P1 ownership WAL without changing it or writing a profile marker; local-profile provisions a permanent UUID and encrypted Drift session, persists a synthetic Tasks row and reopens it. It bypasses no ownership gate and proves no complete module UI, Google Play entitlement, Auth removal or P1 notification migration.

Run secondary-guard on a fresh disposable package, then local-profile with label local-profile-before on a fresh disposable package, local-profile-reopen without clearing, and local-profile-after after another guest reboot without clearing. Save profile-boot-before.txt and profile-boot-after.txt in native-results. The former must match the storage gate's boot-after.txt, where airplane-after.txt records mode 1; save profile-airplane-after.txt with the actual post-reboot setting. assert-local-profile.ps1 validates the five reports, the permanent ID, distinct boot IDs, airplane evidence and cross-boot file/alias snapshots. A fresh matrix run may never overwrite earlier approved evidence; use a new evidence directory.

The local-profile probe now writes through transactionWithSync on an explicit localOnly connection, proves direct DAO enqueue is rejected by native SQLite TEMP triggers, and proves remote permits are refused. Run local-policy-historical on a fresh disposable package after the profile cold-boot reports: it seeds a synthetic historical queue through an explicitly remote-enabled fixture connection, reopens locally, and verifies that updates, deletion and bulk cleanup cannot change the historical row or partially erase the task. assert-local-profile.ps1 requires this fifth report. No real UID data is adopted, no app startup is switched, and module-level migration still requires separate tests.

The fixtures use real native ESP/keysets and legacy cipher setup, actual current app UserDatabaseFactory/schema 11, read-only database integrity/content checks, hashes of stored files and KeyStore alias metadata. Corruption/missing material is injected only in this disposable package. No real key is exported or recovered from a missing KeyStore entry. WAL/SHM/journal/backup sentinels are not falsely presented as valid SQLite migration files.

## UID and bound P1 snapshot

Use a fresh lab directory and the offline profile manifest for the snapshot probe.

```powershell
.\tools\local_native_storage_recovery\prepare.ps1 -GateDirectory <new-absolute-lab-path> -UidSnapshot
```

Build `lib/uid_snapshot_probe.dart` as an x86_64 profile target. Check the manifest for `dev.lifeos.recovery.life_os` and confirm it has no `INTERNET` permission. Install on a dedicated offline AVD where this test package is absent. Use the `gate_scenario` Activity extra with `seed`, save `files/gate-result.json`, force-stop this package while its writers still hold the WAL, sync the guest and reboot. Check distinct `/proc/sys/kernel/random/boot_id` values. Archive the first report before replacing the harness output, then launch `verify` on the same data. Read the JSON with `ConvertFrom-Json -AsHashtable` because the primary-file digest uses an empty key.

The expected counts are 28 passing checks in `seed` and 30 in `verify`, with the same `sources` fields across the boots and no `fatal` field. The physical files kept by the archive include the main database, WAL and SHM. The query uses a second copy and rebuilding the WAL index there leaves the archived bytes intact. The test uses distinct native keys and compares only their fingerprints. The result covers encrypted synthetic sources with the current legacy schema and a committed queue row present solely in the WAL.

Use this probe only to prepare the preservation gate. Migration requires independent proof of custody, source quiescence and a verified destination dataset before activation.

## UID/P1 migration preparation

Generate a separate lab with the custody probe and its second Android process.

```powershell
.\tools\local_native_storage_recovery\prepare.ps1 -GateDirectory <new-absolute-lab-path> -UidMigrationPreparation
```

Build `lib/uid_migration_probe.dart` as an x86_64 profile target. Check the APK for package `dev.lifeos.recovery.life_os.custody`, absence of `INTERNET` permission and the `Stage19WriterActivity` manifest entry with process `:writer`. Install in an offline Android lab with that package absent. Use the fully qualified Activity names in the `dev.lifeos.recovery.life_os` namespace.

1. Launch `Stage19WriterActivity` with `gate_scenario=writer` and wait for `files/stage19-writer.json`.
2. Launch `MainActivity` with `gate_scenario=blocked`, verify `files/stage19-blocked.json` and match both report PIDs to the live Android processes. Stop only the completed `blocked` process. Create the marker `files/stage19/release-writer` in the custody sandbox and wait for `files/stage19-writer-released.json`.
3. Launch `MainActivity` with `gate_scenario=interrupt`. Collect `files/stage19-writer-blocked.json` and `files/stage19-interrupt.json`. Require `files/stage19/attempt-interrupted/staged.json` and an absent `ready.json` in that attempt.
4. Sync the guest, force-stop the custody package and reboot. Compare `/proc/sys/kernel/random/boot_id` before and after. Launch `MainActivity` with `gate_scenario=resume` and collect `files/stage19-resume.json`.
5. Require 88 distinct passing checks across the report stages, excluding the repeated checks in the writer reports. Compare the source proof and the file hashes of the interrupted attempt. Verify the ready receipt and the physical destination digests under `files/stage19/attempt-resumed`.

The sources use schema 11. Each destination uses the actual blank Local-First schema 12 with a new native key and installation namespace. An extra archive table holds the historical queue and durable SQLite triggers block modifications. The active queue stays empty. The synthetic custody issuer and exclusive lock qualify the lab protocol. Any later migration needs authority and an exhaustive inventory of source writers in the real app.
