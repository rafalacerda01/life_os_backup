const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const {before, after, beforeEach, test} = require('node:test');
const {initializeTestEnvironment, assertSucceeds, assertFails} = require('@firebase/rules-unit-testing');
const {
  doc, collection, getDoc, getDocFromServer, getDocs, setDoc, updateDoc, deleteDoc,
  writeBatch, runTransaction, Timestamp, serverTimestamp, deleteField, increment,
  disableNetwork, enableNetwork,
} = require('firebase/firestore');

// Missing or non-local emulators are an error, never a skipped/production test.
const endpoint = process.env.FIRESTORE_EMULATOR_HOST;
assert.match(endpoint ?? '', /^(127\.0\.0\.1|localhost):\d+$/,
  'A loopback FIRESTORE_EMULATOR_HOST is required; use --project demo-life-os');
const [host, portText] = endpoint.split(':');
const port = Number(portText);
assert.ok(port > 0 && port <= 65535, 'Invalid Firestore Emulator port');
const PROJECT = 'demo-life-os';
const OWNER = 'water-owner';
const DAY = '2026-10-13';
const ROOT = `users/${OWNER}`;
const HEALTH = `${ROOT}/health_info/${DAY}`;
const MARKER = `${ROOT}/water_protocol/activation`;
const STATE = `${ROOT}/water_state/${DAY}`;
const RECEIPT = `${ROOT}/water_increment_receipts/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa`;
const GUARD = `account_deletion_guards/${OWNER}`;
const EPOCH = '11111111-1111-4111-8111-111111111111';
const date = () => Timestamp.fromMillis(1000);
const cycle = () => ({isEnabled: true, lastPeriodStart: '2026-10-01',
  cycleLengthDays: 28, periodLengthDays: 5});
const health = (water = 1000) => ({waterIntakeMl: water, mood: 'before',
  hasTakenPillToday: false, menstrualCycle: cycle(), date: date()});
const activation = (extra = {}) => ({protocolVersion: 2, epoch: EPOCH,
  status: 'ACTIVE', legacyWritesBlocked: true, ...extra});
let env;

before(async () => {
  env = await initializeTestEnvironment({projectId: PROJECT,
    firestore: {host, port, rules: readFileSync(resolve(__dirname, '../../firestore.rules'), 'utf8')}});
});
beforeEach(async () => {await env.clearFirestore();});
after(async () => {if (env) await env.cleanup();});
const dbFor = (uid = OWNER) => uid === null
  ? env.unauthenticatedContext().firestore() : env.authenticatedContext(uid).firestore();
async function seed(...entries) {
  // Privileged context is only used for local emulator fixtures.
  await env.withSecurityRulesDisabled(async context => {
    const batch = writeBatch(context.firestore());
    for (const [path, data] of entries) batch.set(doc(context.firestore(), path), data);
    await batch.commit();
  });
}
async function seedBarrier(data = activation()) {await seed([MARKER, data]);}
async function readHealth(db, path = HEALTH) {
  return (await getDocFromServer(doc(db, path))).data();
}
function deferred() {
  let resolve;
  const promise = new Promise(done => {resolve = done;});
  return {promise, resolve};
}

for (const water of [0, 250, 1000000]) {
  test(`V1 absent marker permits create water ${water}`, async () => {
    const db = dbFor();
    await assertSucceeds(setDoc(doc(db, HEALTH), health(water)));
    assert.equal((await readHealth(db)).waterIntakeMl, water);
  });
}
test('V1 absent marker permits absolute update and regression', async () => {
  await seed([HEALTH, health()]);
  const db = dbFor();
  await assertSucceeds(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1250}));
  assert.equal((await readHealth(db)).waterIntakeMl, 1250);
  await assertSucceeds(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1000}));
  assert.equal((await readHealth(db)).waterIntakeMl, 1000);
});
test('V1 absent marker preserves add, remove, replace and increment permissions', async () => {
  await seed([HEALTH, {mood: 'before', date: date()}]);
  const ref = doc(dbFor(), HEALTH);
  await assertSucceeds(updateDoc(ref, {waterIntakeMl: 250}));
  await assertSucceeds(updateDoc(ref, {waterIntakeMl: increment(250)}));
  await assertSucceeds(updateDoc(ref, {waterIntakeMl: deleteField()}));
  await assertSucceeds(setDoc(ref, health()));
  await assertSucceeds(setDoc(ref, {mood: 'replace', date: date()}));
});
for (const [label, value] of [['negative', -1], ['above cap', 1000001],
  ['string', '250'], ['null', null], ['fractional', 250.5]]) {
  for (const operation of ['create', 'update']) {
    test(`V1 ${operation} rejects ${label} water`, async () => {
      if (operation === 'update') await seed([HEALTH, health()]);
      const ref = doc(dbFor(), HEALTH);
      await assertFails(operation === 'create' ? setDoc(ref, health(value))
        : updateDoc(ref, {waterIntakeMl: value}));
    });
  }
}

