// FUTURE functional tests. Never run without separately approved JVM isolation.
// Loopback alone is NOT evidence of that isolation. No emulator is launched here.
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const {test, before, beforeEach, after} = require('node:test');
const host = process.env.FIRESTORE_EMULATOR_HOST || '';
if (!/^(127\.0\.0\.1|localhost|\[::1\]):[1-9][0-9]{0,4}$/.test(host) ||
    Number(host.slice(host.lastIndexOf(':') + 1)) > 65535) {
  throw new Error('BLOCKED: explicit loopback Firestore Emulator required before SDK import');
}
const {initializeTestEnvironment, assertSucceeds, assertFails} = require('@firebase/rules-unit-testing');
const {doc, collection, getDoc, getDocFromServer, getDocs, setDoc, updateDoc,
  deleteDoc, deleteField, writeBatch, runTransaction, disableNetwork, enableNetwork,
  serverTimestamp, Timestamp, increment, arrayUnion, collectionGroup} = require('firebase/firestore');
let env;
const controls = uid => ['retired_auth_identities/' + uid, 'account_deletion_guards/' + uid,
  'account_deletion_guards/' + uid + '/control/operation'];
const dbFor = uid => env.authenticatedContext(uid, {email: 'same@example.test'}).firestore();
const profile = () => ({email: 'same@example.test', displayName: 'Synthetic', isPremium: false,
  photoUrl: null, xp: 0, level: 1, streak: 0, habitsCount: 0, tasksCount: 0,
  goalsCount: 0, subjectsCount: 0, medicationsCount: 0, transactionsCount: 0});
const health = () => ({waterIntakeMl: 0, date: Timestamp.fromMillis(1000), mood: 'before'});
async function seed(path, data) {
  await env.withSecurityRulesDisabled(c => setDoc(doc(c.firestore(), path), data));
}
async function trustedRead(path) {
  let data;
  await env.withSecurityRulesDisabled(async c => {
    data = (await getDocFromServer(doc(c.firestore(), path))).data();
  });
  return data;
}
async function retire(uid, index = 0, data = {}) {await seed(controls(uid)[index], data);}
async function seedCircle() {
  await seed('users/admin', {...profile(), activeCircleId: 'circle'});
  await seed('users/member', {...profile(), activeCircleId: null});
  await seed('circles/circle', {name: 'Synthetic', description: 'Synthetic circle', adminId: 'admin', memberCount: 1,
    memberLimit: 3, challengeCount: 0, lastChallengeId: null, schemaVersion: 2,
    createdAt: Timestamp.fromMillis(1), updatedAt: Timestamp.fromMillis(1)});
  await seed('circles/circle/members/admin', {role: 'admin', displayNameSnapshot: 'Admin',
    photoUrlSnapshot: null, joinedAt: Timestamp.fromMillis(1)});
}
function join() {
  const db = dbFor('member'), batch = writeBatch(db);
  batch.set(doc(db, 'circles/circle/members/member'), {role: 'member', displayNameSnapshot: 'Member',
    photoUrlSnapshot: null, joinedAt: serverTimestamp()});
  batch.update(doc(db, 'circles/circle'), {memberCount: increment(1), updatedAt: serverTimestamp()});
  batch.update(doc(db, 'users/member'), {activeCircleId: 'circle'});
  return batch.commit();
}
before(async () => {
  env = await initializeTestEnvironment({projectId: 'demo-life-os', firestore: {
    rules: readFileSync(resolve(__dirname, '../../firestore.rules'), 'utf8')}});
});
beforeEach(async () => {await env.clearFirestore();});
after(async () => {if (env) await env.cleanup();});

