
const cleanupManifest = require("../account_cleanup_manifest");
const realRemoveTree = cleanupManifest.removeTree;
// Preserve the genuine executor for the native arrangement of the two REDs.
Object.defineProperty(cleanupManifest,'__nativeRemoveTree',{value:realRemoveTree});
// Trace and pause the real versioned executor, not a fictitious SDK RPC.
cleanupManifest.removeTree = async options => {
  options.db.fixtureTreeOptions = options;
  return options.db.versionedDelete(options.ref);
};

function trackFixtureVersions(db) {
  db.fixtureVersions = new Map();
  let serial = 0, current;
  const touch = p => db.fixtureVersions.set(p, Timestamp.fromMillis(++serial));
  Object.defineProperty(db, "store", {
    configurable: true, get: () => current,
    set: value => {
      if (current) for (const [p, data] of value) if (current.get(p) !== data) touch(p);
      current = value;
      const set = current.set.bind(current), remove = current.delete.bind(current);
      current.set = (p, data) => {touch(p); return set(p, data);};
      current.delete = p => {touch(p); return remove(p);};
    },
  });
}

"use strict";

const assert = require("node:assert/strict");
const {createHash} = require("node:crypto");
const test = require("node:test");
const {Timestamp} = require("firebase-admin/firestore");

// Preserve the isolated runner's explicit project; historical offline fixtures
// retain their old model binding and do not gain trusted admission.
process.env.GCLOUD_PROJECT ??= "demo-life-os-p1";

// Load the Functions SDK before replacing only the Admin SDK used by index.js.
require("firebase-functions/v1");
const adminPath = require.resolve("firebase-admin");
const indexPath = require.resolve("../index");
require(adminPath);

let activeDb;
// Test-only server configuration through the existing R6B2 seam. The installed
// callback still invokes prepare at its real boundary; no admission is faked.
const fixtureBirthCleanup = require("../birth_ledger_cleanup");
const productionPrepare = fixtureBirthCleanup.prepare;
fixtureBirthCleanup.prepare = (...args) => args[0]?.nativeAuth ?
  productionPrepare(...args) : productionPrepare(...args,
    {verified: true, notBefore: Timestamp.fromMillis(1)});

const originalAdmin = require.cache[adminPath].exports;
require.cache[adminPath].exports = {
  initializeApp() {},
  firestore() {
    return activeDb;
  },
  auth() {
    return {getUser: async (owner) => {
      assert.equal(owner, activeDb.accountUid || uid);
      if (activeDb.nativeAuth) {
        if (activeDb.authHook) await activeDb.authHook(owner);
        return activeDb.nativeAuth.getUser(owner);
      }
      activeDb.fixtureTrace.push({kind: "auth.lookup", uid: owner, present: !!activeDb.authUser});
      if (activeDb.authHook) await activeDb.authHook(owner);
      if (activeDb.authError) throw activeDb.authError;
      if (activeDb.authUser) return activeDb.authUser;
      throw Object.assign(new Error("synthetic not found"),
          {code: "auth/user-not-found"});
    }};
  },
};

delete require.cache[indexPath];
const {cleanupUserData} = require(indexPath);
require.cache[adminPath].exports = originalAdmin;

// Existing unit calls exercise the trusted handler, with managed v1 context.
// Explicit contexts still reach the real callback unchanged for refusal tests.
const managedCleanupRun = cleanupUserData.run;
cleanupUserData.run = (user, context = {eventId: "synthetic-legacy-delete",
  eventType: "google.firebase.auth.user.delete",
  timestamp: "2026-10-13T23:59:59Z", params: {},
  resource: {service: "firebaseauth.googleapis.com",
    name: "projects/demo-life-os-p1"}}) => managedCleanupRun(user, context);

const uid = "sensitive-uid";
const rootPath = `users/${uid}`;
const guardPath = `account_deletion_guards/${uid}`;
const accountHash = createHash("sha256").update(uid, "utf8").digest("hex");
const billingAccountPath = `billing_google_accounts/${accountHash}`;
const billingTokenPath = (id) => `billing_google_tokens/${id}`;

test("P1 runtime identity: v1 onDelete and retry stay unchanged", () => {
  const baseline = require("firebase-functions/v1")
      .runWith({failurePolicy: true})
      .auth.user().onDelete(async () => {});
  const account =
    "life-os-cleanup-runtime@life-os-27b92.iam.gserviceaccount.com";
  const actualEndpoint = {...cleanupUserData.__endpoint};
  const originalEndpoint = {...baseline.__endpoint};
  const actualTrigger = {...cleanupUserData.__trigger};
  const originalTrigger = {...baseline.__trigger};
  assert.equal(actualEndpoint.platform, "gcfv1");
  assert.equal(actualEndpoint.serviceAccountEmail, account);
  assert.equal(actualTrigger.serviceAccountEmail, account);
  assert.equal(typeof managedCleanupRun, "function");
  assert.equal(require("../package.json").engines.node, "22");
  delete actualEndpoint.serviceAccountEmail;
  delete originalEndpoint.serviceAccountEmail;
  delete actualTrigger.serviceAccountEmail;
  delete originalTrigger.serviceAccountEmail;
  // Compare real SDK metadata, including event, retry and region defaults.
  assert.deepEqual(actualEndpoint, originalEndpoint);
  assert.deepEqual(actualTrigger, originalTrigger);
});

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
  // Match Admin listDocuments(showMissing): descendants imply an ancestor ID.
  async listCollections() {
    const prefix = this.path + "/";
    const names = [...new Set([...this.db.store.keys()].filter(p => p.startsWith(prefix))
      .map(p => p.slice(prefix.length).split("/")[0]))];
    return names.map(name => ({path: prefix + name,
      listDocuments: async () => [...new Set([...this.db.store.keys()]
        .filter(p => p.startsWith(prefix + name + "/"))
        .map(p => prefix + name + "/" + p.slice((prefix + name + "/").length).split("/")[0]))]
        .map(p => this.db.doc(p))}));
  }

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

  orderBy() { return this; }

  startAfter(snapshot) { this.cursor = snapshot.ref.path; return this; }

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

  orderBy() { return new FakeQuery(this); }
}

/** Snapshot fake de documento. */
class FakeDocumentSnapshot {
  /**
   * @param {FakeDocumentReference} ref Referencia.
   * @param {Object|undefined} data Dados atuais.
   */
  constructor(ref, data) {
    this.ref = ref;
    this.id = ref.path.split('/').at(-1);
    this.exists = data !== undefined;
    this._data = data;
    if (this.exists) this.updateTime = ref.db.fixtureVersions.get(ref.path) || Timestamp.fromMillis(0);
    if (this.exists) {
      this.createTime = ref.db.createTimes && ref.db.createTimes.has(ref.path) ?
        ref.db.createTimes.get(ref.path) : Timestamp.fromMillis(0);
    }
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
  create(ref, data) {
    this.writes.push({type: "create", ref, data});
    return this;
  }

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

  create(ref, data) {
    this.hasWritten = true;
    return super.create(ref, data);
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
    this.projectId = "demo-life-os-p1";
    this.databaseId = "(default)";
    this.createTimes = new Map();
    this.fixtureTrace = [];
    Object.defineProperty(this, "authUser", {configurable: true,
      get: () => this.fixtureAuthUser,
      set: value => {
        this.fixtureAuthUser = value;
        this.fixtureTrace.push({kind: "auth.set", present: !!value, uid: value?.uid});
      }});
    trackFixtureVersions(this);
    this.store = new Map();
    this.versionedDeletes = [];
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
  doc(path) { return new FakeDocumentReference(this, path); }

  collection(name) {
    return new FakeCollectionReference(this, name);
  }

  collectionGroup(name) {
    const ref = new FakeCollectionReference(this, name);
    ref.group = name;
    return ref;
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
    if (data?.syntheticRecreatedAccount || data?.syntheticRecreatedData) {
      this.fixtureTrace.push({kind: "adversarial.seed", path: documentPath});
    }
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
    if (ref.path.startsWith("circle_cleanup_guards/")) {
      this.fixtureTrace.push({kind: "closure.read", path: ref.path, exists: this.store.has(ref.path)});
    }
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
      if (collectionRef.group) {
        if (documentPath.split('/').at(-2) !== collectionRef.group) continue;
      } else {
        if (!documentPath.startsWith(prefix)) continue;
        const suffix = documentPath.slice(prefix.length);
        if (!suffix || suffix.includes('/')) continue;
      }
      if (ref.cursor && documentPath <= ref.cursor) continue;
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
    const committedLog = [];
    for (const write of writes) {
      if (write.type === "delete") {
        next.delete(write.ref.path);
      } else if (write.type === "create") {
        if (next.has(write.ref.path)) throw new Error("existing create");
        next.set(write.ref.path, write.data);
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
      committedLog.push(`${write.type}:${write.ref.path}`);
    }
    this.store = next;
    this.operationLog.push(...committedLog);
  }

  /**
   * @param {FakeDocumentReference|FakeCollectionReference} ref Raiz removida.
   * @return {Promise<void>} Conclusao da exclusao.
   */
  async versionedDelete(ref) {
    this.versionedDeletes.push(ref.path);
    this.operationLog.push(`versioned:${ref.path}`);
    const failures = this.failRecursiveDeleteOnce?.get(ref.path) || 0;
    if (failures > 0) {
      this.failRecursiveDeleteOnce.set(ref.path, failures - 1);
      throw new Error("versioned executor transport failure");
    }
    return realRemoveTree(this.fixtureTreeOptions);
  }

  /**
   * @param {Function} callback Corpo da transacao.
   * @return {Promise<*>} Resultado do callback.
   */
  async runTransaction(callback) {
    const previous = this.transactionTail || Promise.resolve();
    let release;
    this.transactionTail = new Promise((resolve) => { release = resolve; });
    await previous;
    try {
    this.transactionCount += 1;
    const beforeTransaction = this.beforeTransactions[this.transactionCount];
    if (beforeTransaction) await beforeTransaction();
    const transaction = new FakeTransaction(this);
    const result = await callback(transaction);
    if (this.failHistoryOnce && transaction.writes.some((write) =>
      /\/(processed_events|progress|ranking)\//.test(write.ref.path))) {
      this.failHistoryOnce = false;
      throw new Error('private cleanup failure');
    }
    this.applyWrites(transaction.writes);
    if (this.afterTransactionCommit) {
      await this.afterTransactionCommit(this.transactionCount);
    }
    return result;
    } catch (error) {
      this.fixtureTrace.push({kind: "transaction.error", code: error?.code, message: error?.message});
      throw error;
    } finally { release(); }
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
  db.calls = db.versionedDeletes;
  if (onDelete) {
    db.versionedDelete = async (ref) => {
      db.versionedDeletes.push(ref.path);
      await onDelete({calls: db.calls, documents: db.documents, ref});
      return realRemoveTree(db.fixtureTreeOptions);
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

function progressData(value = 1) {
  return {uid, value, updatedAt: Timestamp.fromMillis(100), lastEventAt: Timestamp.fromMillis(100)};
}

function focusEvent(id) {
  return {uid, source: 'VERIFIED_FOCUS', sessionId: id, challengeType: 'FOCUS_MINUTES',
    contributionValue: 1, sessionStartedAt: Timestamp.fromMillis(0),
    sessionCompletedAt: Timestamp.fromMillis(100), processedAt: Timestamp.fromMillis(100), schemaVersion: 1};
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
 * Prepara um Circle de membro comum com a quantidade indicada de memberships.
 * @param {FakeFirestore} db Banco fake.
 * @param {number} memberLimit Limite persistido no Circle.
 * @param {number} membershipCount Quantidade de memberships existentes.
 * @return {void}
 */
function seedNormalMemberCircleWithMemberships(
    db, memberLimit, membershipCount) {
  db.seed(rootPath, {activeCircleId: circleId});
  db.seed(`circles/${circleId}`, circleData({
    memberCount: membershipCount,
    memberLimit,
  }));
  db.seed(
      `circles/${circleId}/members/${adminUid}`,
      memberData("admin"),
  );
  db.seed(`circles/${circleId}/members/${uid}`, memberData("member"));
  for (let index = 2; index < membershipCount; index += 1) {
    db.seed(
        `circles/${circleId}/members/member-${index}`,
        memberData("member"),
    );
  }
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

// Installed only by the explicitly reconciled historical cases. No existing
// fixture, RED helper or previously approved Circles helper is changed.
function observeHistoricalR5(db) {
  const receiptPath = guardPath + "/control/operation";
  const retiredPath = `retired_auth_identities/${uid}`;
  const state = {transactions: [], native: [], hooks: {}, original: null, admission: null};
  state.controls = () => ({guard: db.data(guardPath), receipt: db.data(receiptPath), retired: db.data(retiredPath)});
  const existing = state.controls();
  if (existing.receipt) state.original = existing;
  const run = db.runTransaction.bind(db);
  db.runTransaction = callback => run(async tx => {
    const row = {reads: [], writes: [], applied: false};
    state.transactions.push(row);
    const get = tx.get.bind(tx);
    tx.get = async ref => {
      if (state.hooks.beforeRead) await state.hooks.beforeRead(row, ref);
      row.reads.push(ref.path);
      return get(ref);
    };
    const result = await callback(tx);
    row.before = state.controls();
    row.writes = tx.writes.map(w => ({type: w.type, path: w.ref.path, data: w.data}));
    row.stage = row.writes.some(w => w.path === receiptPath && w.type === "create") ? "admission" :
      row.writes.some(w => w.path === receiptPath && w.data?.state === "COMPLETE") ? "completion" :
      row.writes.some(w => w.path === billingAccountPath && w.type === "delete") ? "billing-finalizer" :
      row.writes.some(w => w.path.startsWith("billing_google_tokens/") && w.type === "delete") ? "token-page" :
      row.writes.some(w => w.path.startsWith("circle_deletions/") && w.type === "set") ? "circle-claim" : "other";
    if (state.hooks.beforeCommit) await state.hooks.beforeCommit(row);
    state.pending = row;
    return result;
  });
  const apply = db.applyWrites.bind(db);
  db.applyWrites = writes => {
    const row = state.pending;
    state.pending = null;
    apply(writes);
    if (row) {
      row.applied = true;
      row.after = state.controls();
      if (row.stage === "admission") {
        state.admission = row;
        if (!state.original) state.original = row.after;
      }
      if (state.hooks.afterCommit) state.hooks.afterCommit(row);
    }
  };
  const recursive = db.versionedDelete.bind(db);
  db.versionedDelete = async ref => {
    const row = {path: ref.path, controls: state.controls(), completed: false};
    state.native.push(row);
    await recursive(ref);
    row.completed = true;
  };
  return state;
}

function assertHistoricalControls(db, evidence, expectedState) {
  const current = evidence.controls(), original = evidence.original;
  assert.ok(original);
  assert.equal(current.guard.state, expectedState);
  assert.equal(current.receipt.state, expectedState);
  assert.equal(current.guard.deletionId, original.guard.deletionId);
  assert.ok(current.guard.startedAt.isEqual(original.guard.startedAt));
  assert.deepEqual(current.retired, original.retired);
  assert.deepEqual(current.receipt, {...original.receipt, state: expectedState,
    completedAt: expectedState === "COMPLETE" ? current.receipt.completedAt : null});
  assert.equal(current.receipt.uid, uid);
  assert.equal(current.receipt.projectId, db.projectId);
  assert.equal(current.receipt.databaseId, db.databaseId);
  assert.equal(current.receipt.scope.privateRoot, rootPath);
  assert.equal(current.receipt.scope.billingAccountHash, accountHash);
  assert.equal(current.retired.deletionId, current.guard.deletionId);
  if (expectedState === "COMPLETE") assert.ok(current.receipt.completedAt instanceof Timestamp);
  else assert.equal(current.guard.retainUntil, null);
  if (evidence.admission) {
    assert.deepEqual(evidence.admission.writes.map(w => [w.type, w.path]), [
      ["create", `retired_auth_identities/${uid}`], ["create", guardPath], ["create", guardPath + "/control/operation"],
    ]);
    assert.equal(evidence.transactions.filter(row => row.stage === "admission").length, 1);
  }
  for (const row of evidence.transactions.filter(r => r.writes.length && r.stage !== "admission")) {
    assert.equal(row.before.receipt.deletionId, original.receipt.deletionId);
    assert.deepEqual(row.before.receipt.scope, original.receipt.scope);
  }
}

function assertOnlyHistoricalR5Controls(db, evidence) {
  assert.equal(activeDb.data(guardPath).state, 'COMPLETE');
  const audit = [...db.store.keys()].filter(p => p.startsWith(guardPath + "/cleanup_manifests/"));
  assert.ok(audit.length > 0);
  for (const p of audit) {
    const data = db.data(p);
    assert.equal(data.version, 2);
    if (p.includes("/pages/")) assert.equal(data.done, true);
    else assert.equal(data.state, "COMPLETE");
  }
  assert.deepEqual([...db.store.keys()].filter(p => !audit.includes(p)),
    [`retired_auth_identities/${uid}`, guardPath, guardPath + "/control/operation"]);
  assertHistoricalControls(db, evidence, "COMPLETE");
}

function reportHistoricalR5(db, evidence, extra = {}) {
  const current = evidence.controls();
  db.fixtureTrace.push({kind: "historical.r5.evidence", ...extra,
    stages: evidence.transactions.filter(r => r.writes.length).map(r => ({stage: r.stage, applied: r.applied,
      writes: r.writes.map(w => ({type: w.type, path: w.path})), injected: r.injected === true})),
    native: evidence.native.map(r => ({path: r.path, completed: r.completed})),
    originalDeletionId: evidence.original?.receipt?.deletionId, deletionId: current.receipt?.deletionId,
    originalScope: evidence.original?.receipt?.scope, scope: current.receipt?.scope,
    guard: current.guard?.state, receipt: current.receipt?.state});
}


test("versionedDelete resolve e o handler resolve", async () => {
  activeDb = createDb([rootPath, `${rootPath}/tasks/task-1`]);

  const evidence = observeHistoricalR5(activeDb);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.calls, [rootPath]);
  assertOnlyHistoricalR5Controls(activeDb, evidence);
  reportHistoricalR5(activeDb, evidence);
});

test("versionedDelete rejeita e propaga erro sanitizado", async () => {
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
          throw new Error("transient internal failure");
        }


      },
  );

  const evidence = observeHistoricalR5(activeDb);

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));
  assert.equal(activeDb.documents.has(remainingPath), true);

  assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");
  await cleanupUserData.run({uid});

  assert.equal(activeDb.calls.length, 2);
  assertOnlyHistoricalR5Controls(activeDb, evidence);
  reportHistoricalR5(activeDb, evidence);
});

test("root ausente ainda executa versionedDelete", async () => {
  const descendantPath = `${rootPath}/tasks/task-1`;
  activeDb = createDb([descendantPath]);

  const evidence = observeHistoricalR5(activeDb);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.calls, [rootPath]);
  assertOnlyHistoricalR5Controls(activeDb, evidence);
  reportHistoricalR5(activeDb, evidence);
});

test("árvore totalmente ausente termina normalmente", async () => {
  activeDb = createDb();

  const evidence = observeHistoricalR5(activeDb);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.calls, [rootPath]);
  assertOnlyHistoricalR5Controls(activeDb, evidence);
  reportHistoricalR5(activeDb, evidence);
});

test("duas execuções concorrentes permanecem idempotentes", async () => {
  activeDb = createDb([
    rootPath,
    `${rootPath}/tasks/task-1`,
    `${rootPath}/runtime/account_deletion`,
  ]);

  const evidence = observeHistoricalR5(activeDb);

  await Promise.all([
    cleanupUserData.run({uid}),
    cleanupUserData.run({uid}),
  ]);

  assert.deepEqual(activeDb.calls, [rootPath, rootPath]);
  assertOnlyHistoricalR5Controls(activeDb, evidence);
  reportHistoricalR5(activeDb, evidence);
});

test("activeCircleId null preserva cleanup simples", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(`${rootPath}/tasks/task-1`, {title: "fixture"});

  const evidence = observeHistoricalR5(activeDb);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.versionedDeletes, [rootPath]);
  assertOnlyHistoricalR5Controls(activeDb, evidence);
  reportHistoricalR5(activeDb, evidence);
});

