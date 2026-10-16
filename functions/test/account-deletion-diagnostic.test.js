"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {spawnSync} = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const vm = require("node:vm");
const {Timestamp} = require("firebase-admin/firestore");
const {diagnose, validateIsolation} = require("../scripts/account_deletion_diagnostic");
const {parseArgs} = require("../scripts/diagnose_account_deletions");
const {readResidueExistence} = require("../scripts/diagnose_account_deletions");

const NOW = Date.UTC(2026, 9, 15, 12);
const ENV = {FIRESTORE_EMULATOR_HOST: "127.0.0.1:8089",
  FIREBASE_AUTH_EMULATOR_HOST: "127.0.0.1:9099"};
const PROJECT = "demo-life-os";
function guard(id, changes = {}) {
  return {id, version: "100:1", data: {version: 1, state: "IN_PROGRESS",
    deletionId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    startedAt: Timestamp.fromMillis(NOW - 7200000), retainUntil: null,
    ...changes}};
}
function failure(code) {
  return Object.assign(new Error("synthetic-private-user@example.invalid"), {code});
}
function fixture(documents = []) {
  const docs = new Map(documents.map((doc) => [doc.id, doc]));
  const calls = {pages: [], guards: [], auth: [], residues: [], writes: []};
  const hooks = {};
  const readers = {
    getGuardPage: async (query) => {
      calls.pages.push(query);
      if (hooks.page) return hooks.page(query);
      return [...docs.values()].sort((a, b) =>
        Buffer.compare(Buffer.from(a.id), Buffer.from(b.id)))
        .filter((doc) => query.afterId === undefined ||
          Buffer.compare(Buffer.from(doc.id), Buffer.from(query.afterId)) > 0)
        .slice(0, query.limit).map((doc) => ({...doc, data: {...doc.data}}));
    },
    getGuard: async (id) => {
      calls.guards.push(id);
      if (hooks.guard) return hooks.guard(id);
      return docs.get(id) || null;
    },
    getAuthUser: async (id) => {
      calls.auth.push(id);
      if (hooks.auth) return hooks.auth(id);
      return {uid: id};
    },
    getResidueExistence: async (id) => {
      calls.residues.push(id);
      if (hooks.residues) return hooks.residues(id);
      return {userRoot: false, billingAccount: false,
        accountDeletionRuntime: false, birthLedger: false};
    },
  };
  // A writer capability is never supplied. Any attempted mutation is fatal.
  const forbidden = ["set", "create", "update", "delete", "deleteUser",
    "createUser", "batch", "runTransaction", "recursiveDelete"];
  for (const key of forbidden) Object.defineProperty(readers, key, {get() {
    calls.writes.push(key);
    throw new Error("WRITE_CAPABILITY_REQUESTED");
  }});
  return {docs, calls, hooks, run: (extra = {}) => diagnose({
    projectId: PROJECT, env: ENV, nowMillis: NOW, readers, ...extra})};
}

