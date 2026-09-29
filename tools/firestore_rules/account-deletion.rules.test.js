const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const {before, after, beforeEach, test} = require('node:test');
const {initializeTestEnvironment, assertSucceeds, assertFails} = require('@firebase/rules-unit-testing');
const {doc, getDoc, setDoc, updateDoc, deleteDoc, serverTimestamp, Timestamp} = require('firebase/firestore');

// Tests only run with the demo-project Firestore Emulator.
const emulatorAvailable = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
let env;

before(async () => {
  if (!emulatorAvailable) return;
  env = await initializeTestEnvironment({
    projectId: 'demo-life-os',
    firestore: {rules: readFileSync(resolve(__dirname, '../../firestore.rules'), 'utf8')},
  });
});
beforeEach(async () => {if (env) await env.clearFirestore();});
after(async () => {if (env) await env.cleanup();});
function rulesTest(name, run) {
  test(name, {skip: !emulatorAvailable && 'Firestore Emulator required'}, run);
}

const dbFor = uid => env.authenticatedContext(uid).firestore();
const userPath = uid => `users/${uid}`;
const healthPath = uid => `${userPath(uid)}/health_info/main`;
const guardPath = uid => `account_deletion_guards/${uid}`;
const future = () => Timestamp.fromMillis(Date.now() + 65 * 60 * 1000);
const past = () => Timestamp.fromMillis(Date.now() - 60 * 1000);

function userData() {
  return {
    email: 'owner@example.test', displayName: 'Owner', isPremium: false, photoUrl: null,
    xp: 0, level: 1, streak: 0, habitsCount: 0, tasksCount: 0, goalsCount: 0,
    subjectsCount: 0, medicationsCount: 0, transactionsCount: 0,
  };
}
function healthData() {
  return {waterIntakeMl: 250, date: Timestamp.fromMillis(1000)};
}
function notificationData() {
  return {
    title: 'Reminder', description: 'Description', priority: 'normal',
    moduleType: 'health', route: '/health', isRead: false, isCompleted: false,
    dueDate: null, createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  };
}
function privacyData(uid) {
  return {
    accepted: true, userId: uid, consentVersion: '2.0',
    acceptedAt: serverTimestamp(), revokedAt: null,
    updatedAt: serverTimestamp(), source: 'life_os_app',
  };
}
async function seed(path, data) {
  await env.withSecurityRulesDisabled(context => setDoc(doc(context.firestore(), path), data));
}
async function seedGuard(uid, data = {state: 'COMPLETE', retainUntil: future()}) {
  await seed(guardPath(uid), data);
}

rulesTest('retained COMPLETE guard blocks health recreation after user root was deleted', async () => {
  await seedGuard('owner');
  const db = dbFor('owner');
  assert.equal((await getDoc(doc(db, userPath('owner')))).exists(), false);
  await assertFails(setDoc(doc(db, healthPath('owner')), healthData()));
  assert.equal((await getDoc(doc(db, healthPath('owner')))).exists(), false);
});

rulesTest('retained COMPLETE guard blocks valid root profile recreation', async () => {
  await seedGuard('owner');
  await assertFails(setDoc(doc(dbFor('owner'), userPath('owner')), userData()));
});

for (const [name, guard] of [
  ['IN_PROGRESS with null expiry', {state: 'IN_PROGRESS', retainUntil: null}],
  ['retained COMPLETE', {state: 'COMPLETE', retainUntil: future()}],
  ['malformed COMPLETE without expiry', {state: 'COMPLETE'}],
  ['malformed COMPLETE with null expiry', {state: 'COMPLETE', retainUntil: null}],
]) {
  rulesTest(`${name} blocks valid private writes`, async () => {
    await seedGuard('owner', guard);
    await assertFails(setDoc(doc(dbFor('owner'), healthPath('owner')), healthData()));
  });
}

rulesTest('expired COMPLETE guard allows otherwise valid health write', async () => {
  await seedGuard('owner', {state: 'COMPLETE', retainUntil: past()});
  await assertSucceeds(setDoc(doc(dbFor('owner'), healthPath('owner')), healthData()));
});

rulesTest('another UID guard does not block owner and cross-account writes remain denied', async () => {
  await seedGuard('other');
  await assertSucceeds(setDoc(doc(dbFor('owner'), healthPath('owner')), healthData()));
  await assertFails(setDoc(doc(dbFor('other'), healthPath('owner')), healthData()));
});

