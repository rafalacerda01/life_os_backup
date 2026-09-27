const {readFileSync} = require('node:fs');
const assert = require('node:assert/strict');
const {resolve} = require('node:path');
const {before, after, beforeEach, test} = require('node:test');
const {initializeTestEnvironment, assertSucceeds, assertFails} = require('@firebase/rules-unit-testing');
const {doc, setDoc, getDoc, updateDoc, deleteDoc, writeBatch, serverTimestamp, Timestamp, increment} = require('firebase/firestore');

// Never fall back to a production Firestore instance.
const emulatorAvailable = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
let env;
const premium = (overrides = {}) => ({
  isPremium: true,
  premiumProvider: 'google_play',
  premiumProductId: 'life_os_premium',
  premiumTier: 'monthly',
  premiumBasePlanId: 'monthly',
  premiumSubscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
  premiumExpiresAt: Timestamp.fromMillis(Date.now() + 3600000),
  ...overrides,
});
const member = (role = 'member') => ({role, displayNameSnapshot: 'Member', photoUrlSnapshot: null, joinedAt: serverTimestamp()});
const circle = (limit, count = 1) => ({name: 'Circle', description: 'Test circle', adminId: 'admin', memberCount: count, memberLimit: limit, schemaVersion: 2, createdAt: serverTimestamp(), updatedAt: serverTimestamp()});
const dbFor = uid => env.authenticatedContext(uid).firestore();
async function seedUser(uid, data = {}) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'users', uid), {isPremium: false, activeCircleId: null, ...data});
  });
}
async function seedCircle(limit, count, adminData = premium()) {
  await seedUser('admin', {...adminData, activeCircleId: 'circle'});
  await seedUser('joiner');
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'circles/circle'), circle(limit, count));
    await setDoc(doc(db, 'circles/circle/members/admin'), member('admin'));
    for (let i = 1; i < count; i++) {
      await setDoc(doc(db, 'circles/circle/members/m' + i), member());
      await setDoc(doc(db, 'users/m' + i), {isPremium: false, activeCircleId: 'circle'});
    }
  });
}
function create(limit, extra = {}) {
  const db = dbFor('admin');
  const batch = writeBatch(db);
  batch.set(doc(db, 'circles/circle'), circle(limit));
  batch.set(doc(db, 'circles/circle/members/admin'), member('admin'));
  batch.update(doc(db, 'users/admin'), {activeCircleId: 'circle', ...extra});
  return batch.commit();
}
function join(uid = 'joiner', circleUpdates = {}) {
  const db = dbFor(uid);
  const batch = writeBatch(db);
  batch.set(doc(db, 'circles/circle/members', uid), member());
  batch.update(doc(db, 'circles/circle'), {memberCount: increment(1), updatedAt: serverTimestamp(), ...circleUpdates});
  batch.update(doc(db, 'users', uid), {activeCircleId: 'circle'});
  return batch.commit();
}
function leave(uid = 'm1') {
  const db = dbFor(uid);
  const batch = writeBatch(db);
  batch.delete(doc(db, 'circles/circle/members', uid));
  batch.update(doc(db, 'circles/circle'), {memberCount: increment(-1), updatedAt: serverTimestamp()});
  batch.update(doc(db, 'users', uid), {activeCircleId: null});
  return batch.commit();
}
before(async () => {
  if (!emulatorAvailable) return;
  env = await initializeTestEnvironment({projectId: 'demo-life-os', firestore: {rules: readFileSync(resolve(__dirname, '../../firestore.rules'), 'utf8')}});
});
beforeEach(async () => {if (env) await env.clearFirestore();});
after(async () => {if (env) await env.cleanup();});
function rulesTest(name, fn) {test(name, {skip: !emulatorAvailable && 'Run npm run test:rules with Firestore Emulator'}, fn);}

