"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {readFileSync} = require("node:fs");
const {resolve} = require("node:path");
const {Timestamp} = require("firebase-admin/firestore");
const {UserRecord} = require("firebase-admin/auth");
const {userRecordConstructor, UserBuilder} =
  require("firebase-functions/v1/auth");
const {recordManagedAuthBirth, createAuthBirthAdapterTestHarness,
  authBirthError} = require("../water_auth_birth_adapter");
const {createAuthGenerationReader} = require("../water_auth_generation");
// Constructor input captured by the fixture, never a private SDK field.
const liveWire = new WeakMap();

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
 * @param {Object} overrides Synthetic wire attributes.
 * @return {Object} Real installed Functions SDK event constructor result.
 */
function eventUser(overrides = {}) {
  return userRecordConstructor({uid: UID,
    metadata: {createdAt: "2026-10-13T10:00:00Z"},
    email: " synthetic@example.invalid ", displayName: " Synthetic\nOwner ",
    photoURL: " avatar_neural ", providerData: [{providerId: "password",
      uid: "synthetic@example.invalid"}], ...overrides});
}

/**
 * @param {Object} overrides Admin SDK wire attributes.
 * @return {UserRecord} Real installed Admin SDK constructor result.
 */
function liveUser(overrides = {}) {
  const wire = {localId: UID, createdAt: String(BORN.toMillis()),
    providerUserInfo: [{providerId: "password", rawId: "synthetic-owner"}],
    ...overrides};
  const user = new UserRecord(wire);
  liveWire.set(user, wire);
  return user;
}

/**
 * @return {Object} Synthetic SDK handler context, no invented context.uid.
 */
function eventContext() {
  return {eventId: "synthetic-event-1",
    eventType: "google.firebase.auth.user.create",
    resource: {service: "firebaseauth.googleapis.com",
      name: "projects/demo-life-os"},
    timestamp: "2026-10-13T10:00:00.123456789Z", params: {}};
}

/**
 * @return {Object} Synthetic fixture with explicit trusted-code dependencies.
 */
function fixture() {
  const f = {db: new FakeFirestore(), event: {user: eventUser(),
    context: eventContext()}, live: liveUser(), clock: CLOCK, lookups: []};
  f.auth = {app: {options: {projectId: "demo-life-os"}},
    getUser: async (uid) => {
      f.lookups.push(uid);
      if (f.lookupHook) await f.lookupHook();
      if (f.authError) throw f.authError;
      return f.live;
    }};
  f.options = {db: f.db, auth: f.auth, getManagedEvent: () => f.event,
    authGenerationReader: createAuthGenerationReader({auth: f.auth,
      projectId: "demo-life-os", emulatorHost: "127.0.0.1:9099",
      fetchImpl: async (url, request) => {
        assert.equal(url, "http://127.0.0.1:9099/identitytoolkit.googleapis.com/" +
          "v1/projects/demo-life-os/accounts:lookup");
        assert.deepEqual(JSON.parse(request.body), {localId: [UID]});
        if (f.rawLookupHook) await f.rawLookupHook();
        if (f.rawError) throw f.rawError;
        return Response.json(f.rawBody || {users: [liveWire.get(f.live)]});
      }}),
    cohort: {version: 1, id: "closed-test-v1", policy: "NEW_ACCOUNT_V2_ONLY",
      state: "CLOSED", cutoverAt: CUTOVER}, now: () => f.clock};
  f.api = createAuthBirthAdapterTestHarness(f.options);
  f.record = () => f.api.record();
  return f;
}

/**
 * @param {Object} f Fixture.
 * @param {string} code Sanitized refusal.
 * @param {Function} call Action.
 * @return {Promise<void>} Refusal with no writes or identity leakage.
 */
async function unchangedFailure(f, code, call = f.record) {
  const before = [...f.db.docs]; const writes = f.db.writes.length;
  await assert.rejects(call(), (error) => {
    assert.deepEqual(authBirthError(error), {code,
      message: "Não foi possível registrar a origem da conta."});
    assert.equal(error.message,
        "Não foi possível registrar a origem da conta.");
    return true;
  });
  assert.deepEqual([...f.db.docs], before);
  assert.equal(f.db.writes.length, writes);
}