test("usuário sem billing usa barrier transitória e não deixa índices", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});

  const evidence = observeHistoricalR5(activeDb);

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(billingAccountPath), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  const mh = cleanupManifest.refs(activeDb, activeDb.data(guardPath + "/control/operation"), rootPath).header.path;
  assert.deepEqual(activeDb.operationLog, [
    `create:retired_auth_identities/${uid}`,
    `create:${guardPath}`,
    `create:${guardPath}/control/operation`,
    `set:${billingAccountPath}`,
    `create:${mh}`,
    `create:${mh}/pages/0`,
    `versioned:${rootPath}`,
    `delete:${rootPath}`,
    `update:${mh}/pages/0`,
    `update:${mh}`,
    `delete:${billingAccountPath}`,
    `update:${guardPath}`,
    `update:${guardPath}/control/operation`,
  ]);
  assertHistoricalControls(activeDb, evidence, "COMPLETE");
  reportHistoricalR5(activeDb, evidence);
});

test("account ACTIVE fecha barrier antes de tokens e finaliza por último", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid, state: "ACTIVE", future: true});
  activeDb.seed(billingTokenPath("token-a"), {accountHash});
  activeDb.seed(billingTokenPath("token-b"), {accountHash});

  await cleanupUserData.run({uid});

  const barrier = activeDb.operationLog.indexOf(`update:${billingAccountPath}`);
  const firstToken = activeDb.operationLog.indexOf(
      `delete:${billingTokenPath("token-a")}`,
  );
  const userDelete = activeDb.operationLog.indexOf(`versioned:${rootPath}`);
  const accountDelete = activeDb.operationLog.indexOf(
      `delete:${billingAccountPath}`,
  );
  assert.ok(barrier >= 0);
  assert.ok(barrier < firstToken);
  assert.ok(firstToken < userDelete);
  assert.ok(userDelete < accountDelete);
  assert.equal(activeDb.data(billingAccountPath), undefined);
  assert.equal(activeDb.data(billingTokenPath("token-a")), undefined);
  assert.equal(activeDb.data(billingTokenPath("token-b")), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
});

test("orphan DELETING sem user conclui idempotentemente", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(billingAccountPath, {uid, state: "DELETING"});

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(billingAccountPath), undefined);
  assert.deepEqual(activeDb.versionedDeletes, [rootPath]);
});

test("205 token indexes são removidos em páginas limitadas", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid, state: "ACTIVE"});
  const originalPaths = [];
  for (let index = 0; index < 205; index += 1) {
    const path = billingTokenPath(`token-${String(index).padStart(3, "0")}`);
    originalPaths.push(path);
    activeDb.seed(path, {accountHash});
  }
  const foreign = billingTokenPath("foreign");
  activeDb.seed(foreign, {accountHash: "other-owner", keep: true});
  const evidence = observeHistoricalR5(activeDb);

  await cleanupUserData.run({uid});

  const pages = evidence.transactions.filter(row => row.stage === "token-page");
  assert.deepEqual(pages.map(row => row.writes.length), [100, 100, 5]);
  assert.ok(pages.every(row => row.applied && row.writes.every(w => w.type === "delete" && originalPaths.includes(w.path))));
  assert.deepEqual(pages.flatMap(row => row.writes.map(w => w.path)).sort(), originalPaths.sort());
  assert.equal(originalPaths.some(path => activeDb.data(path)), false);
  assert.deepEqual(activeDb.data(foreign), {accountHash: "other-owner", keep: true});
  assert.equal(activeDb.operationLog.some(entry => entry.endsWith(":" + foreign)), false);
  assert.equal(activeDb.data(billingAccountPath), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  assertHistoricalControls(activeDb, evidence, "COMPLETE");
  reportHistoricalR5(activeDb, evidence, {pages: pages.map(row => row.writes.length), foreignPreserved: true});
});

test("falha no cleanup de tokens mantém barrier e user para retry", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid, state: "ACTIVE"});
  activeDb.seed(billingTokenPath("token-a"), {accountHash});
  for (let index = 0; index < 204; index++) activeDb.seed(billingTokenPath(`token-${String(index).padStart(3, "0")}`), {accountHash});
  const foreign = billingTokenPath("foreign");
  activeDb.seed(foreign, {accountHash: "other-owner", keep: true});
  const evidence = observeHistoricalR5(activeDb);
  let failed = false, pagesAttempted = 0;
  evidence.hooks.beforeCommit = row => {
    if (row.stage === "token-page" && ++pagesAttempted === 2) {
      failed = true; row.injected = true;
      throw new Error("synthetic token page commit refused");
    }
  };

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.deepEqual(activeDb.data(billingAccountPath), {
    uid,
    state: "DELETING",
  });
  assert.equal(activeDb.data(rootPath) !== undefined, true);
  assert.equal(activeDb.data(billingTokenPath("token-a")) !== undefined, true);
  assert.deepEqual(activeDb.versionedDeletes, []);
  assert.equal(failed, true);
  assert.equal(pagesAttempted, 2);
  assert.equal([...activeDb.store.values()].filter(data => data.accountHash === accountHash).length, 105);
  assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");

  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(billingAccountPath), undefined);
  assert.equal(activeDb.data(billingTokenPath("token-a")), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  assert.deepEqual(evidence.transactions.filter(row => row.stage === "token-page").map(row => [row.writes.length, row.applied]),
      [[100, true], [100, false], [100, true], [5, true]]);
  assert.equal([...activeDb.store.values()].some(data => data.accountHash === accountHash), false);
  assert.deepEqual(activeDb.data(foreign), {accountHash: "other-owner", keep: true});
  assert.equal(activeDb.operationLog.some(entry => entry.endsWith(":" + foreign)), false);
  assertHistoricalControls(activeDb, evidence, "COMPLETE");
  reportHistoricalR5(activeDb, evidence, {failed, pagesAttempted, foreignPreserved: true});
});

test("falha no versionedDelete mantém barrier para retry", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid, state: "ACTIVE"});
  activeDb.seed(billingTokenPath("token-a"), {accountHash});
  activeDb.failRecursiveDeleteOnce.set(rootPath, 1);

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.equal(activeDb.data(billingAccountPath).state, "DELETING");
  assert.equal(activeDb.data(rootPath) !== undefined, true);
  assert.equal(activeDb.data(billingTokenPath("token-a")), undefined);

  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(billingAccountPath), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
});

test("falha na finalização deixa orphan DELETING recuperável", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid, state: "ACTIVE"});
  const evidence = observeHistoricalR5(activeDb);
  let failed = false;
  evidence.hooks.beforeCommit = row => {
    if (!failed && row.stage === "billing-finalizer") {
      assert.equal(activeDb.data(rootPath), undefined);
      assert.equal(activeDb.data(billingAccountPath).state, "DELETING");
      assert.equal(row.before.receipt.state, "IN_PROGRESS");
      failed = true; row.injected = true;
      throw new Error("private finalizer failure");
    }
  };
  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));
  assert.equal(failed, true);
  assert.equal(evidence.transactions.find(row => row.injected).applied, false);
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(billingAccountPath).state, "DELETING");
  assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");
  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(billingAccountPath), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  assertHistoricalControls(activeDb, evidence, "COMPLETE");
  reportHistoricalR5(activeDb, evidence, {failed, boundary: "billing-finalizer-commit"});
});

test("account UID divergente falha fechado antes de cleanup", async () => {
  const tokenPath = billingTokenPath("token-a");
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid: "different-user", state: "ACTIVE"});
  activeDb.seed(tokenPath, {accountHash});

  const evidence = observeHistoricalR5(activeDb);

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.deepEqual(activeDb.data(billingAccountPath), {
    uid: "different-user",
    state: "ACTIVE",
  });
  assert.equal(activeDb.data(tokenPath) !== undefined, true);
  assert.equal(activeDb.data(rootPath) !== undefined, true);
  assert.deepEqual(activeDb.versionedDeletes, []);
  assert.deepEqual(activeDb.operationLog, [`create:retired_auth_identities/${uid}`,
    `create:${guardPath}`, `create:${guardPath}/control/operation`]);
  assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");
  reportHistoricalR5(activeDb, evidence);
});

test("account state inválido falha fechado", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid, state: "UNKNOWN"});

  const evidence = observeHistoricalR5(activeDb);

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.deepEqual(activeDb.data(billingAccountPath), {uid, state: "UNKNOWN"});
  assert.equal(activeDb.data(rootPath) !== undefined, true);
  assert.deepEqual(activeDb.versionedDeletes, []);
  assert.deepEqual(activeDb.operationLog, [`create:retired_auth_identities/${uid}`,
    `create:${guardPath}`, `create:${guardPath}/control/operation`]);
  assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");
  reportHistoricalR5(activeDb, evidence);
});

test("token indexes sem account inicial convergem sem resíduos", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingTokenPath("token-a"), {accountHash});
  activeDb.seed(billingTokenPath("token-b"), {accountHash});

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(billingAccountPath), undefined);
  assert.equal(activeDb.data(billingTokenPath("token-a")), undefined);
  assert.equal(activeDb.data(billingTokenPath("token-b")), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
});