const markers = [
  ['PREPARING', activation({status: 'PREPARING'})],
  ['ACTIVE', activation()],
  ['INACTIVE', activation({status: 'INACTIVE'})],
  ['unknown status', activation({status: 'UNKNOWN'})],
  ['empty', {}],
  ['malformed', {status: 42, epoch: null}],
  ['invalid epoch', activation({epoch: 'invalid'})],
  ['missing epoch', {protocolVersion: 2, status: 'ACTIVE', legacyWritesBlocked: true}],
  ['legacy flag false', activation({legacyWritesBlocked: false})],
  ['missing legacy flag', {protocolVersion: 2, epoch: EPOCH, status: 'ACTIVE'}],
  ['invalid legacy flag', activation({legacyWritesBlocked: 'true'})],
  ['unexpected fields', activation({extra: 'untrusted'})],
  ['wrong version', activation({protocolVersion: 1})],
];
for (const [label, marker] of markers) {
  test(`Barrier ${label} blocks water create including zero and all field mutations`, async () => {
    await seed([MARKER, marker], [HEALTH, health()],
      [`${HEALTH}-without-water`, {mood: 'before', date: date()}]);
    const db = dbFor();
    await assertFails(setDoc(doc(db, `${HEALTH}-zero`), health(0)));
    await assertFails(setDoc(doc(db, `${HEALTH}-new`), health(250)));
    await assertFails(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1250}));
    await assertFails(updateDoc(doc(db, HEALTH), {waterIntakeMl: deleteField()}));
    await assertFails(updateDoc(doc(db, `${HEALTH}-without-water`), {waterIntakeMl: 250}));
    // A malformed marker closes water, without blocking legitimate mood.
    await assertSucceeds(updateDoc(doc(db, HEALTH), {mood: 'after'}));
    assert.equal((await readHealth(db)).waterIntakeMl, 1000);
  });
}

for (const [label, initial, write] of [
  ['increase', health(), ref => updateDoc(ref, {waterIntakeMl: 1250})],
  ['regression', health(1250), ref => updateDoc(ref, {waterIntakeMl: 1000})],
  ['addition', {mood: 'before', date: date()}, ref => updateDoc(ref, {waterIntakeMl: 250})],
  ['deleteField', health(), ref => updateDoc(ref, {waterIntakeMl: deleteField()})],
  ['replace removing water', health(), ref => setDoc(ref, {mood: 'after', date: date()})],
  ['increment transform', health(), ref => updateDoc(ref, {waterIntakeMl: increment(250)})],
  ['set merge absolute', health(), ref => setDoc(ref, {waterIntakeMl: 1250}, {merge: true})],
]) {
  test(`ACTIVE rejects ${label} and preserves the complete original document`, async () => {
    await seed([MARKER, activation()], [HEALTH, initial]);
    const db = dbFor();
    await assertFails(write(doc(db, HEALTH)));
    assert.deepEqual(await readHealth(db), initial);
  });
}

