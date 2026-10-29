const r5core = require("../deletion_control");
const {Timestamp} = require("firebase-admin/firestore");
const assert = require("node:assert/strict");
const test = require("node:test");
const {cleanupProgress, cleanupOrphanProgress, parseArgs, runCli} = require("../scripts/cleanup-orphan-circle-progress");

const path = "circles/circle/challenges/challenge/progress/former";
function fixture(extra = {}) {
  const store = new Map(Object.entries({
    "circles/circle": {schemaVersion: 2, adminId: "admin"},
    "circles/circle/members/admin": {role: "admin"},
    "circles/circle/challenges/challenge": {schemaVersion: 2},
    [path]: {value: 4},
    "circles/circle/members/current": {role: "member"},
    "circles/circle/challenges/challenge/progress/current": {uid: "current", value: 8},
    "circles/circle/challenges/challenge/processed_events/old": {uid: "former"}, ...extra,
  }));
  const deletes = [];
  const db = {
    doc: key => ref(key),
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
      doc: id => ref(`${key}/${id}`), get: async () => ({ref: ref(key), exists: store.has(key), data: () => store.get(key)})};
  }
  return {db, store, deletes, ref: ref(path), reference: ref};
}
test("dry-run identifies legacy orphan by document ID and preserves current member and events", async () => {
  const f = fixture(); const before = new Map(f.store);
  assert.deepEqual(await cleanupOrphanProgress(f.db), {CANDIDATE: 1, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0, RETIRED: 0});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
});
test("apply deletes only validated orphan; second dry-run has zero candidates", async () => {
  const f = fixture(); const before = new Map(f.store);
  assert.deepEqual(await cleanupProgress(f.db, f.ref, {apply: true}), {status: "APPLIED"});
  assert.deepEqual(f.deletes, [path]);
  before.delete(path); assert.deepEqual(f.store, before);
  assert.deepEqual(await cleanupOrphanProgress(f.db), {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0, RETIRED: 0});
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
  assert.deepEqual(report, {mode: "DRY_RUN", counts: {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0, RETIRED: 0}});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
});

test("CLI dry-run with a candidate blocks rollout with nonzero exit code", async () => {
  const f = fixture(); const before = new Map(f.store);
  const {code, report} = await invokeCli(f);
  assert.notEqual(code, 0);
  assert.deepEqual(report, {mode: "DRY_RUN", counts: {CANDIDATE: 1, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0, RETIRED: 0}});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
});

test("CLI dry-run with a conflict returns nonzero without writes", async () => {
  const f = fixture({[path]: {value: "invalid"}}); const before = new Map(f.store);
  const {code, report} = await invokeCli(f);
  assert.notEqual(code, 0);
  assert.deepEqual(report, {mode: "DRY_RUN", counts: {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 1, APPLIED: 0, RETIRED: 0}});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, []);
});

test("CLI apply removes only validated candidate and reports counts without IDs", async () => {
  const f = fixture(); const before = new Map(f.store);
  const {code, report} = await invokeCli(f, ["--apply"]);
  assert.equal(code, 0);
  assert.deepEqual(report, {mode: "APPLY", counts: {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 0, APPLIED: 1, RETIRED: 0}});
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
  assert.deepEqual(report, {mode: "DRY_RUN", counts: {CANDIDATE: 0, UNCHANGED: 1, CONFLICT: 0, APPLIED: 0, RETIRED: 0}});
  assert.deepEqual(f.store, before); assert.deepEqual(f.deletes, [path]);
});

