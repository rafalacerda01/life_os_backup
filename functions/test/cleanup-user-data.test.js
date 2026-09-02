"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {Timestamp} = require("firebase-admin/firestore");

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

/** Referencia fake de documento. */
class FakeDocumentReference {
  /**
   * @param {FakeFirestore} db Banco fake.
   * @param {string} documentPath Path do documento.
   */
  constructor(db, documentPath) {
    this.db = db;
    this.path = documentPath;
    this.kind = "document";
  }

  /**
   * @param {string} name Nome da subcollection.
   * @return {FakeCollectionReference} Referencia criada.
   */
  collection(name) {
    return new FakeCollectionReference(this.db, `${this.path}/${name}`);
  }

  /** @return {Promise<FakeDocumentSnapshot>} Snapshot atual. */
  get() {
    return Promise.resolve(this.db.documentSnapshot(this));
  }
}

/** Query fake limitada a igualdade e limit. */
class FakeQuery {
  /**
   * @param {FakeCollectionReference} collectionRef Collection base.
   * @param {Array<Object>} filters Filtros acumulados.
   * @param {number|null} limitValue Limite da query.
   */
  constructor(collectionRef, filters = [], limitValue = null) {
    this.collectionRef = collectionRef;
    this.filters = filters;
    this.limitValue = limitValue;
    this.kind = "query";
    this.path = collectionRef.path;
  }

  /**
   * @param {string} field Campo filtrado.
   * @param {string} op Operador.
   * @param {*} value Valor esperado.
   * @return {FakeQuery} Nova query.
   */
  where(field, op, value) {
    return new FakeQuery(
        this.collectionRef,
        [...this.filters, {field, op, value}],
        this.limitValue,
    );
  }

  /**
   * @param {number} value Limite.
   * @return {FakeQuery} Nova query.
   */
  limit(value) {
    return new FakeQuery(this.collectionRef, this.filters, value);
  }

  /** @return {Promise<FakeQuerySnapshot>} Resultado da query. */
  get() {
    return Promise.resolve(this.collectionRef.db.querySnapshot(this));
  }
}

/** Referencia fake de collection. */
class FakeCollectionReference {
  /**
   * @param {FakeFirestore} db Banco fake.
   * @param {string} collectionPath Path da collection.
   */
  constructor(db, collectionPath) {
    this.db = db;
    this.path = collectionPath;
    this.kind = "collection";
  }

  /**
   * @param {string} id ID do documento.
   * @return {FakeDocumentReference} Referencia criada.
   */
  doc(id) {
    return new FakeDocumentReference(this.db, `${this.path}/${id}`);
  }

  /**
   * @param {string} field Campo filtrado.
   * @param {string} op Operador.
   * @param {*} value Valor esperado.
   * @return {FakeQuery} Query criada.
   */
  where(field, op, value) {
    return new FakeQuery(this, [{field, op, value}]);
  }

  /**
   * @param {number} value Limite.
   * @return {FakeQuery} Query criada.
   */
  limit(value) {
    return new FakeQuery(this, [], value);
  }
}

/** Snapshot fake de documento. */
class FakeDocumentSnapshot {
  /**
   * @param {FakeDocumentReference} ref Referencia.
   * @param {Object|undefined} data Dados atuais.
   */
  constructor(ref, data) {
    this.ref = ref;
    this.exists = data !== undefined;
    this._data = data;
  }

  /** @return {Object|undefined} Dados atuais. */
  data() {
    return this._data;
  }
}

/** Snapshot fake de query. */
class FakeQuerySnapshot {
  /** @param {Array<FakeDocumentSnapshot>} docs Documentos. */
  constructor(docs) {
    this.docs = docs;
  }
}

/** Acumulador fake de escritas. */
class FakeWriter {
  /** @param {FakeFirestore} db Banco fake. */
  constructor(db) {
    this.db = db;
    this.writes = [];
  }

  /**
   * @param {FakeDocumentReference} ref Referencia removida.
   * @return {FakeWriter} O proprio writer.
   */
  delete(ref) {
    this.writes.push({type: "delete", ref});
    return this;
  }

  /**
   * @param {FakeDocumentReference} ref Referencia criada ou substituida.
   * @param {Object} data Dados armazenados.
   * @return {FakeWriter} O proprio writer.
   */
  set(ref, data) {
    this.writes.push({type: "set", ref, data});
    return this;
  }

