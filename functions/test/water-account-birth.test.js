"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {readFileSync} = require("node:fs");
const {spawnSync} = require("node:child_process");
const {resolve} = require("node:path");
const {pathToFileURL} = require("node:url");
const {Timestamp} = require("firebase-admin/firestore");
const {recordAccountBirth, createAccountBirthTestHarness, birthError} =
  require("../water_account_birth");

const UID = "synthetic-owner";
const PATH = `account_birth_decisions/${UID}`;
const ROOT = `users/${UID}`;
const GUARD = `account_deletion_guards/${UID}`;
const CUTOVER = Timestamp.fromMillis(Date.parse("2026-10-01T00:00:00Z"));
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
    this.projectId = "demo-life-os";
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
  ref(path) {
    return {path, kind: "doc", collection: (name) =>
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
      if (this.hooks.afterCommit) await this.hooks.afterCommit();
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
 * @return {Object} Synthetic trusted birth event.
 */
function origin() {
  return {source: {type: "FIREBASE_AUTH_CREATE", eventId: "synthetic-event-1",
    projectId: "demo-life-os", tenantId: null, uid: UID,
    authCreatedAt: BORN, eventAt: BORN},
  identity: {uid: UID, email: " synthetic@example.invalid ",
    displayName: " Synthetic\nOwner ", photoUrl: " avatar_neural "},
  cohort: {version: 1, id: "closed-test-v1", policy: "NEW_ACCOUNT_V2_ONLY",
    state: "CLOSED", cutoverAt: CUTOVER}};
}
/**
 * @return {Object} Synthetic current Auth generation.
 */
function live() {
  return {uid: UID, projectId: "demo-life-os", tenantId: null,
    authCreatedAt: BORN};
}
/**
 * @return {Object} Independent test fixture.
 */
function fixture() {
  const f = {db: new FakeFirestore(), birth: origin(), live: live(), clock:
      CLOCK};
  f.options = {db: f.db, getTrustedBirth: () => copy(f.birth),
    getCurrentAuthGeneration: async (uid) => {
      assert.equal(uid, UID); return copy(f.live);
    }, now: () => f.clock};
  f.api = createAccountBirthTestHarness(f.options);
  f.record = () => f.api.record();
  return f;
}
/**
 * @param {Object} f Fixture.
 * @param {string} code Expected domain refusal.
 * @param {Function} call Action.
 * @return {Promise<void>} Refusal and no-write assertion.
 */
async function unchangedFailure(f, code, call = f.record) {
  const before = [...f.db.docs]; const writes = f.db.writes.length;
  await assert.rejects(call(), (e) => e.code === code);
  assert.deepEqual([...f.db.docs], before); assert.equal(
      f.db.writes.length, writes);
}

test("synthetic event creates one durable closed record an" +
    "d compatible original identity", async () => {
  const f = fixture(); const result = await f.record(); const r =
      f.db.docs.get(PATH);
  assert.equal(result.eligible, false); assert.equal(
      result.alreadyRecorded, false);
  assert.match(result.decisionId, new RegExp(
      "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]" +
    "{3}-[0-9a-f]{12}$"));
  assert.deepEqual(r, {version: 1, uid: UID, projectId: "demo-life-os",
    tenantId: null, authCreatedAt: BORN,
    sourceType: "FIREBASE_AUTH_CREATE", sourceEventId: "synthetic-event-1",
    eventAt: BORN, cohort: f.birth.cohort, decisionId: result.decisionId,
    originalIdentity: {uid: UID, email: "synthetic@example.invalid",
      displayName: "SyntheticOwner", photoUrl: "avatar_neural"},
    status: "RECORDED_COHORT_CLOSED", recordedAt: CLOCK});
  assert.equal(f.db.docs.size, 1); assert.equal(f.db.writes[0].type, "create");
  assert.equal(f.db.writes[0].data.recordedAt.constructor.name,
      "ServerTimestampTransform");
});
test("duplicate event and fresh process-like factory retur" +
    "n original decisionId with zero writes", async () => {
  const f = fixture(); const first = await f.record(); const before =
      [...f.db.docs];
  const second = await createAccountBirthTestHarness(f.options).record();
  assert.deepEqual(second, {...first, alreadyRecorded: true});
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, 1);
});
test("response lost after actual fake commit recovers immu" +
    "table original decision", async () => {
  const f = fixture(); f.db.hooks.afterCommit = () => {
    throw new Error("lost");
  };
  await assert.rejects(f.record(), /lost/); const before = [...f.db.docs];
  f.db.hooks = {}; const replay = await f.record();
  assert.equal(replay.decisionId, f.db.docs.get(PATH).decisionId);
  assert.equal(replay.alreadyRecorded, true);
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, 1);
});
test("two concurrent same events commit one decision and r" +
    "eplay the winner", async () => {
  const f = fixture(); const hold = pause(); let commits = 0;
  f.db.hooks.beforeCommit = async () => {
    if (++commits === 1) await hold.hold();
  };
  const pending = f.record(); await hold.reached;
  const winner = await createAccountBirthTestHarness(f.options).record();
  hold.release(); const loser = await pending;
  assert.equal(loser.decisionId, winner.decisionId);
  assert.equal(loser.alreadyRecorded, true); assert.equal(f.db.conflicts, 1);
  assert.equal(f.db.writes.length, 1);
});
test("transaction retry retains its generated candidate decisionId",
    async () => {
      const f = fixture(); let candidate;
      f.db.hooks.beforeCommit = ({attempt, pending}) => {
        if (attempt === 1) {
          candidate = pending[0].data.decisionId; f.db.put(ROOT, {});
          f.db.put(ROOT, undefined);
        }
      };
      assert.equal((await f.record()).decisionId, candidate);
      assert.equal(f.db.conflicts, 1); assert.equal(f.db.writes.length, 1);
    });
