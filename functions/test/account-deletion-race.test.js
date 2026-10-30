const cleanupManifest = require("../account_cleanup_manifest");
const realRemoveTree = cleanupManifest.removeTree;
cleanupManifest.removeTree = options => {
  options.db.fixtureTreeOptions = options;
  return options.db.recursiveDelete(options.ref);
};
"use strict";
const assert = require('node:assert/strict');
const test = require('node:test');
const {AsyncLocalStorage} = require('node:async_hooks');
const {createHash} = require('node:crypto');
const {Timestamp} = require('firebase-admin/firestore');
const context = new AsyncLocalStorage();
const UID = 'synthetic-owner', OTHER = 'synthetic-other';
const ROOT = 'users/' + UID, L = 'account_birth_decisions/' + UID, G = 'account_deletion_guards/' + UID;
const CREATED = Timestamp.fromDate(new Date('2026-10-13T10:00:00Z'));
const CLOCK = Timestamp.fromDate(new Date('2026-10-13T11:00:00Z'));
function copy(v) {
  if (v instanceof Timestamp) return v;
  if (Array.isArray(v)) return v.map(copy);
  if (v && typeof v === 'object' && Object.getPrototypeOf(v) !== Object.prototype) return v;
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, copy(x)]));
  return v;
}
function gate() {
  const reached = Promise.withResolvers(), release = Promise.withResolvers();
  return { reached: reached.promise, release: release.resolve,
    async hold() { reached.resolve(); await release.promise; } };
}