rulesTest('Free creates 3; cannot create 10 or 30', async () => {
  await seedUser('admin');
  await assertFails(create(10));
  await assertFails(create(30));
  await assertSucceeds(create(3));
});
for (const tier of ['monthly', 'annual']) {
  for (const state of ['ACTIVE', 'IN_GRACE_PERIOD', 'CANCELED']) {
    rulesTest(`Valid ${tier}/${state} creates 30; never creates legacy 10`, async () => {
      await seedUser('admin', premium({premiumTier: tier, premiumBasePlanId: tier, premiumSubscriptionState: 'SUBSCRIPTION_STATE_' + state}));
      await assertFails(create(10));
      await assertFails(create(3));
      await assertSucceeds(create(30));
    });
  }
}
const invalid = [
  ['raw flag', {isPremium: true}],
  ['downgraded', premium({isPremium: false})],
  ['expired', premium({premiumExpiresAt: Timestamp.fromMillis(1)})],
  ['provider', premium({premiumProvider: 'mock'})],
  ['product', premium({premiumProductId: 'other'})],
  ['tier mismatch', premium({premiumTier: 'annual'})],
  ['unknown tier', premium({premiumTier: 'weekly', premiumBasePlanId: 'weekly'})],
  ['unknown state', premium({premiumSubscriptionState: 'UNKNOWN'})],
  ['on hold', premium({premiumSubscriptionState: 'SUBSCRIPTION_STATE_ON_HOLD'})],
  ['pending', premium({premiumSubscriptionState: 'SUBSCRIPTION_STATE_PENDING'})],
  ['paused', premium({premiumSubscriptionState: 'SUBSCRIPTION_STATE_PAUSED'})],
  ['expired state', premium({premiumSubscriptionState: 'SUBSCRIPTION_STATE_EXPIRED'})],
  ['string expiry', premium({premiumExpiresAt: '2099-01-01'})],
  ['null expiry', premium({premiumExpiresAt: null})],
];
for (const field of Object.keys(premium())) {
  const data = premium(); delete data[field];
  invalid.push(['missing ' + field, data]);
}
for (const [name, data] of invalid) {
  rulesTest(`${name}: create falls back to 3, join capped at 3`, async () => {
    await seedUser('admin', data);
    await assertFails(create(30));
    await assertSucceeds(create(3));
    await seedCircle(30, 2, data);
    await assertSucceeds(join());
    await seedUser('next');
    await assertFails(join('next'));
  });
}
for (const limit of [3, 10, 30]) {
  rulesTest(`Stored ${limit}: join final slot succeeds and overflow fails`, async () => {
    await seedCircle(limit, limit - 1);
    await assertSucceeds(join());
    await seedUser('next');
    await assertFails(join('next'));
  });
}
for (const limit of [10, 30]) {
  rulesTest(`Downgrade ${limit} with 8 members preserves members and allows leave`, async () => {
    await seedCircle(limit, 8, premium({premiumExpiresAt: Timestamp.fromMillis(1)}));
    await assertFails(join());
    const db = dbFor('admin');
    const before = await getDoc(doc(db, 'circles/circle'));
    if (before.data().memberCount !== 8) throw Error('Count changed on denied join');
    await assertSucceeds(getDoc(doc(db, 'circles/circle/members/m1')));
    await assertSucceeds(leave());
    const after = await getDoc(doc(db, 'circles/circle'));
    if (after.data().memberCount !== 7 || after.data().memberLimit !== limit) throw Error('Leave altered capacity');
  });
}
rulesTest('Missing admin profile caps join at 3 and does not block leave', async () => {
  await seedCircle(30, 3);
  await env.withSecurityRulesDisabled(async (context) => {
    const batch = writeBatch(context.firestore()); batch.delete(doc(context.firestore(), 'users/admin')); await batch.commit();
  });
  await assertFails(join());
  await assertSucceeds(leave());
  await assertSucceeds(join());
});
rulesTest('Upgrade keeps stored Free limit at 3', async () => {
  await seedCircle(3, 3, premium());
  await assertFails(join());
  await assertFails(updateDoc(doc(dbFor('admin'), 'circles/circle'), {memberLimit: 30}));
});
rulesTest('Client cannot forge entitlement in profile or atomic create', async () => {
  await seedUser('admin');
  for (const [key, value] of Object.entries(premium())) {
    await assertFails(updateDoc(doc(dbFor('admin'), 'users/admin'), {[key]: value}));
  }
  await assertFails(create(30, premium()));
});
rulesTest('Join cannot inflate limit or bypass atomic membership/count/user writes', async () => {
  await seedCircle(3, 2);
  await assertFails(join('joiner', {memberLimit: 30}));
  await assertFails(join('joiner', {memberCount: 1}));
  const db = dbFor('joiner');
  await assertFails(setDoc(doc(db, 'circles/circle/members/joiner'), member()));
  await assertFails(updateDoc(doc(db, 'circles/circle'), {memberCount: 3, updatedAt: serverTimestamp()}));
});
for (const limit of [0, 4, 31, '30']) {
  rulesTest(`Invalid stored limit ${JSON.stringify(limit)} rejects join`, async () => {
    await seedCircle(limit, 1);
    await assertFails(join());
  });
}
rulesTest('Unauthenticated creation denied; admin profile remains private', async () => {
  await seedCircle(30, 1);
  await assertFails(getDoc(doc(dbFor('joiner'), 'users/admin')));
  await assertFails(setDoc(doc(env.unauthenticatedContext().firestore(), 'circles/other'), circle(30)));
});