test("real SDK constructors adapt to unchanged B2-A and CLOSED identity",
    async () => {
      const f = fixture(); const result = await f.record();
      const record = f.db.docs.get(PATH);
      assert.equal(result.eligible, false);
      assert.equal(record.status, "RECORDED_COHORT_CLOSED");
      assert.equal(record.cohort.state, "CLOSED");
      assert.equal(record.authCreatedAt.nanoseconds, 0);
      assert.equal(record.eventAt.nanoseconds, 123456789);
      assert.deepEqual(record.originalIdentity, {uid: UID,
        email: "synthetic@example.invalid", displayName: "SyntheticOwner",
        photoUrl: "avatar_neural"});
      assert.deepEqual(f.lookups, [UID]);
      assert.deepEqual([...f.db.docs.keys()], [PATH]);
      assert.equal(f.db.writes[0].type, "create");
      assert.equal(f.db.writes[0].data.recordedAt.constructor.name,
          "ServerTimestampTransform");
      for (const key of ["eligible", "epoch", "balance", "runId",
        "legacyWritersExcluded", "passwordHash", "customClaims"]) {
        assert.equal(Object.hasOwn(record, key), false);
      }
    });

test("installed v1 SDK normalizes legacy wire context before adapter",
    async () => {
      const f = fixture();
      // Test-local SDK object only, never an exported/registered deployment.
      const sdkFunction = new UserBuilder(() => "projects/demo-life-os", {})
          .onCreate((user, context) => {
            f.event = {user, context}; return f.record();
          });
      const result = await sdkFunction({uid: UID,
        providerData: [{providerId: "google.com", uid: "synthetic-google"}],
        metadata: {createdAt: "2026-10-13T10:00:00Z"}},
      {eventId: "sdk-wire-1", timestamp: "2026-10-13T10:00:01Z",
        eventType: "providers/firebase.auth/eventTypes/user.create",
        resource: "projects/demo-life-os"});
      assert.equal(result.eligible, false);
      assert.equal(f.event.context.eventType,
          "google.firebase.auth.user.create");
      assert.equal(f.db.docs.get(PATH).sourceEventId, "sdk-wire-1");
    });

test("duplicate via fresh adapter returns durable original decision",
    async () => {
      const f = fixture(); const first = await f.record();
      const before = [...f.db.docs];
      const replay =
        await createAuthBirthAdapterTestHarness(f.options).record();
      assert.deepEqual(replay, {...first, alreadyRecorded: true});
      assert.deepEqual([...f.db.docs], before);
      assert.equal(f.db.writes.length, 1);
    });

test("same UID with a different eventId cannot create another birth",
    async () => {
      const f = fixture(); await f.record();
      f.event.context.eventId = "different-event";
      await unchangedFailure(f, "WATER_BIRTH_CONFLICT");
    });