test("delayed delivery uses event birth, not receipt time," +
    " and never becomes eligible", async () => {
  const f = fixture(); f.clock = Timestamp.fromMillis(CLOCK.toMillis() +
      86400000 * 30);
  f.db.commitClock = f.clock;
  const result = await f.record(); const record = f.db.docs.get(PATH);
  assert.ok(record.authCreatedAt.isEqual(BORN)); assert.ok(
      record.eventAt.isEqual(BORN));
  assert.ok(record.recordedAt.isEqual(f.clock));
  assert.equal(result.eligible, false);
});
test("event before cutover cannot be repaired by recent re" +
    "ceipt or recent live Auth", async () => {
  const f = fixture(); f.birth.source.authCreatedAt = Timestamp.fromMillis(1);
  f.birth.source.eventAt = CUTOVER; f.live.authCreatedAt =
      f.birth.source.authCreatedAt;
  await unchangedFailure(f, "WATER_BIRTH_BEFORE_CUTOVER");
});
for (const kind of ["read", "commit"]) {
  test(("failure before " +
    (kind) +
    " leaves no partial record; explicit retry recovers"), async () => {
    const f = fixture();
    f.db.hooks[kind === "read" ? "onRead" : "beforeCommit"] = () => {
      throw new Error("storage");
    };
    await assert.rejects(f.record(), /storage/); assert.equal(
        f.db.docs.size, 0);
    assert.equal(f.db.writes.length, 0); f.db.hooks = {};
    assert.equal((await f.record()).alreadyRecorded, false);
  });
}
for (const data of [{state: "IN_PROGRESS"}, {state: "COMPLETE",
  retainUntil: Timestamp.fromMillis(1)}, {}, null]) {
  test(("any existing deletion guard fails closed " +
    (JSON.stringify(data)) +
    ""), async () => {
    const f = fixture(); f.db.put(GUARD, data);
    await unchangedFailure(f, "WATER_ACCOUNT_DELETING");
  });
}
test("guard created after absence reads wins retry without" +
    " birth record resurrection", async () => {
  const f = fixture(); const hold = pause();
  f.db.hooks.beforeCommit = async ({attempt}) => {
    if (attempt === 1) await hold.hold();
  };
  const pending = f.record(); await hold.reached;
  f.db.put(GUARD, {state: "IN_PROGRESS"}); hold.release();
  await assert.rejects(pending, (e) => e.code === "WATER_ACCOUNT_DELETING");
  assert.equal(f.db.docs.has(PATH), false); assert.equal(f.db.writes.length, 0);
});
test("legacy root created concurrently prevents retrospect" +
    "ive birth recording", async () => {
  const f = fixture(); const hold = pause();
  f.db.hooks.beforeCommit = async ({attempt}) => {
    if (attempt === 1) await hold.hold();
  };
  const pending = f.record(); await hold.reached; f.db.put(ROOT, {xp:
      500}); hold.release();
  await assert.rejects(pending, (e) => e.code === "WATER_BIRTH_CONFLICT");
  assert.equal(f.db.docs.has(PATH), false); assert.deepEqual(f.db.docs.get(
      ROOT), {xp: 500});
});
for (const path of [ROOT, `${ROOT}/water_protocol/eligibility`,
  `${ROOT}/runtime/water_admission`, `${ROOT}/runtime/account_deletion`]) {
  test(`existing root or orphan protected document refuses ${path}`,
      async () => {
        const f = fixture(); f.db.put(path, {});
        await unchangedFailure(f, path.endsWith("account_deletion") ?
        "WATER_ACCOUNT_DELETING" : "WATER_BIRTH_CONFLICT");
      });
}
for (const change of [
  (b) => {
    b.source.eventId = "different";
  },
  (b) => {
    b.source.authCreatedAt = Timestamp.fromMillis(BORN.toMillis() - 1);
  },
  (b) => {
    b.cohort.id = "different-cohort";
  },
  (b) => {
    b.cohort.cutoverAt = Timestamp.fromMillis(CUTOVER.toMillis() + 1);
  },
  (b) => {
    b.identity.displayName = "different identity";
  },
]) {
  test(("replay refuses different event/generation/cohort/identity " +
    (change.toString()) +
    ""), async () => {
    const f = fixture(); await f.record(); change(f.birth);
    if (f.birth.source.authCreatedAt !== BORN) {
      f.live.authCreatedAt =
        f.birth.source.authCreatedAt;
    }
    await unchangedFailure(f, "WATER_BIRTH_CONFLICT");
  });
}
for (const patch of [{decisionId: "local-1"}, {status: "ELIGIBLE"}, {
  eligible: true},
{uid: "different"}, {projectId: "foreign-project"}, {tenantId: "other"},
{recordedAt: "bad"}, {recordedAt: new Timestamp(CLOCK.seconds,
    CLOCK.nanoseconds + 1)},
{cohort: {}}, {originalIdentity: {}}, {authCreatedAt: "bad"}, {
  sourceEventId: "other"}]) {
  test(("malformed persisted decision is never repaired " +
    (JSON.stringify(patch)) +
    ""), async () => {
    const f = fixture(); await f.record(); f.db.put(PATH, {
      ...f.db.docs.get(PATH), ...patch});
    await unchangedFailure(f, "WATER_BIRTH_CONFLICT");
  });
}
for (const bad of [undefined, {}, {creationTime: BORN, firstLogin: true},
  {...origin(), enabled: true}, {...origin(), token: "synthetic-secret"}]) {
  test(("malformed or client-style origin is rejected " +
    (JSON.stringify(bad)) +
    ""), async () => {
    const f = fixture(); f.birth = bad; await unchangedFailure(f,
        "WATER_BIRTH_INVALID_ORIGIN");
  });
}
for (const field of ["uid", "projectId", "tenantId", "authCreatedAt"]) {
  test(("live Auth generation mismatch " +
    (field) +
    " refuses even with root absent"), async () => {
    const f = fixture(); f.live[field] = field === "authCreatedAt" ?
      new Timestamp(BORN.seconds, BORN.nanoseconds + 1) : "different";
    await unchangedFailure(f, "WATER_BIRTH_GENERATION_CONFLICT");
  });
}
test("trusted user-not-found blocks delayed event after de" +
    "letion; uncertainty does not authorize", async () => {
  const f = fixture(); f.live = null;
  await unchangedFailure(f, "WATER_BIRTH_AUTH_NOT_FOUND");
  f.options.getCurrentAuthGeneration = () => {
    throw new Error("Auth network failed");
  };
  await assert.rejects(createAccountBirthTestHarness(f.options).record(),
      /Auth network failed/);
  assert.equal(f.db.writes.length, 0);
});
test("changed trusted identity on transaction retry cannot" +
    " mint another decision", async () => {
  const f = fixture(); f.db.hooks.beforeCommit = ({attempt}) => {
    if (attempt === 1) {
      f.birth.identity.displayName = "changed"; f.db.put(ROOT, {});
      f.db.put(ROOT, undefined);
    }
  };
  await unchangedFailure(f, "WATER_BIRTH_CONFLICT");
});
for (const invalidUid of ["", "uid/other", ".", "..", "__reserved__", " uid ",
  "a".repeat(129), "é".repeat(70), "bad\n"]) {
  test(`canonical UID refuses ${JSON.stringify(invalidUid)}`, async () => {
    const f = fixture(); f.birth.source.uid = invalidUid;
    f.birth.identity.uid = invalidUid;
    await unchangedFailure(f, "WATER_BIRTH_INVALID_ORIGIN");
  });
}
for (const change of [
  (b) => {
    b.source.projectId = "real-project";
  },
  (b) => {
    b.source.tenantId = "tenant";
  },
  (b) => {
    b.source.type = "HTTP_FIRST_LOGIN";
  },
  (b) => {
    b.source.eventAt = new Timestamp(CLOCK.seconds, CLOCK.nanoseconds + 1);
  },
  (b) => {
    b.identity.uid = "other";
  },
  (b) => {
    b.identity.email = "e".repeat(321);
  },
  (b) => {
    b.identity.password = "synthetic-secret";
  },
]) {
  test(`invalid source or identity refuses ${change.toString()}`, async () => {
    const f = fixture(); change(f.birth);
    await unchangedFailure(f, "WATER_BIRTH_INVALID_ORIGIN");
  });
}
test("null profile values normalize once to F-A compatible originals",
    async () => {
      const f = fixture(); Object.assign(f.birth.identity, {email: null,
        displayName: null, photoUrl: null});
      await f.record(); assert.deepEqual(f.db.docs.get(PATH).originalIdentity,
          {uid: UID, email: "", displayName: "Novo Usuário", photoUrl: null});
    });
