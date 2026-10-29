const r5core = require("../deletion_control");
const {Timestamp} = require("firebase-admin/firestore");
const assert = require("node:assert/strict");
const test = require("node:test");
const {MAX_CIRCLE_CHALLENGES, inspectCircle, backfillCircle, backfillCircles, parseArgs, runCli} =
  require("../scripts/backfill-circle-challenge-count");

const legacy = () => ({schemaVersion: 2, adminId: "admin", memberCount: 1,
  memberLimit: 3, updatedAt: "unchanged"});

function fixture(count, root = legacy()) {
  const children = Array.from({length: count}, (_, index) => ({id: `c-${index}`,
    data: () => ({endAt: new Date(0), schemaVersion: index % 2 ? 1 : 2})}));
  const collection = {get: async () => ({size: children.length, docs: children})};
  const ref = {id: "circle", get path() {return "circles/" + this.id;},
    get: async () => ({ref, exists: true, data: () => root}),
    collection: (name) => {
      if (name === "members") return {doc: id => reference(ref.path + "/members/" + id)};
      assert.equal(name, "challenges");
      return collection;
    }};
  const writes = [];
  function reference(path) {
    if (path === ref.path) return ref;
    const value = path === ref.path + '/members/admin' ? {role: 'admin'} : undefined;
    const result = {path, id: path.split('/').at(-1), collection: name => ({doc: id => reference(path + '/' + name + '/' + id)}),
      get: async () => ({ref: result, exists: value !== undefined, data: () => value})};
    return result;
  }
  const db = {doc: reference, runTransaction: async (callback) => callback({
    get: (target) => target.get(),
    update: (target, patch) => {
      assert.equal(target, ref);
      writes.push(patch);
      Object.assign(root, patch);
    },
    delete: () => assert.fail("No deletions allowed"),
  })};
  return {db, ref, root, writes, children};
}

test("CLI defaults to dry-run and requires explicit project; apply is explicit", () => {
  assert.deepEqual(parseArgs(["--project", "demo-life-os"]), {apply: false, projectId: "demo-life-os"});
  assert.deepEqual(parseArgs(["--apply", "--project", "demo-life-os"]), {apply: true, projectId: "demo-life-os"});
  assert.throws(() => parseArgs([]));
  assert.throws(() => parseArgs(["--project", "demo-life-os", "--unknown"]));
  assert.equal(MAX_CIRCLE_CHALLENGES, 240);
});

for (const count of [0, 7, 240]) {
  test(`dry-run counts all ${count} Challenges, including expired and legacy`, async () => {
    const f = fixture(count);
    const original = {...f.root};
    const result = await backfillCircle(f.db, f.ref);
    assert.deepEqual(result, {status: "CANDIDATE", actualCount: count,
      patch: {challengeCount: count, lastChallengeId: null}});
    assert.deepEqual(f.writes, []);
    assert.deepEqual(f.root, original);
    assert.equal(f.children.length, count);
  });
  test(`apply ${count} updates only metadata and second dry-run is unchanged`, async () => {
    const f = fixture(count);
    const original = {...f.root};
    const children = [...f.children];
    assert.equal((await backfillCircle(f.db, f.ref, {apply: true})).status, "APPLIED");
    assert.deepEqual(f.writes, [{challengeCount: count, lastChallengeId: null}]);
    assert.deepEqual(f.root, {...original, challengeCount: count, lastChallengeId: null});
    assert.deepEqual(f.children, children);
    assert.equal((await backfillCircle(f.db, f.ref)).status, "UNCHANGED");
    assert.equal((await backfillCircle(f.db, f.ref, {apply: true})).status, "UNCHANGED");
    assert.equal(f.writes.length, 1);
  });
}

test("241 documents reports OVER_LIMIT in dry-run and apply without writes or truncation", async () => {
  const f = fixture(241);
  const original = {...f.root};
  for (const apply of [false, true]) {
    assert.deepEqual(await backfillCircle(f.db, f.ref, {apply}), {status: "OVER_LIMIT", actualCount: 241});
  }
  assert.deepEqual(f.root, original);
  assert.deepEqual(f.writes, []);
  assert.equal(f.children.length, 241);
});