// Synthetic MVCC fixture: missing reads and collection ranges carry versions;
// updates are buffered and every callback retry gets a fresh snapshot.
class MaintenanceDb {
  projectId = 'demo-life-os-p1'; databaseId = '(default)';
  store = new Map(); versions = new Map(); attempts = []; commits = []; conflicts = [];
  failRead = null; ambiguousRead = null; beforeCommit = null; failCommit = null;
  put(path, data) {
    if (data === undefined) this.store.delete(path); else this.store.set(path, copyValue(data));
    for (const key of [path, 'q:' + path.slice(0, path.lastIndexOf('/'))]) this.versions.set(key, (this.versions.get(key) || 0) + 1);
  }
  doc(path) {
    const ref = {path, id: path.split('/').at(-1), collection: name => this.collection(path + '/' + name),
      get: async () => this.snapshot(ref, this.store)};
    for (const method of ['set', 'update', 'delete', 'create']) ref[method] = () => assert.fail('Direct writes forbidden');
    return ref;
  }
  collection(path, bound = Infinity, cursor = '') {
    const ref = {path, kind: 'query', doc: id => this.doc(path + '/' + id),
      orderBy: () => ref, limit: n => this.collection(path, n, cursor),
      startAfter: s => this.collection(path, bound, s.ref.path),
      count: () => ({...ref, kind: 'aggregate'}),
      get: async () => this.query(ref, this.store), bound, cursor};
    return ref;
  }
  collectionGroup(group, bound = Infinity, cursor = '') {
    const ref = {path: group, group, kind: 'query', bound, cursor,
      orderBy: () => ref, limit: n => this.collectionGroup(group, n, cursor),
      startAfter: s => this.collectionGroup(group, bound, s.ref.path), get: async () => this.query(ref, this.store)};
    return ref;
  }
  snapshot(ref, state) {return {ref, id: ref.id, exists: state.has(ref.path), data: () => copyValue(state.get(ref.path))};}
  query(ref, state) {
    const docs = [...state.keys()].sort().filter(p => (!ref.cursor || p > ref.cursor) &&
      (ref.group ? p.split('/').at(-2) === ref.group : p.startsWith(ref.path + '/') && !p.slice(ref.path.length + 1).includes('/')))
      .slice(0, ref.bound).map(p => this.snapshot(this.doc(p), state));
    return {docs, size: docs.length, empty: docs.length === 0};
  }
  async runTransaction(callback) {
    for (let attempt = 1; attempt <= 8; attempt++) {
      const state = new Map(this.store), versions = new Map(this.versions), reads = new Map(), pending = [];
      const row = {attempt, reads, pending}; this.attempts.push(row);
      const write = (type, ref, data) => pending.push({type, path: ref.path, data: copyValue(data)});
      const result = await callback({get: async ref => {
        assert.equal(pending.length, 0, 'reads must precede writes');
        const key = ref.kind ? 'q:' + ref.path : ref.path;
        reads.set(key, versions.get(key) || 0);
        if (ref.path === this.failRead) throw new Error('synthetic-private-key-token-path');
        if (ref.path === this.ambiguousRead) return {ref, exists: 'unknown', data: () => undefined};
        if (ref.kind === 'aggregate') return {data: () => ({count: this.query(ref, state).size})};
        return ref.kind ? this.query(ref, state) : this.snapshot(ref, state);
      }, create: (ref, data) => write('create', ref, data), update: (ref, data) => write('update', ref, data),
      delete: ref => write('delete', ref), set: (ref, data) => write('set', ref, data)});
      await this.beforeCommit?.(row);
      const changed = [...reads].filter(([key, version]) => (this.versions.get(key) || 0) !== version).map(([key]) => key);
      if (changed.length) {this.conflicts.push({...row, changed}); continue;}
      if (this.failCommit?.(row)) throw new Error('synthetic-private-commit-failure');
      for (const w of pending) {
        if (w.type === 'update') assert.ok(this.store.has(w.path), 'no upsert');
        if (w.type === 'create') assert.equal(this.store.has(w.path), false, 'no replace');
      }
      for (const w of pending) this.put(w.path, w.type === 'delete' ? undefined : w.type === 'update' ? {...this.store.get(w.path), ...w.data} : w.data);
      this.commits.push(row); return result;
    }
    throw new Error('synthetic-contention');
  }
}
function copyValue(value) {
  if (Array.isArray(value)) return value.map(copyValue);
  if (value && Object.getPrototypeOf(value) === Object.prototype) return Object.fromEntries(Object.entries(value).map(([k,v]) => [k,copyValue(v)]));
  return value;
}
const r5paths = uid => ['retired_auth_identities/' + uid, 'account_deletion_guards/' + uid,
  'account_deletion_guards/' + uid + '/control/operation'];
