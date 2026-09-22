const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { before, after, beforeEach, test } = require('node:test');
const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const {
  doc, getDoc, setDoc, updateDoc, serverTimestamp,
} = require('firebase/firestore');

const emulatorAvailable = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
let env;

before(async () => {
  if (!emulatorAvailable) return;
  env = await initializeTestEnvironment({
    projectId: 'demo-life-os',
    firestore: {
      rules: readFileSync(resolve(__dirname, '../../firestore.rules'), 'utf8'),
    },
  });
});
beforeEach(async () => { if (env) await env.clearFirestore(); });
after(async () => { if (env) await env.cleanup(); });

function rulesTest(name, run) {
  test(name, { skip: !emulatorAvailable && 'Firestore Emulator required' }, run);
}
function consentFor(uid) {
  return doc(env.authenticatedContext(uid).firestore(), 'users/user-a/privacy/ai_consent');
}
function payload(version = '2.0') {
  return {
    accepted: true,
    userId: 'user-a',
    consentVersion: version,
    acceptedAt: serverTimestamp(),
    revokedAt: null,
    updatedAt: serverTimestamp(),
    source: 'life_os_app',
  };
}
async function seed(version = '1.0') {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), 'users/user-a/privacy/ai_consent'),
      payload(version),
    );
  });
}

rulesTest('owner cria e lê consentimento 2.0', async () => {
  await assertSucceeds(setDoc(consentFor('user-a'), payload()));
  await assertSucceeds(getDoc(consentFor('user-a')));
});

rulesTest('owner migra aceite explícito 1.0 para 2.0', async () => {
  await seed();
  await assertSucceeds(updateDoc(consentFor('user-a'), {
    accepted: true,
    consentVersion: '2.0',
    acceptedAt: serverTimestamp(),
    revokedAt: null,
    updatedAt: serverTimestamp(),
    source: 'life_os_app',
  }));
  await assertSucceeds(getDoc(consentFor('user-a')));
});

rulesTest('owner revoga e reaceita consentimento 2.0', async () => {
  await seed('2.0');
  await assertSucceeds(updateDoc(consentFor('user-a'), {
    accepted: false,
    revokedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  }));
  await assertSucceeds(updateDoc(consentFor('user-a'), {
    accepted: true,
    acceptedAt: serverTimestamp(),
    revokedAt: null,
    updatedAt: serverTimestamp(),
  }));
});

rulesTest('owner reaceita 1.0 revogado como 2.0', async () => {
  await seed();
  await assertSucceeds(updateDoc(consentFor('user-a'), {
    accepted: false,
    revokedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  }));
  await assertSucceeds(updateDoc(consentFor('user-a'), {
    accepted: true,
    consentVersion: '2.0',
    acceptedAt: serverTimestamp(),
    revokedAt: null,
    updatedAt: serverTimestamp(),
  }));
});

rulesTest('outro usuário não lê nem escreve consentimento', async () => {
  await seed('2.0');
  await assertFails(getDoc(consentFor('user-b')));
  await assertFails(updateDoc(consentFor('user-b'), {
    accepted: false, revokedAt: serverTimestamp(), updatedAt: serverTimestamp(),
  }));
});

rulesTest('versões arbitrárias e campos extras são negados', async () => {
  for (const version of ['3.0', 'abc', 'latest', null]) {
    await assertFails(setDoc(consentFor('user-a'), payload(version)));
  }
  await assertFails(setDoc(consentFor('user-a'), {
    ...payload(), extra: true,
  }));
  await seed('2.0');
  await assertFails(updateDoc(consentFor('user-a'), {
    consentVersion: '3.0', updatedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(consentFor('user-a'), {
    extra: true, updatedAt: serverTimestamp(),
  }));
});
