const cleanupManifest = require("../account_cleanup_manifest");
const realRemoveTree = cleanupManifest.removeTree;
cleanupManifest.removeTree = async options => {
  // These certified legacy fixtures model a known original Auth release.
  // Record that modeled result through the real journal transitions so retries
  // do not pretend that an unknown release is confirmed. No production hook.
  if (options.operation.origin === "PRE_AUTH" &&
      (await cleanupManifest.state(options)).authOutcome === "NOT_REQUESTED") {
    await cleanupManifest.authOutcome(options, "NOT_REQUESTED", "DISPATCHED");
    await cleanupManifest.authOutcome(options, "DISPATCHED", "CONFIRMED");
  }
  options.db.fixtureTreeOptions = options;
  return options.db.recursiveDelete(options.ref);
};
"use strict";
const reachOrFail=require("./helpers/observed-gate.cjs");
/* eslint-disable require-jsdoc -- Synthetic MVCC fixture and contract cases. */
// Offline only: fail on any network or ADC attempt.
const network = {attempts: 0};
function noNetwork() {network.attempts++; throw new Error("NETWORK_FORBIDDEN");}
for (const name of ["node:http", "node:https"]) {
  require(name).request = noNetwork; require(name).get = noNetwork;
}
require("node:net").Socket.prototype.connect = noNetwork;
require("node:tls").connect = noNetwork;
require("node:http2").connect = noNetwork;
global.fetch = noNetwork;
const {GoogleAuth} = require("google-auth-library");
for (const key of ["getClient", "getApplicationDefault", "getProjectId"]) GoogleAuth.prototype[key] = noNetwork;


const assert = require("node:assert/strict");
const test = require("node:test");
const {Timestamp} = require("firebase-admin/firestore");
const {userRecordConstructor} = require("firebase-functions/v1/auth");
const {prepare} = require("../birth_ledger_cleanup");
const {createAccountBirthRecorder} = require("../water_account_birth");

const UID = "synthetic-owner";
const PATH = `account_birth_decisions/${UID}`;
const ROOT = `users/${UID}`;
const GUARD = `account_deletion_guards/${UID}`;
const BORN = Timestamp.fromMillis(Date.parse("2026-10-13T10:00:00Z"));
const CLOCK = Timestamp.fromMillis(Date.parse("2026-10-13T12:00:00Z"));

/**
 * @param {*} v Value.
 * @return {*} Stable test data copy.
 */
function copy(v) {
  if (v instanceof Timestamp) return v;
  if (Array.isArray(v)) return v.map(copy);
  if (v && typeof v === "object" &&
    Object.getPrototypeOf(v) === Object.prototype) {
    return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, copy(x)]));
  }
  return v;
}

/**
 * @return {Object} Promise barrier without a sleep.
 */
function pause() {
  const reached = Promise.withResolvers();
  const release = Promise.withResolvers();
  return {reached: reached.promise, release: release.resolve,
    hold: async () => {
      reached.resolve(); await release.promise;
    }};
}

// Reads include absent-document versions; retries execute the real core
// callback.
// All write preconditions validate before any buffered write becomes visible.
/**
 * Deterministic test-only MVCC storage.
 */
class FakeFirestore {
  /**
   * Construct the synthetic namespace.
   */
  constructor() {
    this.projectId = "demo-life-os-p1";
    this.databaseId = "(default)";
    this.docs = new Map(); this.versions = new Map(); this.writes = [];
    this.commitClock = CLOCK;
    this.hooks = {}; this.attempts = 0; this.conflicts = 0;
  }
  /**
   * @param {string} path Document path.
   * @param {*} data Replacement or deletion.
   * @return {void}
   */
  put(path, data) {
    if (data === undefined) this.docs.delete(path);
    else this.docs.set(path, copy(data));
    for (const key of [path, `query:${path.split("/").slice(0, -1).join("/")}`,
      `group:${path.split("/").at(-2)}`]) {
      this.versions.set(key, (this.versions.get(key) || 0) + 1);
    }
  }
  /**
   * @param {string} path Document path.
   * @return {Object} Reference.
   */
  doc(path) { return this.ref(path); }
  ref(path) {
    return {path, kind: "doc", listCollections: async () => {
      const names = [...new Set([...this.docs.keys()].filter(p => p.startsWith(path + "/"))
        .map(p => p.slice(path.length + 1).split("/")[0]))];
      return names.map(name => ({path: path + "/" + name,
        listDocuments: async () => [...new Set([...this.docs.keys()]
          .filter(p => p.startsWith(path + "/" + name + "/"))
          .map(p => path + "/" + name + "/" +
            p.slice((path + "/" + name + "/").length).split("/")[0]))].map(p => this.ref(p))}));
    }, collection: (name) =>
      this.collection(`${path}/${name}`),
    get: async () => this.snapshot(path, this.docs)};
  }
  /**
   * @param {string} path Document path.
   * @param {Map} docs Snapshot data.
   * @return {Object} Snapshot.
   */
  snapshot(path, docs, versions = this.versions) {
    return {ref: this.ref(path), id: path.split("/").at(-1),
      exists: docs.has(path), updateTime: docs.has(path) ? Timestamp.fromMillis(versions.get(path) || 0) : undefined, data: () => copy(docs.get(path))};
  }
  /**
   * @param {string} path Query path.
   * @param {boolean} group Collection group.
   * @param {Array} filters Equality filters.
   * @param {number} limit Bound.
   * @return {Object} Query.
   */
  query(path, group = false, filters = [], limit = Infinity) {
    const q = {path, group, filters, bound: limit, kind: "query",
      where: (field, op, value) => this.query(path, group,
          [...filters, {field, op, value}], limit),
      limit: (n) => this.query(path, group, filters, n), orderBy: () => q,
      startAfter: snapshot => {q.cursor = snapshot.ref.path; return q;},
      get: async () => this.querySnapshot(q, this.docs)};
    return q;
  }
  /**
   * @param {string} path Collection path.
   * @return {Object} Collection.
   */
  collection(path) {
    return {...this.query(path), doc: (id) => this.ref(`${path}/${id}`)};
  }
  /**
   * @param {string} name Group name.
   * @return {Object} Group query.
   */
  collectionGroup(name) {
    return this.query(name, true);
  }
  /**
   * @param {Object} q Query.
   * @param {Map} docs Snapshot data.
   * @return {Object} Query result.
   */
  querySnapshot(q, docs) {
    const result = [...docs.keys()].sort().filter((p) =>
      (q.group ? p.split("/").at(-2) === q.path :
        p.startsWith(`${q.path}/`) &&
        !p.slice(q.path.length + 1).includes("/")) &&
      (!q.cursor || p > q.cursor) && q.filters.every((f) => f.op === "==" && docs.get(p)[f.field] === f.value),
    ).slice(0, q.bound).map((p) => this.snapshot(p, docs));
    return {docs: result, empty: result.length === 0, size: result.length};
  }
  /**
   * @param {Function} callback Real core callback.
   * @return {Promise<*>} Committed result.
   */
  async runTransaction(callback) {
    for (let attempt = 1; attempt <= 10; attempt++) {
      this.attempts++;
      const docs = new Map([...this.docs].map(([p, d]) => [p, copy(d)]));
      const versions = new Map(this.versions); const reads = new Map();
      const pending = [];
      const buffer = (type, ref, data) => pending.push({type, ref, data});
      const result = await callback({get: async (ref) => {
        assert.equal(pending.length, 0, "all reads must precede writes");
        const key = ref.kind === "query" ?
          `${ref.group ? "group" : "query"}:${ref.path}` : ref.path;
        reads.set(key, versions.get(key) || 0);
        if (this.hooks.onRead) await this.hooks.onRead(ref);
        return ref.kind === "query" ? this.querySnapshot(ref, docs) :
          this.snapshot(ref.path, docs, versions);
      }, create: (ref, data) => buffer("create", ref, data),
      set: (ref, data) => buffer("set", ref, data),
      update: (ref, data) => buffer("update", ref, data),
      delete: (ref) => buffer("delete", ref)});
      if (this.hooks.beforeCommit) {
        await this.hooks.beforeCommit({attempt, pending});
      }
      if ([...reads].some(([k, v]) => (this.versions.get(k) || 0) !== v)) {
        this.conflicts++; continue;
      }
      for (const w of pending) {
        if (w.type === "create") assert.equal(this.docs.has(w.ref.path), false);
        if (w.type === "update") assert.equal(this.docs.has(w.ref.path), true);
      }
      for (const w of pending) {
        const data = w.data && Object.fromEntries(Object.entries(w.data).map(
            ([k, v]) => [k, v && v.constructor &&
                v.constructor.name === "ServerTimestampTransform" ?
              this.commitClock : v],
        ));
        this.put(w.ref.path, w.type === "delete" ? undefined :
          w.type === "update" ? {...this.docs.get(w.ref.path), ...data} : data);
        this.writes.push(w);
      }
      if (this.hooks.afterCommit) await this.hooks.afterCommit({pending});
      return result;
    }
    throw new Error("MVCC retry exhaustion");
  }
  /**
   * @param {Object} ref Root reference.
   * @return {Promise<void>} Test tree deletion.
   */
  async recursiveDelete(ref) {
    return realRemoveTree(this.fixtureTreeOptions);
  }
}