const nonWaterFields = [
  ['mood', {mood: 'after'}],
  ['pill', {hasTakenPillToday: true}],
  ['cycle', {menstrualCycle: {...cycle(), cycleLengthDays: 30}}],
];
for (const hasBarrier of [false, true]) {
  for (const [label, fields] of nonWaterFields) {
    test(`${hasBarrier ? 'ACTIVE' : 'V1'} creates valid ${label} without water`, async () => {
      if (hasBarrier) await seedBarrier();
      const db = dbFor();
      await assertSucceeds(setDoc(doc(db, HEALTH), {...fields, date: date()}));
      assert.deepEqual(await readHealth(db), {...fields, date: date()});
    });
    test(`${hasBarrier ? 'ACTIVE' : 'V1'} updates ${label} preserving water and other fields`, async () => {
      await seed([HEALTH, health()]);
      if (hasBarrier) await seedBarrier();
      const db = dbFor();
      await assertSucceeds(updateDoc(doc(db, HEALTH), fields));
      assert.deepEqual(await readHealth(db), {...health(), ...fields});
    });
  }
  for (const [label, data] of [
    ['missing date', {mood: 'after'}],
    ['invalid date', {mood: 'after', date: '2026-10-13'}],
    ['date only', {date: date()}],
    ['extra field', {mood: 'after', date: date(), extra: true}],
    ['invalid mood', {mood: 42, date: date()}],
    ['invalid pill', {hasTakenPillToday: 'yes', date: date()}],
    ['invalid cycle', {menstrualCycle: {...cycle(), periodLengthDays: 40}, date: date()}],
  ]) {
    test(`${hasBarrier ? 'ACTIVE' : 'V1'} still rejects create schema ${label}`, async () => {
      if (hasBarrier) await seedBarrier();
      await assertFails(setDoc(doc(dbFor(), HEALTH), data));
    });
  }
  test(`${hasBarrier ? 'ACTIVE' : 'V1'} update validates the final non-water schema`, async () => {
    await seed([HEALTH, health()]);
    if (hasBarrier) await seedBarrier();
    const ref = doc(dbFor(), HEALTH);
    for (const invalid of [{date: deleteField()}, {mood: 42}, {hasTakenPillToday: null},
      {menstrualCycle: {...cycle(), cycleLengthDays: 0}}, {extra: true}]) {
      await assertFails(updateDoc(ref, invalid));
    }
  });
  test(`${hasBarrier ? 'ACTIVE' : 'V1'} still denies deletion of health document`, async () => {
    await seed([HEALTH, health()]);
    if (hasBarrier) await seedBarrier();
    await assertFails(deleteDoc(doc(dbFor(), HEALTH)));
  });
}
test('ACTIVE merge of non-water fields preserves full stored health state', async () => {
  await seed([HEALTH, health()], [MARKER, activation()]);
  const db = dbFor();
  await assertSucceeds(setDoc(doc(db, HEALTH), {mood: 'merge', date: date()}, {merge: true}));
  assert.deepEqual(await readHealth(db), {...health(), mood: 'merge'});
});
test('ACTIVE merge into absent document permits valid mood but denies water', async () => {
  await seedBarrier();
  const db = dbFor();
  await assertSucceeds(setDoc(doc(db, HEALTH), {mood: 'merge', date: date()}, {merge: true}));
  await assertFails(setDoc(doc(db, `${HEALTH}-new`), health(), {merge: true}));
});
for (const [label, write] of [
  ['update', ref => updateDoc(ref, {waterIntakeMl: 1000, mood: 'after'})],
  ['merge', ref => setDoc(ref, {waterIntakeMl: 1000, mood: 'after'}, {merge: true})],
  ['replacement', ref => setDoc(ref, {...health(), mood: 'after'})],
  ['zero increment', ref => updateDoc(ref, {waterIntakeMl: increment(0), mood: 'after'})],
]) {
  test(`ACTIVE identical water ${label} passes because final water is unchanged`, async () => {
    await seed([HEALTH, health()], [MARKER, activation()]);
    const db = dbFor();
    await assertSucceeds(write(doc(db, HEALTH)));
    assert.deepEqual(await readHealth(db), {...health(), mood: 'after'});
  });
}