for (const [label, fields] of [
  ["partial count", {challengeCount: 0}], ["partial last ID", {lastChallengeId: null}],
  ["divergent count", {challengeCount: 1, lastChallengeId: null}],
  ...[null, "0", -1, 0.5, 241].map(value => [`invalid count ${value}`, {challengeCount: value, lastChallengeId: null}]),
  ...["", " bad ", "x".repeat(129), "bad/id", 7].map(value => [`invalid last ID ${value}`, {challengeCount: 0, lastChallengeId: value}]),
  ["invalid schema", {schemaVersion: 1}],
]) {
  test(`${label} reports CONFLICT without overwriting`, async () => {
    const f = fixture(0, {...legacy(), ...fields});
    const original = {...f.root};
    assert.equal((await backfillCircle(f.db, f.ref, {apply: true})).status, "CONFLICT");
    assert.deepEqual(f.root, original);
    assert.deepEqual(f.writes, []);
  });
}

test("consistent existing fields with a valid last ID remain unchanged", () => {
  assert.equal(inspectCircle({...legacy(), challengeCount: 2, lastChallengeId: "last-id"}, 2).status, "UNCHANGED");
});

test("apply rechecks state inside transaction instead of overwriting a raced migration", async () => {
  const f = fixture(0);
  const run = f.db.runTransaction;
  f.db.runTransaction = (callback) => {
    Object.assign(f.root, {challengeCount: 1, lastChallengeId: "other"});
    return run(callback);
  };
  assert.equal((await backfillCircle(f.db, f.ref, {apply: true})).status, "CONFLICT");
  assert.deepEqual(f.writes, []);
});

test("runner paginates Circles and reports each result without implicit writes", async () => {
  const first = fixture(0);
  const second = fixture(241);
  second.ref.id = "over-limit";
  const firstDoc = first.db.doc;
  first.db.doc = path => path.startsWith(second.ref.path) ? second.db.doc(path) : firstDoc(path);
  let cursor;
  let pages = 0;
  first.db.collection = name => {
    assert.equal(name, "circles");
    const query = {
      orderBy: () => query,
      limit: value => {assert.equal(value, 200); return query;},
      startAfter: value => {cursor = value; return query;},
      get: async () => {
        pages++;
        return cursor ? {empty: true, docs: []} : {empty: false, docs: [
          {id: first.ref.id, ref: first.ref}, {id: second.ref.id, ref: second.ref},
        ]};
      },
    };
    return query;
  };
  const results = await backfillCircles(first.db);
  assert.deepEqual(results.map(result => result.status), ["CANDIDATE", "OVER_LIMIT"]);
  assert.equal(pages, 2);
  assert.deepEqual(first.writes, []);
  assert.deepEqual(second.writes, []);
});

function cliFixture(count, root = legacy()) {
  const f = fixture(count, root);
  f.db.collection = (name) => {
    assert.equal(name, "circles");
    let after;
    const query = {
      orderBy: () => query,
      limit: (value) => {assert.equal(value, 200); return query;},
      startAfter: (value) => {after = value; return query;},
      get: async () => after ? {empty: true, docs: []} :
        {empty: false, docs: [{id: f.ref.id, ref: f.ref}]},
    };
    return query;
  };
  return f;
}

test("importing the CLI does not load or initialize Firebase Admin", (t) => {
  const Module = require("node:module");
  const originalLoad = Module._load;
  const path = require.resolve("../scripts/backfill-circle-challenge-count");
  const cached = require.cache[path];
  t.mock.method(Module, "_load", function(request, ...args) {
    if (request === "firebase-admin" || request.startsWith("firebase-admin/")) {
      assert.fail("Import must not load Firebase Admin");
    }
    return originalLoad.call(this, request, ...args);
  });
  delete require.cache[path];
  try {
    assert.equal(typeof require(path).runCli, "function");
  } finally {
    require.cache[path] = cached;
  }
});

test("CLI modular bootstrap passes its Firestore to the real dry-run flow", async (t) => {
  const Module = require("node:module");
  const originalLoad = Module._load;
  const f = cliFixture(7);
  const events = [];
  const output = [];
  t.mock.method(Module, "_load", function(request, ...args) {
    if (request === "firebase-admin") assert.fail("Legacy Admin API must not be used");
    if (request === "firebase-admin/app") {
      return {initializeApp: (options) => events.push(["initializeApp", options])};
    }
    if (request === "firebase-admin/firestore") {
      return {
        getFirestore: () => {events.push(["getFirestore"]); return f.db;},
        FieldPath: {documentId: () => "documentId"},
      };
    }
    return originalLoad.call(this, request, ...args);
  });
  assert.equal(await runCli(["--project", "demo-life-os"], {log: (value) => output.push(JSON.parse(value))}), 0);
  assert.deepEqual(events, [["initializeApp", {projectId: "demo-life-os"}], ["getFirestore"]]);
  assert.deepEqual(output, [{mode: "DRY_RUN", results: [{circleId: "circle", status: "CANDIDATE",
    actualCount: 7, patch: {challengeCount: 7, lastChallengeId: null}}]}]);
  assert.deepEqual(f.writes, []);
});