  /**
   * @param {FakeDocumentReference} ref Referencia atualizada.
   * @param {Object} data Patch aplicado.
   * @return {FakeWriter} O proprio writer.
   */
  update(ref, data) {
    this.writes.push({type: "update", ref, data});
    return this;
  }
}

/** Batch fake com falha injetavel. */
class FakeBatch extends FakeWriter {
  /** Aplica o batch de forma atomica. @return {Promise<void>} Conclusao. */
  async commit() {
    this.db.batchCommitCount += 1;
    this.db.batchSizes.push(this.writes.length);
    if (this.db.failBatchAt === this.db.batchCommitCount) {
      throw new Error("private batch failure");
    }
    this.db.applyWrites(this.writes);
  }
}

/** Transacao fake que impede leitura depois de escrita. */
class FakeTransaction extends FakeWriter {
  /** @param {FakeFirestore} db Banco fake. */
  constructor(db) {
    super(db);
    this.hasWritten = false;
  }

  /**
   * @param {Object} ref Documento ou query.
   * @return {Promise<Object>} Snapshot correspondente.
   */
  async get(ref) {
    if (this.hasWritten) throw new Error("read after write");
    if (ref.kind === "query" || ref.kind === "collection") {
      return this.db.querySnapshot(ref);
    }
    return this.db.documentSnapshot(ref);
  }

  /** @inheritdoc */
  delete(ref) {
    this.hasWritten = true;
    return super.delete(ref);
  }

  /** @inheritdoc */
  set(ref, data) {
    this.hasWritten = true;
    return super.set(ref, data);
  }

  /** @inheritdoc */
  update(ref, data) {
    this.hasWritten = true;
    return super.update(ref, data);
  }
}

/** Firestore em memoria suficiente para o trigger. */
class FakeFirestore {
  /** Inicializa estado observavel e injecoes de falha. */
  constructor() {
    this.store = new Map();
    this.recursiveDeletes = [];
    this.operationLog = [];
    this.failRecursiveDeleteOnce = new Map();
    this.failBatchAt = null;
    this.batchCommitCount = 0;
    this.batchSizes = [];
    this.transactionCount = 0;
    this.beforeTransactions = {};
    this.afterTransactionCommit = null;
  }

  /**
   * @param {string} name Collection raiz.
   * @return {FakeCollectionReference} Referencia criada.
   */
  collection(name) {
    return new FakeCollectionReference(this, name);
  }

  /** @return {FakeBatch} Novo batch. */
  batch() {
    return new FakeBatch(this);
  }

  /**
   * @param {string} documentPath Path do documento.
   * @param {Object} data Dados armazenados.
   * @return {void}
   */
  seed(documentPath, data) {
    this.store.set(documentPath, data);
  }

  /**
   * @param {string} documentPath Path consultado.
   * @return {Object|undefined} Dados atuais.
   */
  data(documentPath) {
    return this.store.get(documentPath);
  }

  /**
   * @param {FakeDocumentReference} ref Referencia consultada.
   * @return {FakeDocumentSnapshot} Snapshot atual.
   */
  documentSnapshot(ref) {
    return new FakeDocumentSnapshot(ref, this.store.get(ref.path));
  }

  /**
   * @param {Object} ref Collection ou query.
   * @return {FakeQuerySnapshot} Resultado atual.
   */
  querySnapshot(ref) {
    const collectionRef = ref.kind === "query" ? ref.collectionRef : ref;
    const filters = ref.kind === "query" ? ref.filters : [];
    const limitValue = ref.kind === "query" ? ref.limitValue : null;
    const prefix = `${collectionRef.path}/`;
    let docs = [];

    for (const [documentPath, data] of [...this.store.entries()].sort()) {
      if (!documentPath.startsWith(prefix)) continue;
      const suffix = documentPath.slice(prefix.length);
      if (!suffix || suffix.includes("/")) continue;
      const snapshot = new FakeDocumentSnapshot(
          new FakeDocumentReference(this, documentPath),
          data,
      );
      const matches = filters.every((filter) =>
        filter.op === "==" && data && data[filter.field] === filter.value,
      );
      if (matches) docs.push(snapshot);
    }

    if (limitValue !== null) docs = docs.slice(0, limitValue);
    return new FakeQuerySnapshot(docs);
  }