const guards = [
  ['IN_PROGRESS', {state: 'IN_PROGRESS', retainUntil: null}, false],
  ['retained COMPLETE', {state: 'COMPLETE', retainUntil: Timestamp.fromMillis(Date.now() + 86400000)}, false],
  ['expired COMPLETE', {state: 'COMPLETE', retainUntil: Timestamp.fromMillis(1)}, true],
  ['empty malformed', {}, false],
  ['missing retention', {state: 'COMPLETE'}, false],
  ['invalid retention', {state: 'COMPLETE', retainUntil: 'expired'}, false],
];
for (const hasBarrier of [false, true]) {
  for (const [label, guard, canWrite] of guards) {
    test(`${hasBarrier ? 'ACTIVE' : 'V1'} preserves ${label} guard and owner reads`, async () => {
      await seed([GUARD, guard], [HEALTH, health()]);
      if (hasBarrier) await seedBarrier();
      const db = dbFor();
      const expectNonWater = canWrite ? assertSucceeds : assertFails;
      await expectNonWater(setDoc(doc(db, `${HEALTH}-mood`), {mood: 'new', date: date()}));
      await expectNonWater(updateDoc(doc(db, HEALTH), {hasTakenPillToday: true}));
      const expectWater = canWrite && !hasBarrier ? assertSucceeds : assertFails;
      await expectWater(setDoc(doc(db, `${HEALTH}-water`), health(250)));
      await expectWater(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1250}));
      await assertSucceeds(getDoc(doc(db, HEALTH)));
      await assertSucceeds(getDocs(collection(db, `${ROOT}/health_info`)));
    });
  }
  test(`${hasBarrier ? 'ACTIVE' : 'V1'} other UID guard and marker do not leak across accounts`, async () => {
    await seed(['account_deletion_guards/other', {state: 'IN_PROGRESS', retainUntil: null}],
      ['users/other/water_protocol/activation', activation()], [HEALTH, health()]);
    if (hasBarrier) await seedBarrier();
    const db = dbFor();
    await assertSucceeds(updateDoc(doc(db, HEALTH), {mood: 'after'}));
    await (hasBarrier ? assertFails : assertSucceeds)(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1250}));
  });
  for (const actor of ['other', null]) {
    test(`${hasBarrier ? 'ACTIVE' : 'V1'} rejects ${actor ?? 'unauthenticated'} health reads and writes`, async () => {
      await seed([HEALTH, health()]);
      if (hasBarrier) await seedBarrier();
      const db = dbFor(actor);
      await assertFails(setDoc(doc(db, `${HEALTH}-new`), health()));
      await assertFails(setDoc(doc(db, `${HEALTH}-mood`), {mood: 'new', date: date()}));
      await assertFails(updateDoc(doc(db, HEALTH), {mood: 'after'}));
      await assertFails(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1250}));
      await assertFails(getDoc(doc(db, HEALTH)));
      await assertFails(getDocs(collection(db, `${ROOT}/health_info`)));
    });
  }
}

for (const [label, path] of [['marker', MARKER], ['state', STATE], ['receipt', RECEIPT]]) {
  for (const actor of [OWNER, 'other', null]) {
    for (const operation of ['get', 'list', 'create', 'update', 'delete']) {
      test(`V2 ${label} ${operation} denied to ${actor ?? 'unauthenticated'} without wildcard bypass`, async () => {
        if (operation !== 'create') await seed([path, {fixture: true}]);
        const db = dbFor(actor);
        const ref = doc(db, path);
        const write = {
          get: () => getDoc(ref),
          list: () => getDocs(collection(db, path.slice(0, path.lastIndexOf('/')))),
          create: () => setDoc(ref, activation()),
          update: () => updateDoc(ref, {fixture: false}),
          delete: () => deleteDoc(ref),
        };
        await assertFails(write[operation]());
      });
    }
  }
}
test('Owner cannot replace marker or overwrite authoritative state/receipt', async () => {
  await seed([MARKER, activation()], [STATE, {waterIntakeMl: 1000}], [RECEIPT, {fixture: true}]);
  const db = dbFor();
  for (const path of [MARKER, STATE, RECEIPT]) {
    await assertFails(setDoc(doc(db, path), {waterIntakeMl: 0}));
  }
});
test('User root permissions do not authorize unknown V2 IDs or nested subcollections', async () => {
  await seed([ROOT, {displayName: 'Owner'}]);
  const db = dbFor();
  await assertSucceeds(getDoc(doc(db, ROOT)));
  for (const path of [`${ROOT}/water_protocol/other`, `${ROOT}/water_state/other`,
    `${ROOT}/water_increment_receipts/other`, `${MARKER}/nested/escape`]) {
    await assertFails(setDoc(doc(db, path), {waterIntakeMl: 250}));
    await assertFails(getDoc(doc(db, path)));
  }
});