const invalidEvents = [
  ["foreign project", (f) =>
    f.event.context.resource.name = "projects/foreign"],
  ["foreign service", (f) => f.event.context.resource.service = "other"],
  ["resource UID invented", (f) =>
    f.event.context.resource.name += `/users/${UID}`],
  ["foreign tenant", (f) => f.event.user.tenantId = "tenant-1"],
  ["invented context tenant", (f) => f.event.context.tenantId = "tenant-1"],
  ["delete event", (f) =>
    f.event.context.eventType = "google.firebase.auth.user.delete"],
  ["unconverted legacy wire type", (f) => f.event.context.eventType =
    "providers/firebase.auth/eventTypes/user.create"],
  ["v2 event", (f) =>
    f.event.context.eventType = "google.firebase.auth.user.v2.created"],
  ["missing timestamp", (f) => delete f.event.context.timestamp],
  ["impossible date", (f) =>
    f.event.context.timestamp = "2026-02-30T10:00:00Z"],
  ["leap second", (f) => f.event.context.timestamp = "2026-10-13T10:00:60Z"],
  ["non RFC3339", (f) => f.event.context.timestamp = "13 Oct 2026"],
  ["unknown offset", (f) =>
    f.event.context.timestamp = "2026-10-13T10:00:00-00:00"],
  ["future event", (f) => f.event.context.timestamp = "2026-10-14T10:00:00Z"],
  ["event before creation", (f) =>
    f.event.context.timestamp = "2026-10-13T09:59:59Z"],
  ["missing eventId", (f) => delete f.event.context.eventId],
  ["blank eventId", (f) => f.event.context.eventId = " "],
  ["oversized eventId", (f) => f.event.context.eventId = "x".repeat(513)],
  ["control eventId", (f) => f.event.context.eventId = "x\ny"],
  ["context UID differs", (f) => f.event.context.uid = "other"],
  ["params UID differs", (f) => f.event.context.params = {uid: "other"}],
  ["context auth is not Auth event authority", (f) => f.event.context.auth =
    {uid: UID, token: {auth_time: 1}}],
  ["metadata absent", (f) => delete f.event.user.metadata],
  ["metadata plain client JSON", (f) => f.event.user.metadata =
    {creationTime: "2026-10-13T10:00:00Z"}],
  ["metadata invalid", (f) => f.event.user.metadata.creationTime = "invalid"],
  ["creation absent but first sign-in present", (f) => {
    f.event.user.metadata.creationTime = null;
    f.event.user.metadata.lastSignInTime = "2026-10-13T10:00:00Z";
  }],
  ["UID slash", (f) => f.event.user.uid = "a/b"],
  ["UID trimmed", (f) => f.event.user.uid = " synthetic-owner "],
  ["UID reserved", (f) => f.event.user.uid = "__reserved__"],
  ["UID utf8 oversized", (f) => f.event.user.uid = "é".repeat(65)],
];
for (const [label, mutate] of invalidEvents) {
  test(`closed refusal before writes: ${label}`, async () => {
    const f = fixture(); mutate(f);
    await unchangedFailure(f, "WATER_BIRTH_INVALID_ORIGIN");
  });
}

for (const [label, live, code] of [
  ["Admin UID differs", () => liveUser({localId: "other"}),
    "WATER_BIRTH_GENERATION_CONFLICT"],
  ["generation differs", () =>
    liveUser({createdAt: String(BORN.toMillis() + 1000)}),
  "WATER_BIRTH_GENERATION_CONFLICT"],
  ["Admin creation metadata missing", () => liveUser({createdAt: undefined}),
    "WATER_BIRTH_INVALID_ORIGIN"],
  ["Admin tenant differs", () => liveUser({tenantId: "tenant-1"}),
    "WATER_BIRTH_INVALID_ORIGIN"],
  ["plain JSON is not Admin SDK lookup result", () => ({uid: UID,
    metadata: {creationTime: BORN.toDate().toUTCString()}}),
  "WATER_BIRTH_GENERATION_CONFLICT"],
]) {
  test(label, async () => {
    const f = fixture(); f.live = live(); await unchangedFailure(f, code);
  });
}

for (const code of ["auth/user-not-found", "auth/internal-error"]) {
  test(`Admin ${code} fails closed without leaking details`, async () => {
    const f = fixture(); f.authError = Object.assign(
        new Error("synthetic secret network detail"), {code});
    await unchangedFailure(f, code === "auth/user-not-found" ?
      "WATER_BIRTH_AUTH_NOT_FOUND" : "WATER_BIRTH_AUTH_UNAVAILABLE");
  });
}

test("delayed delivery preserves original creation and event timestamps",
    async () => {
      const f = fixture(); f.clock = Timestamp.fromMillis(CLOCK.toMillis() +
        30 * 86400000); f.db.commitClock = f.clock;
      assert.equal((await f.record()).eligible, false);
      assert.ok(f.db.docs.get(PATH).authCreatedAt.isEqual(BORN));
      assert.ok(f.db.docs.get(PATH).recordedAt.isEqual(f.clock));
    });

test("pre-cutover event cannot use recent delivery or first sign-in instead",
    async () => {
      const f = fixture(); f.event.user = eventUser({metadata: {
        createdAt: "2026-09-30T23:59:59Z", lastSignedInAt:
          "2026-10-13T10:00:00Z"}});
      f.live = liveUser({createdAt: String(CUTOVER.toMillis() - 1000)});
      await unchangedFailure(f, "WATER_BIRTH_BEFORE_CUTOVER");
    });