/**
 * @return {Object} Managed synthetic event and real core on MVCC fake.
 */
function fixture() {
  const db = new FakeFirestore(); const f = {db};
  f.user = userRecordConstructor({uid: UID, metadata: {
    creationTime: BORN.toDate().toUTCString()}});
  f.context = {eventType: "google.firebase.auth.user.delete",
    eventId: "synthetic-delete-1", timestamp: "2026-10-13T13:00:00Z",
    resource: {service: "firebaseauth.googleapis.com",
      name: "projects/demo-life-os-p1"}, params: {}};
  f.lookups = [];
  f.lookup = async (uid) => {
    f.lookups.push(uid);
    if (f.authError) throw f.authError;
    if (f.live) return f.live;
    throw Object.assign(new Error("synthetic not found"),
        {code: "auth/user-not-found"});
  };
  f.birth = createAccountBirthRecorder({db, projectId: db.projectId, now: () => CLOCK,
    getTrustedBirth: () => ({source: {type: "FIREBASE_AUTH_CREATE",
      eventId: "synthetic-create-1", uid: UID, projectId: "demo-life-os-p1",
      tenantId: null, authCreatedAt: BORN, eventAt: BORN},
    identity: {uid: UID, email: "synthetic@example.invalid",
      displayName: "Synthetic", photoUrl: null},
    cohort: {version: 1, id: "closed-r3", policy: "NEW_ACCOUNT_V2_ONLY",
      state: "CLOSED", cutoverAt: Timestamp.fromMillis(1)}}),
    getCurrentAuthGeneration: () => ({uid: UID, projectId: "demo-life-os-p1",
      tenantId: null, authCreatedAt: BORN})});
  f.prepare = () => {f.certifiedFixture = true; return prepare(db, f.user, f.context, f.lookup,
      {verified: true, notBefore: Timestamp.fromMillis(1)});};
  return f;
}

const cleanup = require("../birth_ledger_cleanup");
const originalPrepareForCallback = cleanup.prepare;
// Propagate the SAME explicit synthetic rollout used to admit this fixture.
// No event/payload can select it; unprepared cases remain CLOSED.
cleanup.prepare = (...args) => active?.certifiedFixture ?
  originalPrepareForCallback(...args, {verified: true, notBefore: Timestamp.fromMillis(1)}) :
  originalPrepareForCallback(...args);
const core = require("../deletion_control");
const {createHash} = require("node:crypto");
// Reuse the existing MVCC fixture above; replace only Admin IO at the SDK seam.
process.env.GCLOUD_PROJECT = "demo-life-os-p1";
require("firebase-functions/v1");
const adminPath = require.resolve("firebase-admin");
require(adminPath);
const originalAdmin = require.cache[adminPath].exports;
let active;
require.cache[adminPath].exports = {initializeApp() {}, firestore: () => active.db,
  auth: () => ({getUser: uid => active.lookup(uid)})};
delete require.cache[require.resolve("../index")];
const {cleanupUserData} = require("../index");
require.cache[adminPath].exports = originalAdmin;
const OP = GUARD + "/control/operation", RES = "retired_auth_identities/" + UID;
const HASH = createHash("sha256").update(UID).digest("hex");
const BILL = "billing_google_accounts/" + HASH;
const TOKEN = "billing_google_tokens/synthetic-token";
const FOREIGN = "users/synthetic-other/health_info/2026-10-13";
const CHILD = ROOT + "/health_info/2026-10-13";
function realFixture() {
  const f = fixture();
  f.context.timestamp = new Date(Date.now() + 5000).toISOString();
  f.db.put(ROOT, {activeCircleId: null}); f.db.put(CHILD, {waterIntakeMl: 250});
  f.db.put(FOREIGN, {waterIntakeMl: 750});
  f.effects = [];
  const recursive = f.db.recursiveDelete.bind(f.db);
  f.db.recursiveDelete = async ref => {
    assert.equal(f.db.docs.get(OP).state, "IN_PROGRESS");
    assert.equal(f.db.docs.get(GUARD).deletionId, f.db.docs.get(OP).deletionId);
    f.effects.push(ref.path);
    if (f.failRoot && ref.path === ROOT) {
      f.failRoot = false; throw new Error("private chunk failure before commit");
    }
    await recursive(ref);
  };
  f.run = () => {active = f; return cleanupUserData.run(f.user, f.context);};
  f.preAuth = async () => {
    f.certifiedFixture = true;
    const binding = {projectId: f.db.projectId, databaseId: f.db.databaseId, uid: UID};
    const c = core.createController({db: f.db, binding, clock: () => Timestamp.now(),
      uuid: require("node:crypto").randomUUID, ports: {
        getAuthenticatedSubject: async () => binding,
        getAuthUser: async () => ({uid: UID}),
      }});
    const a = await c.admitBackend();
    return {controller: c, admission: a};
  };
  return f;
}
function pending(f) {
  assert.equal(f.db.docs.get(GUARD).state, "IN_PROGRESS");
  assert.equal(f.db.docs.get(GUARD).retainUntil, null);
  assert.equal(f.db.docs.get(OP).state, "IN_PROGRESS");
  assert.equal(f.db.docs.get(OP).completedAt, null);
  assert.equal(f.db.docs.get(RES).deletionId, f.db.docs.get(OP).deletionId);
}
function terminal(f, original) {
  assert.equal(f.db.docs.get(OP).state, "COMPLETE");
  assert.equal(f.db.docs.get(GUARD)?.state ?? "COMPLETE", "COMPLETE");
  assert.deepEqual(f.db.docs.get(OP), {...original, state: "COMPLETE", completedAt: f.db.docs.get(OP).completedAt});
  assert.equal([...f.db.docs.keys()].some(p => p === ROOT || p.startsWith(ROOT + "/")), false);
  assert.deepEqual(f.db.docs.get(FOREIGN), {waterIntakeMl: 750});
}
const blocked = promise => assert.rejects(promise, {message: "USER_DATA_CLEANUP_FAILED"});