test("token surgindo antes do finalizer mantém barrier até retry", async () => {
  const lateTokenPath = billingTokenPath("late-token");
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid, state: "ACTIVE"});
  const evidence = observeHistoricalR5(activeDb);
  let injected = false;
  evidence.hooks.beforeRead = (row, ref) => {
    if (!injected && ref.path === "billing_google_tokens" && !activeDb.data(rootPath)) {
      assert.equal(activeDb.data(billingAccountPath).state, "DELETING");
      assert.ok(ref.filters.some(filter => filter.field === "accountHash" && filter.value === accountHash));
      activeDb.seed(lateTokenPath, {accountHash});
      injected = true; row.injected = true;
    }
  };
  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));
  assert.equal(injected, true);
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(lateTokenPath) !== undefined, true);
  assert.equal(activeDb.data(billingAccountPath).state, "DELETING");
  assert.ok(activeDb.fixtureTrace.some(row => row.kind === "transaction.error" && row.message === "BILLING_CLEANUP_INCOMPLETE"));
  assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");
  await withoutErrorLog(() => assert.rejects(cleanupUserData.run({uid}),
    {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(activeDb.data(billingAccountPath).state, "DELETING");
  assert.ok(activeDb.data(lateTokenPath));
  assert.equal(activeDb.data(guardPath).state, "IN_PROGRESS");

});

test("account removido durante finalização converge idempotentemente", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(billingAccountPath, {uid, state: "ACTIVE"});
  activeDb.beforeTransactions[5] = () => {
    activeDb.store.delete(billingAccountPath);
  };

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(billingAccountPath), undefined);
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

test("memberLimit 30 aceita exclusão de membro comum", async () => {
  activeDb = new FakeFirestore();
  seedNormalMemberCircleWithMemberships(activeDb, 30, 2);

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 1);
  assert.equal(activeDb.data(rootPath), undefined);
});