async function reserveReal(db, uid) {
  const binding = {projectId: db.projectId, databaseId: db.databaseId, uid};
  const controller = r5core.createController({db, binding, clock: () => Timestamp.fromMillis(1000),
    uuid: () => '12345678-1234-4234-8234-123456789abc',
    ports: {getAuthenticatedSubject: async () => binding, getAuthUser: async () => ({uid})}});
  const admission = await controller.admitBackend();
  assert.equal(admission.status, 'ADMITTED');
  return {controller, admission};
}
function seedMaintenance(kind) {
  const db = new MaintenanceDb(), uid = kind === 'challenges' ? 'admin' : 'target';
  db.put('users/' + uid, {updatedAt: 'original', marker: 'preserve'});
  db.put('users/B', {updatedAt: 'B', habitsCount: 99});
  db.put('users/B/habits/b', {keep: true});
  db.put('circles/circle', {schemaVersion: 2, adminId: 'admin'});
  db.put('circles/circle/members/admin', {role: 'admin'});
  db.put('circles/circle/challenges/challenge', {schemaVersion: 2});
  const target = kind === 'counts' ? 'users/' + uid : kind === 'challenges' ? 'circles/circle' :
    kind === 'ranking' ? 'circles/circle/ranking/' + uid : 'circles/circle/challenges/challenge/progress/' + uid;
  if (kind === 'counts') for (const col of ['habits','tasks','goals','subjects','medications','transactions']) db.put('users/' + uid + '/' + col + '/one', {keep: true});
  else if (kind !== 'challenges') db.put(target, {value: 4, untouched: 'keep'});
  db.put('circles/other', {schemaVersion: 2, adminId: 'B', keep: true});
  return {db,uid,target};
}
function storedControls(db,uid) {return r5paths(uid).map(p => [p,copyValue(db.store.get(p))]);}
const retirementCases = [
  ['PRE_AUTH',0,{version:2,state:'RESERVED',origin:'PRE_AUTH'}],
  ['AUTH_EVENT',0,{version:2,state:'RESERVED',origin:'AUTH_EVENT'}],
  ['IN_PROGRESS',1,{version:1,state:'IN_PROGRESS'}],
  ['COMPLETE',1,{version:1,state:'COMPLETE'}],
  ['expired guard',1,{version:1,state:'COMPLETE',retainUntil:Timestamp.fromMillis(1)}],
  ['parentless COMPLETE receipt',2,{version:1,state:'COMPLETE'}],
  ['REVIEW_REQUIRED',2,{version:1,state:'REVIEW_REQUIRED'}],
  ...[0,1,2].map(n => ['malformed ' + n,n,{version:999}]),
];

