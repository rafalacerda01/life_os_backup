"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {createSyntheticRetirementContractV2} = require("../retired_identity_contract_v2");

const PROJECT = "demo-life-os";
const DATABASE = "(default)";
const UID = "synthetic-owner";
const ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const PRIVATE = "synthetic-private@example.invalid";
const clone = (value) => structuredClone(value);
const key = (collection, uid = UID, project = PROJECT, database = DATABASE) =>
  `projects/${project}/databases/${database}/documents/${collection}/${uid}`;
const G = () => key("account_deletion_guards");
const R = () => key("retired_auth_identities");
const guard = (extra = {}) => ({version: 1, state: "IN_PROGRESS", deletionId: ID,
  startedAt: 2000, retainUntil: null, ...extra});
const saved = (origin, extra = {}) => ({version: 2, state: "RESERVED",
  deletionId: ID, origin, ...extra});
const ORIGINS = {reservePreAuth: "PRE_AUTH", recordAuthEvent: "AUTH_EVENT",
  recordLegacyReview: "LEGACY_REVIEW"};

// Create-only MVCC fake; retries validate every read, including missing records.
function store() {
  const docs = new Map();
  const counters = {reads: 0, writes: 0, attempts: 0};
  const hooks = {};
  let version = 0;
  const seed = (p, data, createTimeMs = 3000) =>
    docs.set(p, {data: clone(data), createTimeMs, version: ++version});
  const read = (p) => clone(docs.get(p));
  async function runTransaction(callback) {
    for (let attempt = 0; attempt < 8; attempt++) {
      counters.attempts++;
      const reads = new Map();
      const writes = new Map();
      const result = await callback({
        get: async (p) => {
          assert.equal(writes.size, 0, "all reads must precede writes");
          counters.reads++;
          const doc = docs.get(p);
          reads.set(p, doc?.version);
          return doc ? {exists: true, data: clone(doc.data),
            createTimeMs: doc.createTimeMs} : {exists: false};
        },
        create: (p, data) => {
          assert.equal(reads.has(p), true);
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
      for (const [p, data] of writes) { seed(p, data); counters.writes++; }
      if (hooks.failAfterCommit) {
        delete hooks.failAfterCommit;
        throw new Error(PRIVATE);
      }
      return result;
    }
    throw new Error(PRIVATE);
  }
  return {docs, counters, hooks, seed, read, runTransaction};
}

function fixture({projectId = PROJECT, databaseId = DATABASE, uid = UID} = {}) {
  const db = store();
  db.seed(key("account_deletion_guards", uid, projectId, databaseId), guard());
  const authority = Object.freeze({});
  const evidence = Object.fromEntries(Object.keys(ORIGINS).map((action) =>
    [action, Object.freeze({})]));
  const calls = {auth: 0, provenance: [], authorize: []};
  const hooks = {};
  let auth = {state: "PRESENT"};
  const ports = {
    authorize: async (scope, proof) => {
      calls.authorize.push(scope);
      return hooks.authorize ? hooks.authorize(scope, proof) : proof === authority;
    },
    attestOrigin: async (scope, proof) => {
      calls.provenance.push(scope);
      if (hooks.attestOrigin) return hooks.attestOrigin(scope, proof);
      // Separate opaque capabilities for procedure, managed event and review.
      // Their scope is captured by trusted fixture code, never by request JSON.
      return scope.projectId === projectId && scope.databaseId === databaseId &&
        scope.uid === uid && scope.deletionId === ID &&
        scope.origin === ORIGINS[scope.action] && proof === evidence[scope.action];
    },
    observeAuth: async (scope) => {
      assert.equal(scope.projectId, projectId);
      assert.equal(scope.databaseId, databaseId);
      assert.equal(scope.uid, uid);
      calls.auth++;
      return hooks.auth ? hooks.auth(calls.auth) : clone(auth);
    },
    runTransaction: db.runTransaction,
  };
  const model = createSyntheticRetirementContractV2({projectId, databaseId, ports});
  const input = (action, extra = {}) => ({uid, deletionId: ID, authority,
    ...(ORIGINS[action] ? {evidence: evidence[action]} : {}), ...extra});
  return {db, model, ports, authority, evidence, hooks, calls, input,
    setAuth: (value) => {auth = value;},
    invoke: (action, extra) => model[action](input(action, extra)),
    inspect: (extra) => model.inspect(input("inspect", extra)),
    admission: (extra = {}) => model.checkAdmission({uid, authority, ...extra})};
}
function result(value, expected) {
  assert.deepEqual(value, {status: expected, destructiveAuthority: false});
  assert.equal(Object.isFrozen(value), true);
}

for (const [action, origin] of Object.entries(ORIGINS)) {
  test(`${origin}: separate trusted evidence records minimal origin and preserves guard`, async () => {
    const f = fixture();
    if (origin !== "PRE_AUTH") f.setAuth({state: "ABSENT"});
    const before = f.db.read(G());
    result(await f.invoke(action), origin === "LEGACY_REVIEW" ?
      "LEGACY_REVIEW_RECORDED_INCONCLUSIVE" : `${origin}_RECORD_ACKNOWLEDGED`);
    assert.deepEqual(f.db.read(R()).data, saved(origin));
    assert.equal(f.db.counters.reads, 2);
    assert.equal(f.db.counters.writes, 1);
    assert.deepEqual(f.db.read(G()), before);
    result(await f.admission(), "UID_RESERVED");
  });

  test(`${origin}: declared provenance and operator authority are insufficient`, async () => {
    const f = fixture();
    result(await f.invoke(action, {evidence: {origin, verified: true}}), "PROVENANCE_UNPROVEN");
    result(await f.invoke(action, {origin}), "INPUT_INVALID");
    assert.equal(f.calls.auth, 0);
    assert.equal(f.db.counters.reads, 0);
    assert.equal(f.db.counters.writes, 0);
  });

  test(`${origin}: exact replay is read-only and concurrent callers converge`, async () => {
    const f = fixture();
    if (origin !== "PRE_AUTH") f.setAuth({state: "ABSENT"});
    const expected = origin === "LEGACY_REVIEW" ?
      "LEGACY_REVIEW_RECORDED_INCONCLUSIVE" : `${origin}_RECORD_ACKNOWLEDGED`;
    const outputs = await Promise.all([f.invoke(action), f.invoke(action)]);
    outputs.forEach((value) => result(value, expected));
    assert.equal(f.db.counters.writes, 1);
    assert.ok(f.db.counters.attempts >= 3);
    const before = f.db.read(R());
    result(await f.invoke(action), expected);
    assert.deepEqual(f.db.read(R()), before);
    assert.equal(f.db.counters.writes, 1);
  });
}

test("old active account can pre-reserve without creation metadata", async () => {
  const f = fixture();
  result(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
  result(await f.invoke("reservePreAuth"), "PRE_AUTH_RECORD_ACKNOWLEDGED");
  assert.equal(Object.hasOwn(f.db.read(R()).data, "authCreatedAtMs"), false);
});

test("pre-Auth procedure commits before the synthetic controller removes Auth", async () => {
  const f = fixture();
  result(await f.invoke("reservePreAuth"), "PRE_AUTH_RECORD_ACKNOWLEDGED");
  assert.ok(f.db.read(R()));
  f.setAuth({state: "ABSENT"});
  result(await f.inspect(), "PRE_AUTH_PROCEDURE_REVALIDATION_REQUIRED");
  const before = f.db.read(R());
  result(await f.invoke("reservePreAuth"), "AUTH_ABSENT_CANNOT_PRE_RESERVE");
  assert.deepEqual(f.db.read(R()), before);
});

test("managed event admits legacy absence without inventing a pre-Auth reservation", async () => {
  const f = fixture(); f.setAuth({state: "ABSENT"});
  result(await f.inspect(), "LEGACY_REVIEW_REQUIRED");
  result(await f.invoke("recordAuthEvent"), "AUTH_EVENT_RECORD_ACKNOWLEDGED");
  result(await f.inspect(), "MANAGED_AUTH_EVENT_REVALIDATION_REQUIRED");
  f.setAuth({state: "PRESENT"});
  const before = f.db.read(R());
  result(await f.invoke("reservePreAuth"), "ORIGIN_CONFLICT");
  assert.deepEqual(f.db.read(R()), before);
});

test("batch deletion without individual event stays review-only", async () => {
  const f = fixture(); f.setAuth({state: "ABSENT"});
  result(await f.invoke("recordAuthEvent", {evidence: {batchDelete: true}}), "PROVENANCE_UNPROVEN");
  result(await f.invoke("recordLegacyReview"), "LEGACY_REVIEW_RECORDED_INCONCLUSIVE");
  result(await f.inspect(), "LEGACY_REVIEW_REQUIRED");
});

for (const [initial, later] of [["recordLegacyReview", "recordAuthEvent"],
  ["recordAuthEvent", "recordLegacyReview"], ["reservePreAuth", "recordAuthEvent"],
  ["recordLegacyReview", "reservePreAuth"], ["recordAuthEvent", "reservePreAuth"],
  ["reservePreAuth", "recordLegacyReview"]]) {
  test(`origin cannot be promoted or rewritten: ${initial} to ${later}`, async () => {
    const f = fixture();
    if (initial !== "reservePreAuth") f.setAuth({state: "ABSENT"});
    await f.invoke(initial);
    f.setAuth({state: later === "reservePreAuth" ? "PRESENT" : "ABSENT"});
    const before = f.db.read(R());
    result(await f.invoke(later), "ORIGIN_CONFLICT");
    assert.deepEqual(f.db.read(R()), before);
    assert.equal(f.db.counters.writes, 1);
  });
}

test("legitimate event and legacy review racing cannot adopt each other's origin", async () => {
  const f = fixture(); f.setAuth({state: "ABSENT"});
  const outputs = await Promise.all([f.invoke("recordAuthEvent"), f.invoke("recordLegacyReview")]);
  assert.equal(outputs.filter((o) => o.status === "ORIGIN_CONFLICT").length, 1);
  assert.equal(f.db.counters.writes, 1);
  outputs.forEach((o) => assert.equal(o.destructiveAuthority, false));
});

for (const [name, replacement, expected] of [
  ["COMPLETE", guard({state: "COMPLETE", retainUntil: 9000}), "GUARD_COMPLETE"],
  ["another operation", guard({deletionId: OTHER}), "OPERATION_CONFLICT"],
  ["invalid schema", guard({version: 2}), "GUARD_INVALID"],
]) {
  test(`MVCC retry revalidates guard changed to ${name}`, async () => {
    const f = fixture();
    f.db.hooks.beforeCommit = () => f.db.seed(G(), replacement);
    result(await f.invoke("reservePreAuth"), expected);
    assert.equal(f.db.counters.attempts, 2);
    assert.equal(f.db.counters.writes, 0);
    assert.equal(f.db.read(R()), undefined);
    assert.deepEqual(f.db.read(G()).data, replacement);
  });
}

test("same guard rewritten by a peer retries without duplicating reservation", async () => {
  const f = fixture(); f.db.hooks.beforeCommit = () => f.db.seed(G(), guard());
  result(await f.invoke("reservePreAuth"), "PRE_AUTH_RECORD_ACKNOWLEDGED");
  assert.equal(f.db.counters.attempts, 2);
  assert.equal(f.db.counters.writes, 1);
});

test("guard owner and a concurrent incompatible deletionId stay fenced", async () => {
  const f = fixture();
  f.hooks.attestOrigin = () => true; // even a broader synthetic attestor cannot override guard
  const outputs = await Promise.all([f.invoke("reservePreAuth"),
    f.invoke("reservePreAuth", {deletionId: OTHER})]);
  result(outputs[0], "PRE_AUTH_RECORD_ACKNOWLEDGED");
  result(outputs[1], "OPERATION_CONFLICT");
  f.db.seed(G(), guard({deletionId: OTHER}));
  result(await f.invoke("reservePreAuth", {deletionId: OTHER}), "RESERVATION_CONFLICT");
  assert.equal(f.db.counters.writes, 1);
});

test("V1 remains untouched and cannot be upgraded using a V2 origin", async () => {
  const f = fixture();
  f.db.seed(R(), {version: 1, state: "RESERVED", deletionId: ID, authCreatedAtMs: 1000});
  const before = f.db.read(R());
  for (const action of Object.keys(ORIGINS)) {
    f.setAuth({state: action === "reservePreAuth" ? "PRESENT" : "ABSENT"});
    result(await f.invoke(action), "V1_REVIEW_REQUIRED");
  }
  result(await f.inspect(), "V1_REVIEW_REQUIRED");
  result(await f.admission(), "UID_RESERVED");
  assert.deepEqual(f.db.read(R()), before);
  assert.equal(f.db.counters.writes, 0);
});

test("malformed V1 is not silently accepted as a migration candidate", async () => {
  for (const extra of [{authCreatedAtMs: null}, {authCreatedAtMs: NaN},
    {origin: "PRE_AUTH"}, {deletionId: [ID]}]) {
    const f = fixture();
    f.db.seed(R(), {version: 1, state: "RESERVED", deletionId: ID,
      authCreatedAtMs: 1000, ...extra});
    const before = f.db.read(R());
    result(await f.inspect(), "RECORD_INVALID");
    result(await f.invoke("reservePreAuth"), "RECORD_INVALID");
    assert.deepEqual(f.db.read(R()), before);
    assert.equal(f.db.counters.writes, 0);
  }
});

test("legacy IN_PROGRESS or missing guard is inconclusive, never auto-created", async () => {
  const f = fixture(); f.setAuth({state: "ABSENT"});
  result(await f.inspect(), "LEGACY_REVIEW_REQUIRED");
  f.db.docs.delete(G());
  result(await f.inspect(), "LEGACY_REVIEW_REQUIRED");
  result(await f.invoke("recordAuthEvent"), "GUARD_INVALID");
  assert.equal(f.db.counters.writes, 0);
});

test("COMPLETE and residual descendants require terminal proof without reopening", async () => {
  const f = fixture(); f.setAuth({state: "ABSENT"});
  f.db.seed(G(), guard({state: "COMPLETE", retainUntil: 9000}));
  const orphan = key(`users/${UID}/private`, "orphan");
  f.db.seed(orphan, {sentinel: true}); // root intentionally absent
  const before = clone([...f.db.docs]);
  result(await f.inspect(), "TERMINAL_PROOF_REQUIRED");
  result(await f.invoke("recordAuthEvent"), "GUARD_COMPLETE");
  assert.deepEqual([...f.db.docs], before);
  assert.equal(f.db.counters.writes, 0);
});

test("COMPLETE racing inspection is revalidated and never treated as clean", async () => {
  const f = fixture(); f.setAuth({state: "ABSENT"});
  f.db.hooks.beforeCommit = () => f.db.seed(G(), guard({state: "COMPLETE", retainUntil: 9000}));
  result(await f.inspect(), "TERMINAL_PROOF_REQUIRED");
  assert.equal(f.db.counters.attempts, 2);
});

test("root absence with descendants does not change reservation classification or remove anything", async () => {
  const f = fixture();
  const orphan = key(`users/${UID}/private`, "orphan");
  f.db.seed(orphan, {sentinel: true});
  const before = f.db.read(orphan);
  await f.invoke("reservePreAuth"); f.setAuth({state: "ABSENT"});
  result(await f.inspect(), "PRE_AUTH_PROCEDURE_REVALIDATION_REQUIRED");
  assert.deepEqual(f.db.read(orphan), before);
});

for (const action of ["recordAuthEvent", "recordLegacyReview"]) {
  test(`Auth present or reappeared blocks ${action}`, async () => {
    const f = fixture();
    result(await f.invoke(action), "AUTH_PRESENT_RECOVERY_BLOCKED");
    f.setAuth({state: "ABSENT"}); await f.invoke(action);
    f.setAuth({state: "PRESENT"});
    result(await f.invoke(action), "AUTH_PRESENT_RECOVERY_BLOCKED");
    result(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
    assert.equal(f.db.counters.writes, 1);
  });
}

test("Auth reappearance between inspection observations fails closed", async () => {
  const f = fixture();
  f.hooks.auth = (count) => ({state: count === 1 ? "ABSENT" : "PRESENT"});
  result(await f.inspect(), "AUTH_CHANGED_REQUIRES_REVIEW");
});

test("Auth changes during commit leave an inconclusive durable record, never order proof", async () => {
  const f = fixture();
  f.db.hooks.beforeCommit = () => f.setAuth({state: "ABSENT"});
  result(await f.invoke("reservePreAuth"), "AUTH_CHANGED_REQUIRES_REVIEW");
  assert.deepEqual(f.db.read(R()).data, saved("PRE_AUTH"));
  result(await f.inspect(), "PRE_AUTH_PROCEDURE_REVALIDATION_REQUIRED");
  result(await f.admission(), "UID_RESERVED");
});

test("PRESENT to PRESENT replacement is deliberately not claimed as generation detection", async () => {
  const f = fixture(); let replaced = false;
  f.db.hooks.beforeCommit = () => {replaced = true; f.setAuth({state: "PRESENT"});};
  result(await f.invoke("reservePreAuth"), "PRE_AUTH_RECORD_ACKNOWLEDGED");
  assert.equal(replaced, true);
  result(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
});

for (const observation of [{state: "AMBIGUOUS"}, {state: "CONFLICT"},
  {state: "PRESENT", createdAtMs: 1000}, {state: "ABSENT", email: PRIVATE}, null]) {
  test(`invalid or generation-like Auth observation is not identity proof: ${JSON.stringify(observation)}`, async () => {
    const f = fixture(); f.setAuth(observation);
    result(await f.invoke("reservePreAuth"), "IDENTITY_AMBIGUOUS");
    result(await f.inspect(), "IDENTITY_AMBIGUOUS");
    assert.equal(f.db.counters.writes, 0);
  });
}

test("lost commit response is resolved by reread and replay without rewriting origin", async () => {
  const f = fixture(); f.db.hooks.failAfterCommit = true;
  result(await f.invoke("reservePreAuth"), "UNKNOWN_REQUIRES_REREAD");
  const committed = f.db.read(R());
  result(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
  result(await f.invoke("reservePreAuth"), "PRE_AUTH_RECORD_ACKNOWLEDGED");
  assert.deepEqual(f.db.read(R()), committed);
  assert.equal(f.db.counters.writes, 1);
});

test("lost commit response followed by Auth absence does not manufacture a new PRE_AUTH", async () => {
  const f = fixture(); f.db.hooks.failAfterCommit = true;
  await f.invoke("reservePreAuth"); f.setAuth({state: "ABSENT"});
  result(await f.inspect(), "PRE_AUTH_PROCEDURE_REVALIDATION_REQUIRED");
  result(await f.invoke("reservePreAuth"), "AUTH_ABSENT_CANNOT_PRE_RESERVE");
  result(await f.invoke("recordAuthEvent"), "ORIGIN_CONFLICT");
  assert.equal(f.db.counters.writes, 1);
});

test("failure before commit remains unknown and explicit retry can recover", async () => {
  const f = fixture(); f.db.hooks.failBeforeCommit = true;
  result(await f.invoke("reservePreAuth"), "UNKNOWN_REQUIRES_REREAD");
  assert.equal(f.db.read(R()), undefined);
  result(await f.inspect(), "AUTH_PRESENT_RECOVERY_BLOCKED");
  result(await f.invoke("reservePreAuth"), "PRE_AUTH_RECORD_ACKNOWLEDGED");
  assert.equal(f.db.counters.writes, 1);
});

for (const extra of [{version: 3}, {origin: "CLIENT"}, {state: "COMPLETE"},
  {deletionId: "bad"}, {authCreatedAtMs: 1000}, {email: PRIVATE}]) {
  test(`malformed V2 fails closed without overwrite: ${Object.keys(extra).join(",")}`, async () => {
    const f = fixture(); f.db.seed(R(), saved("PRE_AUTH", extra));
    const before = f.db.read(R());
    result(await f.invoke("reservePreAuth"), "RECORD_INVALID");
    result(await f.inspect(), "RECORD_INVALID");
    result(await f.admission(), "RECORD_INVALID");
    assert.deepEqual(f.db.read(R()), before);
    assert.equal(f.db.counters.writes, 0);
  });
}

test("reservation with a missing guard cannot authorize even classification as recoverable", async () => {
  const f = fixture(); f.db.seed(R(), saved("AUTH_EVENT")); f.db.docs.delete(G());
  f.setAuth({state: "ABSENT"});
  result(await f.inspect(), "GUARD_INVALID");
  result(await f.admission(), "UID_RESERVED");
});

test("absent reservation never authorizes admission", async () => {
  result(await fixture().admission(), "LEGACY_OR_NEW_UNPROVEN");
});

test("unauthorized actions never observe Auth, attest provenance or touch storage", async () => {
  const f = fixture();
  for (const action of [...Object.keys(ORIGINS), "inspect"]) {
    result(await f.invoke(action, {authority: {enabled: true}}), "OPERATOR_UNAUTHORIZED");
  }
  result(await f.admission({authority: {enabled: true}}), "OPERATOR_UNAUTHORIZED");
  assert.equal(f.calls.auth, 0);
  assert.equal(f.calls.provenance.length, 0);
  assert.equal(f.db.counters.reads, 0);
});

test("provenance capabilities are action and scope bound, including operation", async () => {
  const f = fixture();
  result(await f.invoke("reservePreAuth", {evidence: f.evidence.recordAuthEvent}), "PROVENANCE_UNPROVEN");
  result(await f.invoke("reservePreAuth", {deletionId: OTHER}), "PROVENANCE_UNPROVEN");
  result(await f.invoke("reservePreAuth", {uid: "other"}), "PROVENANCE_UNPROVEN");
  const second = fixture({databaseId: "other-db"});
  result(await second.invoke("reservePreAuth", {evidence: f.evidence.reservePreAuth}), "PROVENANCE_UNPROVEN");
  const third = fixture({projectId: "demo-other"});
  result(await third.invoke("reservePreAuth", {evidence: f.evidence.reservePreAuth}), "PROVENANCE_UNPROVEN");
  assert.equal(f.db.counters.writes, 0);
  assert.equal(second.db.counters.writes, 0);
});

test("truthy declarations from either boundary are not accepted as true", async () => {
  const f = fixture();
  f.hooks.authorize = () => ({authorized: true});
  result(await f.invoke("reservePreAuth"), "OPERATOR_UNAUTHORIZED");
  delete f.hooks.authorize;
  f.hooks.attestOrigin = () => ({verified: true});
  result(await f.invoke("reservePreAuth"), "PROVENANCE_UNPROVEN");
  assert.equal(f.calls.auth, 0);
  assert.equal(f.db.counters.reads, 0);
});

test("stored operation IDs must be strings, not values coercible to a UUID", async () => {
  const f = fixture(); f.db.seed(G(), guard({deletionId: [ID]}));
  result(await f.invoke("reservePreAuth"), "GUARD_INVALID");
  f.db.seed(G(), guard()); f.db.seed(R(), saved("PRE_AUTH", {deletionId: [ID]}));
  result(await f.inspect(), "RECORD_INVALID");
  assert.equal(f.db.counters.writes, 0);
});

test("request and collaborator replacement across await cannot change captured scope", async () => {
  const f = fixture(); const request = f.input("reservePreAuth");
  f.hooks.authorize = (scope) => {
    assert.equal(Object.isFrozen(scope), true);
    request.uid = "other"; request.deletionId = OTHER;
    request.evidence = {};
    f.ports.attestOrigin = () => false;
    return true;
  };
  result(await f.model.reservePreAuth(request), "PRE_AUTH_RECORD_ACKNOWLEDGED");
  assert.deepEqual(f.db.read(R()).data, saved("PRE_AUTH"));
  assert.equal(f.db.read(key("retired_auth_identities", "other")), undefined);
});

test("errors, identifiers and extra request data are sanitized on every public method", async () => {
  const f = fixture(); const outputs = [];
  for (const action of [...Object.keys(ORIGINS), "inspect"]) {
    f.hooks.authorize = () => {throw Object.assign(new Error(PRIVATE), {code: PRIVATE});};
    outputs.push(await f.invoke(action));
    delete f.hooks.authorize;
    outputs.push(await f.invoke(action, {email: PRIVATE}));
  }
  f.hooks.auth = () => {throw new Error(PRIVATE);};
  outputs.push(await f.inspect());
  f.hooks.attestOrigin = () => {throw new Error(PRIVATE);};
  outputs.push(await f.invoke("recordAuthEvent"));
  f.hooks.authorize = () => {throw new Error(PRIVATE);};
  outputs.push(await f.admission());
  for (const output of outputs) {
    assert.deepEqual(Object.keys(output).sort(), ["destructiveAuthority", "status"]);
    assert.equal(output.destructiveAuthority, false);
    for (const privateValue of [PRIVATE, UID, ID, PROJECT, DATABASE]) {
      assert.equal(JSON.stringify(output).includes(privateValue), false);
    }
  }
});

test("unrelated UID, project, database, guard and descendants stay unchanged", async () => {
  const f = fixture();
  const unrelated = [key("retired_auth_identities", "other"),
    key("retired_auth_identities", UID, "demo-other"),
    key("retired_auth_identities", UID, PROJECT, "other-db")];
  unrelated.forEach((p) => f.db.seed(p, {sentinel: true}));
  const before = unrelated.map((p) => f.db.read(p));
  await f.invoke("reservePreAuth");
  assert.deepEqual(unrelated.map((p) => f.db.read(p)), before);
  const second = fixture({projectId: "demo-other", databaseId: "other-db"});
  result(await second.invoke("reservePreAuth"), "PRE_AUTH_RECORD_ACKNOWLEDGED");
});

test("production scope, destructive collaborators and invalid input are refused", async () => {
  const ports = {authorize: () => true, attestOrigin: () => true,
    observeAuth: () => ({state: "PRESENT"}), runTransaction: () => {}};
  for (const [projectId, databaseId] of [["life-os-27b92", DATABASE],
    ["demo-../prod", DATABASE], [PROJECT, "../prod"], [PROJECT, ""]]) {
    assert.throws(() => createSyntheticRetirementContractV2({projectId, databaseId, ports}),
        (error) => error.destructiveAuthority === false && !error.message.includes(projectId));
  }
  assert.throws(() => createSyntheticRetirementContractV2({projectId: PROJECT,
    databaseId: DATABASE, ports: {...ports, deleteUser: () => {}}}));
  const f = fixture();
  for (const uid of ["../other", "__reserved__", "bad\nuid", " x", "x".repeat(129)]) {
    result(await f.invoke("reservePreAuth", {uid}), "INPUT_INVALID");
  }
  result(await f.invoke("reservePreAuth", {deletionId: "bad"}), "INPUT_INVALID");
  assert.equal(f.calls.authorize.length, 0);
});

test("module has no real-service capabilities or integration with production entrypoints", () => {
  const file = path.join(__dirname, "../retired_identity_contract_v2.js");
  const source = fs.readFileSync(file, "utf8");
  const module = {exports: {}};
  const forbidden = () => {throw new Error("FORBIDDEN_CAPABILITY");};
  vm.runInNewContext(source, {module, require: forbidden, fetch: forbidden,
    console: {log: forbidden, error: forbidden}, process: new Proxy({}, {get: forbidden})});
  assert.deepEqual(Object.keys(module.exports), ["createSyntheticRetirementContractV2"]);
  assert.doesNotMatch(source, /require\(|fetch\(|https?:|process\.|console\.|setTimeout\(/);
  for (const relative of ["../index.js", "../birth_ledger_cleanup.js",
    "../../backend/api/account/delete.js", "../../backend/api/account/_birth_ledger_cleanup.js"]) {
    assert.doesNotMatch(fs.readFileSync(path.join(__dirname, relative), "utf8"),
        /retired_identity_contract_v2/);
  }
  assert.deepEqual(Object.keys(fixture().model).sort(),
      ["checkAdmission", "inspect", "recordAuthEvent", "recordLegacyReview", "reservePreAuth"]);
});