test("CLI rejects a missing project before initializing Firebase", async () => {
  await assert.rejects(runCli([], {
    initializeApp: () => assert.fail("Must not initialize without project"),
    getFirestore: () => assert.fail("Must not get Firestore without project"),
  }), /An explicit --project PROJECT_ID is required/);
});

test("CLI writes only with explicit apply using an injected in-memory Firestore", async () => {
  const f = cliFixture(7);
  const output = [];
  assert.equal(await runCli(["--project", "demo-life-os", "--apply"], {
    initializeApp: () => {}, getFirestore: () => f.db,
    log: (value) => output.push(JSON.parse(value)),
  }), 0);
  assert.equal(output[0].mode, "APPLY");
  assert.equal(output[0].results[0].status, "APPLIED");
  assert.deepEqual(f.writes, [{challengeCount: 7, lastChallengeId: null}]);
});

for (const [status, count, root, exitCode] of [
  ["UNCHANGED", 0, {...legacy(), challengeCount: 0, lastChallengeId: null}, 0],
  ["CONFLICT", 0, {...legacy(), challengeCount: 1, lastChallengeId: null}, 1],
  ["OVER_LIMIT", 241, legacy(), 1],
]) {
  test(`CLI preserves ${status} exit code ${exitCode} without writes`, async () => {
    const f = cliFixture(count, {...root});
    const original = {...f.root};
    const output = [];
    assert.equal(await runCli(["--project", "demo-life-os"], {
      initializeApp: () => {}, getFirestore: () => f.db,
      log: (value) => output.push(JSON.parse(value)),
    }), exitCode);
    assert.equal(output[0].results[0].status, status);
    assert.deepEqual(f.writes, []);
    assert.deepEqual(f.root, original);
  });
}

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

const invokeMaintenance = async(f,kind,apply) => backfillCircle(f.db,f.db.doc(f.target),{apply});
for (const kind of ["challenges"]) {
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

test('R6C3 challenges: UID absent/divergent, retired CLI and unreadable closure never apply',async()=>{
  for(const adminId of [null,' bad ','other']){
    const f=seedMaintenance('challenges');f.db.put(f.target,{schemaVersion:2,adminId});const before=new Map(f.db.store);
    assert.equal((await invokeMaintenance(f,'challenges',true)).status,'CONFLICT');assert.deepEqual(f.db.store,before);
  }
  const f=seedMaintenance('challenges');await reserveReal(f.db,f.uid);const before=new Map(f.db.store);
  assert.equal(await runCli(['--project','demo-life-os-p1','--apply'],{initializeApp:()=>{},getFirestore:()=>f.db,log:()=>{}}),1);
  assert.deepEqual(f.db.store,before);
  f.db.failRead='circle_cleanup_guards/circle';
  // Use a fresh active fixture: a retired skip needs no Circle authorization.
  const active=seedMaintenance('challenges');active.db.failRead='circle_cleanup_guards/circle';
  await assert.rejects(invokeMaintenance(active,'challenges',true),{message:'Circle challenge-count backfill failed closed.'});
});
test('R6C3 challenges: query phantom and owner change trigger fresh validation',async()=>{
  const f=seedMaintenance('challenges');let changed=false;
  f.db.beforeCommit=row=>{if(!changed&&row.pending.length){changed=true;f.db.put('circles/circle/challenges/two',{schemaVersion:1});}};
  await invokeMaintenance(f,'challenges',true);assert.equal(f.db.store.get(f.target).challengeCount,2);assert.equal(f.db.conflicts.length,1);
  const other=seedMaintenance('challenges');let moved=false;
  other.db.beforeCommit=row=>{if(!moved&&row.pending.length){moved=true;other.db.put(other.target,{schemaVersion:2,adminId:'other'});}};
  assert.equal((await invokeMaintenance(other,'challenges',true)).status,'CONFLICT');assert.equal(other.db.store.get(other.target).challengeCount,undefined);
});

for (const kind of ["challenges"]) {
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
