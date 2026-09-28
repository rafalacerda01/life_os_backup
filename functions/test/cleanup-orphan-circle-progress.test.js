const assert = require("node:assert/strict");
const test = require("node:test");
const {cleanupProgress, cleanupOrphanProgress, parseArgs, runCli} = require("../scripts/cleanup-orphan-circle-progress");

const path = "circles/circle/challenges/challenge/progress/former";
function fixture(extra = {}) {
  const store = new Map(Object.entries({
    "circles/circle": {schemaVersion: 2},
    "circles/circle/challenges/challenge": {schemaVersion: 2},
    [path]: {value: 4},
    "circles/circle/members/current": {role: "member"},
    "circles/circle/challenges/challenge/progress/current": {uid: "current", value: 8},
    "circles/circle/challenges/challenge/processed_events/old": {uid: "former"}, ...extra,
  }));
  const deletes = [];
  const db = {
    collection: name => ref(name),
    collectionGroup: name => {
      assert.equal(name, "progress"); let cursor;
      const query = {orderBy: () => query, limit: value => {assert.equal(value, 200); return query;},
        startAfter: value => {cursor = value.ref.path; return query;},
        get: async () => {
          const docs = [...store.keys()].filter(key => key.includes("/progress/") && (!cursor || key > cursor)).sort().slice(0, 200)
            .map(key => ({ref: ref(key)}));
          return {empty: docs.length === 0, docs};
        }};
      return query;
    },
    runTransaction: async callback => {
      if (db.beforeTransaction) {db.beforeTransaction(); db.beforeTransaction = null;}
      const writes = [];
      const result = await callback({get: reference => {assert.equal(writes.length, 0); return reference.get();},
        delete: reference => writes.push(reference.path)});
      for (const key of writes) {store.delete(key); deletes.push(key);}
      return result;
    },
  };
  function ref(key) {
    return {path: key, id: key.split("/").at(-1), collection: name => ref(`${key}/${name}`),
      doc: id => ref(`${key}/${id}`), get: async () => ({exists: store.has(key), data: () => store.get(key)})};
  }
  return {db, store, deletes, ref: ref(path), reference: ref};
}
test("dry-run identifies legacy orphan by document ID and preserves current member and events", async () => {
  const f = fixture(); const before = new Map(f.store);
  assert.deepEqual(await cleanupOrphanProgress(f.db), {CANDIDATE: 1, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
});
test("apply deletes only validated orphan; second dry-run has zero candidates", async () => {
  const f = fixture(); const before = new Map(f.store);
  assert.deepEqual(await cleanupProgress(f.db, f.ref, {apply: true}), {status: "APPLIED"});
  assert.deepEqual(f.deletes, [path]);
  before.delete(path); assert.deepEqual(f.store, before);
  assert.deepEqual(await cleanupOrphanProgress(f.db), {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0});
});
test("apply revalidates a membership added after dry-run", async () => {
  const f = fixture();
  assert.equal((await cleanupProgress(f.db, f.ref)).status, "CANDIDATE");
  f.db.beforeTransaction = () => f.store.set("circles/circle/members/former", {role: "member"});
  assert.equal((await cleanupProgress(f.db, f.ref, {apply: true})).status, "UNCHANGED");
  assert.deepEqual(f.deletes, []);
});
for (const bad of ["users/uid/progress/former", "circles/ bad /challenges/challenge/progress/former", "circles/circle/challenges/challenge/progress/ bad "]) {
  test(`malformed path ${bad} is a conflict without deletion`, async () => {
    const f = fixture({[bad]: {value: 4}});
    assert.equal((await cleanupProgress(f.db, f.reference(bad), {apply: true})).status, "CONFLICT");
    assert.deepEqual(f.deletes, []);
  });
}
for (const [label, extra] of [
  ["mismatched uid", {[path]: {uid: "other", value: 4}}],
  ["invalid value", {[path]: {value: "4"}}],
  ["invalid timestamp", {[path]: {value: 4, updatedAt: null}}],
  ["invalid circle schema", {"circles/circle": {schemaVersion: 1}}],
  ["invalid challenge schema", {"circles/circle/challenges/challenge": {schemaVersion: 3}}],
  ["deleting Circle", {"circles/circle": {schemaVersion: 2, deletionState: "SERVER_DELETING"}}],
]) {
  test(`${label} is a conflict without writes`, async () => {
    const f = fixture(extra); const before = new Map(f.store);
    assert.equal((await cleanupProgress(f.db, f.ref, {apply: true})).status, "CONFLICT");
    assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
  });
}
test("legacy Challenge schema 1 remains eligible with valid progress", async () => {
  const f = fixture({"circles/circle/challenges/challenge": {schemaVersion: 1}});
  assert.equal((await cleanupProgress(f.db, f.ref)).status, "CANDIDATE");
});
test("scan paginates more than 200 progress documents without writing", async () => {
  const f = fixture();
  for (let i = 0; i < 205; i++) f.store.set(`circles/circle/challenges/challenge/progress/former-${i}`, {value: 1});
  assert.equal((await cleanupOrphanProgress(f.db)).CANDIDATE, 206); assert.deepEqual(f.deletes, []);
});
test("CLI requires explicit project, defaults to dry-run and uses modular bootstrap", async t => {
  assert.deepEqual(parseArgs(["--project", "demo-life-os"]), {apply: false, projectId: "demo-life-os"});
  assert.throws(() => parseArgs([]));
  const Module = require("node:module"); const load = Module._load;
  const f = fixture(); const calls = []; const output = [];
  t.mock.method(Module, "_load", function(request, ...args) {
    if (request === "firebase-admin") assert.fail("Legacy Admin API is forbidden");
    if (request === "firebase-admin/app") return {initializeApp: options => calls.push(options)};
    if (request === "firebase-admin/firestore") return {getFirestore: () => {calls.push("getFirestore"); return f.db;}, FieldPath: {documentId: () => "id"}};
    return load.call(this, request, ...args);
  });
  assert.equal(await runCli(["--project", "demo-life-os"], {log: value => output.push(JSON.parse(value))}), 1);
  assert.deepEqual(calls, [{projectId: "demo-life-os"}, "getFirestore"]);
  assert.equal(output[0].mode, "DRY_RUN"); assert.deepEqual(f.deletes, []);
});

async function invokeCli(f, args = []) {
  const output = [];
  const code = await runCli(["--project", "demo-life-os", ...args], {
    initializeApp: options => assert.deepEqual(options, {projectId: "demo-life-os"}),
    getFirestore: () => f.db,
    log: value => output.push(JSON.parse(value)),
  });
  assert.equal(output.length, 1);
  return {code, report: output[0]};
}

test("CLI clean dry-run returns zero without writes", async () => {
  const f = fixture(); f.store.delete(path); const before = new Map(f.store);
  const {code, report} = await invokeCli(f);
  assert.equal(code, 0);
  assert.deepEqual(report, {mode: "DRY_RUN", counts: {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0}});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
});

test("CLI dry-run with a candidate blocks rollout with nonzero exit code", async () => {
  const f = fixture(); const before = new Map(f.store);
  const {code, report} = await invokeCli(f);
  assert.notEqual(code, 0);
  assert.deepEqual(report, {mode: "DRY_RUN", counts: {CANDIDATE: 1, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0}});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
});

test("CLI dry-run with a conflict returns nonzero without writes", async () => {
  const f = fixture({[path]: {value: "invalid"}}); const before = new Map(f.store);
  const {code, report} = await invokeCli(f);
  assert.notEqual(code, 0);
  assert.deepEqual(report, {mode: "DRY_RUN", counts: {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 1, APPLIED: 0}});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
});

test("CLI apply removes only validated candidate and reports counts without IDs", async () => {
  const f = fixture(); const before = new Map(f.store);
  const {code, report} = await invokeCli(f, ["--apply"]);
  assert.equal(code, 0);
  assert.deepEqual(report, {mode: "APPLY", counts: {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 0, APPLIED: 1}});
  assert.deepEqual(f.deletes, [path]); before.delete(path); assert.deepEqual(f.store, before);
  const serialized = JSON.stringify(report);
  for (const identifier of [path, "circle", "challenge", "former", "current"]) {
    assert.equal(serialized.includes(identifier), false);
  }
});

test("CLI second dry-run after validated apply returns zero", async () => {
  const f = fixture();
  assert.equal((await invokeCli(f, ["--apply"])).code, 0);
  const before = new Map(f.store);
  const {code, report} = await invokeCli(f);
  assert.equal(code, 0);
  assert.deepEqual(report, {mode: "DRY_RUN", counts: {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0}});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, [path]);
});