test("R6B2 real SDK boundary keeps v1, restricted service account, retry and Node 22", () => {
  assert.equal(cleanupUserData.__endpoint.platform, "gcfv1");
  assert.equal(cleanupUserData.__endpoint.serviceAccountEmail,
      "life-os-cleanup-runtime@life-os-27b92.iam.gserviceaccount.com");
  assert.deepEqual(cleanupUserData.__trigger.failurePolicy, {retry: {}});
  assert.equal(require("../package.json").engines.node, "22");
});
test("R6B2 real callback associates PRE_AUTH without replacing ID, scope or origin", async () => {
  const f = realFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  await f.run(); terminal(f, original);
  assert.equal(f.db.docs.get(OP).origin, "PRE_AUTH");
  assert.deepEqual(f.effects, [ROOT]);
  assert.equal(f.db.writes.filter(w => w.type === "create" && w.ref.path === RES).length, 1);
});
test("R6B2 synthetic certified AUTH_EVENT admits once and keeps actual event ID", async () => {
  const f = realFixture(); f.db.put(ROOT, undefined); await f.birth.record();
  f.db.put(ROOT, {activeCircleId: null});
  const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  assert.equal(original.origin, "AUTH_EVENT"); assert.equal(original.sourceEventId, f.context.eventId);
  await f.run(); terminal(f, original); assert.equal(f.db.docs.has(PATH), false);
  const before = [...f.db.docs], writes = f.db.writes.length;
  await f.run(); assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, writes);
  assert.deepEqual(f.effects, [ROOT]);
});
test("R6B2 no certified boundary creates deny-only REVIEW_REQUIRED and never cleans", async () => {
  const f = realFixture(); f.context.verified = true; f.context.association = "NEW_POLICY";
  await blocked(f.run());
  assert.equal(f.db.docs.get(OP).state, "REVIEW_REQUIRED");
  assert.equal(f.db.docs.get(OP).scope, null); assert.equal(f.db.docs.has(GUARD), false);
  assert.deepEqual(f.effects, []); assert.equal(f.db.docs.has(ROOT), true);
  const before = [...f.db.docs], writes = f.db.writes.length;
  await blocked(f.run()); assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, writes);
});
for (const state of ["IN_PROGRESS", "COMPLETE"]) test("R6B2 legacy guard " + state + " cannot supply authority", async () => {
  const f = realFixture();
  f.db.put(GUARD, {version: 1, state, deletionId: "30000000-0000-4000-8000-000000000001",
    startedAt: CLOCK, retainUntil: state === "COMPLETE" ? Timestamp.fromMillis(CLOCK.toMillis()+1000) : null});
  const before = [...f.db.docs], writes = f.db.writes.length;
  await blocked(f.run()); assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, writes);
  assert.deepEqual(f.effects, []);
});
test("R6B2 repeated event before and after COMPLETE keeps a single operation", async () => {
  const f = realFixture(); const a = await f.prepare(), b = await f.prepare();
  assert.equal(a.guard.deletionId, b.guard.deletionId);
  const original = copy(f.db.docs.get(OP)); await f.run(); terminal(f, original);
  const count = f.db.writes.length; await f.run(); assert.equal(f.db.writes.length, count);
  assert.deepEqual(f.effects, [ROOT]);
});
test("R6B2 concurrent callback cleaners share original authority and delete no foreign UID", async () => {
  const f = realFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  await Promise.all([f.run(), f.run()]); terminal(f, original);
  assert.ok(f.effects.length >= 1 && f.effects.length <= 2);
  assert.ok(f.effects.every(path => path === ROOT));
  assert.equal(f.db.writes.filter(w => w.type === "create" && w.ref.path === OP).length, 1);
});
for (const code of ["auth/internal-error", "ETIMEDOUT", "UNAVAILABLE", "unexpected"]) {
  test("R6B2 Auth lookup " + code + " preserves pending scope and stops effects", async () => {
    const f = realFixture(); await f.preAuth(); const before = [...f.db.docs];
    f.authError = Object.assign(new Error("private auth details"), {code});
    await blocked(f.run()); pending(f); assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, []);
  });
}
test("R6B2 reappeared Auth blocks original cleanup and preserves all controls", async () => {
  const f = realFixture(); await f.preAuth(); const before = [...f.db.docs];
  f.live = {uid: UID}; await blocked(f.run()); pending(f);
  assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, []);
});
test("R6B2 divergent event cannot replace original AUTH_EVENT source or scope", async () => {
  const f = realFixture(); await f.prepare(); const before = [...f.db.docs];
  f.context.eventId = "different-event";
  await blocked(f.run()); assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, []);
});
test("R6B2 guard disappearance blocks retry and never recreates parent", async () => {
  const f = realFixture(); await f.preAuth(); f.db.put(GUARD, undefined); const before = [...f.db.docs];
  await blocked(f.run()); assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, []);
});
test("R6B2 partial root failure leaves pending, same scope retry and no false completion", async () => {
  const f = realFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  f.failRoot = true; await blocked(f.run()); pending(f);
  assert.equal(f.failRoot, false); assert.equal(f.db.docs.has(ROOT), true); assert.equal(f.db.docs.has(CHILD), true);
  assert.deepEqual(f.db.docs.get(OP), original);
  await f.run(); terminal(f, original); assert.deepEqual(f.effects, [ROOT, ROOT]);
});
test("R6B2 partial Billing transaction failure stops before root and keeps original authority", async () => {
  const f = realFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  f.db.put(BILL, {uid: UID, state: "ACTIVE"}); f.db.put(TOKEN, {accountHash: HASH});
  let injected = 0;
  f.db.hooks.beforeCommit = ({pending: writes}) => {
    if (!injected && writes.some(w => w.type === "delete" && w.ref.path === TOKEN)) {
      injected++; throw new Error("private billing failure");
    }
  };
  await blocked(f.run()); pending(f); assert.equal(injected, 1);
  assert.deepEqual(f.effects, []); assert.equal(f.db.docs.has(TOKEN), true);
  f.db.hooks = {}; await f.run(); terminal(f, original); assert.equal(f.db.docs.has(TOKEN), false);
});
test("R6B2 Circle ownership conflict stops cleanup and leaves pending", async () => {
  const f = realFixture(); await f.preAuth();
  f.db.put(ROOT, {activeCircleId: "unproven-circle"});
  f.db.put("circles/unproven-circle", {adminId: "other", memberCount: 2, schemaVersion: 2});
  await blocked(f.run()); pending(f); assert.deepEqual(f.effects, []);
  assert.equal(f.db.docs.has("circles/unproven-circle"), true); assert.equal(f.db.docs.has(ROOT), true);
});
for (const applied of [false, true]) test("R6B2 admission commit lost applied=" + applied + " never cleans before confirmed authority", async () => {
  const f = realFixture(); let injected = 0;
  const hook = ({pending: writes}) => {
    if (!injected && writes.some(w => w.type === "create" && w.ref.path === OP)) {
      injected++; throw new Error("private lost admission");
    }
  };
  f.db.hooks[applied ? "afterCommit" : "beforeCommit"] = hook;
  if (applied) {
    const a = await f.prepare(); pending(f); assert.equal(injected, 1); assert.deepEqual(f.effects, []);
    f.db.hooks = {}; const original = cleanup.originalOperation(f.db, a); await f.run(); terminal(f, original);
  } else {
    await assert.rejects(f.prepare(), {code: "ACCOUNT_DELETION_BLOCKED"});
    assert.equal(injected, 1); assert.equal(f.db.docs.has(OP), false); assert.equal(f.db.docs.has(RES), false);
    assert.equal(f.db.docs.has(GUARD), false); assert.deepEqual(f.effects, []);
  }
});
test("R6B2 final commit lost reply rechecks terminal state without another effect", async () => {
  const f = realFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP)); let lost = 0;
  f.db.hooks.afterCommit = ({pending: writes}) => {
    if (!lost && writes.some(w => w.ref.path === OP && w.data?.state === "COMPLETE")) {
      lost++; throw new Error("private final reply");
    }
  };
  await f.run(); terminal(f, original); assert.equal(lost, 1);
  f.db.hooks = {}; await f.run(); assert.deepEqual(f.effects, [ROOT]);
});
test("R6B2 COMPLETE receipt survives missing parent; residues never reopen it", async () => {
  const f = realFixture(); await f.preAuth(); await f.run();
  const receipt = copy(f.db.docs.get(OP)); f.db.put(GUARD, undefined);
  const before = [...f.db.docs], writes = f.db.writes.length;
  await f.run(); assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, writes);
  f.db.put(CHILD, {waterIntakeMl: 999});
  await blocked(f.run()); assert.equal(f.db.docs.get(CHILD).waterIntakeMl, 999);
  assert.equal(f.db.docs.has(GUARD), false); assert.deepEqual(f.db.docs.get(OP), receipt);
  assert.deepEqual(f.effects, [ROOT]);
});
test("R6B2 peer completes while callback is paused: no new effects after terminal observation", async t => {
  const f = realFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  const hold = pause(); t.after(hold.release); let paused = false;
  f.db.hooks.beforeCommit = async ({pending: writes}) => {
    if (!paused && writes.some(w => w.ref.path === BILL && w.type === "set")) {
      paused = true; await hold.hold();
    }
  };
  const first = f.run(); await reachOrFail(hold.reached,first);
  await f.run(); const count = f.effects.length; hold.release(); await first;
  terminal(f, original); assert.equal(f.effects.length, count); assert.ok(f.db.conflicts >= 1);
});
test("R6B2 PRE_AUTH event predating operation cannot acquire original authority", async () => {
  const f = realFixture(); await f.preAuth(); f.context.timestamp = "2026-10-13T13:00:00Z";
  const before = [...f.db.docs]; await blocked(f.run()); assert.deepEqual([...f.db.docs], before);
  assert.deepEqual(f.effects, []);
});
test("R6B2 preserves replaced data after last lookup without claiming an atomic Auth fence", async () => {
  const f = realFixture(); await f.preAuth();
  const recursive = f.db.recursiveDelete.bind(f.db);
  f.db.recursiveDelete = async ref => {
    if (ref.path === ROOT) {f.live = {uid: UID}; f.db.put(CHILD, {newIdentity: true});}
    return recursive(ref);
  };
  await blocked(f.run());
  assert.equal(f.db.docs.has(CHILD), true, "sealed versions must preserve the privileged replacement");
  assert.equal(f.live.uid, UID); pending(f);
});
test("R6B2 partial Circle history failure preserves remaining page and original controls", async () => {
  const f = realFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  const history = "circles/old-circle/challenges/old-challenge/progress/" + UID;
  f.db.put(history, {uid: UID, value: 2});
  let injected = 0;
  f.db.hooks.beforeCommit = ({pending: writes}) => {
    if (!injected && writes.some(w => w.type === "delete" && w.ref.path === history)) {
      injected++; throw new Error("private Circle page failure");
    }
  };
  await blocked(f.run()); pending(f); assert.equal(injected, 1);
  assert.equal(f.db.docs.get(BILL).state, "DELETING");
  assert.equal(f.db.docs.has(history), true); assert.deepEqual(f.effects, []);
  f.db.hooks = {}; await f.run(); terminal(f, original); assert.equal(f.db.docs.has(history), false);
});
test("R6B2 read unavailable is not absence and cannot reserve or clean", async () => {
  const f = realFixture(), before = [...f.db.docs]; let reads = 0;
  f.db.hooks.onRead = ref => {
    if (ref.path === OP) {reads++; throw new Error("private permission failure");}
  };
  await blocked(f.run()); assert.equal(reads, 1);
  assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, []);
});
test("R6B2 final commit refused preserves ledger and cannot claim COMPLETE", async () => {
  const f = realFixture(); f.db.put(ROOT, undefined); await f.birth.record();
  f.db.put(ROOT, {activeCircleId: null}); await f.prepare();
  const original = copy(f.db.docs.get(OP)); let failed = 0;
  f.db.hooks.beforeCommit = ({pending: writes}) => {
    if (writes.some(w => w.ref.path === OP && w.data?.state === "COMPLETE")) {
      failed++; throw new Error("private final commit refused");
    }
  };
  await blocked(f.run()); assert.equal(failed, 1); pending(f);
  assert.equal(f.db.docs.has(PATH), true); assert.deepEqual(f.db.docs.get(OP), original);
  f.db.hooks = {}; await f.run(); terminal(f, original); assert.equal(f.db.docs.has(PATH), false);
});