  /**
   * @param {Array<Object>} writes Escritas acumuladas.
   * @return {void}
   */
  applyWrites(writes) {
    const next = new Map(this.store);
    for (const write of writes) {
      if (write.type === "delete") {
        next.delete(write.ref.path);
      } else if (write.type === "set") {
        next.set(write.ref.path, write.data);
      } else if (write.type === "update") {
        if (!next.has(write.ref.path)) throw new Error("missing update");
        next.set(write.ref.path, {
          ...next.get(write.ref.path),
          ...write.data,
        });
      } else {
        throw new Error("unknown write type");
      }
      this.operationLog.push(`${write.type}:${write.ref.path}`);
    }
    this.store = next;
  }

  /**
   * @param {FakeDocumentReference|FakeCollectionReference} ref Raiz removida.
   * @return {Promise<void>} Conclusao da exclusao.
   */
  async recursiveDelete(ref) {
    this.recursiveDeletes.push(ref.path);
    this.operationLog.push(`recursive:${ref.path}`);
    const failures = this.failRecursiveDeleteOnce.get(ref.path) || 0;
    if (failures > 0) {
      this.failRecursiveDeleteOnce.set(ref.path, failures - 1);
      throw new Error("private recursive delete failure");
    }
    for (const documentPath of [...this.store.keys()]) {
      if ((ref.kind === "document" && documentPath === ref.path) ||
          documentPath.startsWith(`${ref.path}/`)) {
        this.store.delete(documentPath);
      }
    }
  }

  /**
   * @param {Function} callback Corpo da transacao.
   * @return {Promise<*>} Resultado do callback.
   */
  async runTransaction(callback) {
    this.transactionCount += 1;
    const beforeTransaction = this.beforeTransactions[this.transactionCount];
    if (beforeTransaction) await beforeTransaction();
    const transaction = new FakeTransaction(this);
    const result = await callback(transaction);
    this.applyWrites(transaction.writes);
    if (this.afterTransactionCommit) {
      await this.afterTransactionCommit(this.transactionCount);
    }
    return result;
  }
}

/**
 * Cria um banco e preserva compatibilidade com os testes basicos anteriores.
 * @param {string[]} initialPaths Documentos inicialmente existentes.
 * @param {Function} onDelete Implementacao opcional da exclusao.
 * @return {FakeFirestore} Banco simulado.
 */
function createDb(initialPaths = [], onDelete) {
  const db = new FakeFirestore();
  for (const documentPath of initialPaths) db.seed(documentPath, {});
  db.documents = {
    get size() {
      return db.store.size;
    },
    [Symbol.iterator]() {
      return db.store.keys();
    },
    has(documentPath) {
      return db.store.has(documentPath);
    },
    delete(documentPath) {
      return db.store.delete(documentPath);
    },
  };
  db.calls = db.recursiveDeletes;
  if (onDelete) {
    db.recursiveDelete = async (ref) => {
      db.recursiveDeletes.push(ref.path);
      await onDelete({calls: db.calls, documents: db.documents, ref});
    };
  }
  return db;
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

const circleId = "circle-1";
const adminUid = "admin-user";
const remainingUid = "remaining-user";

/**
 * @param {Object} overrides Campos substituidos.
 * @return {Object} Circle V2 valido.
 */
function circleData(overrides = {}) {
  return {
    adminId: adminUid,
    memberCount: 2,
    memberLimit: 3,
    schemaVersion: 2,
    updatedAt: "fixture",
    ...overrides,
  };
}

/**
 * @param {string} role Papel do membro.
 * @return {Object} Membership minima.
 */
function memberData(role) {
  return {role};
}

/**
 * Prepara um Circle em que o usuario excluido e membro comum.
 * @param {FakeFirestore} db Banco fake.
 * @return {void}
 */
function seedNormalMemberCircle(db) {
  db.seed(rootPath, {activeCircleId: circleId});
  db.seed(`circles/${circleId}`, circleData());
  db.seed(
      `circles/${circleId}/members/${adminUid}`,
      memberData("admin"),
  );
  db.seed(`circles/${circleId}/members/${uid}`, memberData("member"));
}

/**
 * Prepara um Circle administrado pelo usuario excluido.
 * @param {FakeFirestore} db Banco fake.
 * @param {boolean} withRemainingMember Se inclui outro membro.
 * @return {void}
 */
function seedAdminCircle(db, withRemainingMember) {
  db.seed(rootPath, {activeCircleId: circleId});
  db.seed(`circles/${circleId}`, circleData({
    adminId: uid,
    memberCount: withRemainingMember ? 2 : 1,
  }));
  db.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  if (withRemainingMember) {
    db.seed(
        `circles/${circleId}/members/${remainingUid}`,
        memberData("member"),
    );
    db.seed(`users/${remainingUid}`, {activeCircleId: circleId, keep: true});
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

test("activeCircleId null preserva cleanup simples", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(`${rootPath}/tasks/task-1`, {title: "fixture"});

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.recursiveDeletes, [rootPath]);
  assert.equal(activeDb.store.size, 0);
});

test("membro comum sai atomicamente e Circle permanece", async () => {
  activeDb = new FakeFirestore();
  seedNormalMemberCircle(activeDb);

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 1);
  assert.equal(activeDb.data(`circles/${circleId}`) !== undefined, true);
  assert.equal(activeDb.data(rootPath), undefined);
});