const invokeMaintenance = async(f,kind,apply) => cleanupProgress(f.db,f.db.doc(f.target),{apply});
for (const kind of ["orphan"]) {
  test('R6C3 ' + kind + ': active read set, idempotence, B and scope preserved', async t => {
    const f=seedMaintenance(kind), before=new Map(f.db.store);
    await invokeMaintenance(f,kind,true);
    const writes=f.db.commits.filter(r=>r.pending.length);
    assert.equal(writes.length,1); assert.equal(writes[0].pending.length,1);
    assert.equal(writes[0].pending[0].path,f.target);
    for(const p of r5paths(f.uid)) assert.ok(writes[0].reads.has(p),p);
    for(const [p,v] of before) if(p!==f.target) assert.deepEqual(f.db.store.get(p),v,p);
    assert.deepEqual(storedControls(f.db,f.uid),r5paths(f.uid).map(p=>[p,undefined]));
    await invokeMaintenance(f,kind,true);
    assert.equal(f.db.commits.filter(r=>r.pending.length).length,1);
    t.diagnostic(JSON.stringify({kind,evidence:'active',reads:[...writes[0].reads.keys()],writes:writes[0].pending.map(w=>w.path)}));
  });
  for(const [label,index,value] of retirementCases) test('R6C3 ' + kind + ': ' + label + ' denies without cleanup',async()=>{
    const f=seedMaintenance(kind); f.db.put(r5paths(f.uid)[index],value); const before=new Map(f.db.store);
    const result=await invokeMaintenance(f,kind,true);
    assert.match(JSON.stringify(result),/RETIRED|"retired":1/);
    assert.deepEqual(f.db.store,before);assert.equal(f.db.commits.some(r=>r.pending.length),false);
  });
  for(const field of ['failRead','ambiguousRead']) for(const index of [0,1,2]) test('R6C3 '+kind+': '+field+' control '+index+' is error, not retired skip',async()=>{
    const f=seedMaintenance(kind);f.db[field]=r5paths(f.uid)[index];const before=new Map(f.db.store);
    await assert.rejects(invokeMaintenance(f,kind,true),error=>!error.message.includes('synthetic-private'));
    assert.deepEqual(f.db.store,before);assert.equal(f.db.commits.length,0);
  });
  test('R6C3 '+kind+': presence cannot hide another unreadable control',async()=>{
    const f=seedMaintenance(kind);f.db.put(r5paths(f.uid)[0],{});f.db.failRead=r5paths(f.uid)[2];
    await assert.rejects(invokeMaintenance(f,kind,true));assert.equal(f.db.commits.length,0);
  });
  test('R6C3 '+kind+': dry-run reads but never writes',async()=>{
    const f=seedMaintenance(kind),before=new Map(f.db.store);await invokeMaintenance(f,kind,false);
    assert.deepEqual(f.db.store,before);assert.equal(f.db.commits.some(r=>r.pending.length),false);
  });
  test('R6C3 '+kind+': real controller wins before writer commit; retry rereads',async t=>{
    const f=seedMaintenance(kind);let reserved=false,original;
    f.db.beforeCommit=async row=>{if(reserved||!row.pending.some(w=>w.path===f.target))return;
      reserved=true;original=await reserveReal(f.db,f.uid);};
    const before=new Map(f.db.store);await invokeMaintenance(f,kind,true);
    assert.equal(reserved,true);assert.equal(f.db.conflicts.length,1);
    for(const p of r5paths(f.uid)) assert.ok(f.db.conflicts[0].changed.includes(p),p);
    for(const [p,v]of before)assert.deepEqual(f.db.store.get(p),v,p);
    assert.equal(f.db.commits.some(r=>r.pending.some(w=>w.path===f.target)),false);
    assert.ok(f.db.attempts.some(r=>r.attempt===2&&r5paths(f.uid).every(p=>r.reads.has(p))));
    const control=original.controller.originalOperation(original.admission.handle);
    assert.equal(control.scope.privateRoot,'users/'+f.uid);
    assert.equal(f.db.store.get(r5paths(f.uid)[2]).state,'IN_PROGRESS');
    t.diagnostic(JSON.stringify({kind,evidence:'real-R5-wins',conflicts:f.db.conflicts.map(r=>r.changed),commits:f.db.commits.map(r=>r.pending.map(w=>w.path))}));
  });
  test('R6C3 '+kind+': writer first, original reservation later, replay skips',async()=>{
    const f=seedMaintenance(kind);await invokeMaintenance(f,kind,true);const original=await reserveReal(f.db,f.uid);
    const operation=original.controller.originalOperation(original.admission.handle),before=new Map(f.db.store);
    await invokeMaintenance(f,kind,true);assert.deepEqual(f.db.store,before);
    assert.equal((await original.controller.admitBackend()).status,'RESUMED');
    assert.deepEqual(f.db.store.get(r5paths(f.uid)[2]),operation);
    assert.equal(f.db.commits.filter(r=>r.pending.some(w=>w.path===f.target)).length,1);
  });
  test('R6C3 '+kind+': target removed after read is never recreated',async()=>{
    const f=seedMaintenance(kind);let removed=false;
    f.db.beforeCommit=async row=>{if(!removed&&row.pending.some(w=>w.path===f.target)){removed=true;f.db.put(f.target,undefined);}};
    try {await invokeMaintenance(f,kind,true);}catch(error){assert.equal(error.message.includes('synthetic-private'),false);}
    assert.equal(removed,true);assert.equal(f.db.store.has(f.target),false);
    assert.equal(f.db.commits.some(r=>r.pending.some(w=>w.path===f.target)),false);
  });
  test('R6C3 '+kind+': failed commit preserves data; retry applies once',async()=>{
    const f=seedMaintenance(kind),before=new Map(f.db.store);
    f.db.failCommit=row=>row.pending.some(w=>w.path===f.target);
    await assert.rejects(invokeMaintenance(f,kind,true),error=>!error.message.includes('synthetic-private'));
    assert.deepEqual(f.db.store,before);f.db.failCommit=null;await invokeMaintenance(f,kind,true);
    assert.equal(f.db.commits.filter(r=>r.pending.some(w=>w.path===f.target)).length,1);
  });
  if(kind!=='counts') for(const [label,p,value]of [
    ['closed','circle_cleanup_guards/circle',{state:'SERVER_DELETING'}],
    ['incompatible marker','circle_deletions/circle',{state:'bad',circleId:'other'}],
    ['deletionState','circles/circle',{schemaVersion:2,adminId:'admin',deletionState:null}],
    ['missing owner','circles/circle',{schemaVersion:2}],
    ['owner mismatch','circles/circle/members/admin',{role:'member',uid:'other'}],
  ]) test('R6C3 '+kind+': '+label+' refuses without mutation',async()=>{
    const f=seedMaintenance(kind);f.db.put(p,value);const before=new Map(f.db.store);
    try{const result=await invokeMaintenance(f,kind,true);assert.match(JSON.stringify(result),/CONFLICT/);}catch(error){assert.equal(error.message.includes('synthetic-private'),false);}
    assert.deepEqual(f.db.store,before);assert.equal(f.db.commits.some(r=>r.pending.length),false);
  });
}