test("R6B2 offline suite made zero network or ADC calls", () => assert.equal(network.attempts, 0));

// P1-R6B2-CIRCLES-PRODUCTION-FIX-R1: same real callback and existing MVCC fixture.
const circles = require("../circle_cleanup");
const CIRCLE = "circles/synthetic-owned", MARKER = "circle_deletions/synthetic-owned";
const CLOSURE = "circle_cleanup_guards/synthetic-owned", PEER = "synthetic-member";
function ownedCircle(f, count = 1, id = "synthetic-owned") {
  const path = "circles/" + id;
  f.db.put(ROOT, {activeCircleId: id});
  f.db.put(path, {schemaVersion: 2, adminId: UID, memberCount: count, memberLimit: count > 3 ? 30 : 3});
  f.db.put(path + "/members/" + UID, {role: "admin"});
  for (let n = 1; n < count; n++) {
    const peer = n === 1 ? PEER : "synthetic-member-" + n;
    f.db.put(path + "/members/" + peer, {role: "member"});
    f.db.put("users/" + peer, {activeCircleId: id, keep: true});
  }
  f.db.put(path + "/challenges/c/progress/" + UID, {uid: UID, value: 1});
  return path;
}
function orphanCircle(f, peers = true) {
  ownedCircle(f, peers ? 2 : 1);
  f.db.put(CIRCLE, undefined);
  f.db.put(CIRCLE + "/challenges/missing/unknown/private", {syntheticOrphan: true});
}
for (const count of [1, 2, 30]) test("Circles fix D1/D3 legitimate managed owner with " + count + " members", async () => {
  const f = realFixture(); ownedCircle(f, count);
  const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  const claimed = [];
  f.db.hooks.afterCommit = () => {
    const marker = f.db.docs.get(MARKER);
    if (marker?.state === "SERVER_DELETING") claimed.push(copy(marker));
  };
  await f.run(); terminal(f, original);
  assert.equal(f.db.docs.has(CIRCLE), false); assert.equal(f.db.docs.has(MARKER), false);
  assert.equal(f.db.docs.get(CLOSURE).state, "SERVER_DELETING");
  assert.ok(claimed.length); assert.ok(claimed.every(c => c.initiatedBy === UID && c.memberUids.length === count));
  assert.deepEqual(f.effects, [CIRCLE, ROOT]);
  if (count > 1) assert.deepEqual(f.db.docs.get("users/" + PEER), {activeCircleId: null, keep: true});
  const before = [...f.db.docs], effects = [...f.effects];
  await f.run(); assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, effects);
});
test("Circles fix restrictive pre-Auth preflight still refuses shared owned Circle", async () => {
  const f = realFixture(); ownedCircle(f, 2); const before = [...f.db.docs];
  await assert.rejects(f.db.runTransaction(tx => circles.preflightOwned(tx, f.db, UID)), {code: "CIRCLE_ADMIN_ACTION_REQUIRED"});
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.docs.has(OP), false); assert.deepEqual(f.effects, []);
});
test("Circles fix D3 stored long Circle ID stays cleanable with proved closure", async () => {
  const f = realFixture(), id = "c".repeat(129); const path = ownedCircle(f, 1, id);
  const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  await f.run(); terminal(f, original); assert.equal(f.db.docs.has(path), false);
  assert.equal(f.db.docs.get("circle_cleanup_guards/" + id).state, "SERVER_DELETING");
});
test("Circles fix D2 missing root removes only claimed concrete descendants including absent parents", async () => {
  const f = realFixture(); orphanCircle(f);
  f.db.put("circles/foreign/challenges/c/progress/" + PEER, {uid: PEER, value: 7});
  const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  await f.run(); terminal(f, original);
  assert.equal([...f.db.docs.keys()].some(p => p.startsWith(CIRCLE + "/")), false);
  assert.deepEqual(f.effects, [ROOT], "no native collection recursiveDelete delegation");
  assert.deepEqual(f.db.docs.get("users/" + PEER), {activeCircleId: null, keep: true});
  assert.deepEqual(f.db.docs.get("circles/foreign/challenges/c/progress/" + PEER), {uid: PEER, value: 7});
  assert.equal(f.db.docs.get(MARKER).state, "AUTH_DELETE_ORPHAN_CLEANUP");
  const before = [...f.db.docs], count = f.db.writes.length; await f.run();
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, count);
});
test("Circles fix D2 pages stay <=200; partial commit failure retains original claim and retry scope", async () => {
  const f = realFixture(); orphanCircle(f, false);
  for (let n = 0; n < 417; n++) f.db.put(CIRCLE + "/challenges/missing/progress/item-" + n, {syntheticOldData: true});
  const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  let pages = 0, failed = 0; const sizes = [];
  f.db.hooks.beforeCommit = ({pending: writes}) => {
    const removed = writes.filter(w => w.type === "delete" && w.ref.path.startsWith(CIRCLE + "/"));
    if (removed.length) {
      sizes.push(removed.length); assert.ok(removed.length <= 200);
      if (++pages === 2) {failed++; throw new Error("synthetic orphan page failure");}
    }
  };
  await blocked(f.run()); pending(f); assert.equal(failed, 1); assert.equal(pages, 2);
  assert.deepEqual(f.db.docs.get(OP), original);
  assert.equal(f.db.docs.get(MARKER).state, "SERVER_DELETING");
  assert.equal(f.db.docs.get(MARKER).initiatedBy, UID); assert.equal(f.db.docs.has(ROOT), true);
  assert.deepEqual(f.effects, []);
  f.db.hooks = {}; await f.run(); terminal(f, original);
  assert.equal([...f.db.docs.keys()].some(p => p.startsWith(CIRCLE + "/")), false);
  assert.ok(sizes.every(n => n <= 200));
});
test("Circles fix D2 new descendant during a page is included without changing operation", async () => {
  const f = realFixture(); orphanCircle(f, false);
  const a = await f.prepare(), original = cleanup.originalOperation(f.db, a); let added = 0;
  const late = CIRCLE + "/challenges/missing/unknown/late";
  f.db.hooks.beforeCommit = ({pending: writes}) => {
    if (!added && writes.some(w => w.type === "delete" && w.ref.path.startsWith(CIRCLE + "/"))) {
      added++; f.db.put(late, {syntheticConcurrentWriter: true});
    }
  };
  await f.run(); terminal(f, original); assert.equal(added, 1); assert.equal(f.db.docs.has(late), false);
});
test("Circles fix D2 recreated Circle root aborts before descendant commit", async () => {
  const f = realFixture(); orphanCircle(f, false); await f.prepare(); let added = 0;
  const replacement = {schemaVersion: 2, adminId: PEER, memberCount: 1, memberLimit: 3};
  f.db.hooks.beforeCommit = ({pending: writes}) => {
    if (!added && writes.some(w => w.type === "delete" && w.ref.path.startsWith(CIRCLE + "/"))) {
      added++; f.db.put(CIRCLE, replacement);
    }
  };
  await blocked(f.run()); pending(f); assert.equal(added, 1);
  assert.deepEqual(f.db.docs.get(CIRCLE), replacement);
  assert.equal(f.db.writes.some(w => w.type === "delete" && w.ref.path.startsWith(CIRCLE + "/")), false);
  assert.deepEqual(f.effects, []);
});
test("Circles fix D2 neither legacy marker alone nor member role grants orphan ownership", async () => {
  const f = realFixture(); orphanCircle(f, false);
  f.db.put(CIRCLE + "/members/" + UID, {role: "member"});
  f.db.put(MARKER, {version: 1, state: "AUTH_DELETE_ORPHAN_CLEANUP", circleId: "synthetic-owned", createdAt: CLOCK});
  await f.prepare(); await blocked(f.run()); pending(f);
  assert.equal(f.db.docs.has(CLOSURE), false); assert.equal(f.db.docs.has(CIRCLE + "/members/" + UID), true);
  assert.deepEqual(f.effects, []);
});
test("Circles fix D2 native recursive fence still rejects collection paths and foreign roots", async () => {
  const f = realFixture(); orphanCircle(f, false); const a = await f.prepare();
  const db = cleanup.cleanupDatabase(f.db, a), before = [...f.db.docs];
  for (const path of [CIRCLE + "/members", "circles/foreign", "users/foreign"]) {
    await assert.rejects(db.recursiveDelete(f.db.doc(path)), {code: "ACCOUNT_STATE_CONFLICT"});
  }
  assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, []);
});
test("Circles fix D3 partial native deletion with lost root resumes only original closure and claim", async () => {
  const f = realFixture(); ownedCircle(f, 2); const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  const native = f.db.recursiveDelete.bind(f.db); let failed = 0;
  f.db.recursiveDelete = async ref => {
    if (ref.path === CIRCLE && !failed) {
      failed++; f.db.put(CIRCLE, undefined); f.db.put(CIRCLE + "/members/" + UID, undefined);
      throw new Error("synthetic partial Circle delete");
    }
    return native(ref);
  };
  await blocked(f.run()); pending(f); assert.equal(failed, 1);
  const claim = copy(f.db.docs.get(MARKER)); assert.equal(claim.state, "SERVER_DELETING");
  assert.equal(f.db.docs.get(CLOSURE).state, "SERVER_DELETING");
  await f.run(); terminal(f, original);
  assert.deepEqual(f.db.docs.get(MARKER), {version: 1, state: "AUTH_DELETE_ORPHAN_CLEANUP",
    circleId: "synthetic-owned", createdAt: claim.createdAt});
  assert.deepEqual(f.effects, [ROOT]);
});
test("Circles fix D2 Auth reappears after claim: new pages stop and COMPLETE is not fabricated", async () => {
  const f = realFixture(); orphanCircle(f, false); await f.prepare(); let present = 0;
  f.db.hooks.afterCommit = ({pending: writes}) => {
    if (!present && writes.some(w => w.ref.path === MARKER && w.data?.state === "SERVER_DELETING")) {
      present++; f.live = {uid: UID};
    }
  };
  await blocked(f.run()); pending(f); assert.equal(present, 1);
  assert.equal(f.db.writes.some(w => w.type === "delete" && w.ref.path.startsWith(CIRCLE + "/")), false);
  assert.deepEqual(f.effects, []);
});
test("Circles fix D3 root ownership mismatch in pending claim blocks all destruction", async () => {
  const f = realFixture(); ownedCircle(f, 1); await f.prepare();
  f.db.put(MARKER, {version: 1, state: "SERVER_DELETING", circleId: "synthetic-owned",
    initiatedBy: PEER, memberUids: [PEER, UID], createdAt: CLOCK});
  await blocked(f.run()); pending(f); assert.deepEqual(f.effects, []);
  assert.equal(f.db.docs.has(CIRCLE), true);
});
test("Circles fix D2 unclaimed member arriving during a page cannot be erased", async () => {
  const f = realFixture(); orphanCircle(f, false); await f.prepare(); let added = 0;
  const path = CIRCLE + "/members/unclaimed-member";
  f.db.hooks.beforeCommit = ({pending: writes}) => {
    if (!added && writes.some(w => w.type === "delete" && w.ref.path.startsWith(CIRCLE + "/"))) {
      added++; f.db.put(path, {role: "member"});
    }
  };
  await blocked(f.run()); pending(f); assert.equal(added, 1);
  assert.deepEqual(f.db.docs.get(path), {role: "member"});
  assert.equal(f.db.writes.some(w => w.type === "delete" && w.ref.path.startsWith(CIRCLE + "/")), false);
});
test("Circles fix D2 late orphan at tombstone commit blocks terminal success", async () => {
  const f = realFixture(); orphanCircle(f, false); await f.prepare(); let added = 0;
  const late = CIRCLE + "/challenges/missing/new-collection/late";
  f.db.hooks.afterCommit = ({pending: writes}) => {
    if (!added && writes.some(w => w.ref.path === MARKER && w.data?.state === "AUTH_DELETE_ORPHAN_CLEANUP")) {
      added++; f.db.put(late, {syntheticLatePrivilegedWriter: true});
    }
  };
  await blocked(f.run()); pending(f); assert.equal(added, 1); assert.equal(f.db.docs.has(late), true);
  assert.equal(f.db.docs.has(ROOT), true); assert.deepEqual(f.effects, []);
  f.db.hooks = {}; await blocked(f.run()); pending(f); assert.equal(f.db.docs.has(late), true);
});
test("Circles fix D2 legacy tombstone needs independent owner proof and keeps its timestamp", async () => {
  const f = realFixture(); orphanCircle(f, false);
  const old = {version: 1, state: "AUTH_DELETE_ORPHAN_CLEANUP", circleId: "synthetic-owned", createdAt: CLOCK};
  f.db.put(MARKER, old); const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  await f.run(); terminal(f, original); assert.deepEqual(f.db.docs.get(MARKER), old);
});
test("Circles fix D2 cannot redirect an admitted operation to another absent Circle", async () => {
  const f = realFixture(); orphanCircle(f, false); const a = await f.prepare(), before = [...f.db.docs];
  await assert.rejects(circles.cleanupMissingCircle(cleanup.cleanupDatabase(f.db, a), UID, a.guard, "another-circle"), {code: "ACCOUNT_STATE_CONFLICT"});
  assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, []);
});
test("Circles fix D3 invalid closure is never replaced and permits no recursive deletion", async () => {
  const f = realFixture(); ownedCircle(f, 1); await f.prepare();
  f.db.put(CLOSURE, {version: 2, state: "SERVER_DELETING", createdAt: CLOCK});
  await blocked(f.run()); pending(f);
  assert.equal(f.db.docs.get(CLOSURE).version, 2); assert.equal(f.db.docs.has(CIRCLE), true);
  assert.deepEqual(f.effects, []);
});
test("Circles fix D3 Auth reappearance after closure prevents member link updates and deletion", async () => {
  const f = realFixture(); ownedCircle(f, 2); await f.prepare(); let present = 0;
  f.db.hooks.afterCommit = ({pending: writes}) => {
    if (!present && writes.some(w => w.ref.path === CLOSURE)) {present++; f.live = {uid: UID};}
  };
  await blocked(f.run()); pending(f); assert.equal(present, 1);
  assert.deepEqual(f.db.docs.get("users/" + PEER), {activeCircleId: "synthetic-owned", keep: true});
  assert.equal(f.db.docs.has(CIRCLE), true); assert.deepEqual(f.effects, []);
});
test("Circles fix original COMPLETE capability cannot start another orphan operation", async () => {
  const f = realFixture(); orphanCircle(f, false); const a = await f.prepare(); await f.run();
  const before = [...f.db.docs], writes = f.db.writes.length, effects = [...f.effects];
  await assert.rejects(circles.cleanupMissingCircle(cleanup.cleanupDatabase(f.db, a), UID, a.guard, "synthetic-owned"), {code: "ACCOUNT_CLEANUP_COMPLETE"});
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, writes); assert.deepEqual(f.effects, effects);
});
test("Circles fix ambiguous missing root and legacy pending marker cannot mint closure", async () => {
  const f = realFixture(); f.db.put(ROOT, {});
  const marker = {version: 1, state: "SERVER_DELETING", circleId: "synthetic-owned",
    initiatedBy: PEER, memberUids: [PEER, UID], createdAt: CLOCK};
  f.db.put(MARKER, marker); f.db.put("users/" + PEER, {activeCircleId: "synthetic-owned", keep: true});
  await f.prepare(); await blocked(f.run()); pending(f);
  assert.equal(f.db.docs.has(CLOSURE), false); assert.deepEqual(f.db.docs.get(MARKER), marker);
  assert.deepEqual(f.db.docs.get("users/" + PEER), {activeCircleId: "synthetic-owned", keep: true});
  assert.deepEqual(f.effects, []);
});
for (const orphan of [false, true]) test("Circles fix concurrent duplicate cleaners converge without new scope; orphan=" + orphan, async () => {
  const f = realFixture(); if (orphan) orphanCircle(f); else ownedCircle(f, 2);
  const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  const outcomes = await Promise.allSettled([f.run(), f.run()]);
  assert.ok(outcomes.some(o => o.status === "fulfilled"));
  for (const outcome of outcomes) if (outcome.status === "rejected") {
    assert.equal(outcome.reason.message, "USER_DATA_CLEANUP_FAILED");
  }
  await f.run(); terminal(f, original);
  assert.equal([...f.db.docs.keys()].some(p => p.startsWith(CIRCLE + "/")), false);
  assert.equal(f.db.writes.filter(w => w.type === "create" && w.ref.path === OP).length, 1);
  assert.equal(f.db.writes.filter(w => w.type === "create" && w.ref.path === RES).length, 1);
  const before = [...f.db.docs], effects = [...f.effects]; await f.run();
  assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, effects);
});