test('Forbidden water plus valid mood batch rolls back both documents', async () => {
  const otherHealth = `${HEALTH}-other`;
  await seed([MARKER, activation()], [HEALTH, health()], [otherHealth, health()]);
  const db = dbFor();
  const batch = writeBatch(db);
  batch.update(doc(db, HEALTH), {waterIntakeMl: 1250});
  batch.update(doc(db, otherHealth), {mood: 'after'});
  await assertFails(batch.commit());
  assert.deepEqual(await readHealth(db), health());
  assert.deepEqual(await readHealth(db, otherHealth), health());
});
for (const action of ['delete', 'update', 'replace']) {
  test(`Batch cannot ${action} marker and write water atomically`, async () => {
    await seed([MARKER, activation()], [HEALTH, health()]);
    const db = dbFor();
    const batch = writeBatch(db);
    if (action === 'delete') batch.delete(doc(db, MARKER));
    if (action === 'update') batch.update(doc(db, MARKER), {status: 'INACTIVE'});
    if (action === 'replace') batch.set(doc(db, MARKER), {});
    batch.update(doc(db, HEALTH), {waterIntakeMl: 1250});
    await assertFails(batch.commit());
    assert.deepEqual(await readHealth(db), health());
    await assertFails(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1250}));
  });
}
for (const hasBarrier of [false, true]) {
  for (const hasExpiredGuard of [false, true]) {
    for (const size of [5, 30]) {
      test(`Rule access budget: ${size} health writes, barrier=${hasBarrier}, expired guard=${hasExpiredGuard}`, async () => {
        if (hasBarrier) await seedBarrier();
        if (hasExpiredGuard) await seed([GUARD, {state: 'COMPLETE', retainUntil: Timestamp.fromMillis(1)}]);
        const db = dbFor();
        const batch = writeBatch(db);
        for (let i = 0; i < size; i++) batch.set(doc(db, `${HEALTH}-${i}`),
          hasBarrier ? {mood: 'new', date: date()} : health(250));
        await assertSucceeds(batch.commit());
        const result = await getDocs(collection(db, `${ROOT}/health_info`));
        assert.equal(result.size, size);
      });
    }
  }
}
test('ACTIVE valid health updates work in a transaction', async () => {
  await seed([MARKER, activation()], [HEALTH, health()]);
  const db = dbFor();
  await assertSucceeds(runTransaction(db, async tx => {
    const ref = doc(db, HEALTH);
    assert.equal((await tx.get(ref)).data().waterIntakeMl, 1000);
    tx.update(ref, {mood: 'transaction', hasTakenPillToday: true});
  }));
  assert.deepEqual(await readHealth(db), {...health(), mood: 'transaction', hasTakenPillToday: true});
});
test('ACTIVE transaction changing water and mood is denied atomically', async () => {
  await seed([MARKER, activation()], [HEALTH, health()]);
  const db = dbFor();
  await assertFails(runTransaction(db, async tx => {
    const ref = doc(db, HEALTH);
    const total = (await tx.get(ref)).data().waterIntakeMl;
    tx.update(ref, {waterIntakeMl: total + 250, mood: 'transaction'});
  }));
  assert.deepEqual(await readHealth(db), health());
});

test('V1 commit before PREPARING is accepted, subsequent write is blocked', async () => {
  await seed([HEALTH, health()]);
  const db = dbFor();
  await assertSucceeds(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1250}));
  await seedBarrier(activation({status: 'PREPARING'}));
  await assertFails(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1500}));
  assert.equal((await readHealth(db)).waterIntakeMl, 1250);
});
test('V1 transaction started before PREPARING cannot commit water after marker fixture', async () => {
  await seed([HEALTH, health()]);
  const db = dbFor();
  const reached = deferred();
  const release = deferred();
  const transaction = runTransaction(db, async tx => {
    const ref = doc(db, HEALTH);
    const total = (await tx.get(ref)).data().waterIntakeMl;
    reached.resolve();
    await release.promise;
    tx.update(ref, {waterIntakeMl: total + 250});
  });
  const denied = assertFails(transaction);
  try {
    await reached.promise;
    await seedBarrier(activation({status: 'PREPARING'}));
  } finally {
    release.resolve();
  }
  await denied;
  assert.equal((await readHealth(db)).waterIntakeMl, 1000);
});
test('SDK offline water outbox queued before ACTIVE is denied on reconnect', async () => {
  await seed([HEALTH, health()]);
  const db = dbFor();
  await getDocFromServer(doc(db, HEALTH));
  await disableNetwork(db);
  const denied = assertFails(updateDoc(doc(db, HEALTH), {waterIntakeMl: 1250}));
  try {
    await seedBarrier();
  } finally {
    await enableNetwork(db);
  }
  await denied;
  assert.equal((await readHealth(db)).waterIntakeMl, 1000);
});

