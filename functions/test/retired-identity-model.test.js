"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {createSyntheticRetirementModel} = require("../retired_identity_model");

const PROJECT = "demo-life-os";
const DATABASE = "(default)";
const UID = "synthetic-owner";
const ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const START = 2000;
const BORN = 1000;
const PRIVATE = "synthetic-private@example.invalid";
const clone = (v) => structuredClone(v);
const key = (collection, uid = UID, project = PROJECT, database = DATABASE) =>
  `projects/${project}/databases/${database}/documents/${collection}/${uid}`;
const gkey = (uid, project, database) =>
  key("account_deletion_guards", uid, project, database);
const rkey = (uid, project, database) =>
  key("retired_auth_identities", uid, project, database);
const guard = (extra = {}) => ({version: 1, state: "IN_PROGRESS",
  deletionId: ID, startedAt: START, retainUntil: null, ...extra});
const reservation = (extra = {}) => ({version: 1, state: "RESERVED",
  deletionId: ID, authCreatedAtMs: BORN, ...extra});

// MVCC fake: validates all read versions atomically before create-only commit.
// Hooks and barriers are deterministic; no timers, SDK, credentials or network.
function store() {
  const docs = new Map();
  const counters = {reads: 0, writes: 0, attempts: 0};
  let version = 0;
  let clock = 3000;
  const hooks = {};
  const seed = (p, data, createTimeMs = 3000) => {
    docs.set(p, {data: clone(data), createTimeMs, version: ++version});
  };
  const read = (p) => clone(docs.get(p));
  async function runTransaction(callback) {
    for (let attempt = 0; attempt < 8; attempt++) {
      counters.attempts++;
      const reads = new Map();
      const writes = new Map();
      const value = await callback({
        get: async (p) => {
          assert.equal(writes.size, 0, "all reads must precede writes");
          counters.reads++;
          const doc = docs.get(p);
          reads.set(p, doc?.version);
          return doc ? {exists: true, data: clone(doc.data),
            createTimeMs: doc.createTimeMs} : {exists: false};
        },
        create: (p, data) => {
          assert.equal(reads.has(p), true, "create must read its absence first");
          assert.equal(writes.has(p), false);
          writes.set(p, clone(data));
        },
      });
      if (hooks.beforeCommit) {
        const hook = hooks.beforeCommit;
        delete hooks.beforeCommit;
        await hook();
      }
      if ([...reads].some(([p, v]) => docs.get(p)?.version !== v)) continue;
      if (hooks.failBeforeCommit) {
        delete hooks.failBeforeCommit;
        throw new Error(PRIVATE);
      }
      for (const p of writes.keys()) assert.equal(docs.has(p), false);
      for (const [p, data] of writes) {
        seed(p, data, ++clock);
        counters.writes++;
      }
      if (hooks.failAfterCommit) {
        delete hooks.failAfterCommit;
        throw new Error(PRIVATE);
      }
      return value;
    }
    throw new Error(PRIVATE);
  }
  return {docs, counters, hooks, seed, read, runTransaction};
}

function fixture({projectId = PROJECT, databaseId = DATABASE, uid = UID} = {}) {
  const db = store();
  db.seed(gkey(uid, projectId, databaseId), guard(), START);
  const authority = Object.freeze({});
  const calls = {authorize: [], auth: 0};
  let auth = {state: "PRESENT", createdAtMs: BORN};
  const hooks = {};
  const model = createSyntheticRetirementModel({projectId, databaseId, ports: {
    authorize: async (scope, proof) => {
      calls.authorize.push(scope);
      if (hooks.authorize) return hooks.authorize(scope, proof);
      return proof === authority;
    },
    observeAuth: async (scope) => {
      assert.deepEqual(scope, {projectId, databaseId, uid});
      calls.auth++;
      if (hooks.auth) return hooks.auth(calls.auth);
      return clone(auth);
    },
    runTransaction: db.runTransaction,
  }});
  const input = (extra = {}) => ({uid, deletionId: ID, authority, ...extra});
  return {db, calls, hooks, model, input, authority,
    setAuth: (value) => {auth = value;},
    reserve: (extra) => model.reserve(input(extra)),
    inspect: (extra) => model.inspect(input(extra)),
    admission: (extra = {}) => model.checkAdmission({uid, authority, ...extra})};
}
function status(result, expected) {
  assert.deepEqual(result, {status: expected, destructiveAuthority: false});
  assert.equal(Object.isFrozen(result), true);
}