// Cover the appended Circle cases as well as the original offline cases.
test.after(() => assert.equal(network.attempts, 0));

// R6C4-D: append-only coverage; original R5 callback/controller and MVCC above.
// Only the SDK IO seam is synthetic. Never claim real recursiveDelete or IAM.
const reviewNormalWriter = require("../../backend/api/account/_deletion_control.cjs");
const REVIEW_PEER = UID + "-new";
const reviewReceiptPath = (uid, id = "card-1") =>
  "users/" + uid + "/study_card_create_receipts/" + id;
const reviewPayload = (id = "card-1") => ({operation: "create_review_card", version: 1,
  cardId: id, subjectId: "review-subject", question: "Synthetic Q", answer: "Synthetic A",
  createdAt: "2026-10-13T11:00:00.123456Z"});
const reviewModule = () => import("../../backend/api/study/_sync_card_create.js");
async function reviewCreate(f, id = "card-1", uid = UID) {
  const {createStudyCard} = await reviewModule();
  return createStudyCard({db: reviewNormalWriter.withNormalWriterTransactions(f.db, uid),
    userId: uid, body: reviewPayload(id)});
}
function reviewPeerState(f) {
  return new Map([...f.db.docs].filter(([path]) => path === "users/" + REVIEW_PEER ||
    path.startsWith("users/" + REVIEW_PEER + "/") ||
    path === "billing_google_accounts/" + createHash("sha256").update(REVIEW_PEER).digest("hex") ||
    path === "billing_google_tokens/review-peer-token"));
}
async function reviewFixture(ids = ["card-1"]) {
  const f = realFixture();
  f.db.put(ROOT, {uid: UID, email: "same@example.invalid", activeCircleId: null});
  // The original MVCC fixture does not implement merge options. These A
  // documents intentionally contain only the fields written by this helper,
  // so their modeled result agrees with set(..., {merge:true}).
  f.db.put(ROOT + "/study_info/main", {reviewQueue: 0});
  f.db.put(ROOT + "/subjects/review-subject", {cardsToReview: 0});
  const other = "users/" + REVIEW_PEER, {studyCardCreateFingerprint} = await reviewModule();
  f.db.put(other, {uid: REVIEW_PEER, email: "same@example.invalid", isPremium: true, keep: "B-profile"});
  f.db.put(other + "/study_info/main", {reviewQueue: 4, progress: .7, streak: 3});
  f.db.put(other + "/subjects/review-subject", {title: "B", cardsToReview: 4});
  f.db.put(other + "/review_queue/card-1", {subjectId: "review-subject", question: "B-Q", answer: "B-A"});
  f.db.put(reviewReceiptPath(REVIEW_PEER), {version: 1, uid: REVIEW_PEER,
    operation: "create_review_card", operationId: "card-1", subjectId: "review-subject",
    payloadFingerprint: studyCardCreateFingerprint(REVIEW_PEER, reviewPayload()), state: "APPLIED",
    appliedAt: CLOCK, cardCreated: true, reviewQueueDelta: 1, cardsToReviewDelta: 1});
  f.db.put("billing_google_accounts/" + createHash("sha256").update(REVIEW_PEER).digest("hex"),
      {uid: REVIEW_PEER, state: "ACTIVE", keep: "B-billing"});
  f.db.put("billing_google_tokens/review-peer-token", {accountHash:
    createHash("sha256").update(REVIEW_PEER).digest("hex"), keep: "B-token"});
  for (const id of ids) assert.equal((await reviewCreate(f, id)).outcome, "APPLIED");
  f.reviewPeerBefore = copy([...reviewPeerState(f)]);
  return f;
}
function reviewPeerPreserved(f) {
  assert.deepEqual([...reviewPeerState(f)], f.reviewPeerBefore);
  const peerPaths = new Set(f.reviewPeerBefore.map(([path]) => path));
  assert.equal(f.db.writes.some(w => peerPaths.has(w.ref.path)), false);
  assert.equal(f.db.writes.some(w => w.ref.path === "users/" + REVIEW_PEER ||
    w.ref.path.startsWith("users/" + REVIEW_PEER + "/")), false);
}
function reviewOriginal(f, original) {
  assert.equal(original.scope.privateRoot, ROOT);
  assert.equal(original.uid, UID);
  assert.equal(f.db.docs.get(OP).deletionId, original.deletionId);
  assert.deepEqual(f.db.docs.get(OP).scope, original.scope);
  assert.equal(f.db.docs.get(RES).deletionId, original.deletionId);
  assert.equal(f.db.docs.get(RES).state, "RESERVED");
}

