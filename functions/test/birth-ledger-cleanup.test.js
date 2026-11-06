"use strict";
const reachOrFail=require("./helpers/observed-gate.cjs");

const assert = require("node:assert/strict");
const test = require("node:test");
const {Timestamp} = require("firebase-admin/firestore");
const {userRecordConstructor} = require("firebase-functions/v1/auth");
const {prepare, finish, originalOperation} = require("../birth_ledger_cleanup");
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
      return names.map(name => ({listDocuments: async () => [...new Set([...this.docs.keys()]
        .filter(p => p.startsWith(path + "/" + name + "/"))
        .map(p => p.slice(0, (path + "/" + name + "/").length) +
          p.slice((path + "/" + name + "/").length).split("/")[0]))]}));
    }, collection: (name) =>
      this.collection(`${path}/${name}`),
    get: async () => this.snapshot(path, this.docs)};
  }
  /**
   * @param {string} path Document path.
   * @param {Map} docs Snapshot data.
   * @return {Object} Snapshot.
   */
  snapshot(path, docs) {
    return {ref: this.ref(path), id: path.split("/").at(-1),
      exists: docs.has(path), data: () => copy(docs.get(path))};
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
      startAfter: () => q,
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
      q.filters.every((f) => f.op === "==" && docs.get(p)[f.field] === f.value),
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
          this.snapshot(ref.path, docs);
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
    for (const path of [...this.docs.keys()]) {
      if (path === ref.path || path.startsWith(`${ref.path}/`)) {
        this.put(path, undefined);
      }
    }
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
  f.prepare = () => prepare(db, f.user, f.context, f.lookup,
      {verified: true, notBefore: Timestamp.fromMillis(1)});
  return f;
}

/**
 * @param {Object} f Fixture.
 * @return {Promise<void>} Refusal before any writes.
 */
async function refused(f, code = "ACCOUNT_STATE_CONFLICT") {
  const docs = [...f.db.docs]; const writes = f.db.writes.length;
  await assert.rejects(f.prepare(), error => {
    assert.equal(error.code, code);
    if (code === "ACCOUNT_DELETION_BLOCKED") assert.equal(error.retryable, true);
    assert.doesNotMatch(error.message, /auth\/internal-error|synthetic not found/);
    return true;
  });
  assert.deepEqual([...f.db.docs], docs);
  assert.equal(f.db.writes.length, writes);
}

test("atomic finalization removes PII and COMPLETE in exactly one commit",
    async () => {
      const f = fixture(); await f.birth.record(); const a = await f.prepare();
      let seen = false;
      f.db.hooks.beforeCommit = ({pending}) => {
        if (!pending.length) return;
        assert.deepEqual(pending.map((w) => [w.type, w.ref.path]),
            [["delete", PATH], ["update", GUARD], ["update", GUARD + "/control/operation"]]);
        assert.ok(f.db.docs.get(PATH).originalIdentity.email);
        assert.equal(f.db.docs.get(GUARD).state, "IN_PROGRESS"); seen = true;
      };
      await finish(f.db, a); assert.equal(seen, true);
      assert.equal(f.db.docs.has(PATH), false);
      assert.equal(f.db.docs.get(GUARD).state, "COMPLETE");
      assert.ok(f.lookups.length >= 2);
      assert.ok(f.lookups.every(value => value === UID));
      assert.equal(f.db.docs.get(GUARD + "/control/operation").state, "COMPLETE");
    });

for (const mutation of [
  (f) => delete f.context.timestamp,
  (f) => f.context.timestamp = "2026-02-30T13:00:00Z",
  (f) => f.context.eventType = "google.firebase.auth.user.create",
  (f) => f.context.eventId = " ",
  (f) => f.context.resource.name = "projects/other",
  (f) => f.context.resource.service = "other",
  (f) => f.user.uid = "other/uid",
  (f) => f.user.uid = "é".repeat(65),
  (f) => f.user.tenantId = "tenant-1",
  (f) => f.user.metadata.creationTime = "malformed",
  (f) => f.live = {uid: UID},
  (f) => f.authError = {code: "auth/internal-error"},
]) {
  test(`preflight refuses: ${mutation.toString()}`, async () => {
    const f = fixture(); await f.birth.record();
    await mutation(f); await refused(f, f.authError ? "ACCOUNT_DELETION_BLOCKED" : "ACCOUNT_STATE_CONFLICT");
  });
}