test("fractional event matches exact REST milliseconds despite SDK UTC display",
    async () => {
      const f = fixture(); f.event.user = eventUser({metadata: {
        createdAt: "2026-10-13T10:00:00.123Z"}});
      f.live = liveUser({createdAt: String(BORN.toMillis() + 123)});
      assert.equal(f.live.metadata.creationTime,
          "Tue, 13 Oct 2026 10:00:00 GMT");
      assert.equal((await f.record()).eligible, false);
      assert.equal(f.db.docs.get(PATH).authCreatedAt.nanoseconds, 123000000);
    });

test("REST rejects a distinct subsecond generation hidden by SDK UTC display",
    async () => {
      const f = fixture();
      const otherGeneration =
        liveUser({createdAt: String(BORN.toMillis() + 900)});
      assert.equal(otherGeneration.metadata.creationTime,
          f.live.metadata.creationTime);
      f.live = otherGeneration;
      await unchangedFailure(f, "WATER_BIRTH_GENERATION_CONFLICT");
    });

test("RFC3339 offset represents the same managed instant", async () => {
  const f = fixture(); f.event.context.timestamp = "2026-10-13T07:00:01-03:00";
  await f.record(); assert.equal(f.db.docs.get(PATH).eventAt.toMillis(),
      BORN.toMillis() + 1000);
});

for (const provider of ["password", "google.com"]) {
  test(`${provider} is a CLOSED candidate, never eligible`, async () => {
    const f = fixture(); f.event.user.providerData = [{providerId: provider}];
    assert.equal((await f.record()).eligible, false);
  });
}
for (const [label, providers] of [["anonymous", []], ["Admin no provider", []],
  ["custom token", [{providerId: "custom"}]],
  ["phone", [{providerId: "phone"}]],
  ["mixed linked providers", [{providerId: "password"},
    {providerId: "google.com"}]],
  ["unknown", [{providerId: "unknown"}]]]) {
  test(`${label} is refused by candidate provider policy`, async () => {
    const f = fixture(); f.event.user.providerData = providers;
    await unchangedFailure(f, "WATER_BIRTH_UNSUPPORTED_PROVIDER");
  });
}
test("Admin-created provider account cannot be distinguished or made eligible",
    async () => {
      const f = fixture();
      // v1 provides no trustworthy creation-method field for this case.
      f.event.user.customClaims = {eligible: true, legacyWritersExcluded: true};
      f.event.user.isNewUser = true; f.event.user.appVersion = "future";
      assert.equal((await f.record()).eligible, false);
      assert.equal(Object.hasOwn(f.db.docs.get(PATH), "customClaims"), false);
    });

for (const state of ["IN_PROGRESS", "COMPLETE"]) {
  test(`existing ${state} guard denies expired/deleted accounts`, async () => {
    const f = fixture(); f.db.put(GUARD, {state, retainUntil: CUTOVER});
    await unchangedFailure(f, "WATER_ACCOUNT_DELETING");
  });
  test(`concurrent ${state} guard forces retry and refusal`, async () => {
    const f = fixture(); const hold = pause();
    f.db.hooks.beforeCommit = async ({attempt}) => {
      if (attempt === 1) await hold.hold();
    };
    const pending = assert.rejects(f.record(),
        {code: "WATER_ACCOUNT_DELETING"});
    await hold.reached; f.db.put(GUARD, {state}); hold.release(); await pending;
    assert.equal(f.db.conflicts, 1); assert.equal(f.db.writes.length, 0);
    assert.equal(f.db.docs.has(PATH), false);
  });
}

for (const path of [ROOT, `${ROOT}/runtime/account_deletion`,
  `${ROOT}/water_protocol/eligibility`, `${ROOT}/runtime/water_admission`]) {
  test(`legacy/admission/deletion record ${path} is preserved`, async () => {
    const f = fixture(); f.db.put(path, {synthetic: "preserved"});
    await unchangedFailure(f, path.endsWith("account_deletion") ?
      "WATER_ACCOUNT_DELETING" : "WATER_BIRTH_CONFLICT");
  });
}