test("cleanup preserva dados de outros UIDs nos challenges", async () => {
  const challengePath = `circles/${circleId}/challenges/challenge-1`;
  activeDb = new FakeFirestore();
  seedNormalMemberCircle(activeDb);
  activeDb.seed(challengePath, {title: "fixture"});
  activeDb.seed(`${challengePath}/progress/${uid}`, {value: 1});
  activeDb.seed(`${challengePath}/processed_events/event-a`, {uid});
  activeDb.seed(`${challengePath}/processed_events/event-b`, {
    uid: remainingUid,
  });

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(`${challengePath}/progress/${uid}`), undefined);
  assert.equal(
      activeDb.data(`${challengePath}/processed_events/event-a`),
      undefined,
  );
  assert.deepEqual(
      activeDb.data(`${challengePath}/processed_events/event-b`),
      {uid: remainingUid},
  );
});

test("retry de membro não decrementa memberCount novamente", async () => {
  const challengePath = `circles/${circleId}/challenges/challenge-1`;
  activeDb = new FakeFirestore();
  seedNormalMemberCircle(activeDb);
  activeDb.seed(challengePath, {title: "fixture"});
  activeDb.seed(`${challengePath}/progress/${uid}`, {value: 1});
  activeDb.failBatchAt = 1;

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 1);
  assert.equal(activeDb.data(rootPath) !== undefined, true);
  assert.equal(activeDb.recursiveDeletes.includes(rootPath), false);

  activeDb.failBatchAt = null;
  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 1);
  assert.equal(activeDb.data(rootPath), undefined);
});

test("admin unico remove Circle inteiro antes do usuario", async () => {
  activeDb = new FakeFirestore();
  seedAdminCircle(activeDb, false);
  const markerPath = `circle_deletions/${circleId}`;
  activeDb.afterTransactionCommit = (number) => {
    if (number !== 1) return;
    assert.equal(
        activeDb.data(markerPath).state,
        "AUTH_DELETE_ORPHAN_CLEANUP",
    );
    assert.equal(
        activeDb.data(`circles/${circleId}`).deletionState,
        "SERVER_DELETING",
    );
    assert.deepEqual(activeDb.recursiveDeletes, []);
  };

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.recursiveDeletes, [
    `circles/${circleId}`,
    rootPath,
  ]);
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  const markerSet = activeDb.operationLog.indexOf(`set:${markerPath}`);
  assert.ok(markerSet >= 0);
  assert.ok(
      markerSet <
        activeDb.operationLog.indexOf(`recursive:circles/${circleId}`),
  );
  assert.equal(activeDb.data(markerPath).version, 1);
  assert.equal(activeDb.data(markerPath).circleId, circleId);
  assert.equal(
      activeDb.operationLog.indexOf(`update:circles/${circleId}`) <
        activeDb.operationLog.indexOf(`recursive:circles/${circleId}`),
      true,
  );
});

test("admin com membros limpa referencias e não promove sucessor", async () => {
  activeDb = new FakeFirestore();
  seedAdminCircle(activeDb, true);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.data(`users/${remainingUid}`), {
    activeCircleId: null,
    keep: true,
  });
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  const markerPath = `circle_deletions/${circleId}`;
  const markerSet = activeDb.operationLog.indexOf(`set:${markerPath}`);
  assert.ok(markerSet >= 0);
  assert.ok(
      markerSet <
        activeDb.operationLog.indexOf(`recursive:circles/${circleId}`),
  );
  assert.equal(activeDb.data(markerPath).state, "AUTH_DELETE_ORPHAN_CLEANUP");
});