test("opening the cohort or adding authority flags is refu" +
    "sed even in the synthetic seam", async () => {
  for (const patch of [{state: "OPEN"}, {enabled: true}, {
    legacyWritersExcluded: true}, {version: 2}]) {
    const f = fixture(); Object.assign(f.birth.cohort, patch);
    await unchangedFailure(f, "WATER_BIRTH_COHORT_CLOSED");
  }
});
test("zero-argument seam refuses request UID/flags, nonfun" +
    "ction source and production DB", async () => {
  const f = fixture();
  await unchangedFailure(f, "WATER_BIRTH_INVALID_ORIGIN", () =>
    f.api.record({uid: "victim", enabled: true}));
  for (const patch of [{enabled: true}, {getTrustedBirth: origin()}, {db: {
    ...f.db, projectId: "real-project"}}]) {
    assert.throws(() => createAccountBirthTestHarness({...f.options, ...patch}),
        (e) => e.code === "WATER_BIRTH_INVALID_CONFIGURATION");
  }
});
test("closed production entry ignores env, valid-looking e" +
    "vent and callback without IO", async (t) => {
  const previous = process.env.WATER_BIRTH_COHORT_ENABLED;
  process.env.WATER_BIRTH_COHORT_ENABLED = "true";
  t.after(() => {
    if (previous === undefined) delete process.env.WATER_BIRTH_COHORT_ENABLED;
    else process.env.WATER_BIRTH_COHORT_ENABLED = previous;
  });
  await assert.rejects(recordAccountBirth({enabled: true, event: origin(),
    db: {runTransaction: () => assert.fail("production IO")},
    getTrustedBirth: () => assert.fail("unverified callback")}),
  (e) => e.code === "WATER_BIRTH_COHORT_CLOSED");
});
test("another UID and its legacy Health history remain untouched", async () => {
  const f = fixture(); f.db.put("users/other/health_info/day", {
    waterIntakeMl: 1000});
  f.db.put("account_birth_decisions/other", {decisionId: "keep"});
  const before = [...f.db.docs]; await f.record();
  for (const [p, value] of before) assert.deepEqual(f.db.docs.get(p), value);
});
test("storage failures cannot forge domain codes or leak i" +
    "dentity/credentials", () => {
  assert.deepEqual(birthError(Object.assign(new Error("secret uid password"),
      {code: "WATER_ACCOUNT_DELETING"})),
  {code: "WATER_BIRTH_STORAGE_UNAVAILABLE",
    message: "Não foi possível registrar a origem da conta."});
});
test("module is inert on import and index exports no new t" +
    "rigger or birth integration", () => {
  const source = readFileSync(require.resolve("../water_account_birth"),
      "utf8");
  const index = readFileSync(require.resolve("../index"), "utf8");
  assert.doesNotMatch(source, new RegExp(
      "console\\.|process\\.env|initializeApp|getFirestore|on" +
    "Create|onDelete|firebase-functions"));
  assert.doesNotMatch(index,
      /water_account_birth|account_birth_decisions|\.onCreate\(/);
  assert.deepEqual(Object.keys(require("../water_account_birth")).sort(),
      ["birthError", "createAccountBirthTestHarness", "recordAccountBirth"]);
});

test("actual active Auth cleanup removes users tree and global birth record",
    async () => {
      const f = fixture(); await f.record();
      f.db.put(ROOT, {activeCircleId: null});
      f.db.put(`${ROOT}/health_info/day`, {waterIntakeMl: 0});
      // Explicit synthetic Admin replacement; no SDK IO.
      require("firebase-functions/v1");
      const adminPath = require.resolve("firebase-admin"); const indexPath =
      require.resolve("../index");
      require(adminPath); const savedAdmin = require.cache[adminPath].exports;
      const savedIndex = require.cache[indexPath]; let cleanup;
      try {
        require.cache[adminPath].exports = {initializeApp() {}, firestore: (
        ) => f.db, auth: () => ({getUser: async () => {
          throw Object.assign(new Error("synthetic not found"),
              {code: "auth/user-not-found"});
        }})};
        delete require.cache[indexPath]; cleanup = require(
            indexPath).cleanupUserData;
      } finally {
        require.cache[adminPath].exports = savedAdmin;
        delete require.cache[indexPath]; if (
          savedIndex) require.cache[indexPath] = savedIndex;
      }
      await cleanup.run({uid: UID}, {eventId: "synthetic-delete-b2a",
        eventType: "google.firebase.auth.user.delete",
        timestamp: "2026-10-13T13:00:00Z",
        resource: {service: "firebaseauth.googleapis.com",
          name: "projects/demo-life-os"}});
      assert.equal(f.db.docs.has(ROOT), false);
      assert.equal(f.db.docs.has(`${ROOT}/health_info/day`), false);
      assert.equal(f.db.docs.has(PATH), false);
      assert.equal(f.db.docs.get(GUARD).state, "COMPLETE");
      // The removed record cannot resurrect after Auth deletion.
      f.live = null; await unchangedFailure(f, "WATER_BIRTH_AUTH_NOT_FOUND");
    });

test("concurrent divergent events cannot overwrite the com" +
    "mitted winner", async () => {
  const f = fixture(); const hold = pause(); let commits = 0;
  f.db.hooks.beforeCommit = async () => {
    if (++commits === 1) await hold.hold();
  };
  const pending = f.record(); await hold.reached;
  const otherBirth = origin(); otherBirth.source.eventId = "synthetic-event-2";
  const other = createAccountBirthTestHarness({...f.options,
    getTrustedBirth: () => copy(otherBirth)});
  const winner = await other.record(); hold.release();
  await assert.rejects(pending, (e) => e.code === "WATER_BIRTH_CONFLICT");
  assert.equal(f.db.docs.get(PATH).decisionId, winner.decisionId);
  assert.equal(f.db.docs.get(PATH).sourceEventId, "synthetic-event-2");
  assert.equal(f.db.writes.length, 1);
});
test("policy opening during transaction retry remains clos" +
    "ed with zero writes", async () => {
  const f = fixture();
  f.db.hooks.beforeCommit = ({attempt}) => {
    if (attempt === 1) {
      f.birth.cohort.state = "OPEN";
      f.db.put(ROOT, {}); f.db.put(ROOT, undefined);
    }
  };
  await unchangedFailure(f, "WATER_BIRTH_COHORT_CLOSED");
});
test("test project restriction is checked after factory cr" +
    "eation and on retry", async () => {
  const first = fixture(); first.db.projectId = "foreign-project";
  await unchangedFailure(first, "WATER_BIRTH_INVALID_CONFIGURATION");
  assert.equal(first.db.attempts, 0);
  const second = fixture(); second.db.hooks.beforeCommit = ({attempt}) => {
    if (attempt === 1) {
      second.db.projectId = "foreign-project";
      second.db.put(ROOT, {}); second.db.put(ROOT, undefined);
    }
  };
  await unchangedFailure(second, "WATER_BIRTH_INVALID_CONFIGURATION");
});
test("closed birth record is not admission authority for t" +
    "he unchanged F-A issuer", async () => {
  const f = fixture(); await f.record(); const r = f.db.docs.get(PATH);
  // Exercise the real ESM helper in an isolated Node process. Keeping the
  // test file CommonJS also preserves the project's ES2018 lint parser.
  const moduleUri = JSON.stringify(pathToFileURL(resolve(__dirname,
      "../../backend/api/health/_issue_water_admission.js")).href);
  const input = {identity: r.originalIdentity, decision: {uid: r.uid,
    decisionId: r.decisionId, policy: r.cohort.policy,
    legacyWritersExcluded: false, initialHealthDay: "2026-10-13"}};
  const code = [
    "import {createWaterAdmissionIssuerTestHarness " +
      "as create} from " + moduleUri + ";",
    "const input=JSON.parse(process.argv[1]);let io=0;",
    "const db={collection(){io++;throw Error('unexpected IO');},",
    "runTransaction(){io++;throw Error('unexpected IO');}};",
    "const api=create({db,getTrustedAdmission:()=>input});",
    "try{await api.issue();throw Error('unexpected admission');}",
    "catch(e){console.log(JSON.stringify({code:e.code,io}));}",
  ].join("\n");
  const before = [...f.db.docs];
  const child = spawnSync(process.execPath,
      ["--input-type=module", "--eval", code, JSON.stringify(input)],
      {encoding: "utf8", shell: false});
  assert.equal(child.status, 0, child.stderr);
  assert.deepEqual(JSON.parse(child.stdout),
      {code: "WATER_ADMISSION_UNAUTHORIZED", io: 0});
  assert.deepEqual([...f.db.docs], before);
  assert.equal(f.db.writes.length, 1);
  assert.equal(f.db.docs.has(ROOT), false);
});
test("cutover compares exact nanos and never admits a birt" +
    "h from before policy", async () => {
  const f = fixture();
  f.birth.cohort.cutoverAt = new Timestamp(BORN.seconds, BORN.nanoseconds + 1);
  await unchangedFailure(f, "WATER_BIRTH_BEFORE_CUTOVER");
});