test('A active UID: own Free profile, permitted profile update and private Health', async () => {
  const db = dbFor('A');
  await assertSucceeds(setDoc(doc(db, 'users/A'), profile()));
  await assertSucceeds(updateDoc(doc(db, 'users/A'), {displayName: 'After'}));
  await assertSucceeds(setDoc(doc(db, 'users/A/health_info/main'), health()));
  assert.equal((await getDoc(doc(db, 'users/A'))).data().displayName, 'After');
  for (const path of controls('A')) assert.equal(await trustedRead(path), undefined);
});
test('B retired root cannot be recreated', async () => {
  await retire('A');
  await assertFails(setDoc(doc(dbFor('A'), 'users/A'), profile()));
  assert.equal(await trustedRead('users/A'), undefined);
});
test('C retired subcollection remains readable by owner and unchanged', async () => {
  await seed('users/A/health_info/main', health()); await retire('A');
  const ref = doc(dbFor('A'), 'users/A/health_info/main');
  await assertFails(updateDoc(ref, {mood: 'after'}));
  assert.deepEqual((await getDoc(ref)).data(), health());
});
for (const [letter, index, data] of [
  ['D', 1, {state: 'COMPLETE', retainUntil: Timestamp.fromMillis(1)}],
  ['E', 0, {version: 2, origin: 'PRE_AUTH', state: 'RESERVED'}],
  ['F', 2, {state: 'COMPLETE'}],
]) test(letter + ' isolated control denies writes, including expired guard and parentless receipt', async () => {
  await retire('A', index, data);
  await assertFails(setDoc(doc(dbFor('A'), 'users/A/health_info/main'), health()));
  assert.deepEqual(await trustedRead(controls('A')[index]), data);
  if (index === 2) assert.equal(await trustedRead(controls('A')[1]), undefined);
});
for (const index of [0, 1, 2]) test('G malformed control ' + index + ' denies by presence', async () => {
  await retire('A', index);
  await assertFails(setDoc(doc(dbFor('A'), 'users/A'), profile()));
  assert.deepEqual(await trustedRead(controls('A')[index]), {});
});
for (const [letter, uid] of [['H', 'member'], ['I', 'admin']]) {
  test(letter + ' retired ' + uid + ' blocks the original three-write join', async () => {
    await seedCircle(); await retire(uid);
    const before = await trustedRead('circles/circle');
    await assertFails(join());
    assert.deepEqual(await trustedRead('circles/circle'), before);
    assert.equal(await trustedRead('circles/circle/members/member'), undefined);
    assert.equal((await trustedRead('users/member')).activeCircleId, null);
  });
}
for (const closure of ['deletionState', 'circle_deletions/circle', 'circle_cleanup_guards/circle']) {
  test('J independent Circle closure ' + closure + ' denies timestamp and join', async () => {
    await seedCircle();
    if (closure === 'deletionState') {
      await seed('circles/circle', {...await trustedRead('circles/circle'), deletionState: 'CLOSED'});
    } else await seed(closure, {});
    const before = await trustedRead('circles/circle');
    await assertFails(updateDoc(doc(dbFor('admin'), 'circles/circle'), {updatedAt: serverTimestamp()}));
    await assertFails(join());
    assert.deepEqual(await trustedRead('circles/circle'), before);
  });
}
test('K active B remains independent of all A controls', async () => {
  for (const index of [0, 1, 2]) await retire('A', index);
  await assertSucceeds(setDoc(doc(dbFor('B'), 'users/B'), profile()));
  await assertSucceeds(setDoc(doc(dbFor('B'), 'users/B/health_info/main'), health()));
});
test('L cross-UID read and write remain denied', async () => {
  await seed('users/A', profile());
  await assertFails(getDoc(doc(dbFor('B'), 'users/A')));
  await assertFails(updateDoc(doc(dbFor('B'), 'users/A'), {displayName: 'B'}));
  assert.deepEqual(await trustedRead('users/A'), profile());
});
test('M mixed allowed/forbidden batch commits neither document', async () => {
  await seed('users/A', profile()); await seed('users/B', profile());
  const db = dbFor('A'), batch = writeBatch(db);
  batch.update(doc(db, 'users/A'), {displayName: 'After'});
  batch.update(doc(db, 'users/B'), {displayName: 'Intrusion'});
  await assertFails(batch.commit());
  assert.deepEqual(await trustedRead('users/A'), profile());
  assert.deepEqual(await trustedRead('users/B'), profile());
});
test('N real Client transaction paused against atomic synthetic controls; NOT the R5 controller', {timeout: 20000}, async () => {
  await seed('users/A', profile());
  let reached, release, paused = false;
  const atRead = new Promise(resolveRead => {reached = resolveRead;});
  const resume = new Promise(resolveResume => {release = resolveResume;});
  const timer = setTimeout(() => {reached(); release();}, 5000);
  const db = dbFor('A');
  const outcome = assertFails(runTransaction(db, async tx => {
    await tx.get(doc(db, 'users/A'));
    if (!paused) {paused = true; reached(); await resume;}
    tx.update(doc(db, 'users/A'), {displayName: 'After'});
  }));
  try {
    await atRead; assert.equal(paused, true, 'transaction must reach the barrier');
    await env.withSecurityRulesDisabled(async c => {
      const batch = writeBatch(c.firestore());
      for (const path of controls('A')) batch.set(doc(c.firestore(), path), {state: 'RESERVED'});
      await batch.commit();
    });
  } finally {release(); clearTimeout(timer);}
  await outcome;
  assert.deepEqual(await trustedRead('users/A'), profile());
  for (const path of controls('A')) assert.deepEqual(await trustedRead(path), {state: 'RESERVED'});
});
test('N inverse order: committed pre-admission mutation remains; later mutation denied', async () => {
  await seed('users/A', profile());
  const ref = doc(dbFor('A'), 'users/A');
  await assertSucceeds(updateDoc(ref, {displayName: 'Before admission'}));
  await retire('A');
  await assertFails(updateDoc(ref, {displayName: 'After admission'}));
  assert.equal((await trustedRead('users/A')).displayName, 'Before admission');
});
test('O queued offline mutation is rejected on reconnection after retirement', {timeout: 20000}, async () => {
  await seed('users/A', profile());
  const db = dbFor('A'), ref = doc(db, 'users/A');
  await getDocFromServer(ref); await disableNetwork(db);
  const outcome = assertFails(updateDoc(ref, {displayName: 'Offline'}));
  try {await retire('A');} finally {await enableNetwork(db);}
  await outcome;
  assert.deepEqual((await getDocFromServer(ref)).data(), profile());
});
for (const path of [...controls('A'), ...controls('A').map(p => p + '/private/data')]) {
  test('P administrative path ' + path + ' denies read/list/create/update/delete and atomic bypass', async () => {
    const db = dbFor('A'), ref = doc(db, path);
    await assertFails(setDoc(ref, {state: 'FORGED'}));
    await seed(path, {state: 'COMPLETE'});
    await assertFails(getDoc(ref));
    await assertFails(getDocs(collection(db, path.slice(0, path.lastIndexOf('/')))));
    await assertFails(updateDoc(ref, {state: 'FORGED'}));
    await assertFails(deleteDoc(ref));
    const batch = writeBatch(db);
    batch.delete(ref); batch.set(doc(db, 'users/A/health_info/main'), health());
    await assertFails(batch.commit());
    assert.deepEqual(await trustedRead(path), {state: 'COMPLETE'});
    assert.equal(await trustedRead('users/A/health_info/main'), undefined);
  });
}
test('Q same email, distinct UID: no recovery of old data or Premium', async () => {
  await seed('users/old', {...profile(), isPremium: true});
  await seed('users/old/health_info/main', health()); await retire('old');
  const db = dbFor('new');
  await assertSucceeds(setDoc(doc(db, 'users/new'), profile()));
  await assertFails(getDoc(doc(db, 'users/old')));
  await assertFails(getDoc(doc(db, 'users/old/health_info/main')));
  await assertFails(updateDoc(doc(db, 'users/old'), {displayName: 'New'}));
  assert.equal((await getDoc(doc(db, 'users/new'))).data().isPremium, false);
  assert.equal((await trustedRead('users/old')).isPremium, true);
});
for (const field of ['isPremium', 'premiumProvider', 'premiumProductId', 'premiumTier',
  'premiumBasePlanId', 'premiumSubscriptionState', 'premiumExpiresAt']) {
  test('R Client SDK cannot grant/change/remove authoritative Premium field ' + field, async () => {
    await seed('users/A', {...profile(), [field]: field === 'isPremium' ? false : 'original'});
    const db = dbFor('A'), ref = doc(db, 'users/A'), beforeData = await trustedRead('users/A');
    await assertFails(updateDoc(ref, {[field]: field === 'isPremium' ? true : 'FORGED'}));
    await assertFails(updateDoc(ref, {[field]: deleteField()}));
    assert.deepEqual(await trustedRead('users/A'), beforeData);
  });
}
for (const path of ['billing_purchase_tokens/token', 'billing_rtdn_events/event',
  'users/A/water_protocol/eligibility', 'users/A/medications/m', 'users/A/transactions/t',
  'users/A/study_progress_state/main', 'circles/circle/challenges/c/processed_events/e']) {
  test('R server-only path remains denied: ' + path, async () => {
    const db = dbFor('A'), ref = doc(db, path);
    await assertFails(setDoc(ref, {value: 'forged'})); await seed(path, {value: 'original'});
    await assertFails(updateDoc(ref, {value: 'forged'})); await assertFails(deleteDoc(ref));
    assert.deepEqual(await trustedRead(path), {value: 'original'});
  });
}