const deletionGuard = (overrides = {}) => ({version: 1, state: 'IN_PROGRESS',
  deletionId: '11111111-1111-4111-8111-111111111111',
  startedAt: Timestamp.fromMillis(Date.now() - 1000), retainUntil: null, ...overrides});
async function seedGuard(uid, data = deletionGuard()) {
  await env.withSecurityRulesDisabled(context =>
    setDoc(doc(context.firestore(), 'account_deletion_guards', uid), data));
}

rulesTest('Account deletion guard denies atomic Circle creation without changing profile', async () => {
  await seedUser('admin');
  await seedGuard('admin');
  await assertFails(create(3));
  assert.equal((await getDoc(doc(dbFor('admin'), 'users/admin'))).data().activeCircleId, null);
});

rulesTest('Account deletion guard denies join and membership recreation', async () => {
  await seedCircle(3, 1);
  await assertSucceeds(join());
  await assertSucceeds(leave('joiner'));
  await seedGuard('joiner');
  await assertFails(join());
  await assertFails(setDoc(doc(dbFor('joiner'), 'circles/circle/members/joiner'), member()));
  assert.equal((await getDoc(doc(dbFor('admin'), 'circles/circle'))).data().memberCount, 1);
});

rulesTest('Account deletion guard independently denies activeCircleId activation', async () => {
  await seedCircle(3, 1);
  await seedGuard('joiner');
  // The full atomic join would otherwise satisfy activation's getAfter checks.
  await assertFails(join());
  await assertFails(updateDoc(doc(dbFor('joiner'), 'users/joiner'), {activeCircleId: 'circle'}));
  assert.equal((await getDoc(doc(dbFor('joiner'), 'users/joiner'))).data().activeCircleId, null);
});

rulesTest('Account deletion guard preserves structurally valid leave and clear', async () => {
  await seedCircle(3, 2);
  await seedGuard('m1');
  await assertSucceeds(leave());
  assert.equal((await getDoc(doc(dbFor('m1'), 'users/m1'))).data().activeCircleId, null);
  assert.equal((await getDoc(doc(dbFor('admin'), 'circles/circle'))).data().memberCount, 1);
});

rulesTest('Clients cannot read create modify or remove account and runtime deletion guards', async () => {
  await seedUser('admin');
  await seedGuard('admin');
  for (const uid of ['admin', 'other']) {
    const db = dbFor(uid);
    for (const key of ['account_deletion_guards/admin', 'users/admin/runtime/account_delete_barrier']) {
      await assertFails(getDoc(doc(db, key)));
      await assertFails(setDoc(doc(db, key), deletionGuard()));
      await assertFails(updateDoc(doc(db, key), {state: 'COMPLETE'}));
      await assertFails(deleteDoc(doc(db, key)));
    }
  }
});

rulesTest('Completed guard still blocks an unexpired authenticated session after user-tree deletion', async () => {
  await seedGuard('admin', deletionGuard({state: 'COMPLETE',
    retainUntil: Timestamp.fromMillis(Date.now() + 65 * 60 * 1000)}));
  // Simulate a still-valid ID token trying to recreate the removed user profile.
  await seedUser('admin');
  await assertFails(create(3));
});