for (const mutation of [
  (r) => r.uid = "other",
  (r) => r.originalIdentity.uid = "other",
  (r) => r.projectId = "other",
  (r) => r.authCreatedAt = Timestamp.fromMillis(
      Date.parse("2026-10-13T14:00:00Z")),
  (r) => r.authCreatedAt = "invalid",
  (r) => r.decisionId = "not-a-uuid",
  (r) => r.cohort.state = "OPEN",
  (r) => r.eligible = true,
]) {
  test(`ledger conflict is preserved: ${mutation.toString()}`, async () => {
    const f = fixture(); await f.birth.record();
    const r = copy(f.db.docs.get(PATH)); mutation(r); f.db.put(PATH, r);
    await refused(f);
  });
}

test("explicit later root is preserved before a guard", async () => {
  const f = fixture(); f.db.put(ROOT, {displayName: "Synthetic later"});
  const snapshot = f.db.snapshot.bind(f.db);
  f.db.snapshot = (path, docs) => ({...snapshot(path, docs),
    createTime: path === ROOT ? Timestamp.fromMillis(
        Date.parse("2026-10-13T14:00:00Z")) : undefined});
  await refused(f); assert.equal(f.db.docs.has(GUARD), false);
});

test("R5 COMPLETE with residual ledger stays terminal and requires review", async () => {
  const f = fixture(); await f.birth.record();
  const record = copy(f.db.docs.get(PATH));
  const original = await f.prepare(); await finish(f.db, original);
  const g = copy(f.db.docs.get(GUARD));
  f.db.put(PATH, record);
  const before = [...f.db.docs], writes = f.db.writes.length;
  const a = await f.prepare();
  assert.equal(f.db.docs.get(GUARD).deletionId, g.deletionId);
  assert.equal(f.db.docs.get(GUARD).state, "COMPLETE");
  let writeAttempts = 0;
  f.db.hooks.beforeCommit = ({pending}) => {
    if (pending.length) {writeAttempts++; throw new Error("synthetic commit fail");}
  };
  await assert.rejects(finish(f.db, a), {code: "ACCOUNT_STATE_CONFLICT"});
  assert.equal(writeAttempts, 0);
  assert.equal(f.db.docs.has(PATH), true);
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, writes);
  f.db.hooks = {};
  await assert.rejects(finish(f.db, a), {code: "ACCOUNT_STATE_CONFLICT"});
  assert.equal(f.db.docs.get(GUARD).state, "COMPLETE");
  assert.deepEqual([...f.db.docs], before);
});

test("changed ledger after admission is preserved and cannot confirm COMPLETE",
    async () => {
      const f = fixture(); await f.birth.record(); const a = await f.prepare();
      const r = copy(f.db.docs.get(PATH));
      r.originalIdentity.displayName = "Changed";
      f.db.put(PATH, r);
      await assert.rejects(finish(f.db, a), {code: "ACCOUNT_STATE_CONFLICT"});
      assert.deepEqual(f.db.docs.get(PATH), r);
      assert.equal(f.db.docs.get(GUARD).state, "IN_PROGRESS");
    });

test("late inserted ledger cannot be erased using an absent-ledger admission",
    async () => {
      const f = fixture(); const old = fixture(); await old.birth.record();
      const a = await f.prepare(); f.db.put(PATH, copy(old.db.docs.get(PATH)));
      await assert.rejects(finish(f.db, a), {code: "ACCOUNT_STATE_CONFLICT"});
      assert.equal(f.db.docs.has(PATH), true);
      assert.equal(f.db.docs.get(GUARD).state, "IN_PROGRESS");
    });