test("lost response after commit replays original birth without new writes",
    async () => {
      const f = fixture(); f.db.hooks.afterCommit = () => {
        throw new Error("lost response detail");
      };
      await assert.rejects(f.record(), {code: "WATER_BIRTH_STORAGE_UNAVAILABLE",
        message: "Não foi possível registrar a origem da conta."});
      const before = [...f.db.docs]; f.db.hooks = {};
      const replay = await f.record();
      assert.equal(replay.alreadyRecorded, true);
      assert.equal(replay.eligible, false);
      assert.equal(replay.decisionId, f.db.docs.get(PATH).decisionId);
      assert.deepEqual([...f.db.docs], before);
      assert.equal(f.db.writes.length, 1);
    });

for (const different of [false, true]) {
  test(`concurrent ${different ? "different" : "same"} events have one winner`,
      async () => {
        const f = fixture(); const hold = pause(); let commits = 0;
        f.db.hooks.beforeCommit = async () => {
          if (++commits === 1) await hold.hold();
        };
        const pending = f.record();
        const observed = different ? assert.rejects(pending,
            {code: "WATER_BIRTH_CONFLICT"}) : pending;
        await hold.reached;
        const otherOptions = {...f.options, getManagedEvent: () => ({
          user: eventUser(), context: {...eventContext(), eventId: different ?
            "synthetic-event-2" : "synthetic-event-1"}})};
        const winner =
          await createAuthBirthAdapterTestHarness(otherOptions).record();
        hold.release(); const replay = await observed;
        if (!different) {
          assert.equal(replay.decisionId, winner.decisionId);
          assert.equal(replay.alreadyRecorded, true);
        }
        assert.equal(f.db.writes.length, 1); assert.equal(f.db.conflicts, 1);
      });
}

test("retry queries generation again and refuses a changed UID generation",
    async () => {
      const f = fixture(); const hold = pause();
      f.db.hooks.beforeCommit = async ({attempt}) => {
        if (attempt === 1) await hold.hold();
      };
      const pending = assert.rejects(f.record(),
          {code: "WATER_BIRTH_GENERATION_CONFLICT"});
      await hold.reached;
      f.live = liveUser({createdAt: String(BORN.toMillis() + 1000)});
      f.db.put(ROOT, {}); f.db.put(ROOT, undefined);
      hold.release(); await pending;
      assert.deepEqual(f.lookups, [UID, UID]);
      assert.equal(f.db.writes.length, 0);
    });

test("generation changing during pending Admin lookup is refused", async () => {
  const f = fixture(); const hold = pause(); f.lookupHook = hold.hold;
  const pending = assert.rejects(f.record(),
      {code: "WATER_BIRTH_GENERATION_CONFLICT"});
  await hold.reached;
  f.live = liveUser({createdAt: String(BORN.toMillis() + 1000)});
  hold.release(); await pending; assert.equal(f.db.writes.length, 0);
});

test("Auth mutation after lookup is outside Firestore transaction read set",
    async () => {
      const f = fixture(); f.db.hooks.beforeCommit = () => {
        f.live = liveUser({createdAt: String(BORN.toMillis() + 1000)});
      };
      assert.equal((await f.record()).eligible, false);
      // Honest characterization: SDK lookup + Firestore are not atomic.
      assert.equal(f.db.writes.length, 1);
    });

test("deleted account delayed event cannot resurrect a decision", async () => {
  const f = fixture(); await f.record(); f.db.put(PATH, undefined);
  f.authError = {code: "auth/user-not-found"};
  await unchangedFailure(f, "WATER_BIRTH_AUTH_NOT_FOUND");
});

test("other UID and profile descendants remain intact", async () => {
  const f = fixture();
  f.db.put("users/other", {displayName: "Synthetic other"});
  f.db.put("account_birth_decisions/other", {decisionId: "preserved"});
  f.db.put(`${ROOT}/health/day`, {waterIntakeMl: 250});
  const before = [...f.db.docs]; await f.record();
  for (const [path, value] of before) {
    assert.deepEqual(f.db.docs.get(path), value);
  }
  assert.deepEqual(f.db.writes.map((w) => w.ref.path), [PATH]);
});