rulesTest('Expired completed guard permits a newly provisioned session', async () => {
  await seedUser('admin');
  await seedGuard('admin', deletionGuard({state: 'COMPLETE',
    retainUntil: Timestamp.fromMillis(1)}));
  await assertSucceeds(create(3));
});

rulesTest('Malformed account guard fails closed without preventing valid leave', async () => {
  await seedCircle(3, 2);
  await seedGuard('joiner', {});
  await assertFails(join());
  await seedGuard('m1', {});
  await assertSucceeds(leave());
});

rulesTest('Another UID guard does not prevent normal create or join', async () => {
  await seedUser('admin');
  await seedUser('joiner');
  await seedGuard('other');
  await assertSucceeds(create(3));
  await assertSucceeds(join());
});

rulesTest('UID-free cleanup closure prevents recreation of a recursively deleted Circle', async () => {
  await seedUser('admin');
  await env.withSecurityRulesDisabled(context =>
    setDoc(doc(context.firestore(), 'circle_cleanup_guards/circle'),
      {version: 1, state: 'SERVER_DELETING', createdAt: Timestamp.now()}));
  await assertFails(create(3));
  await assertFails(getDoc(doc(dbFor('admin'), 'circle_cleanup_guards/circle')));
  await assertFails(deleteDoc(doc(dbFor('admin'), 'circle_cleanup_guards/circle')));
});

rulesTest('Current entitlement is rechecked after downgrade and renewal', async () => {
  await seedCircle(30, 3);
  await assertSucceeds(join());
  await seedUser('admin', {isPremium: false, activeCircleId: 'circle'});
  await seedUser('next');
  await assertFails(join('next'));
  await assertSucceeds(leave());
  await seedUser('admin', {...premium(), activeCircleId: 'circle'});
  await assertSucceeds(join('next'));
});
rulesTest('Concurrent joins cannot exceed the final available slot', async () => {
  await seedCircle(30, 29);
  await seedUser('next');
  const results = await Promise.allSettled([join(), join('next')]);
  if (results.filter(result => result.status === 'fulfilled').length !== 1) {
    throw Error('Exactly one join must succeed');
  }
  const snapshot = await getDoc(doc(dbFor('admin'), 'circles/circle'));
  if (snapshot.data().memberCount !== 30) throw Error('Capacity overflow');
});

function createAt(circleId) {
  const db = dbFor('admin');
  const batch = writeBatch(db);
  batch.set(doc(db, 'circles', circleId), circle(3));
  batch.set(doc(db, 'circles', circleId, 'members/admin'), member('admin'));
  batch.update(doc(db, 'users/admin'), {activeCircleId: circleId});
  return batch.commit();
}

for (const id of ['x'.repeat(129), ' leading', 'trailing ', '\tleading', 'trailing\n', '\u00a0leading', 'trailing\ufeff', '\u{1f600}'.repeat(65)]) {
  rulesTest(`Incompatible Circle ID ${JSON.stringify(id)} cannot be created`, async () => {
    await seedUser('admin');
    await assertFails(createAt(id));
  });
}

rulesTest('Circle ID boundary 128 still permits atomic creation', async () => {
  await seedUser('admin');
  await assertSucceeds(createAt('x'.repeat(128)));
});

rulesTest('Legacy oversized Circle denies atomic join and standalone activation', async () => {
  const id = 'x'.repeat(129);
  await seedUser('admin', {activeCircleId: id});
  await seedUser('joiner');
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore();
    await setDoc(doc(db, 'circles', id), circle(3));
    await setDoc(doc(db, 'circles', id, 'members/admin'), member('admin'));
  });
  const db = dbFor('joiner');
  const batch = writeBatch(db);
  batch.set(doc(db, 'circles', id, 'members/joiner'), member());
  batch.update(doc(db, 'circles', id), {memberCount: increment(1), updatedAt: serverTimestamp()});
  batch.update(doc(db, 'users/joiner'), {activeCircleId: id});
  await assertFails(batch.commit());
  // Pre-existing membership must not authorize standalone activation either.
  await env.withSecurityRulesDisabled(context =>
    setDoc(doc(context.firestore(), 'circles', id, 'members/joiner'), member()));
  await assertFails(updateDoc(doc(db, 'users/joiner'), {activeCircleId: id}));
  assert.equal((await getDoc(doc(db, 'users/joiner'))).data().activeCircleId, null);
});