test("falha no Circle preserva user tree e retry conclui", async () => {
  activeDb = new FakeFirestore();
  seedAdminCircle(activeDb, true);
  activeDb.failRecursiveDeleteOnce.set(`circles/${circleId}`, 1);

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.equal(activeDb.data(rootPath) !== undefined, true);
  assert.equal(
      activeDb.data(`circles/${circleId}`).deletionState,
      "SERVER_DELETING",
  );
  assert.equal(activeDb.recursiveDeletes.includes(rootPath), false);
  const markerPath = `circle_deletions/${circleId}`;
  const marker = activeDb.data(markerPath);
  assert.equal(marker.state, "AUTH_DELETE_ORPHAN_CLEANUP");
  assert.ok(marker.createdAt instanceof Timestamp);

  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.deepEqual(activeDb.data(markerPath), marker);
  assert.equal(activeDb.operationLog.filter(
      (operation) => operation === `set:${markerPath}`,
  ).length, 1);
  assert.deepEqual(activeDb.recursiveDeletes, [
    `circles/${circleId}`,
    `circles/${circleId}`,
    rootPath,
  ]);
});

test("Circle root ausente limpa descendentes", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  activeDb.seed(
      `circles/${circleId}/members/${remainingUid}`,
      memberData("member"),
  );
  activeDb.seed(`users/${remainingUid}`, {
    activeCircleId: circleId,
    keep: true,
  });
  const challengePath = `circles/${circleId}/challenges/challenge-1`;
  activeDb.seed(`${challengePath}/progress/${uid}`, {value: 1});
  activeDb.seed(`${challengePath}/processed_events/event-a`, {uid});

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.data(`users/${remainingUid}`), {
    activeCircleId: null,
    keep: true,
  });
  assert.deepEqual(activeDb.recursiveDeletes, [
    `circles/${circleId}/members`,
    `circles/${circleId}/challenges`,
    rootPath,
  ]);
  assert.equal(activeDb.data(`${challengePath}/progress/${uid}`), undefined);
  assert.equal(
      activeDb.data(`${challengePath}/processed_events/event-a`),
      undefined,
  );
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  const markerPath = `circle_deletions/${circleId}`;
  const marker = activeDb.data(markerPath);
  assert.deepEqual(Object.keys(marker).sort(), [
    "circleId", "createdAt", "state", "version",
  ]);
  assert.equal(marker.state, "AUTH_DELETE_ORPHAN_CLEANUP");
  assert.equal(marker.circleId, circleId);
  assert.equal(marker.version, 1);
  assert.ok(marker.createdAt instanceof Timestamp);
  assert.equal(JSON.stringify(marker).includes(uid), false);
  assert.equal(JSON.stringify(marker).includes(remainingUid), false);
  assert.equal(JSON.stringify(marker).includes("uid"), false);
  assert.ok(
      activeDb.operationLog.indexOf(`set:${markerPath}`) <
        activeDb.operationLog.indexOf(`recursive:circles/${circleId}/members`),
  );
});

test("root recriado após claim não é apagado", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  activeDb.seed(
      `circles/${circleId}/members/${remainingUid}`,
      memberData("member"),
  );
  activeDb.seed(`users/${remainingUid}`, {activeCircleId: circleId});
  const newCircle = circleData({adminId: remainingUid, memberCount: 1});
  const markerPath = `circle_deletions/${circleId}`;
  let recreated = false;
  activeDb.afterTransactionCommit = (number) => {
    if (number !== 1) return;
    assert.equal(activeDb.data(`circles/${circleId}`), undefined);
    assert.equal(
        activeDb.data(markerPath).state,
        "AUTH_DELETE_ORPHAN_CLEANUP",
    );
    assert.deepEqual(activeDb.recursiveDeletes, []);
    activeDb.seed(`circles/${circleId}`, newCircle);
    recreated = true;
  };

  await cleanupUserData.run({uid});

  assert.equal(recreated, true);
  assert.deepEqual(activeDb.data(`circles/${circleId}`), newCircle);
  assert.equal(
      activeDb.recursiveDeletes.includes(`circles/${circleId}`),
      false,
  );
  assert.deepEqual(activeDb.recursiveDeletes, [
    `circles/${circleId}/members`,
    `circles/${circleId}/challenges`,
    rootPath,
  ]);
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  assert.deepEqual(activeDb.data(`users/${remainingUid}`), {
    activeCircleId: null,
  });
  assert.ok(activeDb.data(markerPath));
});