// R6C4-C FUTURE engine cases: prepared only, never executed in this round.
const reviewStudyPaths = uid => ({
  root: 'users/' + uid, info: 'users/' + uid + '/study_info/main',
  subject: 'users/' + uid + '/subjects/subject',
  card: 'users/' + uid + '/review_queue/card',
  receipt: 'users/' + uid + '/study_card_create_receipts/card',
});
const reviewSubject = () => ({title: 'Synthetic subject', cardsToReview: 2, progress: .2,
  streakDays: 3, hasExam: false, examDate: null});
const reviewCard = () => ({subjectId: 'subject', question: 'Synthetic Q', answer: 'Synthetic A', createdAt: Timestamp.fromMillis(1000)});
async function seedReviewStudy(uid = 'A') {
  const p = reviewStudyPaths(uid);
  await seed(p.root, profile());
  await seed(p.info, {reviewQueue: 2, progress: .2, streak: 3});
  await seed(p.subject, reviewSubject());
  await seed(p.card, reviewCard());
  return p;
}

for (const actor of ['active', 'retired', 'foreign', 'anonymous', 'premium-claim']) {
  test('C review create is server-only for ' + actor, async () => {
    const p = await seedReviewStudy();
    if (actor === 'retired') await retire('A');
    const db = actor === 'anonymous' ? env.unauthenticatedContext().firestore() :
      actor === 'premium-claim' ? env.authenticatedContext('A', {isPremium: true, email: 'same@example.test'}).firestore() :
      dbFor(actor === 'foreign' ? 'B' : 'A');
    const card = p.card + '-new';
    await assertFails(setDoc(doc(db, card), reviewCard()));
    assert.equal(await trustedRead(card), undefined);
    assert.equal((await trustedRead(p.info)).reviewQueue, 2);
    assert.equal((await trustedRead(p.subject)).cardsToReview, 2);
  });
}
for (const operation of ['update', 'delete', 'merge-update', 'overwrite']) {
  test('C existing review card forbids Client ' + operation, async () => {
    const p = await seedReviewStudy(), ref = doc(dbFor('A'), p.card), original = await trustedRead(p.card);
    await assertFails(operation === 'delete' ? deleteDoc(ref) :
      operation === 'update' ? updateDoc(ref, {question: 'Changed'}) :
      operation === 'merge-update' ? setDoc(ref, {question: 'Changed'}, {merge: true}) : setDoc(ref, {...reviewCard(), question: 'Changed'}));
    assert.deepEqual(await trustedRead(p.card), original);
  });
}
for (const [operation, action] of [
  ['increment', ref => updateDoc(ref, {reviewQueue: increment(1)})],
  ['decrement', ref => updateDoc(ref, {reviewQueue: increment(-1)})],
  ['absolute', ref => updateDoc(ref, {reviewQueue: 20})],
  ['deleteField', ref => updateDoc(ref, {reviewQueue: deleteField()})],
  ['null', ref => updateDoc(ref, {reviewQueue: null})],
  ['merge', ref => setDoc(ref, {reviewQueue: 20}, {merge: true})],
  ['overwrite', ref => setDoc(ref, {reviewQueue: 20})],
  ['unrelated-progress', ref => updateDoc(ref, {progress: .5})],
]) {
  test('C study_info is server-only including ' + operation, async () => {
    const p = await seedReviewStudy(), before = await trustedRead(p.info);
    await assertFails(action(doc(dbFor('A'), p.info)));
    assert.deepEqual(await trustedRead(p.info), before);
  });
}
for (const path of ['users/A/study_info/main', 'users/A/study_info/other']) {
  test('C study_info absent document cannot be created at ' + path, async () => {
    await assertFails(setDoc(doc(dbFor('A'), path), {reviewQueue: 0}));
    assert.equal(await trustedRead(path), undefined);
  });
}
for (const [operation, action] of [
  ['increment', ref => updateDoc(ref, {cardsToReview: increment(1)})],
  ['decrement', ref => updateDoc(ref, {cardsToReview: increment(-1)})],
  ['absolute', ref => updateDoc(ref, {cardsToReview: 20})],
  ['deleteField', ref => updateDoc(ref, {cardsToReview: deleteField()})],
  ['null', ref => updateDoc(ref, {cardsToReview: null})],
  ['mixed-progress', ref => updateDoc(ref, {cardsToReview: 20, progress: .5})],
  ['merge', ref => setDoc(ref, {cardsToReview: 20}, {merge: true})],
  ['overwrite', ref => setDoc(ref, {...reviewSubject(), cardsToReview: 20})],
  ['array-transform', ref => updateDoc(ref, {cardsToReview: arrayUnion(20)})],
]) {
  test('C subject cardsToReview immutable for Client ' + operation, async () => {
    const p = await seedReviewStudy(), before = await trustedRead(p.subject);
    await assertFails(action(doc(dbFor('A'), p.subject)));
    assert.deepEqual(await trustedRead(p.subject), before);
  });
}
test('C counter cannot be introduced into a Subject lacking it', async () => {
  const p = reviewStudyPaths('A'); await seed(p.subject, {progress: .2, streakDays: 3});
  const before = await trustedRead(p.subject);
  await assertFails(updateDoc(doc(dbFor('A'), p.subject), {cardsToReview: 1}));
  assert.deepEqual(await trustedRead(p.subject), before);
});
for (const patch of [{progress: .5}, {streakDays: 4}, {progress: .5, streakDays: 4}]) {
  test('C legitimate Subject noncounter update preserved: ' + JSON.stringify(patch), async () => {
    const p = await seedReviewStudy();
    await assertSucceeds(updateDoc(doc(dbFor('A'), p.subject), patch));
    assert.deepEqual(await trustedRead(p.subject), {...reviewSubject(), ...patch});
  });
}
test('C full set preserving counter and original fields can still update progress', async () => {
  const p = await seedReviewStudy();
  await assertSucceeds(setDoc(doc(dbFor('A'), p.subject), {...reviewSubject(), progress: .5}));
  assert.equal((await trustedRead(p.subject)).cardsToReview, 2);
});
for (const patch of [{progress: -1}, {progress: 1.1}, {progress: 'bad'}, {progress: null},
  {streakDays: -1}, {streakDays: 1.5}, {streakDays: 'bad'}, {streakDays: null}, {title: 'Forbidden'}, {extra: true}]) {
  test('C original Subject schema/diff still rejects ' + JSON.stringify(patch), async () => {
    const p = await seedReviewStudy(), before = await trustedRead(p.subject);
    await assertFails(updateDoc(doc(dbFor('A'), p.subject), patch));
    assert.deepEqual(await trustedRead(p.subject), before);
  });
}
for (const [index, data] of [[0, {}], [1, {state: 'COMPLETE', retainUntil: Timestamp.fromMillis(1)}], [2, {state: 'COMPLETE'}]]) {
  test('C remaining Subject updates are blocked by isolated R5 ' + index, async () => {
    const p = await seedReviewStudy(), before = await trustedRead(p.subject); await retire('A', index, data);
    if (index === 2) assert.equal(await trustedRead(controls('A')[1]), undefined);
    await assertFails(updateDoc(doc(dbFor('A'), p.subject), {progress: .5}));
    await assertFails(updateDoc(doc(dbFor('A'), p.subject), {streakDays: 4}));
    assert.deepEqual(await trustedRead(p.subject), before);
    assert.deepEqual(await trustedRead(controls('A')[index]), data);
  });
}
for (const retired of [false, true]) {
  test('C owner get/list preserved for Study even retired=' + retired, async () => {
    const p = await seedReviewStudy(); if (retired) await retire('A');
    for (const key of ['info', 'subject', 'card']) {
      await assertSucceeds(getDoc(doc(dbFor('A'), p[key])));
      await assertSucceeds(getDocs(collection(dbFor('A'), p[key].slice(0, p[key].lastIndexOf('/')))));
      await assertFails(getDoc(doc(dbFor('B'), p[key])));
      await assertFails(getDocs(collection(dbFor('B'), p[key].slice(0, p[key].lastIndexOf('/')))));
      await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), p[key])));
    }
  });
}
for (const actor of ['active', 'retired', 'foreign', 'anonymous']) {
  for (const descendant of [false, true]) {
    test('C receipt has no Client get/list/CUD: ' + actor + ' descendant=' + descendant, async () => {
      const p = reviewStudyPaths('A'), path = p.receipt + (descendant ? '/private/data' : '');
      const original = {state: 'APPLIED', payloadFingerprint: 'original'}; await seed(path, original);
      if (actor === 'retired') await retire('A');
      const db = actor === 'anonymous' ? env.unauthenticatedContext().firestore() : dbFor(actor === 'foreign' ? 'B' : 'A');
      const ref = doc(db, path);
      await assertFails(getDoc(ref)); await assertFails(getDocs(collection(db, path.slice(0, path.lastIndexOf('/')))));
      await assertFails(setDoc(doc(db, path + '-new'), {state: 'FORGED'}));
      await assertFails(updateDoc(ref, {state: 'FORGED'})); await assertFails(deleteDoc(ref));
      assert.deepEqual(await trustedRead(path), original); assert.equal(await trustedRead(path + '-new'), undefined);
    });
  }
}
test('C receipt collectionGroup query remains denied', async () => {
  await seed(reviewStudyPaths('A').receipt, {state: 'APPLIED'});
  await assertFails(getDocs(collectionGroup(dbFor('A'), 'study_card_create_receipts')));
});
test('C cross-UID Subject progress/counters and Study/card writes all denied', async () => {
  const p = await seedReviewStudy(), db = dbFor('B'), before = await trustedRead(p.subject);
  await assertFails(updateDoc(doc(db, p.subject), {progress: .5}));
  await assertFails(updateDoc(doc(db, p.subject), {streakDays: 5}));
  await assertFails(updateDoc(doc(db, p.subject), {cardsToReview: 5}));
  await assertFails(updateDoc(doc(db, p.info), {reviewQueue: 5}));
  await assertFails(setDoc(doc(db, p.card + '-new'), reviewCard()));
  assert.deepEqual(await trustedRead(p.subject), before);
});
test('C combined card/counter/receipt batch fails atomically, including allowed progress', async () => {
  const p = await seedReviewStudy(), db = dbFor('A'), batch = writeBatch(db);
  batch.set(doc(db, p.card + '-new'), reviewCard());
  batch.update(doc(db, p.info), {reviewQueue: increment(1)});
  batch.update(doc(db, p.subject), {cardsToReview: increment(1), progress: .5});
  batch.set(doc(db, p.receipt), {state: 'APPLIED'});
  await assertFails(batch.commit());
  assert.equal(await trustedRead(p.card + '-new'), undefined); assert.equal(await trustedRead(p.receipt), undefined);
  assert.equal((await trustedRead(p.info)).reviewQueue, 2); assert.deepEqual(await trustedRead(p.subject), reviewSubject());
});
test('C trusted four-write fixture bypasses Rules; NOT production Admin SDK/IAM proof', async () => {
  const p = await seedReviewStudy(), card = p.card + '-new', receipt = p.receipt + '-new';
  await assertFails(setDoc(doc(dbFor('A'), card), reviewCard()));
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore(), batch = writeBatch(db);
    batch.set(doc(db, card), reviewCard());
    batch.update(doc(db, p.info), {reviewQueue: 3}); batch.update(doc(db, p.subject), {cardsToReview: 3});
    batch.set(doc(db, receipt), {version: 1, uid: 'A', operation: 'create_review_card', operationId: 'card-new',
      subjectId: 'subject', payloadFingerprint: 'f'.repeat(64), state: 'APPLIED', appliedAt: serverTimestamp(),
      cardCreated: true, reviewQueueDelta: 1, cardsToReviewDelta: 1});
    await batch.commit();
  });
  assert.deepEqual(await trustedRead(card), reviewCard()); assert.equal((await trustedRead(p.info)).reviewQueue, 3);
  assert.equal((await trustedRead(p.subject)).cardsToReview, 3); assert.equal((await trustedRead(receipt)).state, 'APPLIED');
  await assertFails(getDoc(doc(dbFor('A'), receipt)));
});