test("R6C4-D active real review writer creates card, counters and APPLIED receipt before admission", async () => {
  const f = await reviewFixture(), receipt = f.db.docs.get(reviewReceiptPath(UID));
  assert.equal(f.db.docs.has(ROOT), true);
  assert.equal(f.db.docs.has(ROOT + "/review_queue/card-1"), true);
  assert.equal(f.db.docs.get(ROOT + "/study_info/main").reviewQueue, 1);
  assert.equal(f.db.docs.get(ROOT + "/subjects/review-subject").cardsToReview, 1);
  assert.deepEqual(Object.keys(receipt).sort(), ["version", "uid", "operation", "operationId",
    "subjectId", "payloadFingerprint", "state", "appliedAt", "cardCreated", "reviewQueueDelta", "cardsToReviewDelta"].sort());
  assert.equal(receipt.uid, UID); assert.equal(receipt.state, "APPLIED");
  assert.equal(receipt.appliedAt instanceof Timestamp, true);
  assert.equal(f.db.docs.has(OP), false); assert.equal(f.db.docs.has(RES), false);
  const {admission} = await f.preAuth(), original = copy(f.db.docs.get(OP));
  assert.equal(admission.status, "ADMITTED");
  await f.run(); terminal(f, original); reviewOriginal(f, original); reviewPeerPreserved(f);
  assert.equal(f.db.docs.has(reviewReceiptPath(UID)), false);
});

