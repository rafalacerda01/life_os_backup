"use strict";

// R3 opt-in test harness only. No exports, production adapter or cleanup imports.
const test = require("node:test");
const assert = require("node:assert/strict");
const {randomUUID} = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const net = require("node:net");
const {createSyntheticRetirementModel} = require("../retired_identity_model");
const PROJECT = "demo-life-os-d2c02r3";
const DATABASE = "(default)";
const ON = process.env.LIFEOS_RETIRED_IDENTITY_EMULATOR_TEST === "1";

function isolation(env = process.env) {
  assert.equal(env.GCLOUD_PROJECT, PROJECT, "DEMO_PROJECT_REQUIRED");
  assert.equal(env.GOOGLE_CLOUD_PROJECT, PROJECT, "DEMO_PROJECT_REQUIRED");
  const hosts = [env.FIRESTORE_EMULATOR_HOST, env.FIREBASE_AUTH_EMULATOR_HOST];
  for (const host of hosts) {
    assert.match(host || "", /^127\.0\.0\.1:[1-9][0-9]{0,4}$/, "LOOPBACK_REQUIRED");
    assert.ok(Number(host.split(":")[1]) <= 65535, "PORT_INVALID");
  }
  assert.notEqual(hosts[0], hosts[1], "DISTINCT_HOSTS_REQUIRED");
  for (const name of ["GOOGLE_APPLICATION_CREDENTIALS", "FIREBASE_TOKEN",
    "FIREBASE_PRIVATE_KEY", "FIREBASE_CLIENT_EMAIL", "GOOGLE_OAUTH_ACCESS_TOKEN",
    "FIREBASE_CONFIG", "FIREBASE_EMULATOR_HUB", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]) {
    assert.equal(env[name], undefined, "EXTERNAL_CONFIGURATION_FORBIDDEN");
  }
  return Object.freeze({firestore: hosts[0], auth: hosts[1]});
}