for (const mutation of [
  (o) => o.enabled = true,
  (o) => o.eligible = true,
  (o) => o.getManagedEvent = {user: eventUser(), context: eventContext()},
  (o) => o.cohort = {...o.cohort, state: "OPEN"},
  (o) => o.cohort = {...o.cohort, eligible: true},
  (o) => o.auth = {...o.auth, app: {options: {projectId: "real-project"}}},
  (o) => o.auth = {...o.auth, tenantId: "tenant-1"},
]) {
  test(`factory activation attempt ${mutation.toString()} is rejected`, () => {
    const f = fixture(); const options = {...f.options}; mutation(options);
    assert.throws(() => createAuthBirthAdapterTestHarness(options),
        {code: "WATER_BIRTH_INVALID_CONFIGURATION"});
    assert.equal(f.db.writes.length, 0); assert.deepEqual(f.lookups, []);
  });
}

test("closed entry and test record reject flags/JSON without IO", async () => {
  const f = fixture(); const old = process.env.WATER_V2_ENABLED;
  const oldProject = process.env.GCLOUD_PROJECT;
  try {
    process.env.WATER_V2_ENABLED = "true";
    process.env.GCLOUD_PROJECT = "real-project";
    const poisoned = new Proxy({}, {get: () => {
      throw new Error("IO");
    }});
    await unchangedFailure(f, "WATER_BIRTH_COHORT_CLOSED", () =>
      recordManagedAuthBirth(poisoned, {enabled: true, eligible: true}));
    await unchangedFailure(f, "WATER_BIRTH_INVALID_ORIGIN", () =>
      f.api.record({user: eventUser(), context: eventContext(),
        eligible: true}));
    assert.equal((await f.record()).eligible, false);
  } finally {
    if (old === undefined) delete process.env.WATER_V2_ENABLED;
    else process.env.WATER_V2_ENABLED = old;
    if (oldProject === undefined) delete process.env.GCLOUD_PROJECT;
    else process.env.GCLOUD_PROJECT = oldProject;
  }
});

test("Auth binding is rechecked after factory and after a pending lookup",
    async () => {
      const f = fixture(); f.auth.app.options.projectId = "foreign";
      await unchangedFailure(f, "WATER_BIRTH_INVALID_CONFIGURATION");
      assert.deepEqual(f.lookups, []);
      f.auth.app.options.projectId = "demo-life-os";
      f.lookupHook = () => f.auth.app.options.projectId = "foreign";
      await unchangedFailure(f, "WATER_BIRTH_INVALID_CONFIGURATION");
    });

test("event mutation during transaction cannot rebind original identity",
    async () => {
      const f = fixture(); let calls = 0;
      const options = {...f.options, getManagedEvent: () => {
        if (++calls > 1) f.event.user.uid = "other";
        return f.event;
      }};
      await unchangedFailure(f, "WATER_BIRTH_CONFLICT", () =>
        createAuthBirthAdapterTestHarness(options).record());
      assert.deepEqual(f.lookups, []);
    });

test("SDK fixture and adapter remain outside active dispatcher", () => {
  const index = readFileSync(resolve(__dirname, "../index.js"), "utf8");
  assert.equal(index.includes("water_auth_birth_adapter"), false);
  assert.equal(index.includes("water_account_birth"), false);
  const adapter = readFileSync(resolve(__dirname,
      "../water_auth_birth_adapter.js"), "utf8");
  assert.equal(adapter.includes("initializeApp("), false);
  assert.equal(adapter.includes(".onCreate("), false);
});

test("optional SDK resource metadata never supplies authority", async () => {
  const f = fixture(); f.event.context.resource.type = "synthetic-type";
  f.event.context.resource.labels = {uid: "other", eligible: "true"};
  assert.equal((await f.record()).eligible, false);
  assert.deepEqual(f.lookups, [UID]);
  assert.equal(f.db.docs.has("account_birth_decisions/other"), false);
});

test("cohort mutation after factory cannot open or rebind its snapshot",
    async () => {
      const f = fixture(); f.options.cohort.state = "OPEN";
      f.options.cohort.id = "other-cohort";
      assert.equal((await f.record()).eligible, false);
      assert.equal(f.db.docs.get(PATH).cohort.state, "CLOSED");
      assert.equal(f.db.docs.get(PATH).cohort.id, "closed-test-v1");
    });