test("root recriado antes do claim impede cleanup residual", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("member"));
  const newCircle = circleData();
  activeDb.beforeTransactions[1] = () => {
    activeDb.seed(`circles/${circleId}`, newCircle);
    activeDb.seed(
        `circles/${circleId}/members/${adminUid}`,
        memberData("admin"),
    );
  };

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.equal(activeDb.transactionCount, 1);
  assert.deepEqual(activeDb.data(`circles/${circleId}`), newCircle);
  assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
  assert.deepEqual(
      activeDb.data(`circles/${circleId}/members/${adminUid}`),
      memberData("admin"),
  );
  assert.deepEqual(activeDb.recursiveDeletes, []);
  assert.equal(activeDb.data(`circle_deletions/${circleId}`), undefined);
  assert.deepEqual(activeDb.operationLog, []);
});

test("retry de root ausente preserva tombstone valido", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  activeDb.failRecursiveDeleteOnce.set(`circles/${circleId}/challenges`, 1);

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  const markerPath = `circle_deletions/${circleId}`;
  const marker = activeDb.data(markerPath);
  assert.ok(marker.createdAt instanceof Timestamp);
  assert.equal(marker.state, "AUTH_DELETE_ORPHAN_CLEANUP");
  assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.recursiveDeletes, [
    `circles/${circleId}/members`,
    `circles/${circleId}/challenges`,
    `circles/${circleId}/members`,
    `circles/${circleId}/challenges`,
    rootPath,
  ]);
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.deepEqual(activeDb.data(markerPath), marker);
  assert.equal(activeDb.operationLog.filter(
      (operation) => operation === `set:${markerPath}`,
  ).length, 1);
});

test("tombstone inconsistente falha fechado sem sobrescrita", async () => {
  const validMarker = {
    version: 1,
    state: "AUTH_DELETE_ORPHAN_CLEANUP",
    circleId,
    createdAt: Timestamp.now(),
  };
  const invalidMarkers = [
    {...validMarker, version: 2},
    {...validMarker, state: "SERVER_DELETING"},
    {...validMarker, circleId: "another-circle"},
    {...validMarker, createdAt: "invalid"},
    {...validMarker, createdAt: null},
    {...validMarker, uid},
    {},
  ];
  for (const marker of invalidMarkers) {
    activeDb = new FakeFirestore();
    activeDb.seed(rootPath, {activeCircleId: circleId});
    activeDb.seed(`circle_deletions/${circleId}`, marker);
    activeDb.seed(
        `circles/${circleId}/members/${remainingUid}`,
        memberData("member"),
    );
    activeDb.seed(`users/${remainingUid}`, {activeCircleId: circleId});

    await withoutErrorLog(() => assert.rejects(
        cleanupUserData.run({uid}),
        {message: "USER_DATA_CLEANUP_FAILED"},
    ));

    assert.deepEqual(activeDb.data(`circle_deletions/${circleId}`), marker);
    assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
    assert.deepEqual(activeDb.data(`users/${remainingUid}`), {
      activeCircleId: circleId,
    });
    assert.deepEqual(activeDb.recursiveDeletes, []);
    assert.deepEqual(activeDb.operationLog, []);
  }
});

test("activeCircleId invalido falha fechado sem apagar usuario", async () => {
  const invalidValues = ["", " bad ", "bad/id", "x".repeat(129)];
  for (const activeCircleId of invalidValues) {
    activeDb = new FakeFirestore();
    activeDb.seed(rootPath, {activeCircleId});

    await withoutErrorLog(() => assert.rejects(
        cleanupUserData.run({uid}),
        {message: "USER_DATA_CLEANUP_FAILED"},
    ));

    assert.equal(activeDb.data(rootPath) !== undefined, true);
    assert.deepEqual(activeDb.recursiveDeletes, []);
  }
});

test("logs do cleanup externo permanecem sanitizados", async () => {
  const email = "private@example.com";
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.failRecursiveDeleteOnce.set(rootPath, 1);

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
  const serialized = JSON.stringify(loggedArguments);
  assert.equal(serialized.includes(uid), false);
  assert.equal(serialized.includes(email), false);
  assert.equal(serialized.includes(rootPath), false);
  assert.equal(serialized.includes("private recursive delete failure"), false);
});