test("root present at finalization prevents ledger delete and COMPLETE",
    async () => {
      const f = fixture(); await f.birth.record(); const a = await f.prepare();
      f.db.put(ROOT, {displayName: "Synthetic root"});
      await assert.rejects(finish(f.db, a), {code: "ACCOUNT_STATE_CONFLICT"});
      assert.equal(f.db.docs.has(PATH), true);
      assert.equal(f.db.docs.get(GUARD).state, "IN_PROGRESS");
    });

test("lost final reply replays without another ledger delete", async () => {
  const f = fixture(); await f.birth.record(); const a = await f.prepare();
  let lost = 0;
  f.db.hooks.afterCommit = ({pending}) => {
    if (!lost && pending.some(w => w.ref.path === GUARD + "/control/operation" && w.data?.state === "COMPLETE")) {
      lost++; throw new Error("synthetic lost reply");
    }
  };
  const result = await finish(f.db, a);
  assert.equal(lost, 1); assert.equal(result.status, "COMPLETE_RECHECKED");
  assert.equal(f.db.docs.has(PATH), false);
  assert.equal(f.db.docs.get(GUARD).state, "COMPLETE");
  f.db.hooks = {}; const before = f.db.writes.length;
  await finish(f.db, await f.prepare());
  assert.equal(f.db.writes.length, before);
});

test("concurrent cleanup of one identity shares guard and removes ledger once",
    async () => {
      const f = fixture(); await f.birth.record();
      const admissions = await Promise.all([f.prepare(), f.prepare()]);
      assert.equal(admissions[0].guard.deletionId,
          admissions[1].guard.deletionId);
      await Promise.all(admissions.map((a) => finish(f.db, a)));
      assert.equal(f.db.docs.has(PATH), false);
      assert.equal(f.db.writes.filter((w) => w.type === "delete" &&
        w.ref.path === PATH).length, 1);
    });

test("birth commits before guard: claim retries and includes the real ledger",
    async t => {
      const f = fixture(); const hold = pause(); let paused = false;
      f.db.hooks.beforeCommit = async ({pending}) => {
        if (!paused && pending.some((w) => w.ref.path === GUARD)) {
          paused = true; await hold.hold();
        }
      };
      const pending = assert.rejects(f.prepare(), {code: "ACCOUNT_STATE_CONFLICT"});
      t.after(async()=>{hold.release();await Promise.allSettled([pending]);});
      await reachOrFail(hold.reached,pending);
      await f.birth.record(); hold.release(); await pending;
      assert.equal(f.db.docs.has(GUARD), false);
      assert.equal(f.db.docs.has(GUARD + "/control/operation"), false);
      assert.equal(f.db.docs.has(PATH), true);
      f.db.hooks = {};
      const a = await f.prepare();
      assert.notEqual(originalOperation(f.db, a).scope.birthDigest, null);
      await finish(f.db, a);
      assert.equal(f.db.docs.has(PATH), false); assert.ok(f.db.conflicts >= 1);
    });

test("guard wins pending birth: real core retries and refuses resurrection",
    async t => {
      const f = fixture(); const hold = pause(); let paused = false;
      f.db.hooks.beforeCommit = async ({pending}) => {
        if (!paused && pending.some((w) => w.ref.path === PATH)) {
          paused = true; await hold.hold();
        }
      };
      const pending = assert.rejects(f.birth.record(),
          {code: "WATER_ACCOUNT_DELETING"});
      t.after(async()=>{hold.release();await Promise.allSettled([pending]);});
      await reachOrFail(hold.reached,pending); await finish(f.db, await f.prepare());
      hold.release(); await pending;
      assert.equal(f.db.docs.has(PATH), false); assert.ok(f.db.conflicts >= 1);
      assert.equal(f.db.docs.get(GUARD).state, "COMPLETE");
    });