test("R6C4-D multiple receipts share only original private scope; prefix-like B profile Study and Billing survive", async () => {
  const ids = ["card-1", "card-2", "card-3"], f = await reviewFixture(ids);
  await f.preAuth(); const original = copy(f.db.docs.get(OP));
  await f.run(); terminal(f, original); reviewOriginal(f, original); reviewPeerPreserved(f);
  for (const id of ids) assert.equal(f.db.docs.has(reviewReceiptPath(UID, id)), false);
  assert.deepEqual(f.effects, [ROOT]);
  assert.equal(f.db.docs.get(reviewReceiptPath(REVIEW_PEER)).state, "APPLIED");
  assert.equal(f.lookups.every(uid => uid === UID), true);
});

test("R6C4-D rootless account and missing receipt parent remain enumerable private descendants", async () => {
  const f = await reviewFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  const missing = reviewReceiptPath(UID, "missing-parent"), deep = missing + "/unknown/private";
  f.db.put(deep, {syntheticOrphan: true}); f.db.put(ROOT, undefined);
  assert.equal(f.db.docs.has(missing), false);
  const children = (await Promise.all((await f.db.doc(ROOT).listCollections()).map(c => c.listDocuments()))).flat();
  assert.equal(children.some(ref => ref.path === missing), true);
  await assert.rejects(circles.assertUserTreeEmpty(f.db, UID), {code: "ACCOUNT_STATE_CONFLICT"});
  await f.run(); terminal(f, original); reviewOriginal(f, original); reviewPeerPreserved(f);
  assert.equal(f.db.docs.has(deep), false); assert.equal(f.db.docs.has(reviewReceiptPath(UID)), false);
});

for (const orphan of [false, true]) test("R6C4-D detectable residual prevents false COMPLETE; orphan=" + orphan, async () => {
  const f = await reviewFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  const path = reviewReceiptPath(UID, "residual") + (orphan ? "/unknown/private" : "");
  const data = orphan ? {syntheticOrphan: true} : copy(f.db.docs.get(reviewReceiptPath(UID)));
  const native = f.db.recursiveDelete.bind(f.db); let retain = true;
  f.db.recursiveDelete = async ref => {
    await native(ref);
    // Fault injection models a residual visible to terminalInventory, not a
    // production writer, nor an atomic real-SDK guarantee.
    if (ref.path === ROOT && retain) f.db.put(path, data);
  };
  await blocked(f.run()); pending(f); reviewOriginal(f, original); reviewPeerPreserved(f);
  assert.equal(f.db.docs.has(ROOT), false); assert.deepEqual(f.db.docs.get(path), data);
  assert.deepEqual(f.db.docs.get(OP), original);
  assert.equal(f.db.writes.some(w => w.ref.path === OP && w.data?.state === "COMPLETE"), false);
  retain = false; await blocked(f.run()); pending(f); reviewPeerPreserved(f);
  assert.deepEqual(f.db.docs.get(path), data); assert.deepEqual(f.effects, [ROOT, ROOT]);
});

for (const phase of ["before-receipt-removal", "after-first-receipt"]) test("R6C4-D partial receipt failure " + phase + " keeps original trace and blocks writer", async () => {
  const f = await reviewFixture(["card-1", "card-2"]); await f.preAuth();
  const original = copy(f.db.docs.get(OP)), reservation = copy(f.db.docs.get(RES));
  let failed = 0;
  f.db.hooks[phase === "after-first-receipt" ? "afterCommit" : "beforeCommit"] = ({pending: writes}) => {
    if (!failed && writes.some(w => w.type === "delete" && w.ref.path === reviewReceiptPath(UID))) {
      failed++; throw new Error("synthetic atomic receipt chunk failure");
    }
  };
  await blocked(f.run()); pending(f); reviewOriginal(f, original); reviewPeerPreserved(f);
  assert.equal(failed, 1); assert.equal(f.db.docs.has(reviewReceiptPath(UID, "card-2")), phase === "before-receipt-removal");
  assert.equal(f.db.docs.has(ROOT), true);
  assert.equal(f.db.docs.has(reviewReceiptPath(UID)), phase === "before-receipt-removal");
  assert.deepEqual(f.db.docs.get(OP), original); assert.deepEqual(f.db.docs.get(RES), reservation);
  const beforeWriter = [...f.db.docs];
  await assert.rejects(reviewCreate(f, "late-card"), {code: "ACCOUNT_DELETION_BLOCKED"});
  assert.deepEqual([...f.db.docs], beforeWriter);
  f.db.hooks = {}; await f.run(); terminal(f, original); reviewOriginal(f, original); reviewPeerPreserved(f);
  assert.deepEqual(f.effects, [ROOT, ROOT]);
  const count = f.db.writes.length, state = [...f.db.docs]; await f.run();
  assert.deepEqual([...f.db.docs], state); assert.equal(f.db.writes.length, count);
  assert.deepEqual(f.effects, [ROOT, ROOT]);
});

for (const missingGuard of [false, true]) test("R6C4-D business residual cannot reopen COMPLETE or reconstruct guard; parentMissing=" + missingGuard, async () => {
  const f = await reviewFixture(), residual = copy(f.db.docs.get(reviewReceiptPath(UID)));
  await f.preAuth(); await f.run();
  const receipt = copy(f.db.docs.get(OP)), reservation = copy(f.db.docs.get(RES));
  f.db.put(reviewReceiptPath(UID), residual); if (missingGuard) f.db.put(GUARD, undefined);
  const before = [...f.db.docs], writes = f.db.writes.length, effects = [...f.effects];
  await blocked(f.run());
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, writes);
  assert.deepEqual(f.effects, effects); assert.deepEqual(f.db.docs.get(OP), receipt);
  assert.deepEqual(f.db.docs.get(RES), reservation); assert.equal(receipt.state, "COMPLETE");
  assert.equal(f.db.docs.has(GUARD), !missingGuard); reviewPeerPreserved(f);
});

test("R6C4-D business receipt alone without root is not active identity or cleanup authority", async () => {
  const f = await reviewFixture(), receipt = copy(f.db.docs.get(reviewReceiptPath(UID)));
  f.db.put(ROOT, undefined);
  await assert.rejects(reviewCreate(f, "new-card"), {code: "REVIEW_CREATE_ROOT_UNAVAILABLE"});
  await blocked(f.run());
  assert.equal(f.db.docs.get(OP).state, "REVIEW_REQUIRED");
  assert.equal(f.db.docs.get(OP).scope, null); assert.equal(f.db.docs.has(GUARD), false);
  assert.equal(f.db.docs.has(ROOT), false); assert.deepEqual(f.db.docs.get(reviewReceiptPath(UID)), receipt);
  assert.deepEqual(f.effects, []); reviewPeerPreserved(f);
});