test('R6C3 orphan: importing CLI does not load Admin or run scan',t=>{
  const Module=require('node:module'),load=Module._load,key=require.resolve('../scripts/cleanup-orphan-circle-progress'),cached=require.cache[key];
  t.mock.method(Module,'_load',function(request,...args){if(request==='firebase-admin'||request.startsWith('firebase-admin/'))assert.fail('Unsafe import');return load.call(this,request,...args);});
  delete require.cache[key];try{assert.equal(typeof require(key).runCli,'function');}finally{require.cache[key]=cached;}
});
test('R6C3 orphan: retired residual is explicit and CLI cannot report clean success',async()=>{
  const f=seedMaintenance('orphan');await reserveReal(f.db,f.uid);const before=new Map(f.db.store),output=[];
  assert.equal(await runCli(['--project','demo-life-os-p1','--apply'],{initializeApp:()=>{},getFirestore:()=>f.db,log:v=>output.push(JSON.parse(v))}),1);
  assert.equal(output[0].counts.RETIRED,1);assert.equal(output[0].counts.APPLIED,0);assert.deepEqual(f.db.store,before);
});
test('R6C3 orphan: divergent UID, challenge closure and unreadable member preserve progress',async()=>{
  const f=seedMaintenance('orphan');f.db.put(f.target,{uid:'other',value:1});
  assert.equal((await invokeMaintenance(f,'orphan',true)).status,'CONFLICT');
  f.db.put(f.target,{value:1});f.db.put('circles/circle/challenges/challenge',{schemaVersion:2,deletionState:'closed'});
  assert.equal((await invokeMaintenance(f,'orphan',true)).status,'CONFLICT');
  f.db.put('circles/circle/challenges/challenge',{schemaVersion:2});f.db.failRead='circles/circle/members/target';
  await assert.rejects(invokeMaintenance(f,'orphan',true),{message:'Circle progress cleanup failed closed.'});assert.ok(f.db.store.has(f.target));
});
test('R6C3 orphan: membership and closure created before delete commit force retry',async()=>{
  for(const target of ['circles/circle/members/target','circle_cleanup_guards/circle']){
    const f=seedMaintenance('orphan');let changed=false;
    f.db.beforeCommit=row=>{if(!changed&&row.pending.length){changed=true;f.db.put(target,{role:'member',state:'SERVER_DELETING'});}};
    const result=await invokeMaintenance(f,'orphan',true);assert.ok(['UNCHANGED','CONFLICT'].includes(result.status));assert.equal(f.db.conflicts.length,1);assert.ok(f.db.store.has(f.target));
    assert.equal(f.db.commits.some(r=>r.pending.length),false);
  }
});

for (const kind of ["orphan"]) {
  for(const index of [0,1,2]) for(const bad of ['absent-with-data','wrong-path','present-without-data']) test('R6C3 '+kind+': '+bad+' snapshot '+index+' is indeterminate',async()=>{
    const f=seedMaintenance(kind),original=f.db.snapshot.bind(f.db),control=r5paths(f.uid)[index],before=new Map(f.db.store);
    f.db.snapshot=(ref,state)=>ref.path!==control?original(ref,state):{
      ref:bad==='wrong-path'?f.db.doc('retired_auth_identities/other'):ref,
      exists:bad==='present-without-data',data:()=>bad==='absent-with-data'?{}:undefined};
    await assert.rejects(invokeMaintenance(f,kind,true));assert.deepEqual(f.db.store,before);assert.equal(f.db.commits.length,0);
  });
  if(kind!=='counts'&&kind!=='orphan') for(const path of ['circle_deletions/circle','circle_cleanup_guards/circle','circles/circle/members/admin']) test('R6C3 '+kind+': Circle fence changes before commit '+path,async()=>{
    const f=seedMaintenance(kind);let changed=false;
    f.db.beforeCommit=row=>{if(!changed&&row.pending.some(w=>w.path===f.target)){changed=true;f.db.put(path,{state:'SERVER_DELETING',role:'member'});}};
    let result,error;try{result=await invokeMaintenance(f,kind,true);}catch(e){error=e;}
    if(!error)assert.equal(result.status,'CONFLICT');
    assert.equal(changed,true);assert.equal(f.db.conflicts.length,1);assert.equal(f.db.commits.some(r=>r.pending.some(w=>w.path===f.target)),false);
  });
}

test('R6C3 CLI: authorization failure is sanitized and never reports success',async()=>{
  await assert.rejects(runCli(['--project','demo-life-os-p1','--apply'],{initializeApp:()=>{throw Error('private-key token path');}}),{message:'Maintenance CLI failed closed.'});
});