// Stable snapshots, absent-document versions AND query-range versions. This
// optimistic fake retries the real callback, discards rejected buffered writes,
// and catches query phantoms. Real Admin Firestore normally uses pessimistic locks.
class FakeFirestore {
  projectId = "demo-life-os-p1";
  databaseId = "(default)";
  doc(path) { return this.ref(path); }
  docs = new Map(); versions = new Map(); created = new Map();
  attempts = []; conflicts = []; writes = []; hooks = {}; recursiveDeletes = [];
  query(path, group = false, filters = [], limit = Infinity) {
    const q = { path, kind: 'query', group, filters, bound: limit,
      where: (field, op, value) => this.query(path, group, [...filters, { field, op, value }], limit),
      limit: n => this.query(path, group, filters, n), orderBy: () => q, startAfter: snapshot => { q.cursor = snapshot.ref.path; return q; },
      get: async () => this.querySnapshot(q, this.docs, this.created) };
    return q;
  }
  collection(path) {
    return { ...this.query(path), doc: id => this.ref(`${path}/${id}`) };
  }
  collectionGroup(name) { return this.query(name, true); }
  ref(path) {
    return { path, kind: 'doc', listCollections: async () => {
      const names = [...new Set([...this.docs.keys()].filter(p => p.startsWith(path + "/"))
        .map(p => p.slice(path.length + 1).split("/")[0]))];
      return names.map(name => ({path: path + "/" + name,
        listDocuments: async () => [...new Set([...this.docs.keys()]
          .filter(p => p.startsWith(path + "/" + name + "/"))
          .map(p => path + "/" + name + "/" +
            p.slice((path + "/" + name + "/").length).split("/")[0]))].map(p => this.ref(p))}));
    }, collection: name => this.collection(`${path}/${name}`),
      get: async () => this.snapshot(path, this.docs, this.created) };
  }
  snapshot(path, docs, created, versions = this.versions) {
    return { ref: this.ref(path), id: path.split('/').at(-1), exists: docs.has(path),
      createTime: created.get(path), updateTime: docs.has(path) ? Timestamp.fromMillis(versions.get(path) || 0) : undefined, data: () => copy(docs.get(path)) };
  }
  querySnapshot(q, docs, created) {
    const found = [...docs.keys()].sort().filter(p =>
      (q.group ? p.split('/').at(-2) === q.path : p.startsWith(`${q.path}/`) &&
        !p.slice(q.path.length + 1).includes('/')) &&
      (!q.cursor || p > q.cursor) && q.filters.every(f => f.op === '==' && docs.get(p)?.[f.field] === f.value))
      .slice(0, q.bound).map(p => this.snapshot(p, docs, created));
    return { docs: found, empty: found.length === 0, size: found.length };
  }
  put(path, data, createdAt = CREATED) {
    if (data === undefined) { this.docs.delete(path); this.created.delete(path); }
    else { this.docs.set(path, copy(data)); if (!this.created.has(path)) this.created.set(path, createdAt); }
    for (const key of [path, `query:${path.split('/').slice(0, -1).join('/')}`,
      `group:${path.split('/').at(-2)}`]) this.versions.set(key, (this.versions.get(key) ?? 0) + 1);
  }
  async runTransaction(callback) {
    const label = context.getStore();
    for (let attempt = 1; attempt <= 10; attempt++) {
      const docs = new Map([...this.docs].map(([p, d]) => [p, copy(d)]));
      const created = new Map(this.created), versions = new Map(this.versions), reads = new Map(), pending = [];
      const record = { label, attempt, reads, pending }; this.attempts.push(record);
      const buffer = (type, ref, data) => pending.push({ type, ref, data: copy(data) });
      const result = await callback({
        get: async ref => {
          assert.equal(pending.length, 0, 'read after write');
          const key = ref.kind === 'query' ? `${ref.group ? 'group' : 'query'}:${ref.path}` : ref.path;
          reads.set(key, versions.get(key) ?? 0);
          await this.hooks.onRead?.({ ...record, path: ref.path });
          return ref.kind === 'query' ? this.querySnapshot(ref, docs, created) : this.snapshot(ref.path, docs, created, versions);
        },
        create: (ref, data) => buffer('create', ref, data),
        set: (ref, data) => buffer('set', ref, data),
        update: (ref, data) => buffer('update', ref, data),
        delete: ref => buffer('delete', ref),
      });
      await this.hooks.beforeCommit?.(record);
      const changed = [...reads].filter(([k, v]) => (this.versions.get(k) ?? 0) !== v).map(([k]) => k);
      if (changed.length) { this.conflicts.push({ label, attempt, changed }); continue; }
      // Validate every precondition before applying any write.
      for (const w of pending) {
        if (w.type === 'create') assert.equal(this.docs.has(w.ref.path), false);
        if (w.type === 'update') assert.equal(this.docs.has(w.ref.path), true);
      }
      for (const w of pending) {
        const data = w.data && Object.fromEntries(Object.entries(w.data).map(([k, v]) =>
          [k, v?.constructor?.name === 'ServerTimestampTransform' ? CLOCK : v]));
        this.put(w.ref.path, w.type === 'delete' ? undefined :
          w.type === 'update' ? { ...this.docs.get(w.ref.path), ...data } : data, CLOCK);
        this.writes.push(w);
      }
      await this.hooks.afterCommit?.(record);
      return result;
    }
    throw new Error('MVCC retry exhaustion');
  }
  batch() {
    const refs = []; const db = this;
    return {delete(ref) {refs.push(ref); return this;},
      commit: () => db.runTransaction(async tx => {for (const ref of refs) tx.delete(ref);})};
  }
  async recursiveDelete(ref) {
    return realRemoveTree(this.fixtureTreeOptions);
  }
}
function ledger(owner = UID) {
  return {version: 1, uid: owner, projectId: 'demo-life-os-p1', tenantId: null,
    authCreatedAt: CREATED, sourceType: 'FIREBASE_AUTH_CREATE', sourceEventId: 'synthetic-create',
    eventAt: CLOCK, cohort: {version: 1, id: 'closed-cohort', policy: 'NEW_ACCOUNT_V2_ONLY',
      state: 'CLOSED', cutoverAt: Timestamp.fromMillis(CREATED.toMillis() - 1000)},
    decisionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    originalIdentity: {uid: owner, email: 'synthetic@example.invalid', displayName: 'Synthetic', photoUrl: null},
    recordedAt: CLOCK, status: 'RECORDED_COHORT_CLOSED'};
}