test("R6C4-D different deletionId cannot assume scope; original continuation still cleans receipts", async () => {
  const f = await reviewFixture(); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  const binding = {projectId: f.db.projectId, databaseId: f.db.databaseId, uid: UID};
  const continuation = id => core.createController({db: f.db, binding, clock: () => Timestamp.now(),
    uuid: require("node:crypto").randomUUID, ports: {getContinuation: async () => ({...binding, deletionId: id})}});
  const different = original.deletionId === "40000000-0000-4000-8000-000000000001" ?
    "40000000-0000-4000-8000-000000000002" : "40000000-0000-4000-8000-000000000001";
  const before = [...f.db.docs], writes = f.db.writes.length;
  await assert.rejects(continuation(different).resumeOriginal(), {code: "OPERATION_CONFLICT"});
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, writes);
  assert.equal((await continuation(original.deletionId).resumeOriginal()).status, "RESUMED");
  await f.run(); terminal(f, original); reviewOriginal(f, original); reviewPeerPreserved(f);
});

test("R6C4-D receipt subtree has no separate recursive authority and cannot target another UID", async () => {
  const f = await reviewFixture(); const a = await f.prepare(), original = cleanup.originalOperation(f.db, a);
  const guarded = cleanup.cleanupDatabase(f.db, a), before = [...f.db.docs];
  for (const path of [reviewReceiptPath(UID), ROOT + "/study_card_create_receipts", "users/" + REVIEW_PEER]) {
    await assert.rejects(guarded.recursiveDelete(f.db.doc(path)), {code: "ACCOUNT_STATE_CONFLICT"});
  }
  assert.deepEqual([...f.db.docs], before); assert.deepEqual(f.effects, []);
  await f.run(); terminal(f, original); reviewPeerPreserved(f);
});

test("R6C4-D business APPLIED shape cannot substitute operation receipt R5", async () => {
  const f = await reviewFixture(); await f.preAuth();
  f.db.put(OP, copy(f.db.docs.get(reviewReceiptPath(UID))));
  const before = [...f.db.docs], writes = f.db.writes.length;
  await blocked(f.run()); assert.deepEqual([...f.db.docs], before);
  assert.equal(f.db.writes.length, writes); assert.deepEqual(f.effects, []); reviewPeerPreserved(f);
});

test("R6C4-D duplicate cleaners converge for multiple business receipts without recreating private data", async () => {
  const f = await reviewFixture(["card-1", "card-2"]); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  const outcomes = await Promise.allSettled([f.run(), f.run()]);
  assert.ok(outcomes.some(o => o.status === "fulfilled"));
  for (const outcome of outcomes) if (outcome.status === "rejected") assert.equal(outcome.reason.message, "USER_DATA_CLEANUP_FAILED");
  await f.run(); terminal(f, original); reviewOriginal(f, original); reviewPeerPreserved(f);
  assert.equal(f.db.writes.filter(w => w.type === "create" && w.ref.path === OP).length, 1);
  assert.equal(f.db.writes.filter(w => w.type === "create" && w.ref.path === RES).length, 1);
  const state = [...f.db.docs], count = f.db.writes.length, effects = [...f.effects]; await f.run();
  assert.deepEqual([...f.db.docs], state); assert.equal(f.db.writes.length, count); assert.deepEqual(f.effects, effects);
});

test("R6C4-D actual normal writer held before commit loses to real R5 retirement and cleanup", {timeout: 10000}, async t => {
  const f = await reviewFixture([]), hold = pause(); t.after(hold.release); let paused = false;
  const reads = [];
  f.db.hooks.onRead = ref => {reads.push(ref.path);};
  f.db.hooks.beforeCommit = async ({pending: writes}) => {
    if (!paused && writes.some(w => w.ref.path === reviewReceiptPath(UID, "racing-card"))) {
      paused = true; assert.equal(writes.length, 4); await hold.hold();
    }
  };
  const writer = assert.rejects(reviewCreate(f, "racing-card"), {code: "ACCOUNT_DELETION_BLOCKED"});
  await reachOrFail(hold.reached,writer); await f.preAuth(); const original = copy(f.db.docs.get(OP));
  await f.run(); hold.release(); await writer;
  terminal(f, original); reviewOriginal(f, original); reviewPeerPreserved(f);
  assert.ok(f.db.conflicts >= 1); assert.equal(f.db.docs.has(reviewReceiptPath(UID, "racing-card")), false);
  assert.equal(f.db.writes.some(w => w.ref.path === reviewReceiptPath(UID, "racing-card")), false);
  for (const path of [GUARD, RES, OP]) assert.ok(reads.includes(path));
  t.diagnostic(JSON.stringify({r6c4D: "retirement-first", conflicts: f.db.conflicts,
    readPaths: reads, scope: original.scope.privateRoot, normalWriterCommitted: false}));
});

test("R6C4-D actual normal writer commits before held admission; original cleanup includes its receipt", {timeout: 10000}, async t => {
  const f = await reviewFixture([]), hold = pause(); t.after(hold.release); let paused = false;
  f.db.hooks.beforeCommit = async ({pending: writes}) => {
    if (!paused && writes.some(w => w.type === "create" && w.ref.path === OP)) {
      paused = true; await hold.hold();
    }
  };
  const retirement = f.preAuth(); await reachOrFail(hold.reached,retirement);
  assert.equal((await reviewCreate(f, "racing-card")).outcome, "APPLIED");
  assert.equal(f.db.docs.has(reviewReceiptPath(UID, "racing-card")), true);
  hold.release(); await retirement; const original = copy(f.db.docs.get(OP));
  await f.run(); terminal(f, original); reviewOriginal(f, original); reviewPeerPreserved(f);
  assert.equal(f.db.docs.has(reviewReceiptPath(UID, "racing-card")), false);
  const before = [...f.db.docs];
  await assert.rejects(reviewCreate(f, "later-card"), {code: "ACCOUNT_DELETION_BLOCKED"});
  assert.deepEqual([...f.db.docs], before);
  t.diagnostic(JSON.stringify({r6c4D: "writer-first", scope: original.scope.privateRoot,
    receiptRemoved: true, controlsRetained: [GUARD, RES, OP]}));
});

test.after(() => {
  assert.equal(network.attempts, 0);
  assert.equal(require("firebase-admin/app").getApps().length, 0);
});

test("unprepared historical AUTH_EVENT is quarantined before Billing or Circle mutations", async () => {
  const f = realFixture();
  await f.prepare();
  f.certifiedFixture = false;
  const original = copy(f.db.docs.get(OP));
  f.db.put(BILL, {uid: UID, state: "ACTIVE"});
  f.db.put(TOKEN, {accountHash: HASH});
  const root = copy(f.db.docs.get(ROOT));
  await blocked(f.run());
  assert.deepEqual(f.db.docs.get(ROOT), root);
  assert.equal(f.db.docs.get(BILL).state, "ACTIVE");
  assert.deepEqual(f.db.docs.get(TOKEN), {accountHash: HASH});
  assert.deepEqual(f.db.docs.get(OP), original);
  assert.deepEqual(f.effects, []);
  assert.deepEqual(f.db.docs.get(FOREIGN), {waterIntakeMl: 750});
});

test("quarantine committed before terminal commit prevents false R5 COMPLETE", async () => {
  const f = realFixture(); await f.preAuth();
  const original = copy(f.db.docs.get(OP)); let injected = 0;
  f.db.hooks.beforeCommit = async ({pending: writes}) => {
    if (!injected && writes.some(w => w.ref.path === OP && w.data?.state === "COMPLETE")) {
      injected++;
      await cleanupManifest.quarantine(f.db.fixtureTreeOptions, "SYNTHETIC_CONCURRENT_REVIEW");
    }
  };
  await blocked(f.run());
  assert.equal(injected, 1); pending(f);
  assert.deepEqual(f.db.docs.get(OP), original);
  assert.equal(f.db.docs.get(cleanupManifest.refs(f.db, original, ROOT).header.path).state, "QUARANTINED");
  assert.equal(f.db.writes.some(w => w.ref.path === OP && w.data?.state === "COMPLETE"), false);
  assert.deepEqual(f.db.docs.get(FOREIGN), {waterIntakeMl: 750});
});