rulesTest('Legacy oversized Circle still permits atomic leave and clear', async () => {
  const id = 'x'.repeat(129);
  await seedUser('admin', {activeCircleId: id});
  await seedUser('joiner', {activeCircleId: id});
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore();
    await setDoc(doc(db, 'circles', id), circle(3, 2));
    await setDoc(doc(db, 'circles', id, 'members/admin'), member('admin'));
    await setDoc(doc(db, 'circles', id, 'members/joiner'), member());
  });
  const db = dbFor('joiner');
  const batch = writeBatch(db);
  batch.delete(doc(db, 'circles', id, 'members/joiner'));
  batch.update(doc(db, 'circles', id), {memberCount: increment(-1), updatedAt: serverTimestamp()});
  batch.update(doc(db, 'users/joiner'), {activeCircleId: null});
  await assertSucceeds(batch.commit());
  assert.equal((await getDoc(doc(db, 'users/joiner'))).data().activeCircleId, null);
});

const newChallenge = () => ({type: 'FOCUS_MINUTES', title: 'Challenge', targetValue: 10,
  startAt: serverTimestamp(), endAt: Timestamp.fromMillis(Date.now() + 3600000),
  createdBy: 'admin', createdAt: serverTimestamp(), updatedAt: serverTimestamp(), schemaVersion: 2});

for (const id of ['x'.repeat(129), ' leading', 'trailing ', '\u00a0leading', 'trailing\ufeff', '\u{1f600}'.repeat(65)]) {
  rulesTest(`Incompatible Challenge ID ${JSON.stringify(id)} cannot be created`, async () => {
    await seedCircle(3, 1);
    await assertFails(setDoc(doc(dbFor('admin'), 'circles/circle/challenges', id), newChallenge()));
  });
}

rulesTest('Valid Challenge boundary 128 is allowed only for admin', async () => {
  await seedCircle(3, 2);
  await assertSucceeds(setDoc(doc(dbFor('admin'), 'circles/circle/challenges', 'x'.repeat(128)), newChallenge()));
  await assertFails(setDoc(doc(dbFor('m1'), 'circles/circle/challenges/other'), {...newChallenge(), createdBy: 'm1'}));
});

rulesTest('Challenge creation in legacy oversized Circle is denied', async () => {
  const id = 'x'.repeat(129);
  await seedUser('admin', {activeCircleId: id});
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'circles', id), circle(3));
    await setDoc(doc(context.firestore(), 'circles', id, 'members/admin'), member('admin'));
  });
  await assertFails(setDoc(doc(dbFor('admin'), 'circles', id, 'challenges/valid'), newChallenge()));
});

rulesTest('ID guards preserve member progress read, deny writes and keep events private', async () => {
  await seedCircle(3, 2);
  const progress = 'circles/circle/challenges/valid/progress/m1';
  const event = 'circles/circle/challenges/valid/processed_events/event';
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), progress), {uid: 'm1', value: 1});
    await setDoc(doc(context.firestore(), event), {uid: 'm1'});
  });
  await assertSucceeds(getDoc(doc(dbFor('m1'), progress)));
  await assertFails(getDoc(doc(dbFor('joiner'), progress)));
  for (const uid of ['admin', 'm1', 'joiner']) {
    await assertFails(setDoc(doc(dbFor(uid), progress), {uid: 'm1', value: 2}));
    await assertFails(updateDoc(doc(dbFor(uid), progress), {value: 2}));
    await assertFails(deleteDoc(doc(dbFor(uid), progress)));
    await assertFails(getDoc(doc(dbFor(uid), event)));
    await assertFails(setDoc(doc(dbFor(uid), event), {uid: 'm1'}));
    await assertFails(deleteDoc(doc(dbFor(uid), event)));
  }
});