// Real installed Functions v1 SDK callback; only Admin IO is replaced.
require('firebase-functions/v1');
const adminPath = require.resolve('firebase-admin');
require(adminPath);
// Test-only server configuration through the existing R6B2 seam. The installed
// callback still invokes prepare at its real boundary; no admission is faked.
const fixtureBirthCleanup = require("../birth_ledger_cleanup");
const productionPrepare = fixtureBirthCleanup.prepare;
fixtureBirthCleanup.prepare = (...args) => productionPrepare(...args,
    {verified: true, notBefore: Timestamp.fromMillis(1)});

const originalAdmin = require.cache[adminPath].exports;
let active;
require.cache[adminPath].exports = {initializeApp() {}, firestore: () => active.db,
  auth: () => ({getUser: async owner => {
    assert.equal(owner, UID);
    throw Object.assign(new Error('synthetic absent'), {code: 'auth/user-not-found'});
  }})};
const indexPath = require.resolve('../index'); delete require.cache[indexPath];
const trigger = require('../index').cleanupUserData;
require.cache[adminPath].exports = originalAdmin;
const circles = require('../circle_cleanup');
function guarded(state = 'IN_PROGRESS') {
  return {version: 1, state, deletionId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    startedAt: CLOCK, retainUntil: state === 'COMPLETE' ? Timestamp.now() : null};
}
async function admitCleanupGuard(f) {
  const user = {uid: UID, metadata: {creationTime: CREATED.toDate().toUTCString()}};
  const event = {eventId: 'synthetic-delete', eventType: 'google.firebase.auth.user.delete',
    timestamp: new Date().toISOString(), resource: {service: 'firebaseauth.googleapis.com',
      name: 'projects/demo-life-os-p1'}};
  const admission = await fixtureBirthCleanup.prepare(f.db, user, event, async () => {
    throw Object.assign(new Error('synthetic absent'), {code: 'auth/user-not-found'});
  });
  f.preparationWrites = [...f.db.writes];
  f.preparedAdmission = admission;
  return admission.guard;
}
async function admitCompletedGuard(f) {
  await admitCleanupGuard(f);
  // This fixture is intentionally empty for the target UID. Use the actual
  // terminal proof/finalization; never construct a COMPLETE receipt by hand.
  await fixtureBirthCleanup.finish(f.db, f.preparedAdmission);
  f.preparationWrites = [...f.db.writes];
  f.db.writes.length = 0; // From here the oracle observes only the two replays.
  return copy(f.db.docs.get(G));
}
const hash = createHash('sha256').update(UID).digest('hex');
const B = 'billing_google_accounts/' + hash;
function fixture({root = true, birth = true} = {}) {
  const db = new FakeFirestore();
  if (root) db.put(ROOT, {activeCircleId: null});
  if (birth) db.put(L, ledger());
  db.put('users/' + OTHER, {private: 'untouched'});
  db.put('account_birth_decisions/' + OTHER, ledger(OTHER));
  return {db};
}
function call(f, label = 'functions') {
  active = f;
  return context.run(label, () => trigger.run({uid: UID,
    metadata: {creationTime: CREATED.toDate().toUTCString()}}, {
    eventId: 'synthetic-delete', eventType: 'google.firebase.auth.user.delete',
    timestamp: new Date().toISOString(),
    resource: {service: 'firebaseauth.googleapis.com', name: 'projects/demo-life-os-p1'}, params: {},
  }));
}
function integral(f) {
  assert.equal(f.db.docs.has(ROOT), false); assert.equal(f.db.docs.has(L), false);
  assert.equal(f.db.docs.get(G).state, 'COMPLETE'); assert.equal(f.db.docs.has(B), false);
  assert.equal([...f.db.docs.keys()].some(p => p.startsWith(ROOT + '/')), false);
  assert.deepEqual(f.db.docs.get('users/' + OTHER), {private: 'untouched'});
  assert.deepEqual(f.db.docs.get('account_birth_decisions/' + OTHER), ledger(OTHER));
}
for (const root of [true, false]) for (const birth of [true, false]) {
  test('R2 real onDelete fences delayed Billing (root=' + root + ',ledger=' + birth + ')',
    {timeout: 10000}, async () => {
      const f = fixture({root, birth}), firstGate = gate(), staleGate = gate();
      let firstHeld = false, secondHeld = false, lateWrites = 0;
      f.db.hooks.beforeCommit = async a => {
        if (a.label === 'first' && !firstHeld && a.pending.some(w => w.ref.path === B && w.type === 'set')) {
          firstHeld = true; await firstGate.hold();
        }
        if (a.label === 'second' && !secondHeld && a.pending.some(w => w.ref.path === B && w.type === 'set')) {
          secondHeld = true; await staleGate.hold();
        }
      };
      f.db.hooks.afterCommit = a => {
        if (a.label === 'second' && f.db.docs.get(G)?.state === 'COMPLETE' &&
          a.pending.some(w => w.ref.path === B && w.type !== 'delete')) {
          lateWrites++; throw new Error('COMMITTED_REPLY_LOST');
        }
      };
      const first = call(f, 'first');
      await firstGate.reached;
      const second = call(f, 'second');
      await staleGate.reached; firstGate.release(); await first;
      const g = f.db.docs.get(G); staleGate.release(); await second;
      assert.equal(lateWrites, 0); assert.ok(f.db.conflicts.some(c => c.label === 'second'));
      assert.deepEqual(f.db.docs.get(G), g); integral(f);
    });
}
test('R2 real onDelete empty COMPLETE is read-only including duplicates', async () => {
  const f = fixture({root: false, birth: false}); const g = await admitCompletedGuard(f);
  await call(f); await call(f); integral(f);
  assert.deepEqual(f.db.docs.get(G), g); assert.equal(f.db.writes.length, 0);
  assert.deepEqual(f.db.recursiveDeletes, []);
});
for (const [name, path, data] of [
  ['Billing', B, {uid: UID, state: 'DELETING'}],
  ['runtime', ROOT + '/runtime/account_deletion', {deletionId: guarded().deletionId}],
  ['orphan', ROOT + '/unknown/missing/nested/private', {pii: 'synthetic'}],
  ['tokens', 'billing_google_tokens/residue', {accountHash: hash}],
  ['membership', 'circles/shared/members/' + UID, {role: 'member'}],
  ['marker', 'circle_deletions/residue', {memberUids: [UID]}],
]) test('R2 real onDelete refuses historical COMPLETE with ' + name, async () => {
  const f = fixture({root: false, birth: false}); f.db.put(G, guarded('COMPLETE')); f.db.put(path, data);
  const before = [...f.db.docs];
  await assert.rejects(call(f), {message: 'USER_DATA_CLEANUP_FAILED'});
  assert.deepEqual([...f.db.docs], before); assert.equal(f.db.writes.length, 0);
  assert.deepEqual(f.db.recursiveDeletes, []);
});
for (const lost of [false, true]) test('R2 real onDelete recovers Billing ' + (lost ? 'lost reply after commit' : 'failure before commit'), async () => {
  const f = fixture(); let failed = false;
  f.db.hooks[lost ? 'afterCommit' : 'beforeCommit'] = a => {
    if (!failed && a.pending.some(w => w.ref.path === B && w.type === 'set')) {
      failed = true; throw new Error('synthetic transport failure');
    }
  };
  await assert.rejects(call(f), {message: 'USER_DATA_CLEANUP_FAILED'});
  assert.equal(f.db.docs.get(G).state, 'IN_PROGRESS');
  assert.equal(f.db.docs.has(B), lost); assert.ok(f.db.docs.has(L));
  await call(f); integral(f);
});
for (const operation of ['owned marker', 'closure reservation', 'member link', 'history anonymization']) {
  test('R2 real Circles cleanup cannot write ' + operation + ' after COMPLETE', async (t) => {
    const f = fixture({root: false, birth: false}); const g = await admitCleanupGuard(f);
    const db = circles.withActiveGuard(f.db, UID, g), ready = gate(); let held = false;
    const target = operation === 'owned marker' ? 'circle_deletions/owned' :
      operation === 'closure reservation' ? 'circle_cleanup_guards/owned' :
      operation === 'member link' ? 'users/' + OTHER : 'circles/shared/challenges/old';
    let cleanup;
    if (operation === 'owned marker') {
      f.db.put('circles/owned', {schemaVersion: 2, adminId: UID, memberLimit: 3, memberCount: 1});
      f.db.put('circles/owned/members/' + UID, {role: 'admin'});
      cleanup = () => circles.cleanupOwned(db, UID, g, true);
    } else if (operation === 'history anonymization') {
      f.db.put(target, {createdBy: UID});
      cleanup = () => circles.cleanupHistory(db, UID, g);
    } else {
      f.db.put('circles/owned', {schemaVersion: 2, adminId: UID, memberLimit: 3,
        memberCount: 2, deletionState: 'SERVER_DELETING'});
      f.db.put('circle_deletions/owned', {version: 1, state: 'SERVER_DELETING', circleId: 'owned',
        initiatedBy: UID, memberUids: [UID, OTHER], createdAt: CLOCK});
      if (operation === 'member link') f.db.put('users/' + OTHER, {private: 'untouched', activeCircleId: 'owned'});
      cleanup = () => circles.cleanupPendingMarkers(db, UID, g);
    }
    f.db.hooks.beforeCommit = async a => {
      if (!held && a.label === 'stale' && a.pending.some(w => w.ref.path === target)) {
        held = true; await ready.hold();
      }
    };
    const stale = context.run('stale', cleanup).then(() => null, e => e);
    await ready.reached;
    const receipt = f.db.docs.get(G + '/control/operation');
    const retired = f.db.docs.get('retired_auth_identities/' + UID);
    assert.equal(receipt.state, 'IN_PROGRESS');
    const writesBefore = f.db.writes.length, nativeBefore = [...f.db.recursiveDeletes];
    f.db.put(G, {...g, state: 'COMPLETE', retainUntil: Timestamp.now()});
    const before = [...f.db.docs]; ready.release();
    assert.equal((await stale).code, 'ACCOUNT_STATE_CONFLICT');
    assert.equal(held, true);
    assert.deepEqual(f.db.docs.get(G + '/control/operation'), receipt);
    assert.deepEqual(f.db.docs.get('retired_auth_identities/' + UID), retired);
    assert.equal(f.db.writes.length, writesBefore);
    assert.deepEqual(f.db.recursiveDeletes, nativeBefore);
    t.diagnostic(JSON.stringify({historicalR5Evidence: true, operation, target, held,
      conflicts: f.db.conflicts.length, guard: f.db.docs.get(G).state, receipt: receipt.state,
      deletionId: receipt.deletionId, scope: receipt.scope, extraWrites: f.db.writes.length - writesBefore}));
    assert.deepEqual([...f.db.docs], before); assert.ok(f.db.conflicts.length);
  });
}

test('R2 onDelete sentinel alone never authorizes terminal success', async () => {
  const f = fixture(); let injected = false;
  f.db.hooks.beforeCommit = attempt => {
    if (!injected && attempt.pending.some(w => w.ref.path === B && w.type === 'set')) {
      injected = true;
      throw Object.assign(new Error('synthetic unproven sentinel'), {code: 'ACCOUNT_CLEANUP_COMPLETE'});
    }
  };
  await assert.rejects(call(f), {message: 'USER_DATA_CLEANUP_FAILED'});
  assert.equal(injected, true); assert.equal(f.db.docs.get(G).state, 'IN_PROGRESS');
  assert.ok(f.db.docs.has(ROOT)); assert.ok(f.db.docs.has(L)); assert.equal(f.db.docs.has(B), false);
});