test("cutover within the coarse creation second is refused conservatively",
    async () => {
      const f = fixture(); const options = {...f.options,
        cohort: {...f.options.cohort,
          cutoverAt: new Timestamp(BORN.seconds, 1)}};
      await unchangedFailure(f, "WATER_BIRTH_BEFORE_CUTOVER", () =>
        createAuthBirthAdapterTestHarness(options).record());
    });

test("Firestore project mutation cannot send a managed event to production",
    async () => {
      const f = fixture(); f.db.projectId = "real-project";
      await unchangedFailure(f, "WATER_BIRTH_INVALID_CONFIGURATION");
      assert.deepEqual(f.lookups, []);
    });

test("SDK missing optional profile fields use the original B2-A defaults",
    async () => {
      const f = fixture(); f.event.user = eventUser({email: undefined,
        displayName: undefined, photoURL: undefined});
      await f.record(); assert.deepEqual(f.db.docs.get(PATH).originalIdentity,
          {uid: UID, email: "", displayName: "Novo Usuário", photoUrl: null});
    });

test("trusted producer failure is sanitized without creating a partial record",
    async () => {
      const f = fixture(); const options = {...f.options,
        getManagedEvent: () => {
          throw new Error("synthetic internal detail");
        }};
      await unchangedFailure(f, "WATER_BIRTH_STORAGE_UNAVAILABLE", () =>
        createAuthBirthAdapterTestHarness(options).record());
    });

test("removed decision cannot resurrect under a COMPLETE deletion guard",
    async () => {
      const f = fixture(); await f.record(); f.db.put(PATH, undefined);
      f.db.put(GUARD, {state: "COMPLETE", retainUntil: CUTOVER});
      // Even a live UID with coarse indistinguishable metadata is denied.
      await unchangedFailure(f, "WATER_ACCOUNT_DELETING");
    });

test("untrusted forged public error code is not accepted as a domain error",
    () => {
      assert.deepEqual(authBirthError({code: "WATER_BIRTH_COHORT_CLOSED",
        message: "synthetic internal detail"}), {
        code: "WATER_BIRTH_STORAGE_UNAVAILABLE",
        message: "Não foi possível registrar a origem da conta."});
    });

test("production trigger preserves v1/retry/identity and CLOSED no IO",
    async () => {
      const prior=process.env.GCLOUD_PROJECT;
      process.env.GCLOUD_PROJECT="demo-life-os";
      try {
        const trigger=require("../water_birth_runtime").trigger;
        assert.equal(trigger.__endpoint.platform, "gcfv1");
        assert.equal(trigger.__endpoint.eventTrigger.retry, true);
        assert.equal(trigger.__endpoint.eventTrigger.eventType,
            "providers/firebase.auth/eventTypes/user.create");
        assert.equal(trigger.__endpoint.serviceAccountEmail,
            "life-os-cleanup-runtime@life-os-27b92.iam.gserviceaccount.com");
        assert.equal(require("../package.json").engines.node, "22");
        const admin=require("firebase-admin/app");
        const before=admin.getApps().length;
        // No app exists: any Firestore/Auth lookup would fail this test.
        await trigger.run({}, {});
        assert.equal(admin.getApps().length, before);
        const policy = require("../water_policy.cjs");
        assert.equal(policy.WATER_COHORT.state, "CLOSED");
      } finally {
        if (prior===undefined) delete process.env.GCLOUD_PROJECT;
        else process.env.GCLOUD_PROJECT=prior;
      }
    });
for (const path of ["retired_auth_identities/"+UID, ROOT]) {
  test("managed birth respects retirement/root deletion "+path, async ()=>{
    const f=fixture();
    f.db.put(path, path===ROOT ?
      {_serverAccountDeletion: {state: "DENY"}} : {});
    await unchangedFailure(f, "WATER_ACCOUNT_DELETING");
  });
}