for (const hasBarrier of [false, true]) {
  test(`${hasBarrier ? 'ACTIVE' : 'V1'} preserves other modules allowed writes and private reads`, async () => {
    await seed([ROOT, {displayName: 'Before'}],
      [`${ROOT}/tasks/task`, {isCompleted: false}],
      [`${ROOT}/habits/habit`, {completedDates: []}],
      [`${ROOT}/goals/goal`, {currentValue: 0}],
      [`${ROOT}/subjects/subject`, {cardsToReview: 0, progress: 0, streakDays: 0}],
      [`${ROOT}/study_info/main`, {reviewQueue: 0}],
      [`${ROOT}/transactions/finance`, {amount: 10}],
      [`${ROOT}/medications/pill`, {name: 'Pill'}]);
    if (hasBarrier) await seedBarrier();
    const db = dbFor();
    const batch = writeBatch(db);
    batch.update(doc(db, ROOT), {displayName: 'After'});
    batch.update(doc(db, `${ROOT}/tasks/task`), {isCompleted: true});
    batch.update(doc(db, `${ROOT}/habits/habit`), {completedDates: [DAY]});
    batch.update(doc(db, `${ROOT}/goals/goal`), {currentValue: 3, lastReset: date()});
    batch.update(doc(db, `${ROOT}/subjects/subject`), {progress: 0.5});
    batch.update(doc(db, `${ROOT}/study_info/main`), {reviewQueue: 1});
    batch.set(doc(db, `${ROOT}/review_queue/review`),
      {subjectId: 'subject', question: 'Question', answer: 'Answer', createdAt: date()});
    batch.set(doc(db, `${ROOT}/checkins/checkin`),
      {energy: 3, focus: 2, motivation: 4, updatedAt: serverTimestamp()});
    batch.set(doc(db, `${ROOT}/focus_logs/log`),
      {targetId: 'subject', targetType: 'SUBJECT', durationSeconds: 60, timestamp: date()});
    batch.set(doc(db, `${ROOT}/privacy/ai_consent`),
      {accepted: true, userId: OWNER, consentVersion: '2.0', acceptedAt: serverTimestamp(),
        revokedAt: null, updatedAt: serverTimestamp(), source: 'life_os_app'});
    await assertSucceeds(batch.commit());
    for (const path of [ROOT, `${ROOT}/tasks/task`, `${ROOT}/habits/habit`,
      `${ROOT}/goals/goal`, `${ROOT}/subjects/subject`, `${ROOT}/study_info/main`,
      `${ROOT}/transactions/finance`, `${ROOT}/medications/pill`, `${ROOT}/privacy/ai_consent`]) {
      await assertSucceeds(getDoc(doc(db, path)));
      await assertFails(getDoc(doc(dbFor('other'), path)));
    }
    assert.equal((await getDoc(doc(db, `${ROOT}/tasks/task`))).data().isCompleted, true);
    assert.equal((await getDoc(doc(db, `${ROOT}/study_info/main`))).data().reviewQueue, 1);
  });
  test(`${hasBarrier ? 'ACTIVE' : 'V1'} preserves server-owned Finance/medication and module field restrictions`, async () => {
    await seed([`${ROOT}/transactions/finance`, {amount: 10}],
      [`${ROOT}/medications/pill`, {name: 'Pill'}],
      [`${ROOT}/tasks/task`, {isCompleted: false}],
      [`${ROOT}/habits/habit`, {completedDates: []}],
      [`${ROOT}/goals/goal`, {currentValue: 0}],
      [`${ROOT}/subjects/subject`, {progress: 0}],
      [`${ROOT}/study_info/main`, {reviewQueue: 0}]);
    if (hasBarrier) await seedBarrier();
    const db = dbFor();
    for (const path of [`${ROOT}/transactions/finance`, `${ROOT}/medications/pill`]) {
      await assertFails(setDoc(doc(db, `${path}-new`), {name: 'new'}));
      await assertFails(updateDoc(doc(db, path), {name: 'changed'}));
      await assertFails(deleteDoc(doc(db, path)));
    }
    for (const [path, fields] of [
      [`${ROOT}/tasks/task`, {title: 'forged'}],
      [`${ROOT}/habits/habit`, {title: 'forged'}],
      [`${ROOT}/goals/goal`, {currentValue: -1}],
      [`${ROOT}/subjects/subject`, {progress: 2}],
      [`${ROOT}/study_info/main`, {progress: 0.5}],
    ]) await assertFails(updateDoc(doc(db, path), fields));
  });
}