test("first reservation is create-only and committed while Auth is still present", async () => {
  const f = fixture();
  const before = f.db.read(gkey());
  status(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
  const saved = f.db.read(rkey());
  assert.deepEqual(saved.data, reservation());
  assert.ok(saved.createTimeMs >= START);
  assert.equal(f.db.counters.reads, 2);
  assert.equal(f.db.counters.writes, 1);
  assert.deepEqual(f.db.read(gkey()), before);
  status(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
  f.setAuth({state: "ABSENT"}); // synthetic removal only AFTER durable reserve
  status(await f.inspect(), "RESERVED_AUTH_ABSENT_NO_AUTHORITY");
});

test("same operation retries without changing the record or its create time", async () => {
  const f = fixture();
  await f.reserve(); const saved = f.db.read(rkey());
  status(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
  assert.deepEqual(f.db.read(rkey()), saved);
  assert.equal(f.db.counters.writes, 1);
  assert.equal(f.db.counters.reads, 4);
});

test("different deletionId cannot acquire the guard", async () => {
  const f = fixture(); await f.reserve();
  status(await f.reserve({deletionId: OTHER_ID}), "OPERATION_CONFLICT");
  assert.equal(f.db.counters.writes, 1);
});

test("different reservation operation refuses even if guard was replaced", async () => {
  const f = fixture(); await f.reserve();
  f.db.seed(gkey(), guard({deletionId: OTHER_ID}));
  status(await f.reserve({deletionId: OTHER_ID}), "RESERVATION_CONFLICT");
  assert.equal(f.db.counters.writes, 1);
  status(await f.admission(), "UID_RESERVED");
});

for (const [name, replacement, expected] of [
  ["COMPLETE", guard({state: "COMPLETE", retainUntil: 9000}), "GUARD_COMPLETE"],
  ["another deletionId", guard({deletionId: OTHER_ID}), "OPERATION_CONFLICT"],
  ["malformed", guard({version: 99}), "GUARD_INVALID"],
]) {
  test(`transaction retries and revalidates guard changed to ${name}`, async () => {
    const f = fixture();
    f.db.hooks.beforeCommit = () => f.db.seed(gkey(), replacement);
    status(await f.reserve(), expected);
    assert.equal(f.db.counters.attempts, 2);
    assert.equal(f.db.counters.writes, 0);
    assert.equal(f.db.read(rkey()), undefined);
    assert.deepEqual(f.db.read(gkey()).data, replacement);
  });
}

test("same guard rewritten by peer causes safe retry and one reservation", async () => {
  const f = fixture();
  f.db.hooks.beforeCommit = () => f.db.seed(gkey(), guard());
  status(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
  assert.equal(f.db.counters.attempts, 2);
  assert.equal(f.db.counters.writes, 1);
});

test("failure before commit is unknown; reread shows no reservation; retry recovers", async () => {
  const f = fixture(); f.db.hooks.failBeforeCommit = true;
  status(await f.reserve(), "UNKNOWN_REQUIRES_REREAD");
  assert.equal(f.db.read(rkey()), undefined);
  status(await f.inspect(), "LEGACY_OR_NEW_UNPROVEN");
  status(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
  assert.equal(f.db.counters.writes, 1);
});

test("lost response after commit is unknown and resolved by reread, never duplicate", async () => {
  const f = fixture(); f.db.hooks.failAfterCommit = true;
  status(await f.reserve(), "UNKNOWN_REQUIRES_REREAD");
  const committed = f.db.read(rkey());
  assert.deepEqual(committed.data, reservation());
  status(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
  status(await f.reserve(), "RESERVATION_ACKNOWLEDGED");
  assert.deepEqual(f.db.read(rkey()), committed);
  assert.equal(f.db.counters.writes, 1);
});

test("lost ACK followed by Auth absence still proves no completed deletion", async () => {
  const f = fixture(); f.db.hooks.failAfterCommit = true;
  status(await f.reserve(), "UNKNOWN_REQUIRES_REREAD");
  const committed = f.db.read(rkey());
  f.setAuth({state: "ABSENT"});
  status(await f.inspect(), "RESERVED_AUTH_ABSENT_NO_AUTHORITY");
  status(await f.reserve(), "AUTH_ABSENT_CANNOT_FIRST_RESERVE");
  assert.deepEqual(f.db.read(rkey()), committed);
  assert.equal(f.db.counters.writes, 1);
});

test("two concurrent executors of same operation converge on one create", async () => {
  const f = fixture();
  const values = await Promise.all([f.reserve(), f.reserve()]);
  values.forEach((v) => status(v, "RESERVATION_ACKNOWLEDGED"));
  assert.equal(f.db.counters.writes, 1);
  assert.ok(f.db.counters.attempts >= 3);
});

test("two concurrent incompatible operations give authority only to guard owner", async () => {
  const f = fixture();
  const values = await Promise.all([f.reserve(), f.reserve({deletionId: OTHER_ID})]);
  status(values[0], "RESERVATION_ACKNOWLEDGED");
  status(values[1], "OPERATION_CONFLICT");
  assert.equal(f.db.counters.writes, 1);
});

test("old executor never reopens COMPLETE even with an existing reservation", async () => {
  const f = fixture(); await f.reserve();
  f.db.seed(gkey(), guard({state: "COMPLETE", retainUntil: 9000}));
  const completed = f.db.read(gkey());
  status(await f.reserve(), "GUARD_COMPLETE");
  f.setAuth({state: "ABSENT"});
  status(await f.inspect(), "TERMINAL_PROOF_REQUIRED");
  assert.deepEqual(f.db.read(gkey()), completed);
  assert.equal(f.db.counters.writes, 1);
});

test("COMPLETE racing an inspection is revalidated without terminal confirmation", async () => {
  const f = fixture(); await f.reserve(); f.setAuth({state: "ABSENT"});
  f.db.hooks.beforeCommit = () => f.db.seed(gkey(),
      guard({state: "COMPLETE", retainUntil: 9000}));
  status(await f.inspect(), "TERMINAL_PROOF_REQUIRED");
  assert.equal(f.db.counters.writes, 1);
  assert.equal(f.db.read(gkey()).data.state, "COMPLETE");
});

test("recreated UID cannot use old reservation or acquire recovery", async () => {
  const f = fixture(); await f.reserve();
  f.setAuth({state: "PRESENT", createdAtMs: 4000});
  status(await f.reserve(), "IDENTITY_CHANGED");
  status(await f.inspect(), "IDENTITY_CHANGED");
  status(await f.admission(), "UID_RESERVED");
  assert.equal(f.db.counters.writes, 1);
});

test("Auth reappearing between observations blocks recovery", async () => {
  const f = fixture(); await f.reserve();
  const start = f.calls.auth;
  f.hooks.auth = (count) => count === start + 1 ? {state: "ABSENT"} :
    {state: "PRESENT", createdAtMs: BORN};
  status(await f.inspect(), "IDENTITY_CHANGED");
});

test("same creation metadata cannot prove generation and never grants deletion", async () => {
  const f = fixture(); await f.reserve();
  // Characterization: an external recreation with indistinguishable metadata
  // cannot be identified by this model. Presence still blocks recovery.
  f.setAuth({state: "PRESENT", createdAtMs: BORN});
  status(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
  f.setAuth({state: "ABSENT"});
  status(await f.inspect(), "RESERVED_AUTH_ABSENT_NO_AUTHORITY");
  assert.equal(f.db.counters.writes, 1);
});

for (const observation of [{state: "AMBIGUOUS"}, {state: "PRESENT"},
  {state: "PRESENT", createdAtMs: NaN}, {state: "ABSENT", email: PRIVATE}]) {
  test(`ambiguous Auth is refused: ${Object.keys(observation).join(",")}`, async () => {
    const f = fixture(); f.setAuth(observation);
    status(await f.reserve(), "IDENTITY_AMBIGUOUS");
    status(await f.inspect(), "IDENTITY_AMBIGUOUS");
    assert.equal(f.db.counters.writes, 0);
  });
}

test("legacy missing reservation is neither recovery nor admission authority", async () => {
  const f = fixture(); f.setAuth({state: "ABSENT"});
  status(await f.inspect(), "LEGACY_OR_NEW_UNPROVEN");
  status(await f.admission(), "LEGACY_OR_NEW_UNPROVEN");
  status(await f.reserve(), "AUTH_ABSENT_CANNOT_FIRST_RESERVE");
  assert.equal(f.db.counters.writes, 0);
});

for (const extra of [{version: 2}, {state: "COMPLETE"}, {deletionId: "bad"},
  {authCreatedAtMs: null}, {email: PRIVATE}]) {
  test(`malformed reservation fails closed: ${Object.keys(extra).join(",")}`, async () => {
    const f = fixture(); f.db.seed(rkey(), reservation(extra));
    const before = f.db.read(rkey());
    status(await f.reserve(), "RECORD_INVALID");
    status(await f.inspect(), "RECORD_INVALID");
    status(await f.admission(), "RECORD_INVALID");
    assert.deepEqual(f.db.read(rkey()), before);
    assert.equal(f.db.counters.writes, 0);
  });
}

test("reservation predating guard or with invalid commit evidence is rejected", async () => {
  for (const stamp of [START - 1, null, NaN]) {
    const f = fixture(); f.db.seed(rkey(), reservation(), stamp);
    status(await f.reserve(), "RECORD_INVALID");
    status(await f.inspect(), "RECORD_INVALID");
    assert.equal(f.db.counters.writes, 0);
  }
});

test("missing guard cannot be created by this model", async () => {
  const f = fixture(); f.db.docs.delete(gkey());
  status(await f.reserve(), "GUARD_INVALID");
  assert.equal(f.db.counters.writes, 0);
});

test("reservation alone with missing guard cannot authorize recovery", async () => {
  const f = fixture(); f.db.seed(rkey(), reservation());
  f.db.docs.delete(gkey()); f.setAuth({state: "ABSENT"});
  status(await f.inspect(), "GUARD_INVALID");
  assert.equal(f.db.counters.writes, 0);
});

test("unauthorized operator and forged proof cause no storage or Auth reads", async () => {
  for (const method of ["reserve", "inspect", "admission"]) {
    const f = fixture();
    status(await f[method]({authority: {enabled: true}}), "OPERATOR_UNAUTHORIZED");
    assert.equal(f.calls.auth, 0);
    assert.equal(f.db.counters.reads, 0);
    assert.equal(f.db.counters.writes, 0);
  }
});

test("authority is bound to action, project, database, UID and operation", async () => {
  const f = fixture(); await f.reserve();
  assert.deepEqual(f.calls.authorize[0], {action: "RESERVE", projectId: PROJECT,
    databaseId: DATABASE, uid: UID, deletionId: ID});
  f.hooks.authorize = (scope, proof) => proof === f.authority && scope.action === "INSPECT";
  status(await f.reserve(), "OPERATOR_UNAUTHORIZED");
  status(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
});

test("exceptions and input PII never appear in output or errors", async () => {
  const f = fixture();
  f.hooks.auth = () => {throw new Error(PRIVATE);};
  const outputs = [await f.reserve(), await f.inspect(), await f.reserve({email: PRIVATE})];
  f.hooks.authorize = () => {throw Object.assign(new Error(PRIVATE), {code: PRIVATE});};
  outputs.push(await f.admission());
  for (const output of outputs) {
    assert.deepEqual(Object.keys(output).sort(), ["destructiveAuthority", "status"]);
    for (const value of [PRIVATE, UID, ID, PROJECT]) {
      assert.equal(JSON.stringify(output).includes(value), false);
    }
    assert.equal(output.destructiveAuthority, false);
  }
});

test("captured request and scope cannot be mutated across await", async () => {
  const f = fixture(); const request = f.input();
  f.hooks.authorize = (scope, proof) => {
    assert.equal(Object.isFrozen(scope), true);
    request.uid = "other"; request.deletionId = OTHER_ID;
    return proof === f.authority;
  };
  status(await f.model.reserve(request), "RESERVATION_ACKNOWLEDGED");
  assert.ok(f.db.read(rkey()));
  assert.equal(f.db.read(rkey("other")), undefined);
});

test("other UIDs, projects and databases remain untouched", async () => {
  const f = fixture();
  const unrelated = [rkey("other"), rkey(UID, "demo-other"), rkey(UID, PROJECT, "other-db")];
  unrelated.forEach((p) => f.db.seed(p, {sentinel: true}));
  const before = unrelated.map((p) => f.db.read(p));
  await f.reserve();
  assert.deepEqual(unrelated.map((p) => f.db.read(p)), before);
  const other = fixture({projectId: "demo-other", databaseId: "other-db"});
  status(await other.reserve(), "RESERVATION_ACKNOWLEDGED");
});

test("production project and extra collaborators cannot initialize model", () => {
  const ports = {authorize: () => true, observeAuth: () => {}, runTransaction: () => {}};
  for (const projectId of ["life-os-27b92", "demo-", "demo-../prod"]) {
    assert.throws(() => createSyntheticRetirementModel({projectId,
      databaseId: DATABASE, ports}), /Synthetic identity contract refused/);
  }
  assert.throws(() => createSyntheticRetirementModel({projectId: PROJECT,
    databaseId: DATABASE, ports: {...ports, deleteUser: () => {throw new Error(PRIVATE);}}}));
});

test("import has no network, credentials, SDK, logs or destructive dependencies", () => {
  const source = fs.readFileSync(path.join(__dirname, "../retired_identity_model.js"), "utf8");
  const module = {exports: {}};
  const forbidden = () => {throw new Error("FORBIDDEN_CAPABILITY");};
  vm.runInNewContext(source, {module, require: forbidden, fetch: forbidden,
    console: {log: forbidden, error: forbidden}, process: new Proxy({}, {get: forbidden})});
  assert.deepEqual(Object.keys(module.exports), ["createSyntheticRetirementModel"]);
  assert.doesNotMatch(source, /require\(|fetch\(|https?:|process\.|console\.|setTimeout\(/);
  const index = fs.readFileSync(path.join(__dirname, "../index.js"), "utf8");
  const cleaner = fs.readFileSync(path.join(__dirname, "../birth_ledger_cleanup.js"), "utf8");
  assert.doesNotMatch(index + cleaner, /retired_identity_model/);
  const f = fixture();
  assert.deepEqual(Object.keys(f.model).sort(), ["checkAdmission", "inspect", "reserve"]);
});
