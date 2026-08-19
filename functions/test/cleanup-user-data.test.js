"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

process.env.GCLOUD_PROJECT = "cleanup-user-data-test";

// Load the Functions SDK before replacing only the Admin SDK used by index.js.
require("firebase-functions/v1");
const adminPath = require.resolve("firebase-admin");
const indexPath = require.resolve("../index");
require(adminPath);

let activeDb;
const originalAdmin = require.cache[adminPath].exports;
require.cache[adminPath].exports = {
  initializeApp() {},
  firestore() {
    return activeDb;
  },
};

delete require.cache[indexPath];
const {cleanupUserData} = require(indexPath);
require.cache[adminPath].exports = originalAdmin;

const uid = "sensitive-uid";
const rootPath = `users/${uid}`;

/**
 * Cria um Firestore mínimo para exercitar recursiveDelete.
 * @param {string[]} initialPaths Documentos inicialmente existentes.
 * @param {Function} onDelete Implementação opcional da exclusão.
 * @return {Object} Banco simulado e seu estado observável.
 */
function createDb(initialPaths = [], onDelete) {
  const documents = new Set(initialPaths);
  const calls = [];

  return {
    calls,
    documents,
    collection(collectionName) {
      return {
        doc(documentId) {
          return {path: `${collectionName}/${documentId}`};
        },
      };
    },
    async recursiveDelete(ref) {
      calls.push(ref.path);

      if (onDelete) {
        await onDelete({calls, documents, ref});
        return;
      }

      await Promise.resolve();
      for (const path of documents) {
        if (path === ref.path || path.startsWith(`${ref.path}/`)) {
          documents.delete(path);
        }
      }
    },
  };
}

/**
 * Suprime o log esperado por testes de falha.
 * @param {Function} callback Operação que emite o log.
 * @return {Promise<*>} Resultado da operação.
 */
async function withoutErrorLog(callback) {
  const originalError = console.error;
  console.error = () => {};
  try {
    return await callback();
  } finally {
    console.error = originalError;
  }
}

test("recursiveDelete resolve e o handler resolve", async () => {
  activeDb = createDb([rootPath, `${rootPath}/tasks/task-1`]);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.calls, [rootPath]);
  assert.equal(activeDb.documents.size, 0);
});

test("recursiveDelete rejeita e propaga erro sanitizado", async () => {
  const email = "private@example.com";
  const originalFailure = `permission denied for ${rootPath} ${email}`;
  activeDb = createDb([], async () => {
    throw new Error(originalFailure);
  });

  const loggedArguments = [];
  const originalError = console.error;
  console.error = (...args) => loggedArguments.push(args);
  try {
    await assert.rejects(
        cleanupUserData.run({uid, email}),
        {message: "USER_DATA_CLEANUP_FAILED"},
    );
  } finally {
    console.error = originalError;
  }

  assert.deepEqual(loggedArguments, [[
    "[cleanupUserData] Falha na limpeza pós-exclusão.",
  ]]);
  const serializedLog = JSON.stringify(loggedArguments);
  assert.equal(serializedLog.includes(uid), false);
  assert.equal(serializedLog.includes(email), false);
  assert.equal(serializedLog.includes(rootPath), false);
  assert.equal(serializedLog.includes(originalFailure), false);
});

test("export habilita retry no trigger de primeira geração", () => {
  assert.equal(cleanupUserData.__endpoint.platform, "gcfv1");
  assert.equal(cleanupUserData.__endpoint.eventTrigger.retry, true);
  assert.equal(
      cleanupUserData.__endpoint.eventTrigger.eventType,
      "providers/firebase.auth/eventTypes/user.delete",
  );
  assert.deepEqual(cleanupUserData.__trigger.failurePolicy, {retry: {}});
});

test("retry completa limpeza iniciada parcialmente", async () => {
  const markerPath = `${rootPath}/runtime/account_deletion`;
  const remainingPath = `${rootPath}/tasks/task-1`;
  let attempt = 0;
  activeDb = createDb(
      [rootPath, markerPath, remainingPath],
      async ({documents, ref}) => {
        attempt += 1;
        if (attempt === 1) {
          documents.delete(ref.path);
          documents.delete(markerPath);
          throw new Error("transient internal failure");
        }

        for (const path of documents) {
          if (path === ref.path || path.startsWith(`${ref.path}/`)) {
            documents.delete(path);
          }
        }
      },
  );

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));
  assert.equal(activeDb.documents.has(remainingPath), true);

  await cleanupUserData.run({uid});

  assert.equal(activeDb.calls.length, 2);
  assert.equal(activeDb.documents.size, 0);
});

test("root ausente ainda executa recursiveDelete", async () => {
  const descendantPath = `${rootPath}/tasks/task-1`;
  activeDb = createDb([descendantPath]);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.calls, [rootPath]);
  assert.equal(activeDb.documents.size, 0);
});

test("árvore totalmente ausente termina normalmente", async () => {
  activeDb = createDb();

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.calls, [rootPath]);
  assert.equal(activeDb.documents.size, 0);
});

test("duas execuções concorrentes permanecem idempotentes", async () => {
  activeDb = createDb([
    rootPath,
    `${rootPath}/tasks/task-1`,
    `${rootPath}/runtime/account_deletion`,
  ]);

  await Promise.all([
    cleanupUserData.run({uid}),
    cleanupUserData.run({uid}),
  ]);

  assert.deepEqual(activeDb.calls, [rootPath, rootPath]);
  assert.equal(activeDb.documents.size, 0);
});