test("empty inventory uses one bounded query and no Auth lookup", async () => {
  const f = fixture(); const r = await f.run();
  assert.equal(r.counts.examined, 0);
  assert.equal(r.truncated, false);
  assert.equal(r.coverage, "EXHAUSTED");
  assert.equal(f.calls.pages.length, 1);
  assert.deepEqual(f.calls.auth, []);
});
test("recent pending guard avoids Auth and revalidation reads", async () => {
  const f = fixture([guard("recent", {startedAt: Timestamp.fromMillis(NOW - 1)})]);
  const r = await f.run();
  assert.equal(r.counts.recentInProgress, 1);
  assert.deepEqual(f.calls.auth, []);
  assert.deepEqual(f.calls.guards, []);
});
test("age threshold includes the exact boundary using a fixed clock", async () => {
  const r = await fixture([guard("old", {startedAt:
    Timestamp.fromMillis(NOW - 3600000)})]).run();
  assert.equal(r.counts.oldAuthPresent, 1);
});
test("old guard with live Auth is an observation, never a cleanup proof", async () => {
  const f = fixture([guard("owner")]); const r = await f.run();
  assert.equal(r.counts.oldAuthPresent, 1);
  assert.equal(r.status, "OBSERVATIONS_ONLY");
  assert.equal(f.calls.auth.length, 1);
  assert.equal(f.calls.guards.length, 1);
});
test("Auth absent only flags potentially incomplete cleanup", async () => {
  const f = fixture([guard("owner")]);
  f.hooks.auth = async () => {throw failure("auth/user-not-found");};
  const r = await f.run();
  assert.equal(r.counts.oldAuthAbsentPotentiallyIncomplete, 1);
  assert.equal(r.counts.inconclusive, 0);
  assert.equal(JSON.stringify(r).includes("COMPLETE"), false);
});
for (const [name, changes] of [
  ["unknown state", {state: "BROKEN"}],
  ["invalid identity", {deletionId: "bad"}],
  ["unexpected private field", {email: "synthetic@example.invalid"}],
  ["bad start", {startedAt: "yesterday"}],
  ["future start", {startedAt: Timestamp.fromMillis(NOW + 1)}],
  ["active expiry", {retainUntil: Timestamp.fromMillis(NOW)}],
]) test("malformed guard: " + name, async () => {
  const f = fixture([guard("owner", changes)]); const r = await f.run();
  assert.equal(r.counts.invalidGuard, 1);
  assert.deepEqual(f.calls.auth, []);
});
test("noncanonical UID is counted invalid without an Auth lookup", async () => {
  const f = fixture([guard(" owner ")]); const r = await f.run();
  assert.equal(r.counts.invalidGuard, 1);
  assert.deepEqual(f.calls.auth, []);
});
test("other guard state does not trigger terminal proof or Auth", async () => {
  const f = fixture([guard("owner", {state: "COMPLETE",
    retainUntil: Timestamp.fromMillis(NOW + 3600000)})]);
  const r = await f.run();
  assert.equal(r.counts.otherGuardStateObserved, 1);
  assert.deepEqual(f.calls.auth, []);
  assert.deepEqual(f.calls.writes, []);
});
for (const change of ["complete", "removed", "replacement", "same fields new version"]) {
  test("guard changed during Auth lookup: " + change, async () => {
    const f = fixture([guard("owner")]);
    f.hooks.auth = async (id) => {
      if (change === "removed") f.docs.delete(id);
      else {
        const next = guard(id);
        next.version = "101:1";
        if (change === "complete") Object.assign(next.data, {state: "COMPLETE",
          retainUntil: Timestamp.fromMillis(NOW + 3600000)});
        if (change === "replacement") next.data.deletionId =
          "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        f.docs.set(id, next);
      }
      return {uid: id};
    };
    const r = await f.run();
    assert.equal(r.counts.inconclusive, 1);
    assert.equal(r.inconclusiveReasons.guardChanged, 1);
    assert.equal(r.counts.oldAuthPresent, 0);
  });
}
test("mismatch in fields fails closed even with a broken unchanged version", async () => {
  const f = fixture([guard("owner")]);
  f.hooks.guard = async () => guard("owner", {deletionId:
    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"});
  const r = await f.run();
  assert.equal(r.inconclusiveReasons.guardChanged, 1);
});
for (const code of ["auth/insufficient-permission", "ECONNRESET", undefined]) {
  test("Auth lookup failure remains inconclusive: " + code, async () => {
    const f = fixture([guard("owner")]);
    f.hooks.auth = async () => {throw failure(code);};
    const r = await f.run();
    assert.equal(r.inconclusiveReasons.authLookupFailed, 1);
    assert.equal(r.counts.oldAuthAbsentPotentiallyIncomplete, 0);
    assert.equal(f.calls.guards.length, 0);
    assert.equal(JSON.stringify(r).includes("synthetic"), false);
  });
}
for (const user of [null, {uid: "another-owner"}]) {
  test("invalid Auth response is inconclusive: " + JSON.stringify(user), async () => {
    const f = fixture([guard("owner")]); f.hooks.auth = async () => user;
    assert.equal((await f.run()).inconclusiveReasons.authLookupFailed, 1);
  });
}
test("Firestore page failure marks coverage incomplete without exposing errors", async () => {
  const f = fixture(); f.hooks.page = async () => {throw failure("PERMISSION_DENIED");};
  const r = await f.run();
  assert.equal(r.coverage, "QUERY_FAILED"); assert.equal(r.truncated, true);
  assert.equal(r.inconclusiveReasons.firestoreReadFailed, 1);
  assert.equal(JSON.stringify(r).includes("synthetic"), false);
});
test("Firestore revalidation failure does not report an Auth classification", async () => {
  const f = fixture([guard("owner")]);
  f.hooks.guard = async () => {throw failure("UNAVAILABLE");};
  const r = await f.run();
  assert.equal(r.counts.inconclusive, 1);
  assert.equal(r.inconclusiveReasons.firestoreReadFailed, 1);
  assert.equal(r.counts.oldAuthPresent, 0);
});
test("missing version avoids Auth and cannot establish stability", async () => {
  const doc = guard("owner"); delete doc.version;
  const f = fixture([doc]); const r = await f.run();
  assert.equal(r.inconclusiveReasons.invalidSnapshot, 1);
  assert.deepEqual(f.calls.auth, []);
});
test("pagination advances with document cursors and does not repeat candidates", async () => {
  const f = fixture(["a", "b", "c", "d", "e"].map((id) => guard(id)));
  const r = await f.run({limits: {pageSize: 2, maxDocuments: 10}});
  assert.equal(r.counts.examined, 5);
  assert.deepEqual(f.calls.pages, [{limit: 2, afterId: undefined},
    {limit: 2, afterId: "b"}, {limit: 2, afterId: "d"}]);
  assert.equal(new Set(f.calls.auth).size, 5);
  assert.equal(r.truncated, false);
});
test("hard budget limits docs, pages, revalidations and Auth with no lookahead", async () => {
  const f = fixture(["a", "b", "c", "d", "e"].map((id) => guard(id)));
  const r = await f.run({limits: {pageSize: 2, maxDocuments: 3}});
  assert.equal(r.counts.examined, 3);
  assert.equal(r.coverage, "LIMIT_REACHED"); assert.equal(r.truncated, true);
  assert.deepEqual(f.calls.pages.map((p) => p.limit), [2, 1]);
  assert.equal(r.operations.guardDocumentResults +
    r.operations.guardRevalidationRequests, 6);
  assert.equal(r.operations.authLookupRequests, 3);
});
test("exact full budget conservatively reports truncated without extra query", async () => {
  const f = fixture([guard("a"), guard("b")]);
  const r = await f.run({limits: {pageSize: 2, maxDocuments: 2}});
  assert.equal(r.truncated, true); assert.equal(f.calls.pages.length, 1);
});
test("failure after a page preserves earlier counts and marks incomplete", async () => {
  const f = fixture([guard("a")]);
  f.hooks.page = async ({afterId}) => {
    if (afterId) throw failure("UNAVAILABLE");
    return [guard("a")];
  };
  const r = await f.run({limits: {pageSize: 1}});
  assert.equal(r.counts.oldAuthPresent, 1); assert.equal(r.truncated, true);
});
for (const page of [[guard("b"), guard("a")], [guard("a"), guard("a")], null]) {
  test("invalid page fails closed: " + JSON.stringify(page?.map((d) => d.id)), async () => {
    const f = fixture(); f.hooks.page = async () => page;
    const r = await f.run(); assert.equal(r.coverage, "INVALID_PAGE");
    assert.equal(r.truncated, true); assert.deepEqual(f.calls.auth, []);
  });
}
test("oversized adapter page never bypasses document budget", async () => {
  const f = fixture(); f.hooks.page = async () => [guard("a"), guard("b")];
  const r = await f.run({limits: {pageSize: 1}});
  assert.equal(r.coverage, "INVALID_PAGE"); assert.equal(r.counts.examined, 0);
});
test("all classifications expose aggregates only and request no writes", async () => {
  const f = fixture([guard("private-owner"), guard("private-malformed", {email: "private@email.invalid"})]);
  const before = JSON.stringify([...f.docs]); const r = await f.run();
  assert.equal(JSON.stringify([...f.docs]), before);
  assert.deepEqual(f.calls.writes, []);
  for (const secret of ["private", "@", "aaaaaaaa-aaaa", "users/"]) {
    assert.equal(JSON.stringify(r).includes(secret), false);
  }
});
for (const env of [{}, {...ENV, FIRESTORE_EMULATOR_HOST: undefined},
  {...ENV, FIREBASE_AUTH_EMULATOR_HOST: undefined},
  {...ENV, FIRESTORE_EMULATOR_HOST: "production.invalid:8080"},
  {...ENV, FIREBASE_AUTH_EMULATOR_HOST: "https://127.0.0.1:9099"},
  {...ENV, FIRESTORE_EMULATOR_HOST: "127.0.0.1:65536"},
  {...ENV, FIRESTORE_EMULATOR_HOST: "127.0.0.1:9099"},
  {...ENV, GOOGLE_APPLICATION_CREDENTIALS: "do-not-read.json"},
  {...ENV, DEBUG: "*"}]) {
  test("unsafe emulator environment refuses before reads: " + JSON.stringify(env), async () => {
    const f = fixture(); await assert.rejects(f.run({env}), /CONFIGURATION_REFUSED/);
    assert.equal(f.calls.pages.length, 0); assert.equal(f.calls.auth.length, 0);
  });
}
for (const projectId of [undefined, "life-os-27b92", "real-project", "demo-", "demo-../prod"]) {
  test("unsafe project refuses: " + projectId, async () => {
    const f = fixture(); await assert.rejects(f.run({projectId}), /CONFIGURATION_REFUSED/);
    assert.equal(f.calls.pages.length, 0);
  });
}
for (const limits of [{pageSize: 0}, {pageSize: 101}, {maxDocuments: 1001},
  {maxDocuments: Infinity}, {olderThanMs: 1}, {enabled: true}]) {
  test("unsafe budget refuses: " + JSON.stringify(limits), async () => {
    const f = fixture(); await assert.rejects(f.run({limits}), /CONFIGURATION_REFUSED/);
    assert.equal(f.calls.pages.length, 0);
  });
}
test("explicit demo project and separate loopback emulators are accepted", () => {
  assert.equal(validateIsolation(PROJECT, ENV).projectId, PROJECT);
});
test("CLI rejects missing emulator without network or credentials", () => {
  const child = spawnSync(process.execPath,
    [path.join(__dirname, "../scripts/diagnose_account_deletions.js"), "--project", PROJECT],
    {env: {}, encoding: "utf8", timeout: 10000});
  assert.equal(child.status, 1); assert.equal(child.stderr, "");
  assert.deepEqual(JSON.parse(child.stdout), {status: "DIAGNOSTIC_REFUSED_OR_FAILED"});
});
test("CLI argument surface has no UID, credential, mutation or activation flag", () => {
  for (const args of [["--uid", "private-owner"], ["--enabled", "true"],
    ["--project", PROJECT, "--project", PROJECT], ["--page-size", "NaN"], ["--project"]]) {
    assert.throws(() => parseArgs(args));
  }
  assert.deepEqual(parseArgs(["--project", PROJECT, "--page-size", "2"]),
    {projectId: PROJECT, limits: {pageSize: 2}});
});

test("CLI SDK wiring uses explicit synthetic auth and read capabilities only", async () => {
  const f = fixture([guard("owner")]);
  const effects = [];
  class OAuth2Client {
    setCredentials(value) {
      assert.equal(value.access_token, "owner");
      this.synthetic = true;
    }
  }
  class GoogleAuth {
    constructor(value) {
      assert.equal(value.projectId, PROJECT);
      assert.equal(value.authClient.synthetic, true);
      this.synthetic = true;
    }
  }
  function wire(doc) {
    return doc ? {exists: true, id: doc.id, data: () => doc.data,
      updateTime: {seconds: 100, nanoseconds: 1}} : {exists: false};
  }
  class Firestore {
    constructor(config) {
      assert.equal(config.projectId, PROJECT);
      assert.equal(config.host, ENV.FIRESTORE_EMULATOR_HOST);
      assert.equal(config.ssl, false);
      assert.equal(config.auth.synthetic, true);
    }
    collection(name) {
      assert.equal(name, "account_deletion_guards");
      return {
        orderBy: (field) => {
          assert.equal(field, "__name__");
          const query = {limit: (limit) => {
            let afterId;
            const page = {startAfter: (id) => {afterId = id; return page;},
              get: async () => ({docs: (await f.runPage({limit, afterId})).map(wire)})};
            return page;
          }};
          return query;
        },
        doc: (id) => ({get: async () => wire(f.docs.get(id))}),
      };
    }
    async terminate() {effects.push("terminate");}
  }
  f.runPage = async ({limit, afterId}) => [...f.docs.values()]
    .filter((d) => !afterId || d.id > afterId).slice(0, limit);
  const core = require("../scripts/account_deletion_diagnostic");
  const sdkApp = {initializeApp: (config) => {
    assert.equal(config.projectId, PROJECT);
    assert.equal(typeof config.credential.getAccessToken, "function");
    effects.push("initialize"); return {};
  }, deleteApp: async () => {effects.push("dispose");}};
  const mod = {exports: {}};
  const requireFake = (name) => {
    if (name === "./account_deletion_diagnostic") return {...core,
      diagnose: (args) => core.diagnose({...args, nowMillis: NOW})};
    if (name === "firebase-admin/app") return sdkApp;
    if (name === "firebase-admin/firestore") return {Firestore,
      FieldPath: {documentId: () => "__name__"}};
    if (name === "google-auth-library") return {GoogleAuth, OAuth2Client};
    if (name === "firebase-admin/auth") return {getAuth: () => ({
      getUser: async (id) => {effects.push("auth-read"); return {uid: id};},
    })};
    if (name === "node:crypto") return require(name);
    throw new Error("UNEXPECTED_SDK_OR_CREDENTIAL_ACCESS");
  };
  const code = fs.readFileSync(path.join(__dirname,
    "../scripts/diagnose_account_deletions.js"), "utf8");
  vm.runInNewContext(code, {require: requireFake, module: mod,
    process: {env: ENV, on() {}, removeListener() {}}, Date,
    AbortController, setTimeout, clearTimeout});
  const r = await mod.exports.run(["--project", PROJECT]);
  assert.equal(r.exitCode, 0); assert.equal(r.report.counts.oldAuthPresent, 1);
  assert.deepEqual(effects, ["initialize", "auth-read", "terminate", "dispose"]);
  assert.deepEqual(f.calls.writes, []);
});

function absent(f) {
  f.hooks.auth = async () => {throw failure("auth/user-not-found");};
  return f;
}
function gate() {
  let reached;
  let release;
  const ready = new Promise((resolve) => {reached = resolve;});
  const pending = new Promise((resolve) => {release = resolve;});
  return {ready, release, hold: () => {reached(); return pending;}};
}

test("R2 manual continuation keeps cursor in memory and advances within page limit", async () => {
  const f = fixture(["a", "b", "c", "d"].map((id) => guard(id)));
  let approvals = 0;
  const r = await f.run({limits: {pageSize: 1, maxPages: 3, maxDocuments: 10},
    control: {beforeNextPage: async (...args) => {
      assert.deepEqual(args, []); approvals++; return true;
    }}});
  assert.equal(approvals, 2); assert.equal(r.counts.examined, 3);
  assert.deepEqual(f.calls.pages.map((p) => p.afterId), [undefined, "a", "b"]);
  assert.equal(r.coverage, "PAGE_LIMIT"); assert.equal(r.coverageInconclusive, true);
  assert.equal(JSON.stringify(r).includes('"cursor"'), false);
  assert.equal(JSON.stringify(r).includes('"afterId"'), false);
});
test("R2 document limit wins without asking for an unnecessary continuation", async () => {
  const f = fixture([guard("a"), guard("b")]);
  const r = await f.run({limits: {pageSize: 1, maxDocuments: 1, maxPages: 10},
    control: {beforeNextPage: async () => {throw new Error("UNNECESSARY_PROMPT");}}});
  assert.equal(r.coverage, "LIMIT_REACHED"); assert.equal(f.calls.pages.length, 1);
});
test("R2 operator interruption preserves previous page without another query", async () => {
  const f = fixture([guard("a"), guard("b")]);
  const r = await f.run({limits: {pageSize: 1},
    control: {beforeNextPage: async () => false}});
  assert.equal(r.coverage, "INTERRUPTED"); assert.equal(r.counts.examined, 1);
  assert.equal(r.inconclusiveReasons.interrupted, 1);
  assert.equal(f.calls.pages.length, 1);
});
test("R2 continuation failure is sanitized and inconclusive", async () => {
  const f = fixture([guard("a"), guard("b")]);
  const r = await f.run({limits: {pageSize: 1},
    control: {beforeNextPage: async () => {throw failure("PRIVATE");}}});
  assert.equal(r.coverage, "INTERRUPTED");
  assert.equal(JSON.stringify(r).includes("synthetic-private"), false);
});
test("R2 concurrent insertion behind cursor does not imply a global snapshot", async () => {
  const f = fixture([guard("b"), guard("d")]);
  const r = await f.run({limits: {pageSize: 1}, control: {beforeNextPage: async () => {
    f.docs.set("a", guard("a")); return true;
  }}});
  assert.equal(r.counts.examined, 2);
  assert.equal(r.snapshotConsistency, "NOT_GLOBAL_SNAPSHOT");
  assert.equal(r.status, "OBSERVATIONS_ONLY");
});
test("R2 already interrupted execution issues no query", async () => {
  const f = fixture(); const controller = new AbortController(); controller.abort();
  const r = await f.run({control: {signal: controller.signal}});
  assert.equal(r.coverage, "INTERRUPTED"); assert.equal(f.calls.pages.length, 0);
});
for (const phase of ["page", "auth", "residue", "guard"]) {
  test("R2 interruption during pending " + phase + " handles late result without changes", async () => {
    const f = absent(fixture([guard("owner")]));
    const controller = new AbortController(); const pending = gate();
    if (phase === "page") f.hooks.page = pending.hold;
    if (phase === "auth") f.hooks.auth = pending.hold;
    if (phase === "residue") f.hooks.residues = pending.hold;
    if (phase === "guard") f.hooks.guard = pending.hold;
    const result = f.run({control: {signal: controller.signal}});
    await pending.ready; controller.abort();
    const r = await result; const before = JSON.stringify(r);
    assert.equal(r.coverage, "INTERRUPTED"); assert.equal(r.coverageInconclusive, true);
    pending.release(phase === "page" ? [guard("owner")] : guard("owner"));
    await Promise.resolve(); await Promise.resolve();
    assert.equal(JSON.stringify(r), before); assert.deepEqual(f.calls.writes, []);
    if (phase === "residue") assert.equal(r.residues.inconclusive, 1);
  });
}
test("R2 deadline expires pending IO using virtual timers, without sleeps", async () => {
  const f = fixture(); const pending = gate(); const timers = new Set();
  f.hooks.page = pending.hold;
  const result = f.run({control: {clock: () => 0,
    schedule: (fn) => {timers.add(fn); return fn;}, cancel: (fn) => timers.delete(fn)}});
  await pending.ready;
  for (const callback of [...timers]) callback();
  const r = await result;
  assert.equal(r.coverage, "TIME_LIMIT"); assert.equal(timers.size, 0);
  assert.equal(r.inconclusiveReasons.timeLimitExceeded, 1);
  assert.equal(f.calls.pages.length, 1);
  pending.release([]);
});
test("R2 time spent waiting for manual continuation consumes the same budget", async () => {
  const f = fixture([guard("a"), guard("b")]); let elapsed = 0;
  const r = await f.run({limits: {pageSize: 1, maxDurationMs: 1000},
    control: {clock: () => elapsed,
      beforeNextPage: async () => {elapsed = 1000; return true;}}});
  assert.equal(r.coverage, "TIME_LIMIT"); assert.equal(f.calls.pages.length, 1);
});
test("R2 expired query result is not classified even if the SDK returned data", async () => {
  const f = fixture(); let elapsed = 0;
  f.hooks.page = async () => {elapsed = 1000; return [guard("owner")];};
  const r = await f.run({limits: {maxDurationMs: 1000}, control: {clock: () => elapsed}});
  assert.equal(r.coverage, "TIME_LIMIT"); assert.equal(r.counts.examined, 0);
  assert.deepEqual(f.calls.auth, []);
});
test("R2 live Auth never reads private residue documents", async () => {
  const f = fixture([guard("owner")]); const r = await f.run();
  assert.equal(r.counts.oldAuthPresent, 1); assert.deepEqual(f.calls.residues, []);
  assert.equal(r.operations.residueDocumentRequests, 0);
});
for (const field of ["userRoot", "billingAccount", "accountDeletionRuntime", "birthLedger"]) {
  test("R2 Auth absent detects only limited synthetic existence: " + field, async () => {
    const f = absent(fixture([guard("owner")]));
    f.hooks.residues = async () => ({userRoot: false, billingAccount: false,
      accountDeletionRuntime: false, birthLedger: false, [field]: true});
    const r = await f.run();
    assert.equal(r.residues.detected, 1); assert.equal(r.residueEvidence[field], 1);
    assert.equal(r.residues.noneObservedInLimitedScope, 0);
    assert.equal(f.calls.auth.length, 2); assert.equal(f.calls.guards.length, 2);
    assert.deepEqual(f.calls.residues, ["owner"]); assert.deepEqual(f.calls.writes, []);
  });
}
test("R2 no limited residue is not an integral deletion confirmation", async () => {
  const f = absent(fixture([guard("owner")])); const r = await f.run();
  assert.equal(r.residues.noneObservedInLimitedScope, 1);
  assert.equal(r.status, "OBSERVATIONS_ONLY");
  assert.equal(JSON.stringify(r).includes("COMPLETE"), false);
  assert.equal(r.operations.residueDocumentRequests, 4);
});
for (const code of ["PERMISSION_DENIED", "ECONNRESET"]) {
  test("R2 residue read failure is inconclusive: " + code, async () => {
    const f = absent(fixture([guard("owner")]));
    f.hooks.residues = async () => {throw failure(code);};
    const r = await f.run();
    assert.equal(r.residues.inconclusive, 1); assert.equal(r.residues.detected, 0);
    assert.equal(r.inconclusiveReasons.residueReadFailed, 1);
    assert.equal(r.residues.noneObservedInLimitedScope, 0);
    assert.equal(JSON.stringify(r).includes("synthetic-private"), false);
  });
}
test("R2 invalid residue adapter cannot produce a no-residue result", async () => {
  const f = absent(fixture([guard("owner")])); f.hooks.residues = async () => ({});
  assert.equal((await f.run()).residues.inconclusive, 1);
});
for (const change of ["version", "removed", "complete"]) {
  test("R2 guard changes during residue verification: " + change, async () => {
    const f = absent(fixture([guard("owner")]));
    f.hooks.residues = async () => {
      if (change === "removed") f.docs.delete("owner");
      else {
        const next = guard("owner"); next.version = "101:1";
        if (change === "complete") Object.assign(next.data, {state: "COMPLETE",
          retainUntil: Timestamp.fromMillis(NOW + 1)});
        f.docs.set("owner", next);
      }
      return {userRoot: true, billingAccount: false,
        accountDeletionRuntime: false, birthLedger: false};
    };
    const r = await f.run();
    assert.equal(r.residues.candidateChanged, 1); assert.equal(r.residues.detected, 0);
    assert.equal(r.residueEvidence.userRoot, 0); assert.deepEqual(f.calls.writes, []);
  });
}
test("R2 Auth reappearing during residue verification invalidates the candidate", async () => {
  const f = fixture([guard("owner")]); let lookups = 0;
  f.hooks.auth = async (id) => {
    if (++lookups === 1) throw failure("auth/user-not-found");
    return {uid: id};
  };
  const r = await f.run();
  assert.equal(r.residues.candidateChanged, 1);
  assert.equal(r.residues.noneObservedInLimitedScope, 0);
});
test("R2 second Auth lookup failure is inconclusive without accepting evidence", async () => {
  const f = fixture([guard("owner")]); let lookups = 0;
  f.hooks.auth = async () => {throw failure(++lookups === 1 ?
    "auth/user-not-found" : "auth/insufficient-permission");};
  const r = await f.run();
  assert.equal(r.residues.inconclusive, 1);
  assert.equal(r.inconclusiveReasons.authLookupFailed, 1);
});
test("R2 last guard revalidation failure is inconclusive", async () => {
  const f = absent(fixture([guard("owner")])); let checks = 0;
  f.hooks.guard = async (id) => {
    if (++checks === 2) throw failure("UNAVAILABLE");
    return f.docs.get(id);
  };
  const r = await f.run();
  assert.equal(r.residues.inconclusive, 1);
  assert.equal(r.residues.noneObservedInLimitedScope, 0);
});
test("R2 mixed inventory queries residues only for necessary absent-Auth candidates", async () => {
  const f = fixture([guard("absent"), guard("live"),
    guard("recent", {startedAt: Timestamp.fromMillis(NOW)}), guard("invalid", {state: "BAD"})]);
  f.hooks.auth = async (id) => {
    if (id === "absent") throw failure("auth/user-not-found");
    return {uid: id};
  };
  const before = JSON.stringify([...f.docs]); const r = await f.run();
  assert.deepEqual(f.calls.residues, ["absent"]);
  assert.equal(r.operations.residueDocumentRequests, 4);
  assert.equal(JSON.stringify([...f.docs]), before); assert.deepEqual(f.calls.writes, []);
  for (const privateValue of ["absent", "live", "aaaaaaaa-aaaa", "100:1", '"afterId"']) {
    assert.equal(JSON.stringify(r).includes(privateValue), false);
  }
});
test("R2 maximum reported logical budgets cover the worst absent-Auth path", async () => {
  const f = absent(fixture([guard("a"), guard("b"), guard("c")]));
  const r = await f.run({limits: {pageSize: 2, maxDocuments: 3, maxPages: 2}});
  assert.equal(r.operations.guardPageRequests, 2);
  assert.equal(r.operations.guardDocumentResults, 3);
  assert.equal(r.operations.guardRevalidationRequests, 6);
  assert.equal(r.operations.residueDocumentRequests, 12);
  assert.equal(r.operations.authLookupRequests, 6);
  assert.equal(r.limits.estimatedMaximumFirestoreReads, 23);
  assert.equal(r.limits.maximumAuthLookups, 6);
});
test("R2 residue SDK adapter reads four proven paths with empty field mask", async () => {
  const calls = []; const owner = "owner";
  const hash = require("node:crypto").createHash("sha256").update(owner).digest("hex");
  const ref = (p) => ({path: p, collection: (name) => collection(p + "/" + name)});
  const collection = (p) => ({doc: (id) => ref(p + "/" + id)});
  const db = {projectId: PROJECT, collection,
    getAll: async (...args) => {
      assert.deepEqual(args.pop(), {fieldMask: []});
      calls.push(...args.map((r) => r.path));
      return args.map((r, i) => ({ref: r, exists: i === 0,
        data() {throw new Error("PRIVATE_CONTENT_ACCESSED");}}));
    }};
  const r = await readResidueExistence(db, owner, ENV);
  assert.deepEqual(calls, ["users/owner", "billing_google_accounts/" + hash,
    "users/owner/runtime/account_deletion", "account_birth_decisions/owner"]);
  assert.deepEqual(r, {userRoot: true, billingAccount: false,
    accountDeletionRuntime: false, birthLedger: false});
});
test("R2 residue SDK adapter refuses invalid UID or missing emulator before IO", async () => {
  let reads = 0; const db = {projectId: PROJECT, collection() {reads++; throw new Error();}};
  await assert.rejects(readResidueExistence(db, "owner", {}));
  await assert.rejects(readResidueExistence(db, "../owner", ENV));
  assert.equal(reads, 0);
});
for (const limits of [{maxPages: 0}, {maxPages: 101}, {maxDurationMs: 999},
  {maxDurationMs: 60001}, {maxDurationMs: Infinity}]) {
  test("R2 invalid new budget refuses before IO: " + JSON.stringify(limits), async () => {
    const f = fixture(); await assert.rejects(f.run({limits}));
    assert.deepEqual(f.calls.pages, []);
  });
}
test("R2 CLI supports bounded manual continuation without an external cursor", () => {
  assert.deepEqual(parseArgs(["--project", PROJECT, "--manual-pages", "true",
    "--max-pages", "2", "--max-duration-ms", "1000"]), {projectId: PROJECT,
    manualPages: true, limits: {maxPages: 2, maxDurationMs: 1000}});
  for (const args of [["--manual-pages", "yes"], ["--cursor", "owner"],
    ["--after-id", "owner"], ["--uid", "owner"]]) assert.throws(() => parseArgs(args));
});