/** @return {Object} Millisecond event and authoritative live generation. */
function preciseFixture() {
  const f = fixture(); const millis = BORN.toMillis() + 946;
  f.event.user = eventUser({metadata: {
    createdAt: new Date(millis).toISOString()}});
  f.event.context.timestamp = new Date(BORN.toMillis() + 1000).toISOString();
  f.live = liveUser({createdAt: String(millis)});
  return f;
}

test("R3 exact millisecond birth and legitimate replay preserve one decision",
    async () => {
      const f = preciseFixture(); const first = await f.record();
      const before = copy(f.db.docs.get(PATH));
      const second =
        await createAuthBirthAdapterTestHarness(f.options).record();
      assert.equal(first.decisionId, second.decisionId);
      assert.equal(second.alreadyRecorded, true);
      assert.equal(f.db.writes.length, 1);
      assert.deepEqual(f.db.docs.get(PATH), before);
      assert.equal(before.authCreatedAt.nanoseconds, 946000000);
      assert.equal(first.eligible, false);
      assert.equal(f.db.docs.has(ROOT), false);
      assert.equal(f.db.docs.has(ROOT + "/water_protocol/eligibility"), false);
    });
for (const delta of [1, 54, 1000, 86400000]) {
  test(`R3 old event rejects generation ${delta}ms later without writes`,
      async () => {
        const f = preciseFixture();
        f.live = liveUser({createdAt: String(BORN.toMillis() + 946 + delta)});
        await unchangedFailure(f, "WATER_BIRTH_GENERATION_CONFLICT");
      });
}
for (const code of ["auth/user-not-found", "auth/internal-error"]) {
  test(`R3 precise event with ${code} cannot write`, async () => {
    const f = preciseFixture(); f.authError = {code};
    await unchangedFailure(f, code === "auth/user-not-found" ?
      "WATER_BIRTH_AUTH_NOT_FOUND" : "WATER_BIRTH_AUTH_UNAVAILABLE");
  });
}
test("R3 REST failure propagates before any write", async () => {
  const f = preciseFixture();
  f.rawError = new DOMException("offline", "TimeoutError");
  await unchangedFailure(f, "WATER_BIRTH_AUTH_UNAVAILABLE");
});
for (const path of [GUARD, "retired_auth_identities/" + UID,
  ROOT + "/runtime/account_deletion", ROOT + "/water_protocol/eligibility",
  ROOT + "/runtime/water_admission", PATH]) {
  test(`R3 precise birth preserves deletion/proof conflict ${path}`,
      async () => {
        const f = preciseFixture();
        f.db.put(path, {status: "synthetic-conflict"});
        await unchangedFailure(f, [GUARD, "retired_auth_identities/" + UID,
          ROOT + "/runtime/account_deletion"].includes(path) ?
          "WATER_ACCOUNT_DELETING" : "WATER_BIRTH_CONFLICT");
      });
}
test("R3 generation changes during raw read in SAME second", async () => {
  const f = preciseFixture(); f.rawLookupHook = async () => {
    f.live = liveUser({createdAt: String(BORN.toMillis() + 947)});
  };
  await unchangedFailure(f, "WATER_BIRTH_GENERATION_CONFLICT");
});
test("R3 retry rechecks precise generation before any write", async () => {
  const f = preciseFixture();
  f.db.hooks.beforeCommit = ({attempt}) => {
    if (attempt === 1) {
      f.db.put(PATH, undefined); // Force real MVCC retry via a read conflict.
      f.live = liveUser({createdAt: String(BORN.toMillis() + 947)});
    }
  };
  await unchangedFailure(f, "WATER_BIRTH_GENERATION_CONFLICT");
  assert.equal(f.db.attempts, 2);
});
test("R3 Auth change AFTER raw lookup remains outside Firestore atomicity",
    async () => {
      const f = preciseFixture(); f.db.hooks.beforeCommit = () => {
        f.live = liveUser({createdAt: String(BORN.toMillis() + 947)});
      };
      const result = await f.record();
      assert.equal(result.eligible, false);
      assert.equal(f.db.docs.get(PATH).authCreatedAt.nanoseconds, 946000000);
      assert.equal(f.db.docs.has(ROOT), false);
      assert.equal(f.db.docs.has(ROOT + "/water_protocol/eligibility"), false);
    });