test("memberLimit 30 aceita exclusão do administrador", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}`, circleData({
    adminId: uid,
    memberCount: 30,
    memberLimit: 30,
  }));
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  for (let index = 1; index < 30; index += 1) {
    activeDb.seed(
        `circles/${circleId}/members/member-${index}`,
        memberData("member"),
    );
  }

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  assert.deepEqual(activeDb.versionedDeletes, [
    `circles/${circleId}`,
    rootPath,
  ]);
});

test("Circle válido com 30 memberships conclui cleanup", async () => {
  activeDb = new FakeFirestore();
  seedNormalMemberCircleWithMemberships(activeDb, 30, 30);

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 29);
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.deepEqual(
      activeDb.data(`circles/${circleId}/members/member-29`),
      memberData("member"),
  );
  assert.equal(activeDb.data(rootPath), undefined);
});

test("mais de 30 memberships falha fechado", async () => {
  const privatePath = `${rootPath}/tasks/task-1`;
  activeDb = new FakeFirestore();
  seedNormalMemberCircleWithMemberships(activeDb, 30, 30);
  activeDb.seed(
      `circles/${circleId}/members/overflow-member`,
      memberData("member"),
  );
  activeDb.seed(privatePath, {title: "private"});

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
  assert.deepEqual(activeDb.data(privatePath), {title: "private"});
  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 30);
  assert.deepEqual(activeDb.versionedDeletes, []);
});

test("memberLimit legado 10 continua aceito", async () => {
  activeDb = new FakeFirestore();
  seedNormalMemberCircleWithMemberships(activeDb, 10, 10);

  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 9);
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
});

test("memberLimit fora de 3, 10 e 30 falha fechado", async () => {
  for (const memberLimit of [11, 31]) {
    const privatePath = `${rootPath}/tasks/task-${memberLimit}`;
    activeDb = new FakeFirestore();
    seedNormalMemberCircleWithMemberships(activeDb, memberLimit, 2);
    activeDb.seed(privatePath, {title: "private"});

    await withoutErrorLog(() => assert.rejects(
        cleanupUserData.run({uid}),
        {message: "USER_DATA_CLEANUP_FAILED"},
    ));

    assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
    assert.deepEqual(activeDb.data(privatePath), {title: "private"});
    assert.equal(activeDb.data(`circles/${circleId}`).memberLimit, memberLimit);
    assert.deepEqual(activeDb.versionedDeletes, []);
  }
});

test("cleanup preserva dados de outros UIDs nos challenges", async () => {
  const challengePath = `circles/${circleId}/challenges/challenge-1`;
  activeDb = new FakeFirestore();
  seedNormalMemberCircle(activeDb);
  activeDb.seed(challengePath, {title: "fixture"});
  activeDb.seed(`${challengePath}/progress/${uid}`, progressData());
  activeDb.seed(`${challengePath}/processed_events/event-a`, focusEvent('event-a'));
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
  activeDb.seed(`${challengePath}/progress/${uid}`, progressData());
  activeDb.failHistoryOnce = true;

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 1);
  assert.equal(activeDb.data(rootPath) !== undefined, true);
  assert.equal(activeDb.versionedDeletes.includes(rootPath), false);

  activeDb.failBatchAt = null;
  await cleanupUserData.run({uid});

  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 1);
  assert.equal(activeDb.data(rootPath), undefined);
});

test("admin unico remove Circle inteiro antes do usuario", async () => {
  activeDb = new FakeFirestore();
  seedAdminCircle(activeDb, false);
  const markerPath = `circle_deletions/${circleId}`;
  const evidence = observeHistoricalR5(activeDb);
  let claimed = 0, originalClaim;
  evidence.hooks.afterCommit = row => {
    if (row.stage !== "circle-claim") return;
    claimed += 1;
    originalClaim = activeDb.data(markerPath);
    assert.equal(originalClaim.state, "SERVER_DELETING");
    assert.equal(originalClaim.initiatedBy, uid);
    assert.deepEqual(originalClaim.memberUids, [uid]);
    assert.equal(
        activeDb.data(`circles/${circleId}`).deletionState,
        "SERVER_DELETING",
    );
    assert.deepEqual(activeDb.versionedDeletes, []);
  };
  await cleanupUserData.run({uid});
  assert.equal(claimed, 1);
  assert.deepEqual(activeDb.versionedDeletes, [
    `circles/${circleId}`,
    rootPath,
  ]);
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal(activeDb.data(rootPath), undefined);
  const markerSet = activeDb.operationLog.indexOf(`set:${markerPath}`);
  assert.ok(markerSet >= 0);
  assert.ok(
      markerSet <
        activeDb.operationLog.indexOf(`versioned:circles/${circleId}`),
  );
  assert.equal(originalClaim.version, 1);
  assert.equal(originalClaim.circleId, circleId);
  assert.equal(activeDb.data(markerPath), undefined);
  assert.equal(activeDb.data(`circle_cleanup_guards/${circleId}`).state, "SERVER_DELETING");
  assert.equal(
      activeDb.operationLog.indexOf(`update:circles/${circleId}`) <
        activeDb.operationLog.indexOf(`versioned:circles/${circleId}`),
      true,
  );
  assertHistoricalControls(activeDb, evidence, "COMPLETE");
  reportHistoricalR5(activeDb, evidence, {claimed});
});

// Read-only instrumentation installed exclusively by the six reconciled cases.
// The existing fake and the RED/adversarial helpers remain unchanged.
function observeCircleReconciliation(db) {
  const operationPath = guardPath + "/control/operation";
  const reservationPath = `retired_auth_identities/${uid}`;
  const markerPath = `circle_deletions/${circleId}`;
  const closurePath = `circle_cleanup_guards/${circleId}`;
  const prefix = `circles/${circleId}/`;
  const evidence = {commits: [], native: [], absentParents: [], pageAttempts: 0,
    failedPages: 0, failPageOnce: null, original: null, originalClaim: null};
  const snapshot = () => ({guard: db.data(guardPath), operation: db.data(operationPath),
    reservation: db.data(reservationPath), claim: db.data(markerPath), closure: db.data(closurePath)});
  const apply = db.applyWrites.bind(db);
  db.applyWrites = writes => {
    const row = {before: snapshot(), writes: writes.map(w => ({type: w.type, path: w.ref.path})), applied: false};
    const circleDeletes = writes.filter(w => w.type === "delete" && w.ref.path.startsWith(prefix));
    row.page = circleDeletes.length > 0;
    if (row.page) {
      evidence.pageAttempts += 1;
      const receipts = writes.filter(w => w.type === "update" &&
        w.ref.path.startsWith(guardPath + "/cleanup_manifests/") &&
        w.ref.path.includes("/pages/") && w.data.done === true);
      assert.equal(writes.length, circleDeletes.length + receipts.length,
        "concrete Circle deletes and their atomic receipts only");
      assert.ok(receipts.length <= 1);
      assert.ok(writes.length <= 200);
      assert.ok(writes.every(w => w.ref.path.split("/").length % 2 === 0));
    }
    evidence.commits.push(row);
    if (row.page && evidence.pageAttempts === evidence.failPageOnce) {
      evidence.failPageOnce = null;
      evidence.failedPages += 1;
      row.failureInjected = true;
      db.fixtureTrace.push({kind: "circle.page.commit.refused", size: writes.length,
        deletionId: row.before.operation.deletionId, state: row.before.operation.state});
      throw new Error("synthetic Circle page commit refused");
    }
    apply(writes);
    row.applied = true;
    row.after = snapshot();
    if (!evidence.original && row.after.operation) evidence.original = row.after;
    if (!evidence.originalClaim && row.after.claim?.state === "SERVER_DELETING") evidence.originalClaim = row.after.claim;
    if (row.after.operation?.state === "COMPLETE") {
      assert.equal(db.data(rootPath), undefined, "COMPLETE follows private-root removal");
      assert.equal(db.data(`circles/${circleId}`), undefined);
      assert.equal([...db.store.keys()].some(p => p.startsWith(prefix)), false,
          "COMPLETE follows concrete descendant cleanup");
    }
  };
  const recursive = db.versionedDelete.bind(db);
  db.versionedDelete = async ref => {
    const row = {path: ref.path, controls: snapshot(), completed: false};
    evidence.native.push(row);
    assert.equal(row.controls.guard.state, "IN_PROGRESS");
    assert.equal(row.controls.operation.state, "IN_PROGRESS");
    await recursive(ref);
    row.completed = true;
  };
  const doc = db.doc.bind(db);
  db.doc = p => {
    const ref = doc(p);
    const list = ref.listCollections.bind(ref);
    ref.listCollections = async () => {
      if (p.startsWith(prefix) && !db.store.has(p)) evidence.absentParents.push(p);
      return list();
    };
    return ref;
  };
  evidence.snapshot = snapshot;
  return evidence;
}

function reportCircleReconciliation(db, evidence) {
  const current = evidence.snapshot();
  db.fixtureTrace.push({kind: "circle.reconciliation.evidence",
    nativeAttempts: evidence.native.map(row => ({path: row.path, completed: row.completed})),
    pages: evidence.commits.filter(row => row.page).map(row => ({size: row.writes.length,
      applied: row.applied, failureInjected: row.failureInjected === true})),
    absentParents: [...new Set(evidence.absentParents)], failedPages: evidence.failedPages,
    partialRootFaults: db.fixtureTrace.filter(row => row.kind === "circle.native.partial.root.removed").length,
    refusalObserved: db.fixtureTrace.some(row => row.kind === "transaction.error" && row.code === "ACCOUNT_STATE_CONFLICT"),
    originalDeletionId: evidence.original.operation.deletionId,
    finalDeletionId: current.operation.deletionId, originalScope: evidence.original.operation.scope,
    finalScope: current.operation.scope, guard: current.guard.state, receipt: current.operation.state,
    markerKeys: Object.keys(current.claim || {}).sort(), closurePresent: !!current.closure});
}

function seedCircleIsolation(db) {
  const sentinels = new Map([
    ["users/circle-outsider", {activeCircleId: "circle-foreign", keep: true}],
    ["users/circle-outsider/notes/keep", {private: true}],
    [`users/${remainingUid}/notes/keep`, {private: true}],
    ["circles/circle-foreign", circleData({adminId: "circle-outsider", memberCount: 1})],
    ["circles/circle-foreign/members/circle-outsider", memberData("admin")],
    ["circles/circle-foreign/challenges/keep/progress/circle-outsider", {uid: "circle-outsider", value: 7}],
  ]);
  for (const [p, data] of sentinels) db.seed(p, data);
  return () => {
    for (const [p, data] of sentinels) assert.deepEqual(db.data(p), data, p);
    assert.equal(db.operationLog.some(entry => [...sentinels.keys()].some(p => entry.endsWith(":" + p))), false);
  };
}

function assertCircleOriginalOperation(db, evidence, state) {
  const original = evidence.original;
  const current = evidence.snapshot();
  assert.ok(original);
  assert.deepEqual(current.reservation, original.reservation);
  assert.deepEqual(current.operation, {...original.operation, state,
    completedAt: state === "COMPLETE" ? current.operation.completedAt : null});
  assert.equal(current.guard.deletionId, original.guard.deletionId);
  assert.ok(current.guard.startedAt.isEqual(original.guard.startedAt));
  assert.equal(current.guard.state, state);
  assert.equal(db.operationLog.filter(entry => entry === "create:" + guardPath + "/control/operation").length, 1);
  for (const row of evidence.commits.filter(r => r.page)) {
    assert.equal(row.before.operation.state, "IN_PROGRESS");
    assert.equal(row.before.operation.deletionId, original.operation.deletionId);
    assert.deepEqual(row.before.operation.scope, original.operation.scope);
  }
  if (state === "COMPLETE") {
    assert.ok(current.operation.completedAt instanceof Timestamp);
    assert.equal(db.data(rootPath), undefined);
    assert.equal(db.data(`circles/${circleId}`), undefined);
    assert.equal([...db.store.keys()].some(p => p.startsWith(`circles/${circleId}/`)), false);
    assert.deepEqual(Object.keys(current.closure).sort(), ["createdAt", "state", "version"]);
    assert.equal(current.closure.state, "SERVER_DELETING");
    assert.equal(current.closure.version, 1);
    assert.ok(current.closure.createdAt instanceof Timestamp);
  } else {
    assert.equal(current.guard.retainUntil, null);
    assert.equal(current.operation.completedAt, null);
  }
}

function assertCircleTombstone(db, originalCreatedAt) {
  const marker = db.data(`circle_deletions/${circleId}`);
  assert.deepEqual(Object.keys(marker).sort(), ["circleId", "createdAt", "state", "version"]);
  assert.equal(marker.version, 1);
  assert.equal(marker.state, "AUTH_DELETE_ORPHAN_CLEANUP");
  assert.equal(marker.circleId, circleId);
  assert.ok(marker.createdAt instanceof Timestamp);
  if (originalCreatedAt) assert.ok(marker.createdAt.isEqual(originalCreatedAt));
  assert.equal(JSON.stringify(marker).includes(uid), false);
  assert.equal(JSON.stringify(marker).includes(remainingUid), false);
  assert.equal(JSON.stringify(marker).includes("uid"), false);
}

function assertCircleReplayReadOnly(db) {
  const before = {data: [...db.store], log: [...db.operationLog], native: [...db.versionedDeletes]};
  return cleanupUserData.run({uid}).then(() => {
    assert.deepEqual([...db.store], before.data);
    assert.deepEqual(db.operationLog, before.log);
    assert.deepEqual(db.versionedDeletes, before.native);
  });
}


test("admin com membros limpa referencias e não promove sucessor", async () => {
  activeDb = new FakeFirestore();
  seedAdminCircle(activeDb, true);
  const isolated = seedCircleIsolation(activeDb);
  const evidence = observeCircleReconciliation(activeDb);
  activeDb.seed(`circles/${circleId}/challenges/original/progress/${remainingUid}`, {uid: remainingUid, value: 2});

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
        activeDb.operationLog.indexOf(`versioned:circles/${circleId}`),
  );
  assert.equal(activeDb.data(markerPath), undefined);
  assert.equal(activeDb.operationLog.includes(`delete:${markerPath}`), true);
  assert.equal(activeDb.operationLog.some(entry => entry === `update:circles/${circleId}/members/${remainingUid}`), false);
  assert.deepEqual(evidence.originalClaim.memberUids.slice().sort(), [remainingUid, uid].sort());
  assert.equal(evidence.originalClaim.initiatedBy, uid);
  assertCircleOriginalOperation(activeDb, evidence, "COMPLETE");
  isolated();
  await assertCircleReplayReadOnly(activeDb);
  reportCircleReconciliation(activeDb, evidence);
});

test("falha no Circle preserva user tree e retry conclui", async () => {
  activeDb = new FakeFirestore();
  seedAdminCircle(activeDb, true);
  const isolated = seedCircleIsolation(activeDb);
  const evidence = observeCircleReconciliation(activeDb);
  const challenge = `circles/${circleId}/challenges/original/progress/${remainingUid}`;
  activeDb.seed(challenge, {uid: remainingUid, value: 2});
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
  assert.equal(activeDb.versionedDeletes.includes(rootPath), false);
  assert.equal(activeDb.failRecursiveDeleteOnce.get(`circles/${circleId}`), 0);
  assert.equal(evidence.native.length, 1);
  assert.equal(evidence.native[0].completed, false);
  assert.deepEqual(activeDb.data(challenge), {uid: remainingUid, value: 2});
  const markerPath = `circle_deletions/${circleId}`;
  const marker = activeDb.data(markerPath);
  assert.equal(marker.state, "SERVER_DELETING");
  assert.ok(marker.createdAt instanceof Timestamp);
  assert.deepEqual(marker, evidence.originalClaim);
  const closure = activeDb.data(`circle_cleanup_guards/${circleId}`);
  assert.equal(closure.state, "SERVER_DELETING");
  assertCircleOriginalOperation(activeDb, evidence, "IN_PROGRESS");
  isolated();

  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal(activeDb.data(markerPath), undefined);
  assert.equal(activeDb.operationLog.filter(
      (operation) => operation === `set:${markerPath}`,
  ).length, 1);
  assert.deepEqual(activeDb.versionedDeletes, [
    `circles/${circleId}`,
    `circles/${circleId}`,
    rootPath,
  ]);
  assert.deepEqual(evidence.native[1].controls.claim, marker);
  assert.deepEqual(evidence.native[1].controls.closure, closure);
  assert.equal(activeDb.data(challenge), undefined);
  assert.deepEqual(activeDb.data(`users/${remainingUid}`), {activeCircleId: null, keep: true});
  assertCircleOriginalOperation(activeDb, evidence, "COMPLETE");
  isolated();
  reportCircleReconciliation(activeDb, evidence);
});

test("Circle root ausente limpa descendentes", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  activeDb.seed(`circles/${circleId}/members/${remainingUid}`, memberData("member"));
  activeDb.seed(`users/${remainingUid}`, {activeCircleId: circleId, keep: true});
  const challengePath = `circles/${circleId}/challenges/challenge-1`;
  activeDb.seed(`${challengePath}/progress/${uid}`, {value: 1});
  activeDb.seed(`${challengePath}/processed_events/event-a`, {uid});
  for (let i = 0; i < 420; i++) activeDb.seed(`${challengePath}/synthetic/page-${i}`, {keepInScope: true});
  assert.equal(activeDb.data(challengePath), undefined);
  const isolated = seedCircleIsolation(activeDb);
  const evidence = observeCircleReconciliation(activeDb);

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.data(`users/${remainingUid}`), {
    activeCircleId: null,
    keep: true,
  });
  assert.deepEqual(activeDb.versionedDeletes, [rootPath]);
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
  const pages = evidence.commits.filter(row => row.page);
  assert.deepEqual(pages.map(row => row.writes.length), [200, 200, 24]);
  assert.ok(pages.every(row => row.applied));
  assert.ok(evidence.absentParents.includes(challengePath));
  assert.ok(activeDb.operationLog.indexOf(`set:${markerPath}`) <
      activeDb.operationLog.indexOf(`delete:circles/${circleId}/members/${uid}`));
  assert.ok(activeDb.operationLog.lastIndexOf(`set:${markerPath}`) < activeDb.operationLog.indexOf(`versioned:${rootPath}`));
  assertCircleTombstone(activeDb, evidence.originalClaim.createdAt);
  assertCircleOriginalOperation(activeDb, evidence, "COMPLETE");
  isolated();
  reportCircleReconciliation(activeDb, evidence);
});

test("root recriado após claim não é apagado", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  activeDb.seed(`circles/${circleId}/members/${remainingUid}`, memberData("member"));
  activeDb.seed(`users/${remainingUid}`, {activeCircleId: circleId});
  const newCircle = circleData({adminId: remainingUid, memberCount: 1});
  const markerPath = `circle_deletions/${circleId}`;
  const evidence = observeHistoricalR5(activeDb);
  let recreated = false, afterRecreation;
  evidence.hooks.afterCommit = row => {
    if (recreated || row.stage !== "circle-claim") return;
    assert.equal(activeDb.data(`circles/${circleId}`), undefined);
    assert.equal(activeDb.data(markerPath).state, "SERVER_DELETING");
    assert.equal(activeDb.data(`circle_cleanup_guards/${circleId}`).state, "SERVER_DELETING");
    assert.deepEqual(activeDb.versionedDeletes, []);
    activeDb.seed(`circles/${circleId}`, newCircle);
    recreated = true;
    afterRecreation = {store: [...activeDb.store], log: [...activeDb.operationLog]};
  };
  await withoutErrorLog(() => assert.rejects(cleanupUserData.run({uid}), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(recreated, true);
  assert.deepEqual(activeDb.data(`circles/${circleId}`), newCircle);
  assert.equal(
      activeDb.versionedDeletes.includes(`circles/${circleId}`),
      false,
  );
  assert.deepEqual(activeDb.versionedDeletes, []);
  assert.deepEqual([...activeDb.store], afterRecreation.store);
  assert.deepEqual(activeDb.operationLog, afterRecreation.log);
  assert.deepEqual(activeDb.data(`circles/${circleId}/members/${uid}`), memberData("admin"));
  assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
  assert.deepEqual(activeDb.data(`users/${remainingUid}`), {activeCircleId: circleId});
  assert.ok(activeDb.data(markerPath));
  assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");
  reportHistoricalR5(activeDb, evidence, {recreated, boundary: "after-original-orphan-claim", conservativeRefusal: true});
});

test("root recriado antes do claim impede cleanup residual", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("member"));
  const newCircle = circleData();
  const evidence = observeHistoricalR5(activeDb);
  let injected = 0;
  evidence.hooks.beforeRead = (row, ref) => {
    if (!injected && ref.path === `circles/${circleId}` && activeDb.data(billingAccountPath)?.state === "DELETING") {
      assert.equal(activeDb.data(ref.path), undefined);
      assert.equal(activeDb.data(`circle_deletions/${circleId}`), undefined);
      activeDb.seed(ref.path, newCircle);
      activeDb.seed(`circles/${circleId}/members/${adminUid}`, memberData("admin"));
      injected += 1; row.injected = true;
    }
  };
  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));
  assert.equal(injected, 1);
  assert.deepEqual(activeDb.data(`circles/${circleId}`), newCircle);
  assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
  assert.deepEqual(
      activeDb.data(`circles/${circleId}/members/${adminUid}`),
      memberData("admin"),
  );
  assert.deepEqual(activeDb.versionedDeletes, []);
  assert.equal(activeDb.data(`circle_deletions/${circleId}`), undefined);
  assert.deepEqual(activeDb.operationLog, [`create:retired_auth_identities/${uid}`, `create:${guardPath}`,
    `create:${guardPath}/control/operation`, `set:${billingAccountPath}`]);
  assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");
  reportHistoricalR5(activeDb, evidence, {injected, boundary: "orphan-claim-root-read"});
});

test("retry de root ausente preserva tombstone valido", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  const challenge = `circles/${circleId}/challenges/absent`;
  for (let i = 0; i < 417; i++) activeDb.seed(`${challenge}/synthetic/page-${i}`, {inOriginalCircle: true});
  const isolated = seedCircleIsolation(activeDb);
  const evidence = observeCircleReconciliation(activeDb);
  evidence.failPageOnce = 2;

  await withoutErrorLog(() => assert.rejects(
      cleanupUserData.run({uid}),
      {message: "USER_DATA_CLEANUP_FAILED"},
  ));

  const markerPath = `circle_deletions/${circleId}`;
  const marker = activeDb.data(markerPath);
  assert.ok(marker.createdAt instanceof Timestamp);
  assert.equal(marker.state, "SERVER_DELETING");
  assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.equal(evidence.failedPages, 1);
  assert.equal(evidence.pageAttempts, 2);
  assert.equal(evidence.commits.filter(row => row.page && row.applied).length, 1);
  assert.equal([...activeDb.store.keys()].filter(p => p.startsWith(`circles/${circleId}/`)).length, 218);
  assert.deepEqual(marker, evidence.originalClaim);
  const closure = activeDb.data(`circle_cleanup_guards/${circleId}`);
  assert.equal(closure.state, "SERVER_DELETING");
  assertCircleOriginalOperation(activeDb, evidence, "IN_PROGRESS");
  isolated();

  await cleanupUserData.run({uid});

  assert.deepEqual(activeDb.versionedDeletes, [rootPath]);
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assertCircleTombstone(activeDb, marker.createdAt);
  assert.equal(activeDb.operationLog.filter(operation => operation === `set:${markerPath}`).length, 2);
  const pages = evidence.commits.filter(row => row.page);
  assert.deepEqual(pages.map(row => [row.writes.length, row.applied]), [[200, true], [200, false], [200, true], [18, true]]);
  assert.deepEqual(pages[1].before.claim, marker);
  assert.deepEqual(pages[2].before.claim, marker);
  assert.deepEqual(pages[2].before.closure, closure);
  assert.deepEqual(activeDb.data(`circle_cleanup_guards/${circleId}`), closure);
  assert.equal(evidence.failedPages, 1);
  assertCircleOriginalOperation(activeDb, evidence, "COMPLETE");
  isolated();
  await assertCircleReplayReadOnly(activeDb);
  reportCircleReconciliation(activeDb, evidence);
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

    const evidence = observeHistoricalR5(activeDb);

    await withoutErrorLog(() => assert.rejects(
        cleanupUserData.run({uid}),
        {message: "USER_DATA_CLEANUP_FAILED"},
    ));

    assert.deepEqual(activeDb.data(`circle_deletions/${circleId}`), marker);
    assert.deepEqual(activeDb.data(rootPath), {activeCircleId: circleId});
    assert.deepEqual(activeDb.data(`users/${remainingUid}`), {
      activeCircleId: circleId,
    });
    assert.deepEqual(activeDb.versionedDeletes, []);
    assert.deepEqual(activeDb.operationLog, [`create:retired_auth_identities/${uid}`,
      `create:${guardPath}`, `create:${guardPath}/control/operation`, `set:${billingAccountPath}`]);
    assertHistoricalControls(activeDb, evidence, "IN_PROGRESS");
    reportHistoricalR5(activeDb, evidence, {invalidMarkerPreserved: true});
  }
});

test("activeCircleId invalido falha fechado sem apagar usuario", async () => {
  const invalidValues = ["", " bad ", "bad/id", "x".repeat(1501)];
  for (const activeCircleId of invalidValues) {
    activeDb = new FakeFirestore();
    activeDb.seed(rootPath, {activeCircleId});

    await withoutErrorLog(() => assert.rejects(
        cleanupUserData.run({uid}),
        {message: "USER_DATA_CLEANUP_FAILED"},
    ));

    assert.equal(activeDb.data(rootPath) !== undefined, true);
    assert.deepEqual(activeDb.versionedDeletes, []);
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

function seedGlobalHistory(db, oldCircle = "old-circle", owner = uid) {
  const challenge = `circles/${oldCircle}/challenges/old-challenge`;
  db.seed(`${challenge}/progress/${owner}`, {...progressData(), uid: owner});
  db.seed(`${challenge}/processed_events/event-old`, {...focusEvent("event-old"), uid: owner});
  db.seed(`circles/${oldCircle}/ranking/${owner}`, {uid: owner, name: "Member", totalXp: 2, photoUrl: null});
  return challenge;
}

test("legacy oversized Circle and Challenge history remains cleanable in fallback", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {});
  const id = "c".repeat(129);
  const root = `circles/${id}/challenges/${"h".repeat(129)}`;
  const original = {schemaVersion: 2, createdBy: uid, title: "Shared challenge"};
  const foreign = {...progressData(7), uid: remainingUid};
  activeDb.seed(root, original);
  activeDb.seed(`${root}/progress/${uid}`, progressData());
  activeDb.seed(`${root}/progress/${remainingUid}`, foreign);
  activeDb.seed(`${root}/processed_events/event-old`, focusEvent("event-old"));
  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(`${root}/progress/${uid}`), undefined);
  assert.equal(activeDb.data(`${root}/processed_events/event-old`), undefined);
  assert.deepEqual(activeDb.data(`${root}/progress/${remainingUid}`), foreign);
  assert.deepEqual(activeDb.data(root), {...original, createdBy: ""});
});

test("legacy oversized pending Circle marker finalizes in fallback", async () => {
  activeDb = new FakeFirestore();
  const id = "c".repeat(129);
  activeDb.seed(rootPath, {});
  activeDb.seed(`circles/${id}`, circleData({adminId: uid, memberCount: 1, deletionState: "SERVER_DELETING"}));
  activeDb.seed(`circles/${id}/members/${uid}`, memberData("admin"));
  activeDb.seed(`circle_deletions/${id}`, {version: 1, state: "SERVER_DELETING",
    circleId: id, initiatedBy: uid, memberUids: [uid], createdAt: Timestamp.fromMillis(100)});
  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(`circles/${id}`), undefined);
  assert.equal(activeDb.data(`circle_deletions/${id}`), undefined);
});

for (const soleAdmin of [false, true]) {
  test(`legacy oversized active Circle supports fallback (sole admin: ${soleAdmin})`, async () => {
    activeDb = new FakeFirestore();
    const id = "c".repeat(129);
    activeDb.seed(rootPath, {activeCircleId: id});
    activeDb.seed(`circles/${id}`, circleData({adminId: soleAdmin ? uid : adminUid,
      memberCount: soleAdmin ? 1 : 2}));
    activeDb.seed(`circles/${id}/members/${uid}`, memberData(soleAdmin ? "admin" : "member"));
    if (!soleAdmin) activeDb.seed(`circles/${id}/members/${adminUid}`, memberData("admin"));
    await cleanupUserData.run({uid});
    assert.equal(activeDb.data(rootPath), undefined);
    assert.equal(activeDb.data(`circles/${id}/members/${uid}`), undefined);
    if (soleAdmin) assert.equal(activeDb.data(`circles/${id}`), undefined);
    else {
      assert.equal(activeDb.data(`circles/${id}`).memberCount, 1);
      assert.ok(activeDb.data(`circles/${id}/members/${adminUid}`));
    }
  });
}

for (const root of [undefined, {}, {activeCircleId: null}]) {
  test(`global cleanup discovers historical data without active Circle: ${JSON.stringify(root)}`, async () => {
    activeDb = new FakeFirestore();
    if (root !== undefined) activeDb.seed(rootPath, root);
    const old = seedGlobalHistory(activeDb);
    activeDb.seed(`${old}/progress/${remainingUid}`, {...progressData(), uid: remainingUid});
    activeDb.seed("circles/old-circle/challenges/old-challenge", {createdBy: uid, name: "Shared"});
    await cleanupUserData.run({uid});
    assert.equal(activeDb.data(`${old}/progress/${uid}`), undefined);
    assert.equal(activeDb.data(`${old}/processed_events/event-old`), undefined);
    assert.equal(activeDb.data(`circles/old-circle/ranking/${uid}`), undefined);
    assert.deepEqual(activeDb.data(`${old}/progress/${remainingUid}`), {...progressData(), uid: remainingUid});
    assert.deepEqual(activeDb.data(old), {createdBy: "", name: "Shared"});
    assert.equal(activeDb.data(rootPath), undefined);
    assert.equal(activeDb.data(guardPath).state, "COMPLETE");
    assert.ok(activeDb.operationLog.indexOf(`set:${guardPath}`) <
      activeDb.operationLog.indexOf(`delete:${old}/progress/${uid}`));
  });
}

test("global fallback cleans Circle A history and current membership B", async () => {
  activeDb = new FakeFirestore();
  seedNormalMemberCircle(activeDb);
  const old = seedGlobalHistory(activeDb);
  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(`${old}/progress/${uid}`), undefined);
  assert.equal(activeDb.data(`circles/${circleId}/members/${uid}`), undefined);
  assert.equal(activeDb.data(`circles/${circleId}`).memberCount, 1);
  assert.deepEqual(activeDb.data(`circles/${circleId}/members/${adminUid}`), memberData("admin"));
});

test("global fallback handles more than 240 challenges and multiple pages of every history group", async () => {
  activeDb = new FakeFirestore();
  for (let index = 0; index < 417; index++) seedGlobalHistory(activeDb, `old-${index}`);
  const evidence = observeHistoricalR5(activeDb);
  await cleanupUserData.run({uid});
  assertOnlyHistoricalR5Controls(activeDb, evidence);
  reportHistoricalR5(activeDb, evidence);
});

test("global fallback failure preserves the barrier and retries without deleting another owner", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {});
  const old = seedGlobalHistory(activeDb);
  activeDb.seed(`${old}/progress/${remainingUid}`, {...progressData(), uid: remainingUid});
  activeDb.failHistoryOnce = true;
  await withoutErrorLog(() => assert.rejects(cleanupUserData.run({uid}), {message: "USER_DATA_CLEANUP_FAILED"}));
  const guard = activeDb.data(guardPath);
  assert.equal(guard.state, "IN_PROGRESS");
  assert.deepEqual(activeDb.data(rootPath), {});
  assert.ok(activeDb.data(`${old}/progress/${uid}`));
  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(guardPath).deletionId, guard.deletionId);
  assert.equal(activeDb.data(guardPath).state, "COMPLETE");
  assert.deepEqual(activeDb.data(`${old}/progress/${remainingUid}`), {...progressData(), uid: remainingUid});
});

for (const [label, key, data] of [
  ["foreign ownership", `circles/old/challenges/c/progress/${remainingUid}`, progressData()],
  ["malformed path", `users/old/progress/${uid}`, progressData()],
  ["missing ownership field", `circles/old/challenges/c/progress/${uid}`, {value: 1}],
]) {
  test(`global fallback fails closed on ${label}`, async () => {
    activeDb = new FakeFirestore();
    activeDb.seed(rootPath, {});
    activeDb.seed(key, data);
    await withoutErrorLog(() => assert.rejects(cleanupUserData.run({uid}), {message: "USER_DATA_CLEANUP_FAILED"}));
    assert.deepEqual(activeDb.data(key), data);
    assert.deepEqual(activeDb.data(rootPath), {});
    assert.equal(activeDb.data(guardPath).state, "IN_PROGRESS");
  });
}

test("fallback finalizes pending Circle deletion UID references without retaining the UID list", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {});
  activeDb.seed(`circle_deletions/${circleId}`, {version: 1, state: "SERVER_DELETING",
    circleId, initiatedBy: adminUid, memberUids: [adminUid, uid], createdAt: Timestamp.now()});
  activeDb.seed(`users/${adminUid}`, {activeCircleId: circleId});
  const markerPath = `circle_deletions/${circleId}`;
  const marker = activeDb.data(markerPath);
  const isolated = seedCircleIsolation(activeDb);
  const evidence = observeCircleReconciliation(activeDb);
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal([...activeDb.store.keys()].some(p => p.startsWith(`circles/${circleId}/`)), false);
  assert.equal(activeDb.data(`circle_cleanup_guards/${circleId}`), undefined);

  await withoutErrorLog(() => assert.rejects(cleanupUserData.run({uid}), {message: "USER_DATA_CLEANUP_FAILED"}));

  assert.deepEqual(activeDb.data(markerPath), marker);
  assert.deepEqual(activeDb.data(`users/${adminUid}`), {activeCircleId: circleId});
  assert.equal(activeDb.data(`circle_cleanup_guards/${circleId}`), undefined);
  assert.deepEqual(activeDb.data(rootPath), {});
  assert.deepEqual(activeDb.versionedDeletes, []);
  assert.equal(evidence.commits.some(row => row.writes.some(w =>
    w.path === markerPath || w.path.startsWith("circles/") || w.path.startsWith("circle_cleanup_guards/") || w.path.startsWith("users/"))), false);
  assertCircleOriginalOperation(activeDb, evidence, "IN_PROGRESS");
  assert.ok(activeDb.fixtureTrace.some(row => row.kind === "transaction.error" && row.code === "ACCOUNT_STATE_CONFLICT"),
      "ambiguous legacy cleanup is refused for operational review; no closure is fabricated");
  isolated();
  const controls = evidence.snapshot();
  const writes = [...activeDb.operationLog];
  await withoutErrorLog(() => assert.rejects(cleanupUserData.run({uid}), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.deepEqual(evidence.snapshot(), controls);
  assert.deepEqual(activeDb.operationLog, writes);
  assert.deepEqual(activeDb.data(markerPath), marker);
  assert.deepEqual(activeDb.versionedDeletes, []);
  isolated();
  reportCircleReconciliation(activeDb, evidence);
});

test("historical owned Circle resumes partial recursive cleanup even after its root disappears", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {});
  activeDb.seed(`circles/${circleId}`, circleData({adminId: uid}));
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  activeDb.seed(`circles/${circleId}/members/${remainingUid}`, memberData("member"));
  activeDb.seed(`users/${remainingUid}`, {activeCircleId: circleId});
  const isolated = seedCircleIsolation(activeDb);
  const evidence = observeCircleReconciliation(activeDb);
  const versionedDelete = activeDb.versionedDelete.bind(activeDb);
  let failed = false;
  let partialFailures = 0;
  activeDb.versionedDelete = async ref => {
    if (ref.path === `circles/${circleId}` && !failed) {
      assert.equal(activeDb.data(ref.path).adminId, uid);
      assert.equal(activeDb.data(ref.path).deletionState, "SERVER_DELETING");
      assert.equal(activeDb.data(`circle_cleanup_guards/${circleId}`).state, "SERVER_DELETING");
      activeDb.store.delete(ref.path);
      failed = true;
      partialFailures += 1;
      activeDb.fixtureTrace.push({kind: "circle.native.partial.root.removed", path: ref.path});
      throw new Error("private partial recursive failure");
    }
    return versionedDelete(ref);
  };
  await withoutErrorLog(() => assert.rejects(cleanupUserData.run({uid}), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(activeDb.data(`circle_deletions/${circleId}`).initiatedBy, uid);
  assert.ok(activeDb.data(`circles/${circleId}/members/${remainingUid}`));
  assert.equal(failed, true);
  assert.equal(partialFailures, 1);
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.deepEqual(activeDb.data(rootPath), {});
  const marker = activeDb.data(`circle_deletions/${circleId}`);
  const closure = activeDb.data(`circle_cleanup_guards/${circleId}`);
  assert.deepEqual(marker, evidence.originalClaim);
  assertCircleOriginalOperation(activeDb, evidence, "IN_PROGRESS");
  isolated();

  await cleanupUserData.run({uid});
  assertCircleTombstone(activeDb, marker.createdAt);
  assert.equal(activeDb.data(`circles/${circleId}/members/${remainingUid}`), undefined);
  assert.deepEqual(activeDb.data(`users/${remainingUid}`), {activeCircleId: null});
  assert.equal(activeDb.data(guardPath).state, "COMPLETE");
  assert.equal(partialFailures, 1);
  assert.deepEqual(activeDb.data(`circle_cleanup_guards/${circleId}`), closure);
  const page = evidence.commits.find(row => row.page);
  assert.ok(page);
  assert.deepEqual(page.before.claim, marker);
  assert.deepEqual(page.before.closure, closure);
  assertCircleOriginalOperation(activeDb, evidence, "COMPLETE");
  isolated();
  await assertCircleReplayReadOnly(activeDb);
  reportCircleReconciliation(activeDb, evidence);
});

test("fallback resumes pending Circle deletion before resolving the current administrator link", async () => {
  activeDb = new FakeFirestore();
  activeDb.seed(rootPath, {activeCircleId: circleId});
  activeDb.seed(`circles/${circleId}`, circleData({adminId: uid, deletionState: "SERVER_DELETING"}));
  activeDb.seed(`circles/${circleId}/members/${uid}`, memberData("admin"));
  activeDb.seed(`circles/${circleId}/members/${remainingUid}`, memberData("member"));
  activeDb.seed(`users/${remainingUid}`, {activeCircleId: circleId});
  activeDb.seed(`circle_deletions/${circleId}`, {version: 1, state: "SERVER_DELETING",
    circleId, initiatedBy: uid, memberUids: [uid, remainingUid], createdAt: Timestamp.now()});
  await cleanupUserData.run({uid});
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(`circles/${circleId}`), undefined);
  assert.equal(activeDb.data(`circle_deletions/${circleId}`), undefined);
  assert.deepEqual(activeDb.data(`users/${remainingUid}`), {activeCircleId: null});
  assert.equal(activeDb.data(guardPath).state, "COMPLETE");
});


// C1 scenarios retained under the approved R3 policy A. The original diagnostic
// patch is preserved separately; timestamp ambiguity does not create authority.
const c1BirthPath = `account_birth_decisions/${uid}`;
const c1Born = Timestamp.fromMillis(Date.parse("2026-10-13T10:00:00Z"));
const c1Clock = Timestamp.fromMillis(Date.parse("2026-10-14T10:00:00Z"));

/**
 * Generate a legitimate CLOSED ledger through the approved real B2-A core.
 * Adapt only the existing private fake's create/serverTimestamp mechanics.
 * @param {FakeFirestore} db Synthetic storage.
 * @param {Timestamp} born Synthetic Auth creation.
 * @return {Promise<Object>} Persisted real core record.
 */
async function c1SeedBirth(db, born = c1Born) {
  const {createAccountBirthRecorder} = require("../water_account_birth");
  const recordedAt = Timestamp.fromMillis(born.toMillis() + 1000);
  const source = {type: "FIREBASE_AUTH_CREATE", uid,
    eventId: `synthetic-create-${born.toMillis()}`,
    projectId: db.projectId, tenantId: null,
    authCreatedAt: born, eventAt: born};
  const syntheticDb = {projectId: db.projectId,
    collection: (name) => db.collection(name),
    runTransaction: (callback) => db.runTransaction((transaction) =>
      callback({get: (ref) => transaction.get(ref),
        create: (ref, data) => {
          assert.equal(db.data(ref.path), undefined, "create cannot overwrite");
          assert.equal(data.recordedAt.constructor.name,
              "ServerTimestampTransform");
          transaction.set(ref, {...data, recordedAt});
        }})),
  };
  const recorder = createAccountBirthRecorder({db: syntheticDb, projectId: db.projectId,
    getTrustedBirth: () => ({source,
      identity: {uid, email: "synthetic-c1@example.invalid",
        displayName: "Synthetic C1 Owner", photoUrl: "synthetic-c1-avatar"},
      cohort: {version: 1, id: "closed-c1", policy: "NEW_ACCOUNT_V2_ONLY",
        state: "CLOSED", cutoverAt: Timestamp.fromMillis(
            Date.parse("2026-10-01T00:00:00Z"))}}),
    getCurrentAuthGeneration: () => ({uid, projectId: db.projectId,
      tenantId: null, authCreatedAt: born}), now: () => recordedAt});
  assert.equal((await recorder.record()).eligible, false);
  return db.data(c1BirthPath);
}

/**
 * @param {*} metadata SDK wire metadata or absence.
 * @return {Object} Actual installed Functions SDK event-record shape.
 */
function c1DeleteUser(metadata = {
  creationTime: c1Born.toDate().toUTCString(),
}) {
  const {userRecordConstructor} = require("firebase-functions/v1/auth");
  return userRecordConstructor({uid, metadata,
    email: "synthetic-delete@example.invalid"});
}

/**
 * @param {Object} user Managed-event record supplied by trusted test code.
 * @return {Promise<void>} Real existing onDelete callback with synthetic IO.
 */
function c1Delete(user = c1DeleteUser()) {
  return cleanupUserData.run(user, {eventId: "synthetic-delete-c1",
    eventType: "google.firebase.auth.user.delete",
    timestamp: "2026-10-13T11:00:00Z",
    resource: {service: "firebaseauth.googleapis.com",
      name: "projects/demo-life-os-p1"}, params: {}});
}

for (const withRoot of [true, false]) {
  test(`C1 resolved: mandatory ledger removal (root present: ${withRoot})`,
      async () => {
        activeDb = new FakeFirestore();
        await c1SeedBirth(activeDb);
        if (withRoot) activeDb.seed(rootPath, {activeCircleId: null});
        await c1Delete();
        assert.equal(activeDb.data(rootPath), undefined);
        assert.equal(activeDb.data(guardPath).state, "COMPLETE");
        assert.equal(activeDb.data(c1BirthPath), undefined,
            "Confirmed deletion must not retain originalIdentity PII");
      });
}

test("C1 resolved: normal cleanup removes original identity under COMPLETE",
    async () => {
      activeDb = new FakeFirestore();
      const ledger = await c1SeedBirth(activeDb);
      activeDb.seed(rootPath, {activeCircleId: null});
      await c1Delete();
      assert.equal(activeDb.data(rootPath), undefined);
      assert.equal(activeDb.data(c1BirthPath), undefined);
      assert.deepEqual(ledger.originalIdentity, {uid,
        email: "synthetic-c1@example.invalid",
        displayName: "Synthetic C1 Owner",
        photoUrl: "synthetic-c1-avatar"});
      assert.equal(activeDb.data(guardPath).state, "COMPLETE");
      assert.equal(activeDb.operationLog.includes(`delete:${c1BirthPath}`),
          true);
    });

test("C1 resolved: ledger-only account is marked COMPLETE after removal",
    async () => {
      activeDb = new FakeFirestore();
      await c1SeedBirth(activeDb);
      await c1Delete();
      assert.equal(activeDb.data(c1BirthPath), undefined);
      assert.deepEqual(activeDb.versionedDeletes, [rootPath]);
      assert.equal(activeDb.data(guardPath).state, "COMPLETE");
    });

test("C1 resolved: old deletion preserves a later generation tree and ledger",
    async () => {
      activeDb = new FakeFirestore();
      const laterRoot = {activeCircleId: null,
        displayName: "Synthetic recreated"};
      await c1SeedBirth(activeDb,
          Timestamp.fromMillis(c1Born.toMillis() + 7200000));
      activeDb.seed(rootPath, laterRoot);
      activeDb.seed(`${rootPath}/health/day`, {waterIntakeMl: 250});
      await withoutErrorLog(() => assert.rejects(c1Delete(),
          {message: "USER_DATA_CLEANUP_FAILED"}));
      assert.deepEqual(activeDb.data(rootPath), laterRoot);
      assert.deepEqual(activeDb.data(`${rootPath}/health/day`),
          {waterIntakeMl: 250});
      assert.deepEqual(activeDb.versionedDeletes, []);
    });

test("C1 resolved: old event cannot delete later tree with divergent ledger",
    async () => {
      activeDb = new FakeFirestore();
      const later = await c1SeedBirth(activeDb,
          Timestamp.fromMillis(c1Born.toMillis() + 7200000));
      activeDb.seed(rootPath, {activeCircleId: null,
        displayName: "Synthetic recreated"});
      activeDb.seed(`${rootPath}/health/day`, {waterIntakeMl: 250});
      await withoutErrorLog(() => assert.rejects(c1Delete(),
          {message: "USER_DATA_CLEANUP_FAILED"}));
      assert.equal(activeDb.data(rootPath).displayName, "Synthetic recreated");
      assert.deepEqual(activeDb.data(`${rootPath}/health/day`),
          {waterIntakeMl: 250});
      assert.deepEqual(activeDb.data(c1BirthPath), later);
      assert.equal(activeDb.data(guardPath), undefined);
    });

test("C1 policy A: missing creation metadata still permits managed deletion",
    async () => {
      activeDb = new FakeFirestore();
      await c1SeedBirth(activeDb);
      activeDb.seed(rootPath, {activeCircleId: null});
      await c1Delete(c1DeleteUser(null));
      assert.equal(activeDb.data(c1BirthPath), undefined);
      assert.equal(activeDb.data(rootPath), undefined);
      assert.equal(activeDb.data(guardPath).state, "COMPLETE");
    });

test("C1 policy A: coarse metadata alone never proves generation reuse",
    async () => {
      const {UserRecord} = require("firebase-admin/auth");
      const old = new UserRecord({localId: uid,
        createdAt: String(c1Born.toMillis() + 100)});
      const later = new UserRecord({localId: uid,
        createdAt: String(c1Born.toMillis() + 900)});
      assert.equal(old.metadata.creationTime, later.metadata.creationTime);
      activeDb = new FakeFirestore();
      await c1SeedBirth(activeDb);
      activeDb.seed(rootPath, {activeCircleId: null});
      const user = c1DeleteUser({creationTime: old.metadata.creationTime});
      await c1Delete(user);
      assert.equal(activeDb.data(c1BirthPath), undefined);
      assert.equal(activeDb.data(rootPath), undefined);
      assert.equal(activeDb.data(guardPath).state, "COMPLETE");
    });

test("C1 resolved: duplicate event is idempotent and removes PII",
    async () => {
      activeDb = new FakeFirestore();
      await c1SeedBirth(activeDb);
      activeDb.seed(rootPath, {activeCircleId: null});
      await c1Delete(); const firstGuard = activeDb.data(guardPath);
      await c1Delete();
      assert.equal(activeDb.data(c1BirthPath), undefined);
      assert.deepEqual(activeDb.data(guardPath), firstGuard);
      // A duplicate COMPLETE event proves absence without repeating effects.
      assert.deepEqual(activeDb.versionedDeletes, [rootPath]);
    });

for (const state of ["IN_PROGRESS", "COMPLETE"]) {
  test(`C1 evidence: existing ${state} guard does not bind Auth generation`,
    async () => {
      activeDb = new FakeFirestore();
      const ledger = await c1SeedBirth(activeDb);
      activeDb.seed(rootPath, {activeCircleId: null});
      const guard = {version: 1, state,
        deletionId: "00000000-0000-4000-8000-000000000001",
        startedAt: c1Born, retainUntil: state === "COMPLETE" ? c1Clock : null};
      activeDb.seed(guardPath, guard);
      const before = {store: [...activeDb.store], log: [...activeDb.operationLog]};
      await withoutErrorLog(() => assert.rejects(c1Delete(), {message: "USER_DATA_CLEANUP_FAILED"}));
      assert.equal(activeDb.data(guardPath).deletionId, guard.deletionId);
      assert.equal(activeDb.data(guardPath).state, state);
      assert.deepEqual(activeDb.data(rootPath), {activeCircleId: null});
      assert.deepEqual(activeDb.data(c1BirthPath), ledger);
      assert.deepEqual([...activeDb.store], before.store);
      assert.deepEqual(activeDb.operationLog, before.log);
      assert.deepEqual(activeDb.versionedDeletes, []);
      assert.equal(activeDb.data(guardPath + "/control/operation"), undefined);
      assert.equal(activeDb.data(`retired_auth_identities/${uid}`), undefined);
      activeDb.fixtureTrace.push({kind: "historical.legacy.refused", state, receiptFabricated: false, effects: 0});
    });
}

test("C1 evidence: failure before tree deletion keeps IN_PROGRESS and PII",
    async () => {
      activeDb = new FakeFirestore();
      const ledger = await c1SeedBirth(activeDb);
      activeDb.seed(rootPath, {activeCircleId: null});
      activeDb.failRecursiveDeleteOnce.set(rootPath, 1);
      await withoutErrorLog(() => assert.rejects(c1Delete(),
          {message: "USER_DATA_CLEANUP_FAILED"}));
      const deletionId = activeDb.data(guardPath).deletionId;
      assert.equal(activeDb.data(guardPath).state, "IN_PROGRESS");
      assert.deepEqual(activeDb.data(c1BirthPath), ledger);
      assert.ok(activeDb.data(rootPath));
      await c1Delete();
      assert.equal(activeDb.data(guardPath).deletionId, deletionId);
      assert.equal(activeDb.data(guardPath).state, "COMPLETE");
      assert.equal(activeDb.data(c1BirthPath), undefined);
    });

test("C1 evidence: failure before guard completion cannot falsely complete",
    async () => {
      activeDb = new FakeFirestore();
      const ledger = await c1SeedBirth(activeDb);
      activeDb.seed(rootPath, {activeCircleId: null});
      const runTransaction = activeDb.runTransaction.bind(activeDb);
      let fail = true;
      activeDb.runTransaction = (callback) => runTransaction(async (tx) => {
        const result = await callback(tx);
        if (fail && tx.writes.some((write) => write.ref.path === guardPath &&
          write.type === "update" && write.data.state === "COMPLETE")) {
          fail = false; throw new Error("synthetic commit failure");
        }
        return result;
      });
      await withoutErrorLog(() => assert.rejects(c1Delete(),
          {message: "USER_DATA_CLEANUP_FAILED"}));
      assert.equal(activeDb.data(rootPath), undefined);
      assert.equal(activeDb.data(guardPath).state, "IN_PROGRESS");
      assert.deepEqual(activeDb.data(c1BirthPath), ledger);
      const deletionId = activeDb.data(guardPath).deletionId;
      await c1Delete();
      assert.equal(activeDb.data(guardPath).deletionId, deletionId);
      assert.equal(activeDb.data(guardPath).state, "COMPLETE");
    });

test("C1 evidence: lost response after COMPLETE replays without a new guard",
    async () => {
      activeDb = new FakeFirestore();
      await c1SeedBirth(activeDb); let lost = false;
      activeDb.seed(rootPath, {activeCircleId: null});
      const evidence = observeHistoricalR5(activeDb);
      activeDb.afterTransactionCommit = () => {
        if (!lost && activeDb.data(guardPath)?.state === "COMPLETE") {
          lost = true; throw new Error("synthetic lost reply");
        }
      };
      await c1Delete();
      assert.equal(lost, true);
      assert.equal(activeDb.data(rootPath), undefined);
      const guard = activeDb.data(guardPath);
      assert.equal(guard.state, "COMPLETE");
      assertHistoricalControls(activeDb, evidence, "COMPLETE");
      const completion = evidence.transactions.findIndex(row => row.stage === "completion" && row.applied);
      assert.ok(completion >= 0);
      const rechecks = evidence.transactions.slice(completion + 1);
      assert.ok(rechecks.some(row => row.reads.includes(guardPath + "/control/operation") && row.reads.includes(rootPath)));
      assert.ok(rechecks.every(row => row.writes.length === 0));
      const beforeReplay = {store: [...activeDb.store], log: [...activeDb.operationLog], versioned: [...activeDb.versionedDeletes]};
      activeDb.afterTransactionCommit = null; await c1Delete();
      assert.deepEqual(activeDb.data(guardPath), guard);
      assert.equal(activeDb.data(c1BirthPath), undefined);
      assert.deepEqual([...activeDb.store], beforeReplay.store);
      assert.deepEqual(activeDb.operationLog, beforeReplay.log);
      assert.deepEqual(activeDb.versionedDeletes, beforeReplay.versioned);
      assert.equal(evidence.transactions.filter(row => row.stage === "completion" && row.applied).length, 1);
      reportHistoricalR5(activeDb, evidence, {lost, terminalReadOnlyRechecks: rechecks.length});
    });

test("C1 evidence: delayed CLOSED birth is refused by the cleanup guard",
    async () => {
      activeDb = new FakeFirestore(); await c1Delete();
      const before = [...activeDb.store];
      await assert.rejects(c1SeedBirth(activeDb),
          {code: "WATER_ACCOUNT_DELETING"});
      assert.deepEqual([...activeDb.store], before);
      assert.equal(activeDb.data(c1BirthPath), undefined);
    });

test("C1 evidence: unrelated UID ledger and every local module stay intact",
    async () => {
      activeDb = new FakeFirestore();
      await c1SeedBirth(activeDb);
      activeDb.seed(rootPath, {activeCircleId: null});
      const other = "synthetic-c1-other";
      const docs = [[`users/${other}`, {displayName: "Synthetic other"}],
        [`account_birth_decisions/${other}`, {synthetic: "other ledger"}],
        [`users/${other}/health/day`, {waterIntakeMl: 500, mood: "fine"}],
        [`users/${other}/checkins/day`, {synthetic: "checkin"}],
        [`users/${other}/tasks/task`, {title: "Synthetic task"}],
        [`users/${other}/habits/habit`, {synthetic: "habit"}],
        [`users/${other}/focus/session`, {synthetic: "focus"}],
        [`users/${other}/subjects/subject`, {synthetic: "subject"}]];
      for (const [path, data] of docs) activeDb.seed(path, data);
      await c1Delete();
      for (const [path, data] of docs) {
        assert.deepEqual(activeDb.data(path), data);
      }
      assert.equal(activeDb.operationLog.some((entry) =>
        entry.includes(other)), false);
    });

test("C1 evidence: legacy ledger-absent cleanup retains its original behavior",
    async () => {
      activeDb = new FakeFirestore();
      activeDb.seed(rootPath, {activeCircleId: null});
      activeDb.seed(`${rootPath}/tasks/task`, {title: "Synthetic legacy"});
      const evidence = observeHistoricalR5(activeDb);
      await c1Delete();
      assert.equal(activeDb.data(rootPath), undefined);
      assert.equal(activeDb.data(c1BirthPath), undefined);
      assertOnlyHistoricalR5Controls(activeDb, evidence);
  reportHistoricalR5(activeDb, evidence);
    });


test("R3 managed UID remains bound across pending Auth lookup", async () => {
  activeDb = new FakeFirestore(); await c1SeedBirth(activeDb);
  activeDb.seed(rootPath, {activeCircleId: null});
  const foreignRoot = "users/synthetic-r3-foreign";
  const foreign = {displayName: "Synthetic foreign"};
  activeDb.seed(foreignRoot, foreign);
  const user = c1DeleteUser();
  activeDb.authHook = () => {
    user.uid = "synthetic-r3-foreign";
  };
  await c1Delete(user);
  assert.deepEqual(activeDb.data(foreignRoot), foreign);
  assert.equal(activeDb.data(rootPath), undefined);
  assert.equal(activeDb.data(c1BirthPath), undefined);
  assert.equal(activeDb.data(guardPath).state, "COMPLETE");
  assert.equal(activeDb.operationLog.some((entry) =>
    entry.includes("synthetic-r3-foreign")), false);
});

test("R3 live Auth refuses before guard, Circles or Billing", async () => {
  activeDb = new FakeFirestore(); await c1SeedBirth(activeDb);
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.authUser = {uid}; const before = [...activeDb.store];
  await withoutErrorLog(() => assert.rejects(c1Delete(),
      {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.deepEqual([...activeDb.store], before);
  assert.deepEqual(activeDb.versionedDeletes, []);
  assert.equal(activeDb.data(guardPath), undefined);
});


for (const creationTime of [null, c1Born.toDate().toUTCString()]) {
  test(`R3 Auth with absent/coarse metadata: ${creationTime}`, async () => {
    const {UserRecord} = require("firebase-admin/auth");
    activeDb = new FakeFirestore(); await c1SeedBirth(activeDb);
    activeDb.seed(rootPath, {activeCircleId: null});
    activeDb.authUser = new UserRecord({localId: uid,
      createdAt: String(c1Born.toMillis() + 900)});
    const before = [...activeDb.store];
    await withoutErrorLog(() => assert.rejects(
        c1Delete(c1DeleteUser({creationTime})),
        {message: "USER_DATA_CLEANUP_FAILED"}));
    assert.deepEqual([...activeDb.store], before);
    assert.deepEqual(activeDb.versionedDeletes, []);
    assert.equal(activeDb.data(guardPath), undefined);
  });
}

// P1 post-Auth evidence: real callback/cleaners, synthetic Admin IO only.
// This fake serializes Firestore transactions; it does not emulate Auth delivery,
// Firestore lock/retry behavior, IAM, or atomicity between Auth and Firestore.
const p1RetiredPath = `retired_auth_identities/${uid}`;
const p1OtherRoot = "users/synthetic-p1-unrelated";
const p1OtherChild = `${p1OtherRoot}/notes/private`;
const p1DeletionId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const p1OtherDeletionId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const p1DenyRecord = (deletionId = p1DeletionId) =>
  ({version: 2, state: "RESERVED", deletionId, origin: "PRE_AUTH"});

async function p1Fixture() {
  activeDb = new FakeFirestore();
  await c1SeedBirth(activeDb);
  activeDb.seed(rootPath, {activeCircleId: null});
  activeDb.seed(`${rootPath}/notes/first`, {syntheticOldData: true});
  activeDb.seed(`${rootPath}/notes/remaining`, {syntheticOldData: true});
  // This scenario starts before Auth deletion with a verified synthetic subject.
  // Admit the original PRE_AUTH operation through the real R5 transaction, then
  // model its Auth deletion before delivering the managed event to the callback.
  const control = require("../deletion_control");
  const binding = {projectId: activeDb.projectId, databaseId: activeDb.databaseId, uid};
  let present = {uid, metadata: {creationTime: c1Born.toDate().toUTCString()}};
  const controller = control.createController({db: activeDb, binding,
    clock: () => c1Born, uuid: () => p1DeletionId, ports: {
      getAuthenticatedSubject: async () => binding,
      getAuthUser: async () => {
        activeDb.fixtureTrace.push({kind: "preAuth.lookup", present: !!present});
        if (present) return present;
        throw Object.assign(new Error("synthetic absent"), {code: "auth/user-not-found"});
      },
    }});
  const beforeAdmissionLog = [...activeDb.operationLog];
  const admitted = await controller.admitBackend();
  activeDb.fixtureOriginalOperation = controller.originalOperation(admitted.handle);
  activeDb.seed(billingAccountPath, {uid, state: "DELETING"});
  await cleanupManifest.captureTree({db: activeDb,
    operation: activeDb.fixtureOriginalOperation, ref: activeDb.doc(rootPath),
    assertOperation: tx => controller.assertOperationTransaction(tx, admitted.handle),
    authorizeCapture: async () => present !== null});
  await cleanupManifest.authOutcome({db: activeDb,
    operation: activeDb.fixtureOriginalOperation, ref: activeDb.doc(rootPath),
    assertOperation: tx => controller.assertOperationTransaction(tx, admitted.handle)},
    "NOT_REQUESTED", "DISPATCHED");
  await cleanupManifest.authOutcome({db: activeDb,
    operation: activeDb.fixtureOriginalOperation, ref: activeDb.doc(rootPath),
    assertOperation: tx => controller.assertOperationTransaction(tx, admitted.handle)},
    "DISPATCHED", "CONFIRMED");
  present = null;
  activeDb.fixtureTrace.push({kind: "preAuth.deleted", admitted: admitted.status});
  // Keep setup evidence separate from the cleanup-only historical log. No log
  // entry emitted after the scenario starts is removed or filtered.
  activeDb.fixturePreparationLog = activeDb.operationLog.slice(beforeAdmissionLog.length);
  activeDb.operationLog.length = 0;
  activeDb.operationLog.push(...beforeAdmissionLog);
  activeDb.seed(p1OtherRoot, {syntheticOtherOwner: true});
  activeDb.seed(p1OtherChild, {syntheticOtherData: true});
  const db = activeDb;
  let authLookups = 0;
  db.authHook = () => { authLookups += 1; };
  return {db, authLookups: () => authLookups};
}

function p1AssertOtherAndDeny(db, record = db.nativeDenyRecord || p1DenyRecord()) {
  const p1RetiredPath = 'retired_auth_identities/' + (db.accountUid || uid);
  assert.deepEqual(db.data(p1OtherRoot), {syntheticOtherOwner: true});
  assert.deepEqual(db.data(p1OtherChild), {syntheticOtherData: true});
  assert.deepEqual(db.data(p1RetiredPath), record);
  assert.equal(db.operationLog.some((entry) =>
    entry.endsWith(p1RetiredPath) || entry.includes(p1OtherRoot)), false);
}

function p1Gate() {
  const reached = Promise.withResolvers();
  const released = Promise.withResolvers();
  return {reached: reached.promise, release: released.resolve,
    async pause() { reached.resolve(); await released.promise; }};
}

// A delegated seam at the real exported pre-root check. All SDK-bound Auth
// queries still execute; the internal final lookups are observed until native IO.
function historicalAuthBoundary(t, db, options = {}) {
  const birth = require("../birth_ledger_cleanup");
  const beforeRoot = birth.beforeRootRemoval;
  const authHook = db.authHook;
  const recursive = db.versionedDelete.bind(db);
  const boundary = {active: false, entered: 0, lookups: [], allUIDs: [], native: [], attempts: 0};
  t.mock.method(birth, "beforeRootRemoval", async (...args) => {
    assert.equal(args[0], db);
    boundary.active = true; boundary.entered += 1;
    return beforeRoot(...args);
  });
  t.mock.method(db, "authHook", async owner => {
    if (authHook) await authHook(owner);
    boundary.allUIDs.push(owner);
    assert.equal(owner, uid);
    if (boundary.active) {
      const lookup = {uid: owner, attempt: boundary.attempts, snapshot: recheckSnapshot(db)};
      boundary.lookups.push(lookup);
      if (options.onLookup) await options.onLookup(lookup, boundary);
    }
  });
  t.mock.method(db, "versionedDelete", async ref => {
    assert.equal(ref.path, rootPath);
    assert.equal(boundary.active, true, "native deletion must follow the real pre-root check");
    assert.ok(boundary.lookups.some(row => row.attempt === boundary.attempts));
    boundary.native.push({path: ref.path, attempt: boundary.attempts});
    boundary.active = false;
    if (options.onNative) await options.onNative(ref, boundary);
    return recursive(ref);
  });
  boundary.run = async (...args) => {
    boundary.active = false; boundary.attempts += 1;
    try {return await c1Delete(...args);} finally {boundary.active = false;}
  };
  return boundary;
}

function assertHistoricalLookupFence(db, boundary) {
  const last = boundary.lookups.at(-1);
  assert.ok(last);
  assert.equal(last.uid, uid);
  const now = recheckSnapshot(db);
  assert.deepEqual(now.store, last.snapshot.store);
  assert.deepEqual(now.operations, last.snapshot.operations);
  assert.deepEqual(now.versioned, last.snapshot.versioned);
  assert.ok(now.transactions > last.snapshot.transactions,
      "read-only R5 snapshot and scope transactions remain between Auth and native IO");
}

function reportHistoricalAuth(db, boundary, extra = {}) {
  db.fixtureTrace.push({kind: "historical.auth.boundary", ...extra,
    entered: boundary.entered, attempts: boundary.attempts,
    boundaryUIDs: boundary.lookups.map(row => row.uid), allUIDs: boundary.allUIDs,
    native: boundary.native, guard: db.data(guardPath)?.state,
    receipt: db.data(guardPath + "/control/operation")?.state});
}


test("P1 recovery: partial post-Auth failure replays the same event and preserves DENY", async (t) => {
  const {db, authLookups} = await p1Fixture();
  const evidence = observeHistoricalR5(db);
  let fail = true;
  const boundary = historicalAuthBoundary(t, db, {onNative: ref => {
    assertHistoricalLookupFence(db, boundary);
    if (fail && ref.path === rootPath) {
      fail = false;
      db.store.delete(rootPath);
      db.store.delete(`${rootPath}/notes/first`);
      throw new Error("PRIVATE-P1-PARTIAL-DELETE");
    }
  }});
  await withoutErrorLog(() => assert.rejects(boundary.run(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(fail, false);
  assert.equal(boundary.entered, 1);
  assert.equal(boundary.native.length, 1);
  assert.ok(authLookups() >= boundary.lookups.length && boundary.lookups.length > 0);
  assert.equal(db.data(rootPath), undefined);
  assert.ok(db.data(`${rootPath}/notes/remaining`));
  assert.ok(db.data(c1BirthPath));
  assert.equal(db.data(guardPath).state, "IN_PROGRESS");
  assert.equal(db.data(guardPath).deletionId, p1DeletionId);
  assertHistoricalControls(db, evidence, "IN_PROGRESS");
  p1AssertOtherAndDeny(db);
  await withoutErrorLog(() => assert.rejects(boundary.run(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.ok(db.data(rootPath + "/notes/remaining"));
  assert.ok(db.data(c1BirthPath));
  assert.equal(db.data(guardPath).state, "IN_PROGRESS");
  assertHistoricalControls(db, evidence, "IN_PROGRESS");
  p1AssertOtherAndDeny(db);
  reportHistoricalAuth(db, boundary, {partialFaultReached: !fail});
});

test("P1 recovery: terminal commit failure cannot acknowledge completion and same-event retry converges", async (t) => {
  const {db} = await p1Fixture();
  const originalTransaction = db.runTransaction.bind(db);
  let fail = true;
  t.mock.method(db, "runTransaction", (callback) => originalTransaction(async (tx) => {
    const result = await callback(tx);
    if (fail && tx.writes.some((write) => write.ref.path === guardPath &&
        write.data && write.data.state === "COMPLETE")) {
      fail = false; throw new Error("PRIVATE-P1-TERMINAL-COMMIT");
    }
    return result;
  }));
  await withoutErrorLog(() => assert.rejects(c1Delete(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(db.data(rootPath), undefined);
  assert.ok(db.data(c1BirthPath));
  assert.equal(db.data(guardPath).state, "IN_PROGRESS");
  p1AssertOtherAndDeny(db);
  await c1Delete();
  assert.equal(db.data(c1BirthPath), undefined);
  assert.equal(db.data(guardPath).state, "COMPLETE");
  assert.equal(db.data(guardPath).deletionId, p1DeletionId);
  p1AssertOtherAndDeny(db);
});

test("P1 recovery: concurrent deliveries of the same event converge for the same operation", async (t) => {
  const {db} = await p1Fixture(), hold = p1Gate(); t.after(hold.release);
  const originalDelete = db.versionedDelete.bind(db);
  let paused = false;
  t.mock.method(db, "versionedDelete", async (ref) => {
    if (!paused && ref.path === rootPath) {paused = true; await hold.pause();}
    return originalDelete(ref);
  });
  const first = c1Delete().then(() => ({ok: true}), (error) => ({error}));
  await Promise.race([hold.reached, first.then(() => assert.fail("first delivery did not reach cleanup"))]);
  await c1Delete(); hold.release();
  assert.deepEqual(await first, {ok: true});
  assert.equal(db.data(guardPath).state, "COMPLETE");
  assert.equal(db.data(guardPath).deletionId, p1DeletionId);
  assert.equal(db.operationLog.filter((entry) => entry === `delete:${c1BirthPath}`).length, 1);
  p1AssertOtherAndDeny(db);
});

for (const changedState of ["different deletionId", "COMPLETE"]) {
  test(`P1 recovery: guard ${changedState} after admission blocks preparatory effects`, async (t) => {
    const {db} = await p1Fixture();
    const birth = require("../birth_ledger_cleanup"), originalPrepare = birth.prepare;
    t.mock.method(birth, "prepare", async (...args) => {
      const admission = await originalPrepare(...args);
      const current = db.data(guardPath);
      db.seed(guardPath, changedState === "COMPLETE" ? {...current,
        state: "COMPLETE", retainUntil: c1Clock} : {...current, deletionId: p1OtherDeletionId});
      return admission;
    });
    const before = [...db.operationLog];
    await withoutErrorLog(() => assert.rejects(c1Delete(), {message: "USER_DATA_CLEANUP_FAILED"}));
    assert.deepEqual(db.operationLog, before);
    assert.ok(db.data(rootPath)); assert.ok(db.data(c1BirthPath));
    assert.deepEqual(db.versionedDeletes, []);
    p1AssertOtherAndDeny(db);
  });
}

for (const markerId of [p1DeletionId, p1OtherDeletionId]) {
  test(`P1 recovery: live reused Auth blocks before admission (marker matches=${markerId === p1DeletionId})`, async () => {
    const {db} = await p1Fixture();
    const {UserRecord} = require("firebase-admin/auth");
    db.authUser = new UserRecord({localId: uid, createdAt: String(c1Clock.toMillis())});
    db.seed(p1RetiredPath, p1DenyRecord(markerId));
    const before = [...db.store], operations = [...db.operationLog];
    await withoutErrorLog(() => assert.rejects(c1Delete(), {message: "USER_DATA_CLEANUP_FAILED"}));
    assert.deepEqual([...db.store], before); assert.deepEqual(db.operationLog, operations);
    assert.deepEqual(db.versionedDeletes, []);
    p1AssertOtherAndDeny(db, p1DenyRecord(markerId));
  });
}

test("P1 recovery: UID and PRE_AUTH marker without managed context cannot authorize cleanup", async () => {
  const {db} = await p1Fixture(); const before = [...db.store];
  await withoutErrorLog(() => assert.rejects(cleanupUserData.run({uid}, {}),
    {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.deepEqual([...db.store], before); assert.deepEqual(db.versionedDeletes, []);
  p1AssertOtherAndDeny(db);
});

test("P1 recovery: unavailable Auth fails closed without trusting the marker", async () => {
  const {db} = await p1Fixture(); const before = [...db.store];
  db.authError = Object.assign(new Error("PRIVATE-P1-AUTH-UNAVAILABLE"), {code: "auth/internal-error"});
  await withoutErrorLog(() => assert.rejects(c1Delete(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.deepEqual([...db.store], before); assert.deepEqual(db.versionedDeletes, []);
  p1AssertOtherAndDeny(db);
});

test("P1 recovery: a detectably later root is refused before destructive work", async () => {
  const {db} = await p1Fixture(); db.createTimes.set(rootPath, c1Clock);
  const before = [...db.store];
  await withoutErrorLog(() => assert.rejects(c1Delete(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.deepEqual([...db.store], before); assert.deepEqual(db.versionedDeletes, []);
  p1AssertOtherAndDeny(db);
});

test("P1 recovery: COMPLETE plus DENY is read-only after mandatory terminal verification", async () => {
  const {db} = await p1Fixture(); await c1Delete();
  const before = [...db.store], operations = [...db.operationLog], recursive = [...db.versionedDeletes];
  await c1Delete();
  assert.deepEqual([...db.store], before); assert.deepEqual(db.operationLog, operations);
  assert.deepEqual(db.versionedDeletes, recursive); p1AssertOtherAndDeny(db);
});

test("P1 recovery: late orphan residue prevents COMPLETE until another real cleanup attempt", async (t) => {
  const {db} = await p1Fixture(), originalDelete = db.versionedDelete.bind(db);
  const orphan = `${rootPath}/unknown/missing/nested/private`; let inject = true;
  t.mock.method(db, "versionedDelete", async (ref) => {
    await originalDelete(ref);
    if (inject && ref.path === rootPath) {inject = false; db.seed(orphan, {syntheticResidue: true});}
  });
  await withoutErrorLog(() => assert.rejects(c1Delete(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.ok(db.data(orphan)); assert.ok(db.data(c1BirthPath));
  assert.equal(db.data(guardPath).state, "IN_PROGRESS"); p1AssertOtherAndDeny(db);
  await withoutErrorLog(() => assert.rejects(c1Delete(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.ok(db.data(orphan)); assert.ok(db.data(c1BirthPath));
  assert.equal(db.data(guardPath).state, "IN_PROGRESS"); p1AssertOtherAndDeny(db);
});

// Original race oracles now use genuine Emulator provenance and native MVCC.
// Their local PASS does not close P1/K01 or authorize any production rollout.
for (const boundary of ["after admission", "before recursive delete"]) {
  test(`P1 RED: reused UID ${boundary} must preserve the recreated account`, async (t) => {
    const fixture = await require('./helpers/trusted-original-operation.cjs')({
      deletionId:p1DeletionId,peerRoot:p1OtherRoot,peerChild:p1OtherChild,t});
    const {db,authLookups,uid,rootPath,guardPath}=fixture;activeDb=db;
    const c1Delete=async()=>{try{return await cleanupUserData.run(fixture.user,fixture.context);}finally{await db.refresh();}};
    const nativeGate=p1Gate();
    const hold={...nativeGate,release:async()=>{try{await db.flush();}finally{nativeGate.release();}}};
    let execution;
    fixture.beforeClose=async()=>{try{await hold.release();}finally{if(execution)await execution;}};
    let lookupsAtPause = null;
    if (boundary === "after admission") {
      const birth = require("../birth_ledger_cleanup"), originalPrepare = birth.prepare;
      t.mock.method(birth, "prepare", async (...args) => {
        const admission = await originalPrepare(...args); await hold.pause(); return admission;
      });
    } else {
      const run = db.runTransaction.bind(db);
      const sealed = cleanupManifest.refs(db, db.fixtureOriginalOperation, rootPath).header.path;
      let paused = false;
      t.mock.method(db, "runTransaction", callback => run(async tx => {
        const get = tx.get.bind(tx);
        tx.get = async ref => {
          const snapshot = await get(ref);
          if (!paused && ref.path === sealed + "/pages/0" &&
              snapshot.exists && snapshot.data().done === false) {
            paused = true;
            lookupsAtPause = authLookups();
            await hold.pause();
          }
          return snapshot;
        };
        return callback(tx);
      }));
    }
    execution = c1Delete().then(() => ({ok: true}), (error) => ({error}));
    await Promise.race([hold.reached, execution.then(() => assert.fail("callback did not reach controlled pause"))]);
    const {UserRecord} = require("firebase-admin/auth");
    db.authUser = new UserRecord({localId: uid, createdAt: String(c1Clock.toMillis())});
    // A privileged synthetic recreation bypasses client Rules, as Admin can.
    // These test labels are ownership evidence in the scenario, not a new schema.
    db.seed(rootPath, {activeCircleId: null, syntheticRecreatedAccount: true});
    db.createTimes.set(rootPath, c1Clock);
    const recreatedChild = `${rootPath}/notes/recreated-private`;
    db.seed(recreatedChild, {syntheticRecreatedData: true});
    await hold.release(); const outcome = await execution;
    p1AssertOtherAndDeny(db);
    t.diagnostic(JSON.stringify({boundary, authLookups: authLookups(), authPresent: !!db.authUser,
      recreatedRootPreserved: !!db.data(rootPath), recreatedChildPreserved: !!db.data(recreatedChild),
      guardState: db.data(guardPath).state, callbackResolved: outcome.ok === true}));
    assert.ok(db.data(recreatedChild), "P1 BLOCKER: an old event deleted data belonging to the recreated UID");
    assert.ok(db.data(rootPath), "P1 BLOCKER: the recreated root must remain intact");
    if (boundary === "before recursive delete") {
      assert.ok(lookupsAtPause > 0, "pause follows the last real Auth lookup");
      assert.equal(authLookups(), lookupsAtPause,
          "preservation must come from the transaction/version fence, not a later Auth lookup");
    }
  });
}


// P1-AUTH-ABSENCE-RECHECK-R1: real callback, synthetic Auth/Firestore IO.
// These checks prove local refusal behavior only, not cross-service atomicity.
function recheckSnapshot(db) {
  return {store: [...db.store], operations: [...db.operationLog],
    versioned: [...db.versionedDeletes], transactions: db.transactionCount};
}

function assertRecheckStopped(db, snapshot, guard) {
  assert.deepEqual(recheckSnapshot(db), snapshot,
      "No cleaner or finalizer may run after an unsafe Auth result");
  assert.deepEqual(db.data(guardPath), guard);
  assert.equal(db.data(guardPath).state, "IN_PROGRESS");
  assert.equal(db.data(guardPath).retainUntil, null);
  assert.ok(db.data(rootPath));
  assert.ok(db.data(`${rootPath}/notes/remaining`));
  assert.ok(db.data(c1BirthPath));
  assert.equal(db.data(billingAccountPath).state, "DELETING");
  p1AssertOtherAndDeny(db);
}

test("P1 absence recheck: Auth absence permits private cleanup immediately after the second query", async (t) => {
  const {db} = await p1Fixture();
  const boundary = historicalAuthBoundary(t, db, {onNative: () => assertHistoricalLookupFence(db, boundary)});
  await boundary.run();
  assert.equal(boundary.entered, 1);
  assert.ok(boundary.lookups.length > 0);
  assert.ok(boundary.allUIDs.every(owner => owner === uid));
  assert.deepEqual(db.versionedDeletes, [rootPath]);
  assert.equal(db.data(rootPath), undefined);
  assert.equal(db.data(`${rootPath}/notes/remaining`), undefined);
  assert.equal(db.data(c1BirthPath), undefined);
  assert.equal(db.data(billingAccountPath), undefined);
  assert.equal(db.data(guardPath).state, "COMPLETE");
  p1AssertOtherAndDeny(db);
  reportHistoricalAuth(db, boundary, {readOnlyFencePreserved: true});
});

for (const [label, result] of [
  ["Auth present", () => ({uid})],
  ["Auth unavailable", () => {
    throw Object.assign(new Error("synthetic unavailable"),
        {code: "auth/internal-error"});
  }],
  ["Auth timeout", () => {
    throw Object.assign(new Error("synthetic timeout"), {code: "ETIMEDOUT"});
  }],
  ["unexpected Auth error", () => {throw new Error("synthetic unexpected");}],
  ["non-error Auth rejection", () => {throw null;}],
  ["not-found message without the exact code", () => {
    throw new Error("auth/user-not-found");
  }],
  ["Auth error resembling the completion sentinel", () => {
    throw Object.assign(new Error("synthetic foreign sentinel"),
        {code: "ACCOUNT_CLEANUP_COMPLETE"});
  }],
]) {
  test(`P1 absence recheck: ${label} rejects without recursive deletion or subsequent cleaners`, async (t) => {
  const {db} = await p1Fixture();
  const guard = db.data(guardPath);
  const controls = db.data(guardPath + "/control/operation");
  let atRecheck, injected = 0;
  const boundary = historicalAuthBoundary(t, db, {onLookup: row => {
    atRecheck = row.snapshot;
    injected += 1;
    db.authUser = result();
  }});
  await withoutErrorLog(() => assert.rejects(boundary.run(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(boundary.entered, 1);
  assert.equal(injected, 1, "refusal occurs at the real pre-root Auth query");
  assert.deepEqual(db.versionedDeletes, []);
  assert.deepEqual(db.data(guardPath + "/control/operation"), controls);
  assertRecheckStopped(db, atRecheck, guard);
  reportHistoricalAuth(db, boundary, {label, injected, noSubsequentCleaner: true});
});
}

test("P1 absence recheck: a pending lookup cannot start private deletion, and a later timeout rejects", {timeout: 5000}, async (t) => {
  const {db} = await p1Fixture();
  const guard = db.data(guardPath);
  const hold = p1Gate();
  t.after(hold.release);
  let atRecheck, injected = 0;
  const boundary = historicalAuthBoundary(t, db, {onLookup: async row => {
    atRecheck = row.snapshot; injected += 1;
    await hold.pause();
    throw Object.assign(new Error("synthetic delayed timeout"), {code: "ETIMEDOUT"});
  }});
  await withoutErrorLog(async () => {
    const execution = boundary.run().then(() => ({ok: true}), error => ({error}));
    await Promise.race([hold.reached, execution.then(() => assert.fail("Callback did not await the new Auth lookup"))]);
    assert.deepEqual(db.versionedDeletes, []);
    assertRecheckStopped(db, atRecheck, guard);
    hold.release();
    const outcome = await execution;
    assert.equal(outcome.ok, undefined);
    assert.equal(outcome.error.message, "USER_DATA_CLEANUP_FAILED");
  });
  assert.equal(boundary.entered, 1);
  assert.equal(injected, 1);
  assertRecheckStopped(db, atRecheck, guard);
  reportHistoricalAuth(db, boundary, {injected, pauseReached: true, timeoutPropagated: true});
});

test("P1 absence recheck: same-event retry retains the original UID and deletion scope", async (t) => {
  const {db} = await p1Fixture();
  const guard = db.data(guardPath);
  const originalReceipt = db.data(guardPath + "/control/operation");
  const birth = require("../birth_ledger_cleanup");
  const originalPrepare = birth.prepare;
  const scopes = [];
  t.mock.method(birth, "prepare", async (...args) => {
    const admission = await originalPrepare(...args);
    scopes.push({uid: args[1].uid, context: {...args[2]}, bound: admission.bound, guard: admission.guard});
    return admission;
  });
  let failed = false;
  const boundary = historicalAuthBoundary(t, db, {onLookup: () => {
    if (!failed) {
      failed = true;
      throw Object.assign(new Error("synthetic unavailable"), {code: "auth/internal-error"});
    }
  }});
  await withoutErrorLog(() => assert.rejects(boundary.run(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(failed, true);
  assert.equal(boundary.entered, 1);
  assert.deepEqual(db.data(guardPath), guard);
  assert.deepEqual(db.data(guardPath + "/control/operation"), originalReceipt);
  assert.deepEqual(db.versionedDeletes, []);
  p1AssertOtherAndDeny(db);
  await boundary.run();
  assert.equal(boundary.entered, 2);
  assert.ok(boundary.lookups.some(row => row.attempt === 1));
  assert.ok(boundary.lookups.some(row => row.attempt === 2));
  assert.equal(scopes.length, 2);
  assert.deepEqual(scopes[1], scopes[0]);
  assert.equal(scopes[0].uid, uid);
  assert.equal(scopes[0].context.eventId, "synthetic-delete-c1");
  assert.equal(db.data(guardPath).deletionId, guard.deletionId);
  assert.ok(db.data(guardPath).startedAt.isEqual(guard.startedAt));
  assert.equal(db.data(guardPath).state, "COMPLETE");
  assert.deepEqual(db.data(guardPath + "/control/operation").scope, originalReceipt.scope);
  assert.deepEqual(db.versionedDeletes, [rootPath]);
  p1AssertOtherAndDeny(db);
  reportHistoricalAuth(db, boundary, {failed, sameEventAndScope: true});
});

test("P1 absence recheck: Auth reappearing before the new query preserves the recreated private tree", async (t) => {
  const {db} = await p1Fixture();
  const guard = db.data(guardPath);
  let recreated, injected = 0;
  const boundary = historicalAuthBoundary(t, db, {onLookup: () => {
    injected += 1;
    // Matching claims and coarse metadata still do not prove continuity.
    db.authUser = {uid, metadata: {creationTime: c1Born.toDate().toUTCString()}, customClaims: {syntheticCopiedClaim: true}};
    db.seed(rootPath, {activeCircleId: null, syntheticRecreatedAccount: true});
    db.seed(`${rootPath}/notes/recreated-private`, {syntheticPrivate: true});
    recreated = recheckSnapshot(db);
  }});
  await withoutErrorLog(() => assert.rejects(boundary.run(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(boundary.entered, 1);
  assert.equal(injected, 1);
  assert.deepEqual(db.versionedDeletes, []);
  assert.deepEqual(db.data(`${rootPath}/notes/recreated-private`),
      {syntheticPrivate: true});
  assertRecheckStopped(db, recreated, guard);
  reportHistoricalAuth(db, boundary, {injected, recreatedDataPreserved: true});
});

test("P1 absence recheck: not-found from recursive deletion is not Auth absence or success", async (t) => {
  const {db, authLookups} = await p1Fixture();
  const guard = db.data(guardPath);
  let beforeDelete, injected = 0;
  const boundary = historicalAuthBoundary(t, db, {onNative: ref => {
    assert.equal(ref.path, rootPath);
    assertHistoricalLookupFence(db, boundary);
    beforeDelete = recheckSnapshot(db);
    injected += 1;
    throw Object.assign(new Error("synthetic storage not found"), {code: "auth/user-not-found"});
  }});
  await withoutErrorLog(() => assert.rejects(boundary.run(), {message: "USER_DATA_CLEANUP_FAILED"}));
  assert.equal(injected, 1);
  assert.equal(boundary.native.length, 1);
  assert.ok(authLookups() >= boundary.lookups.length && boundary.lookups.length > 0);
  assertRecheckStopped(db, beforeDelete, guard);
  reportHistoricalAuth(db, boundary, {injected, storageNotFoundPropagated: true});
});

// Original P1 RED safety assertions remain unchanged above. Its native
// page-read pause follows the final Auth query; version checks protect the
// recreated namespace without asserting atomicity across Auth and Firestore.

// Read-only evidence of reached stages. Never modifies results or test oracles.
test.afterEach(t => {
  if (!activeDb?.fixtureTrace) return;
  const guardPath = 'account_deletion_guards/' + (activeDb.accountUid || uid);
  t.diagnostic(JSON.stringify({fixtureEvidence: true, name: t.name,
    trace: activeDb.fixtureTrace.slice(-16),
    preparationLog: activeDb.fixturePreparationLog,
    versioned: activeDb.versionedDeletes,
    guard: activeDb.data(guardPath)?.state,
    operation: activeDb.data(guardPath + "/control/operation")?.state,
    circleMarker: activeDb.data("circle_deletions/" + circleId),
    closureExists: activeDb.store.has("circle_cleanup_guards/" + circleId),
  }));
});