test("retired identity: real SDKs and disposable Firebase Emulators", {
  skip: !ON && "Explicit disposable Emulator opt-in required", timeout: 120000,
}, async (t) => {
  const hosts = isolation();
  // Refuse any outbound socket except the two explicit loopback emulators.
  const originalConnect = net.Socket.prototype.connect;
  const allowedPorts = new Set([hosts.firestore, hosts.auth].map((h) => Number(h.split(":")[1])));
  let refusedSockets = 0;
  net.Socket.prototype.connect = function(...args) {
    // Node's HTTP agent also passes its already-normalized argument array.
    const first = Array.isArray(args[0]) ? args[0][0] : args[0];
    const options = typeof first === "object" ? first : {port: first, host: args[1]};
    if (options.host !== "127.0.0.1" || !allowedPorts.has(Number(options.port))) {
      refusedSockets++;
      throw new Error("NON_EMULATOR_SOCKET_FORBIDDEN");
    }
    return originalConnect.apply(this, args);
  };
  const {Firestore, Timestamp, FieldValue} = require("firebase-admin/firestore");
  const {initializeApp, deleteApp} = require("firebase-admin/app");
  const {getAuth} = require("firebase-admin/auth");
  const {GoogleAuth, OAuth2Client} = require("google-auth-library");
  const originalADC = GoogleAuth.prototype.getApplicationDefault;
  let adcAttempts = 0;
  GoogleAuth.prototype.getApplicationDefault = function() {
    adcAttempts++; throw new Error("ADC_DISCOVERY_FORBIDDEN");
  };
  const apps = [];
  const databases = [];
  let operations = 0;
  let fixtures = 0;
  const runId = randomUUID();
  function permit() {
    assert.deepEqual(isolation(), hosts, "EMULATOR_CONFIGURATION_CHANGED");
    assert.ok(++operations <= 900, "OPERATION_BUDGET_EXCEEDED");
  }
  function guardMillis(value) {
    // No rounding: unsupported sub-millisecond guard values remain invalid.
    return value instanceof Timestamp && value.nanoseconds % 1000000 === 0 ?
      value.toMillis() : value;
  }
  function result(value, expected) {
    assert.deepEqual(value, {status: expected, destructiveAuthority: false});
  }
  function compareTime(a, b) {
    return a.seconds - b.seconds || a.nanoseconds - b.nanoseconds;
  }
  function deferred() {
    let resolve;
    const promise = new Promise((r) => {resolve = r;});
    return {promise, resolve};
  }

  async function fixture({projectId = PROJECT, databaseId = DATABASE, uid} = {}) {
    assert.ok(++fixtures <= 50, "FIXTURE_BUDGET_EXCEEDED");
    assert.ok([PROJECT, PROJECT + "-other"].includes(projectId), "DEMO_SCOPE_REQUIRED");
    assert.ok([DATABASE, "r3-other-db"].includes(databaseId), "DATABASE_SCOPE_REQUIRED");
    permit();
    uid ||= `r3-${runId}-${fixtures}`;
    const app = initializeApp({projectId, credential: {getAccessToken: async () => {
      permit(); return {access_token: "owner", expires_in: 3600};
    }}}, `r3-${fixtures}`);
    apps.push(app);
    const owner = new OAuth2Client();
    owner.setCredentials({access_token: "owner", expiry_date: Date.now() + 3600000});
    const db = new Firestore({projectId, databaseId, host: hosts.firestore, ssl: false,
      auth: new GoogleAuth({projectId, authClient: owner})});
    databases.push(db);
    const auth = getAuth(app);
    const counters = {reads: 0, createAttempts: 0, committedCreates: 0,
      transactions: 0, auth: 0, commits: 0};
    const hooks = {};
    const authority = Object.freeze({});
    const deletionId = randomUUID();
    const guardRef = db.doc(`account_deletion_guards/${uid}`);
    const reservationRef = db.doc(`retired_auth_identities/${uid}`);
    const fullPrefix = `projects/${projectId}/databases/${databaseId}/documents/`;
    function bound(scope) {
      permit();
      assert.equal(scope.projectId, projectId, "ADAPTER_SCOPE_REFUSED");
      assert.equal(scope.databaseId, databaseId, "ADAPTER_SCOPE_REFUSED");
      assert.equal(scope.uid, uid, "ADAPTER_SUBJECT_REFUSED");
      assert.equal(app.options.projectId, projectId);
      assert.equal(db.projectId, projectId);
      assert.equal(db.databaseId, databaseId);
    }
    async function rawAuth() {
      permit();
      // Local Emulator RPC supplements the public SDK's second-only UTC string.
      // The value is read from actual emulator storage, never chosen by a test.
      const response = await fetch(`http://${hosts.auth}/identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:lookup`, {
        method: "POST", headers: {Authorization: "Bearer owner", "Content-Type": "application/json"},
        body: JSON.stringify({localId: [uid]}), signal: AbortSignal.timeout(5000), redirect: "error",
      });
      assert.equal(response.ok, true, "EMULATOR_LOOKUP_FAILED");
      const body = await response.json();
      if (!body.users || body.users.length === 0) return null;
      assert.equal(body.users.length, 1);
      assert.equal(body.users[0].localId, uid);
      assert.match(body.users[0].createdAt, /^[1-9][0-9]*$/);
      return Number(body.users[0].createdAt);
    }
    async function observe(scope) {
      bound(scope); counters.auth++;
      if (hooks.beforeAuth) await hooks.beforeAuth(counters.auth);
      try {
        permit(); const user = await auth.getUser(uid);
        const raw = await rawAuth();
        if (raw === null || user.uid !== uid || !Number.isSafeInteger(raw) ||
            user.metadata.creationTime !== new Date(raw).toUTCString()) {
          return {state: "AMBIGUOUS"};
        }
        return {state: "PRESENT", createdAtMs: raw};
      } catch (error) {
        if (error.code === "auth/user-not-found") return {state: "ABSENT"};
        throw error;
      }
    }
    function refFor(fullPath) {
      permit();
      assert.ok(fullPath.startsWith(fullPrefix), "REFERENCE_SCOPE_REFUSED");
      const relative = fullPath.slice(fullPrefix.length);
      assert.ok([guardRef.path, reservationRef.path].includes(relative), "REFERENCE_PATH_REFUSED");
      return db.doc(relative);
    }
    async function runTransaction(callback) {
      permit();
      if (hooks.beforeTransaction) await hooks.beforeTransaction();
      let createsInFinalAttempt = 0;
      const value = await db.runTransaction(async (tx) => {
        createsInFinalAttempt = 0;
        counters.transactions++;
        const value = await callback({
          get: async (fullPath) => {
            const ref = refFor(fullPath);
            counters.reads++;
            const snapshot = await tx.get(ref);
            if (!snapshot.exists) return {exists: false};
            const data = snapshot.data();
            if (ref.path === guardRef.path) {
              data.startedAt = guardMillis(data.startedAt);
              if (data.retainUntil !== null) data.retainUntil = guardMillis(data.retainUntil);
            }
            // Native SDK millisecond projection; original precision is inspected
            // separately in tests. No fabricated createTime or timestamp.
            return {exists: true, data, createTimeMs: snapshot.createTime.toMillis()};
          },
          create: (fullPath, data) => {
            counters.createAttempts++;
            createsInFinalAttempt++;
            tx.create(refFor(fullPath), data);
          },
        });
        if (hooks.beforeCommit) await hooks.beforeCommit();
        return value;
      }, {maxAttempts: 3});
      counters.commits++;
      counters.committedCreates += createsInFinalAttempt;
      if (hooks.afterCommit) await hooks.afterCommit();
      return value;
    }
    const actor = (operationId) => createSyntheticRetirementModel({projectId, databaseId, ports: {
      authorize: async (scope, proof) => {
        bound(scope);
        return proof === authority && (scope.deletionId === operationId || scope.deletionId === null);
      }, observeAuth: observe, runTransaction,
    }});
    const model = actor(deletionId);
    permit();
    try {await auth.createUser({uid});} catch (error) {
      if (error.code !== "auth/uid-already-exists") throw error;
    }
    const born = await rawAuth();
    assert.ok(Number.isSafeInteger(born));
    const startedAt = Timestamp.now(); // Same constructor as the current guard.
    permit(); await guardRef.create({version: 1, state: "IN_PROGRESS", deletionId,
      startedAt, retainUntil: null});
    const input = () => ({uid, deletionId, authority});
    return {projectId, databaseId, uid, db, auth, born, startedAt, deletionId,
      model, actor, authority, counters, hooks, rawAuth, guardRef, reservationRef, input,
      reserve: () => model.reserve(input()), inspect: () => model.inspect(input()),
      admission: () => model.checkAdmission({uid, authority}),
      removeAuth: async () => {permit(); await auth.deleteUser(uid);},
      recreateAuth: async () => {permit(); await auth.createUser({uid});},
      read: async () => {permit(); return reservationRef.get();},
      complete: async () => {permit(); return guardRef.update({state: "COMPLETE",
        retainUntil: Timestamp.fromMillis(startedAt.toMillis() + 3900000)});},
    };
  }

  try {
    await t.test("isolation rejects production, missing hosts, aliases and real credential configuration", () => {
      const env = {...process.env};
      for (const extra of [{GCLOUD_PROJECT: "life-os-27b92"}, {FIRESTORE_EMULATOR_HOST: undefined},
        {FIREBASE_AUTH_EMULATOR_HOST: hosts.firestore}, {FIRESTORE_EMULATOR_HOST: "localhost:8080"},
        {FIREBASE_AUTH_EMULATOR_HOST: "remote.invalid:9099"}, {GOOGLE_APPLICATION_CREDENTIALS: "forbidden.json"},
        {FIREBASE_TOKEN: "synthetic-forbidden"}, {HTTPS_PROXY: "http://remote.invalid"}]) {
        assert.throws(() => isolation({...env, ...extra}));
      }
      assert.throws(() => net.createConnection({host: "203.0.113.1", port: 443}), /NON_EMULATOR/);
      assert.equal(refusedSockets, 1);
    });

    await t.test("real reservation commits before controlled Auth removal and has actual createTime", async () => {
      const f = await fixture();
      result(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
      const snapshot = await f.read();
      assert.equal(snapshot.exists, true);
      assert.deepEqual(snapshot.data(), {version: 1, state: "RESERVED",
        deletionId: f.deletionId, authCreatedAtMs: f.born});
      assert.ok(snapshot.createTime instanceof Timestamp);
      assert.ok(compareTime(snapshot.createTime, f.startedAt) >= 0);
      assert.equal((await f.auth.getUser(f.uid)).uid, f.uid);
      await f.removeAuth();
      result(await f.inspect(), "RESERVED_AUTH_ABSENT_NO_AUTHORITY");
      assert.ok(snapshot.createTime.isEqual((await f.read()).createTime));
    });

    await t.test("native tx.create refuses overwrite and preserves content/createTime", async () => {
      const f = await fixture(); await f.reserve(); const before = await f.read();
      await assert.rejects(f.db.runTransaction(async (tx) => {
        tx.create(f.reservationRef, {attemptedOverwrite: true});
      }, {maxAttempts: 1}), (error) => error.code === 6);
      const after = await f.read();
      assert.deepEqual(after.data(), before.data()); assert.ok(after.createTime.isEqual(before.createTime));
    });

    await t.test("idempotent replay performs no create and keeps native updateTime", async () => {
      const f = await fixture(); await f.reserve(); const before = await f.read();
      const creates = f.counters.createAttempts;
      result(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
      const after = await f.read();
      assert.equal(f.counters.createAttempts, creates);
      assert.ok(after.createTime.isEqual(before.createTime));
      assert.ok(after.updateTime.isEqual(before.updateTime));
    });

    await t.test("two real concurrent transactions of the same operation converge", async () => {
      const f = await fixture();
      const both = await Promise.all([f.reserve(), f.reserve()]);
      both.forEach((r) => result(r, "RESERVATION_ACKNOWLEDGED"));
      assert.equal((await f.read()).get("deletionId"), f.deletionId);
      // Retries may repeat callback attempts. Only committed creates matter.
      assert.equal(f.counters.committedCreates, 1);
      assert.ok(f.counters.createAttempts >= 1);
      const snapshot = await f.read();
      assert.ok(snapshot.createTime.isEqual(snapshot.updateTime));
      t.diagnostic(JSON.stringify({scenario: "concurrent-same-operation",
        transactionAttempts: f.counters.transactions,
        createAttempts: f.counters.createAttempts, committedCreates: f.counters.committedCreates}));
    });

    await t.test("incompatible concurrent operations cannot acquire another operation's reservation", async () => {
      const f = await fixture();
      const otherId = randomUUID();
      const other = f.actor(otherId);
      const request = {...f.input(), deletionId: otherId};
      const values = await Promise.all([f.reserve(), other.reserve(request)]);
      result(values[0], "RESERVATION_ACKNOWLEDGED");
      result(values[1], "OPERATION_CONFLICT");
      const before = await f.read();
      await f.guardRef.update({deletionId: otherId});
      result(await other.reserve(request), "RESERVATION_CONFLICT");
      assert.deepEqual((await f.read()).data(), before.data());
    });

    await t.test("guard changed after Auth observation and before transaction read is refused", async () => {
      const f = await fixture(); let fired = false;
      f.hooks.beforeTransaction = async () => {if (!fired) {fired = true; await f.complete();}};
      result(await f.reserve(), "GUARD_COMPLETE");
      assert.equal((await f.read()).exists, false);
    });

    await t.test("guard writer racing a read-locked transaction has a valid serialization order", async () => {
      const f = await fixture(); let peer;
      f.hooks.beforeCommit = () => {peer ||= f.complete();};
      const r = await f.reserve(); const peerCommit = await peer;
      const snapshot = await f.read();
      if (r.status === "RESERVATION_ACKNOWLEDGED") {
        assert.equal(snapshot.exists, true);
        assert.ok(compareTime(snapshot.createTime, peerCommit.writeTime) <= 0);
      } else {
        result(r, "GUARD_COMPLETE"); assert.equal(snapshot.exists, false);
      }
      t.diagnostic(JSON.stringify({scenario: "guard-write-race", reservationStatus: r.status,
        serialization: snapshot.exists ? "RESERVE_THEN_COMPLETE" : "COMPLETE_THEN_REFUSAL"}));
      result(await f.reserve(), "GUARD_COMPLETE");
    });

    await t.test("COMPLETE cannot be reopened by an old executor", async () => {
      const f = await fixture(); await f.reserve(); await f.complete();
      const before = await f.guardRef.get();
      result(await f.reserve(), "GUARD_COMPLETE");
      await f.removeAuth(); result(await f.inspect(), "TERMINAL_PROOF_REQUIRED");
      assert.ok((await f.guardRef.get()).updateTime.isEqual(before.updateTime));
    });

    for (const [label, value] of [["missing", FieldValue.delete()], ["invalid type", "not-a-timestamp"],
      ["submillisecond", new Timestamp(1000, 1000)]]) {
      await t.test(`guard Timestamp ${label} fails closed without rounding`, async () => {
        const f = await fixture(); await f.guardRef.update({startedAt: value});
        result(await f.reserve(), "GUARD_INVALID"); assert.equal((await f.read()).exists, false);
      });
    }

    await t.test("incompatible stored Auth timestamp is refused", async () => {
      const f = await fixture(); await f.reserve();
      await f.reservationRef.update({authCreatedAtMs: Timestamp.now()});
      result(await f.inspect(), "RECORD_INVALID");
    });

    await t.test("exception before commit aborts all writes and is reconciled by reread", async () => {
      const f = await fixture(); f.hooks.beforeCommit = () => {throw new Error("synthetic-private@example.invalid");};
      result(await f.reserve(), "UNKNOWN_REQUIRES_REREAD");
      assert.equal((await f.read()).exists, false);
      delete f.hooks.beforeCommit;
      result(await f.inspect(), "LEGACY_OR_NEW_UNPROVEN");
      result(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
    });

    await t.test("real commit with simulated lost reply is recovered with zero duplicate writes", async () => {
      const f = await fixture(); f.hooks.afterCommit = () => {throw new Error("synthetic-private@example.invalid");};
      result(await f.reserve(), "UNKNOWN_REQUIRES_REREAD");
      const before = await f.read(); assert.equal(before.exists, true);
      delete f.hooks.afterCommit;
      result(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
      const creates = f.counters.createAttempts;
      result(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
      assert.equal(f.counters.createAttempts, creates);
      assert.ok((await f.read()).updateTime.isEqual(before.updateTime));
      await f.removeAuth(); result(await f.inspect(), "RESERVED_AUTH_ABSENT_NO_AUTHORITY");
    });

    await t.test("UID recreated between real Auth observations prevents recovery", async () => {
      const f = await fixture(); await f.reserve(); await f.removeAuth();
      const absentRead = deferred(); const continueRead = deferred();
      // The callback runs before each lookup; insert recreation before lookup #2.
      const next = f.counters.auth + 2;
      f.hooks.beforeAuth = async (count) => {
        if (count === next) {absentRead.resolve(); await continueRead.promise;}
      };
      const pending = f.inspect(); await absentRead.promise;
      await f.recreateAuth(); continueRead.resolve();
      result(await pending, "IDENTITY_CHANGED");
    });

    await t.test("Auth replacement before Firestore commit is NOT fenced by the reservation", async () => {
      const f = await fixture(); let replaced = false;
      f.hooks.beforeCommit = async () => {
        if (!replaced) {replaced = true; await f.removeAuth(); await f.recreateAuth();}
      };
      result(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
      const stored = await f.read();
      assert.equal(stored.get("authCreatedAtMs"), f.born);
      assert.equal((await f.auth.getUser(f.uid)).uid, f.uid);
      const now = await f.rawAuth();
      const inspection = await f.inspect();
      result(inspection, now === f.born ? "AUTH_PRESENT_RECOVERY_BLOCKED" : "IDENTITY_CHANGED");
      assert.equal(inspection.destructiveAuthority, false);
      t.diagnostic(JSON.stringify({scenario: "auth-replacement-before-commit",
        reserveStatus: "RESERVATION_ACKNOWLEDGED", inspectionStatus: inspection.status,
        storedInitialMetadata: stored.get("authCreatedAtMs") === f.born,
        realMetadataChanged: now !== f.born, destructiveAuthority: false}));
    });

    await t.test("legacy account with no reservation does not acquire authority", async () => {
      const f = await fixture(); await f.removeAuth();
      result(await f.inspect(), "LEGACY_OR_NEW_UNPROVEN");
      result(await f.admission(), "LEGACY_OR_NEW_UNPROVEN");
      result(await f.reserve(), "AUTH_ABSENT_CANNOT_FIRST_RESERVE");
      assert.equal((await f.read()).exists, false);
    });

    await t.test("real database and project namespaces isolate the same synthetic UID", async () => {
      const uid = `r3-scope-${runId}`;
      const a = await fixture({uid});
      const b = await fixture({uid, databaseId: "r3-other-db"});
      const c = await fixture({uid, projectId: PROJECT + "-other"});
      result(await a.reserve(), "RESERVATION_ACKNOWLEDGED");
      assert.equal((await b.read()).exists, false); assert.equal((await c.read()).exists, false);
      result(await b.reserve(), "RESERVATION_ACKNOWLEDGED");
      result(await c.reserve(), "RESERVATION_ACKNOWLEDGED");
      assert.notEqual((await a.read()).get("deletionId"), (await b.read()).get("deletionId"));
      assert.notEqual((await a.read()).get("deletionId"), (await c.read()).get("deletionId"));
    });

    await t.test("unauthorized operator causes no Auth or Firestore operation", async () => {
      const f = await fixture(); const before = {...f.counters};
      result(await f.model.reserve({...f.input(), authority: {enabled: true}}), "OPERATOR_UNAUTHORIZED");
      assert.deepEqual(f.counters, before); assert.equal((await f.read()).exists, false);
    });

    await t.test("model outputs do not expose synthetic PII, paths, IDs or underlying errors", async () => {
      const f = await fixture();
      f.hooks.beforeCommit = () => {throw new Error("synthetic-private@example.invalid");};
      const values = [await f.reserve()]; delete f.hooks.beforeCommit;
      values.push(await f.reserve(), await f.inspect(), await f.admission());
      for (const value of values) {
        assert.deepEqual(Object.keys(value).sort(), ["destructiveAuthority", "status"]);
        assert.equal(value.destructiveAuthority, false);
        for (const secret of [f.uid, f.deletionId, PROJECT, "synthetic-private@example.invalid"]) {
          assert.equal(JSON.stringify(value).includes(secret), false);
        }
      }
    });

    await t.test("SDK metadata precision differs from real Auth Emulator storage", async () => {
      const f = await fixture(); const raw = await f.rawAuth();
      const user = await f.auth.getUser(f.uid);
      assert.equal(Date.parse(user.metadata.creationTime) % 1000, 0);
      assert.equal(user.metadata.creationTime, new Date(raw).toUTCString());
      t.diagnostic(JSON.stringify({scenario: "public-auth-sdk-precision",
        utcPrecision: "seconds", storageMillisecondRemainder: raw % 1000,
        observedLoss: raw !== Date.parse(user.metadata.creationTime)}));
      // Missing precision cannot become a precise observation by parsing a date.
      const publicOnly = createSyntheticRetirementModel({projectId: PROJECT, databaseId: DATABASE,
        ports: {authorize: async () => true, observeAuth: async () => ({state: "AMBIGUOUS"}),
          runTransaction: async () => {assert.fail("AMBIGUOUS_AUTH_MUST_NOT_WRITE");}}});
      result(await publicOnly.reserve(f.input()), "IDENTITY_AMBIGUOUS");
    });

    await t.test("real createTime has submillisecond precision outside model representation", async () => {
      const f = await fixture(); await f.reserve(); const snapshot = await f.read();
      assert.ok(snapshot.createTime instanceof Timestamp);
      assert.equal(snapshot.createTime.toMillis(), snapshot.createTime.seconds * 1000 +
        Math.floor(snapshot.createTime.nanoseconds / 1000000));
      assert.ok(snapshot.createTime.nanoseconds >= 0);
      t.diagnostic(JSON.stringify({scenario: "native-createTime",
        nanosBelowMillisecond: snapshot.createTime.nanoseconds % 1000000,
        projection: "NATIVE_SDK_TO_MILLIS", originalTimestampAvailable: true}));
      // The original Timestamp is retained for exact ordering assertions above.
    });

    await t.test("production entrypoints and existing cleanup never import the harness", () => {
      const root = path.resolve(__dirname, "../..");
      for (const name of ["functions/index.js", "functions/birth_ledger_cleanup.js",
        "backend/api/account/delete.js", "backend/api/account/_birth_ledger_cleanup.js"]) {
        assert.doesNotMatch(fs.readFileSync(path.join(root, name), "utf8"),
            /retired.identity.emulator|retired_identity_model/);
      }
      assert.equal(adcAttempts, 0);
      assert.equal(refusedSockets, 1); // Only the intentional rejection test.
    });
    t.diagnostic(JSON.stringify({fixtures, boundedOperations: operations,
      adcAttempts, unexpectedOutboundSockets: refusedSockets - 1,
      sdk: "firebase-admin 14.2.0", project: PROJECT}));
  } finally {
    await Promise.allSettled(databases.map((db) => db.terminate()));
    await Promise.allSettled(apps.map((app) => deleteApp(app)));
    GoogleAuth.prototype.getApplicationDefault = originalADC;
    net.Socket.prototype.connect = originalConnect;
  }
});
