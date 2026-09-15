const {readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const {before, after, beforeEach, test} = require('node:test');
const {initializeTestEnvironment, assertSucceeds, assertFails} = require('@firebase/rules-unit-testing');
const {doc, setDoc, getDoc, updateDoc, writeBatch, serverTimestamp, Timestamp, increment} = require('firebase/firestore');

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