rulesTest('owner reads remain available while private writes are guarded', async () => {
  await seed(healthPath('owner'), healthData());
  await seedGuard('owner');
  await assertSucceeds(getDoc(doc(dbFor('owner'), healthPath('owner'))));
  await assertFails(getDoc(doc(dbFor('other'), healthPath('owner'))));
});

const privateWrites = [
  {name: 'root create', path: '', operation: 'create', data: userData},
  {name: 'root update', path: '', operation: 'update', initial: userData, data: () => ({displayName: 'Updated'})},
  {name: 'habits update', path: '/habits/habit', operation: 'update', initial: () => ({completedDates: []}), data: () => ({completedDates: ['2026-01-01']})},
  {name: 'tasks update', path: '/tasks/task', operation: 'update', initial: () => ({isCompleted: false}), data: () => ({isCompleted: true})},
  {name: 'goals update', path: '/goals/goal', operation: 'update', initial: () => ({currentValue: 0}), data: () => ({currentValue: 3})},
  {name: 'subjects update', path: '/subjects/subject', operation: 'update', initial: () => ({cardsToReview: 0, progress: 0, streakDays: 0}), data: () => ({progress: 0.5})},
  {name: 'checkins create', path: '/checkins/checkin', operation: 'create', data: () => ({energy: 3, focus: 2, motivation: 4, updatedAt: serverTimestamp()})},
  {name: 'checkins update', path: '/checkins/checkin', operation: 'update', initial: () => ({energy: 1, focus: 2, motivation: 3, updatedAt: Timestamp.fromMillis(1000)}), data: () => ({energy: 3, updatedAt: serverTimestamp()})},
  {name: 'focus_logs create', path: '/focus_logs/log', operation: 'create', data: () => ({targetId: 'subject', targetType: 'SUBJECT', durationSeconds: 60, timestamp: Timestamp.fromMillis(1000)})},
  {name: 'focus_logs update', path: '/focus_logs/log', operation: 'update', initial: () => ({targetId: 'subject', targetType: 'SUBJECT', durationSeconds: 60, timestamp: Timestamp.fromMillis(1000)}), data: () => ({durationSeconds: 120})},
  {name: 'health_info create', path: '/health_info/main', operation: 'create', data: healthData},
  {name: 'health_info update', path: '/health_info/main', operation: 'update', initial: healthData, data: () => ({waterIntakeMl: 300})},
  {name: 'study_info create', path: '/study_info/main', operation: 'create', data: () => ({reviewQueue: 0})},
  {name: 'study_info update', path: '/study_info/main', operation: 'update', initial: () => ({reviewQueue: 0}), data: () => ({reviewQueue: 1})},
  {name: 'review_queue create', path: '/review_queue/review', operation: 'create', data: () => ({subjectId: 'subject', question: 'Question', answer: 'Answer', createdAt: serverTimestamp()})},
  {name: 'notifications create', path: '/notifications/notification', operation: 'create', data: notificationData},
  {name: 'notifications update', path: '/notifications/notification', operation: 'update', initial: notificationData, data: () => ({isRead: true, updatedAt: serverTimestamp()})},
  {name: 'notifications delete', path: '/notifications/notification', operation: 'delete', initial: notificationData},
  {name: 'privacy create', path: '/privacy/ai_consent', operation: 'create', data: privacyData},
  {name: 'privacy update', path: '/privacy/ai_consent', operation: 'update', initial: privacyData, data: () => ({accepted: false, revokedAt: serverTimestamp(), updatedAt: serverTimestamp()})},
];

for (const item of privateWrites) {
  rulesTest(`${item.name}: retained guard denies write, absent guard permits it`, async () => {
    const uid = 'owner';
    const path = `${userPath(uid)}${item.path}`;
    if (item.initial) await seed(path, item.initial(uid));
    await seedGuard(uid);
    const db = dbFor(uid);
    const reference = doc(db, path);
    const write = () => {
      if (item.operation === 'delete') return deleteDoc(reference);
      if (item.operation === 'update') return updateDoc(reference, item.data(uid));
      return setDoc(reference, item.data(uid));
    };
    await assertFails(write());
    await env.withSecurityRulesDisabled(context => deleteDoc(doc(context.firestore(), guardPath(uid))));
    await assertSucceeds(write());
  });
}

test('private write matrix covers all twenty currently allowed user writes', () => {
  assert.equal(privateWrites.length, 20);
  assert.deepEqual(privateWrites.filter(item => item.operation === 'delete').map(item => item.name), ['notifications delete']);
});
