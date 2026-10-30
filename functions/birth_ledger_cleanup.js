"use strict";
const {createHash, randomUUID} = require("node:crypto");
const {Timestamp} = require("firebase-admin/firestore");
const circles = require("./circle_cleanup");
const control = require("./deletion_control");
const KEYS = ["version", "uid", "projectId", "tenantId", "authCreatedAt",
  "sourceType", "sourceEventId", "eventAt", "cohort", "decisionId",
  "originalIdentity", "recordedAt", "status"];

/** Fail without any identity, storage or SDK details. */
function fail() {
  const error = new Error("Account cleanup state is inconsistent.");
  error.code = "ACCOUNT_STATE_CONFLICT";
  throw error;
}

/**
 * @param {*} value Value.
 * @param {Array} keys Expected fields.
 * @return {boolean} Exact record.
 */
function exact(value, keys) {
  return value && Object.getPrototypeOf(value) === Object.prototype &&
    Object.keys(value).length === keys.length &&
    keys.every((key) => Object.hasOwn(value, key));
}

/**
 * @param {*} value UID.
 * @return {boolean} Canonical namespace, before references/IO.
 */
function uid(value) {
  return typeof value === "string" && value.length > 0 &&
    value.length <= 128 && Buffer.byteLength(value, "utf8") <= 128 &&
    value.trim() === value && !value.includes("/") &&
    ![".", ".."].includes(value) && !/^__.*__$/.test(value) &&
    // eslint-disable-next-line no-control-regex
    !/[\u0000-\u001f\u007f]/.test(value);
}

/**
 * @param {*} value Time.
 * @return {boolean} Auth-era Firestore time.
 */
function time(value) {
  return value instanceof Timestamp && value.seconds >= 0;
}

/**
 * @param {Timestamp} a First time.
 * @param {Timestamp} b Second time.
 * @return {boolean} Exact ordering; never round to gain authority.
 */
function after(a, b) {
  return a.seconds > b.seconds ||
    (a.seconds === b.seconds && a.nanoseconds > b.nanoseconds);
}

/**
 * Strict UTC form delivered by the managed v1 SDK; preserve supplied fraction.
 * Unsupported time forms fail closed, never use delivery time as event time.
 * @param {*} value Event string.
 * @return {Timestamp} Parsed managed time.
 */
function eventTime(value) {
  const match = typeof value === "string" && value.match(new RegExp(
      "^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})" +
      "(?:\\.(\\d{1,9}))?Z$"));
  if (!match) fail();
  const date = new Date(`${match[1]}.000Z`);
  if (!Number.isFinite(date.getTime()) || date.getTime() < 0 ||
    date.toISOString() !== `${match[1]}.000Z`) fail();
  return new Timestamp(date.getTime() / 1000,
      Number((match[2] || "").padEnd(9, "0")));
}

/**
 * @param {*} value Metadata string, possibly absent for legacy events.
 * @return {*} Time and known precision, or null under policy A.
 */
function metadata(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") fail();
  if (/^\d{4}-/.test(value)) {
    return {at: eventTime(value), coarse: !value.includes(".")};
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.getTime() < 0 ||
    date.toUTCString() !== value) fail();
  return {at: Timestamp.fromMillis(date.getTime()), coarse: true};
}

/**
 * @param {*} value Persisted normalized identity field.
 * @param {number} max Bound.
 * @return {boolean} Bounded normalized text.
 */
function text(value, max) {
  return typeof value === "string" && value.length <= max &&
    value.trim() === value &&
    // eslint-disable-next-line no-control-regex
    !/[\u0000-\u001f\u007f]/.test(value);
}

/**
 * @param {Object} record Approved B2-A closed record.
 * @param {Object} bound Managed deletion, not HTTP/client authority.
 */
function validate(record, bound) {
  const identity = record && record.originalIdentity;
  const cohort = record && record.cohort;
  if (!exact(record, KEYS) || record.version !== 1 ||
    record.uid !== bound.uid || record.projectId !== bound.projectId ||
    record.tenantId !== null || record.sourceType !== "FIREBASE_AUTH_CREATE" ||
    record.status !== "RECORDED_COHORT_CLOSED" ||
    !text(record.sourceEventId, 512) || !record.sourceEventId ||
    !new RegExp("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-" +
        "[89ab][0-9a-f]{3}-[0-9a-f]{12}$").test(record.decisionId) ||
    !time(record.authCreatedAt) || !time(record.eventAt) ||
    !time(record.recordedAt) || after(record.authCreatedAt, record.eventAt) ||
    after(record.eventAt, record.recordedAt) ||
    after(record.authCreatedAt, bound.deletedAt) ||
    !exact(cohort, ["version", "id", "policy", "state", "cutoverAt"]) ||
    cohort.version !== 1 || !uid(cohort.id) ||
    cohort.policy !== "NEW_ACCOUNT_V2_ONLY" || cohort.state !== "CLOSED" ||
    !time(cohort.cutoverAt) || after(cohort.cutoverAt, record.authCreatedAt) ||
    !exact(identity, ["uid", "email", "displayName", "photoUrl"]) ||
    identity.uid !== bound.uid || !text(identity.email, 320) ||
    !text(identity.displayName, 200) || !identity.displayName ||
    !(identity.photoUrl === null || text(identity.photoUrl, 2048))) fail();
  if (bound.created && (bound.created.coarse ?
    bound.created.at.seconds !== record.authCreatedAt.seconds :
    !bound.created.at.isEqual(record.authCreatedAt))) fail();
}

// Process-local capabilities. Neither HTTP JSON nor a copied object can resume.
const admissions = new WeakMap();

function session(db, auth, admission) {
  const value = admission && admissions.get(admission);
  if (!value || value.db !== db || value.auth !== auth ||
      db.projectId !== value.operation.projectId ||
      db.databaseId !== value.operation.databaseId) fail();
  return value;
}

function unavailable() {
  const error = new Error("Account deletion remains pending.");
  error.code = "ACCOUNT_DELETION_BLOCKED";
  error.retryable = true;
  throw error;
}

async function controlled(work) {
  try { return await work(); } catch (error) {
    if (error instanceof control.DeletionControlError) {
      if (["READ_UNAVAILABLE", "COMMIT_OUTCOME_UNKNOWN", "AUTH_UNAVAILABLE",
        "BOUNDARY_UNAVAILABLE"].includes(error.code)) unavailable();
      if (error.code === "CIRCLE_ADMIN_ACTION_REQUIRED") {
        const admin = new Error("Circle administration required.");
        admin.code = "CIRCLE_ADMIN_ACTION_REQUIRED";
        throw admin;
      }
      if (error.code === "COMPLETE") {
        const terminal = new Error("Account cleanup is terminal.");
        terminal.code = "ACCOUNT_CLEANUP_COMPLETE";
        throw terminal;
      }
      fail();
    }
    throw error;
  }
}

// An absence here is only an observation. It never admits a new operation.
async function lookup(auth, accountUid) {
  let user;
  try { user = await auth.getUser(accountUid); } catch (error) {
    if (error?.code === "auth/user-not-found") return null;
    unavailable();
  }
  if (!user || user.uid !== accountUid || user.disabled === true ||
      (user.tenantId !== undefined && user.tenantId !== null)) fail();
  metadata(user.metadata?.creationTime); // Invalid metadata is a conflict.
  return user;
}

function checkRoot(root, operation) {
  if (root.exists && root.createTime !== undefined &&
      (!time(root.createTime) ||
        after(root.createTime, operation.scope.guardStartedAt))) fail();
}

function checkUser(user, operation) {
  const created = user ? metadata(user.metadata?.creationTime) : null;
  if (created && (created.coarse ?
    created.at.seconds > operation.scope.guardStartedAt.seconds :
    after(created.at, operation.scope.guardStartedAt))) fail();
  return created;
}

// Real terminal queries: no constant attestation can substitute for these reads.
async function assertTerminal(tx, db, accountUid) {
  const privateHash = createHash("sha256").update("users/" + accountUid).digest("hex");
  const journal = await tx.get(db.doc("account_deletion_guards/" + accountUid +
    "/cleanup_manifests/" + privateHash));
  if (journal.exists) {
    const h = journal.data();
    const original = await tx.get(db.doc("account_deletion_guards/" + accountUid + "/control/operation"));
    if (h.version !== 2 || h.uid !== accountUid || h.projectId !== db.projectId ||
        h.databaseId !== db.databaseId || h.state !== "COMPLETE" ||
        !original.exists || h.deletionId !== original.data().deletionId ||
        ["UNKNOWN", "DISPATCHED"].includes(h.authOutcome) ||
        (original.data().origin === "PRE_AUTH" && h.authOutcome !== "CONFIRMED")) fail();
  }

  const hash = createHash("sha256").update(accountUid, "utf8").digest("hex");
  const billing = await tx.get(db.collection("billing_google_accounts").doc(hash));
  const tokens = await tx.get(db.collection("billing_google_tokens")
      .where("accountHash", "==", hash).limit(1));
  const runtime = await tx.get(db.collection("users").doc(accountUid)
      .collection("runtime").limit(1));
  await circles.assertEmpty(tx, db, accountUid);
  await circles.verifyReferences(db, accountUid, tx);
  if (billing.exists || tokens.docs.length || runtime.docs.length) fail();
}

// No production R5 rollout boundary has been certified. An override is usable
// only by synthetic tests in the dedicated demo project, never from EventContext.
const CLOSED_ROLLOUT = Object.freeze({verified: false, notBefore: null});

async function prepare(db, user, context, getUser, syntheticRollout) {
  return controlled(async () => {
    const binding = control.validateBinding({projectId: db?.projectId,
      databaseId: db?.databaseId, uid: user?.uid});
    if (!context || context.eventType !== "google.firebase.auth.user.delete" ||
        !text(context.eventId, 512) || !context.eventId ||
        context.resource?.service !== "firebaseauth.googleapis.com" ||
        context.resource.name !== `projects/${binding.projectId}` ||
        (user.tenantId !== undefined && user.tenantId !== null) ||
        typeof getUser !== "function") fail();
    const bound = Object.freeze({...binding, deletedAt: eventTime(context.timestamp),
      created: metadata(user.metadata?.creationTime)});
    if (bound.created && after(bound.created.at, bound.deletedAt)) fail();
    const rollout = syntheticRollout === undefined ? CLOSED_ROLLOUT : syntheticRollout;
    if (syntheticRollout !== undefined &&
        (binding.projectId !== "demo-life-os-p1" ||
         !exact(rollout, ["verified", "notBefore"]) ||
         typeof rollout.verified !== "boolean" ||
         !(rollout.notBefore === null || time(rollout.notBefore)))) fail();
    const auth = {getUser};
    if (await lookup(auth, binding.uid)) fail();
    let controller, admitted, admission;
    const ports = {
      getManagedEvent: async () => {
        // This seam is called only by the managed v1 callback. JSON fields such
        // as association/deletionId/verified in the event never select authority.
        const current = await db.runTransaction(tx => tx.get(
            db.doc(`account_deletion_guards/${binding.uid}/control/operation`)));
        if (current.exists) {
          const original = control.validateControl(current.data(), binding);
          return {...binding, eventId: context.eventId,
            association: "ORIGINAL_OPERATION", deletionId: original.deletionId};
        }
        const newPolicy = rollout.verified === true && time(rollout.notBefore) &&
          !after(rollout.notBefore, bound.deletedAt);
        return {...binding, eventId: context.eventId,
          association: newPolicy ? "NEW_POLICY" : "REVIEW", deletionId: null};
      },
      getAuthUser: async () => {
        const live = await lookup(auth, binding.uid);
        if (live) fail();
        throw Object.assign(new Error("Auth absent."), {code: "auth/user-not-found"});
      },
      admissionTransaction: async (tx, operation) => {
        const root = await tx.get(db.collection("users").doc(binding.uid));
        const ledger = await tx.get(db.collection("account_birth_decisions").doc(binding.uid));
        if (operation.state === "REVIEW_REQUIRED") return;
        checkRoot(root, operation);
        if (root.exists && root.createTime !== undefined &&
            (!time(root.createTime) || after(root.createTime, bound.deletedAt))) fail();
        if (ledger.exists) validate(ledger.data(), bound);
        await circles.preflightManagedOwned(tx, db, binding.uid);
      },
      authorizeCleanup: async () => {
        const current = await controller.continueOperation(admitted.handle);
        if (current.status !== "IN_PROGRESS") fail();
        const original = controller.originalOperation(admitted.handle);
        return {...binding, deletionId: original.deletionId};
      },
      terminalInventory: async context => {
        await circles.assertUserTreeEmpty(db, binding.uid);
        await db.runTransaction(tx => assertTerminal(tx, db, binding.uid));
        return {...context, privateTreeEmpty: true, externalResourcesEmpty: true};
      },
      terminalTransaction: async (tx, context) => {
        await assertTerminal(tx, db, binding.uid);
        return {...context, privateTreeEmpty: true, externalResourcesEmpty: true};
      },
    };
    controller = control.createController({db, binding,
      clock: () => Timestamp.now(), uuid: randomUUID, ports});
    admitted = await controller.admitManagedEvent();
    if (!admitted.handle) {
      const error = new Error("Account cleanup requires review.");
      error.code = "ACCOUNT_CLEANUP_REVIEW_REQUIRED";
      error.retryable = true;
      throw error;
    }
    const operation = controller.originalOperation(admitted.handle);
    // Temporal inconsistency rejects an old event; a date never grants authority.
    if (operation.origin === "PRE_AUTH" &&
        after(operation.scope.guardStartedAt, bound.deletedAt)) fail();
    const value = {db, auth, controller, handle: admitted.handle, operation,
      sawAbsent: true};
    const guard = circles.bindOperation(db, binding.uid, controller, admitted.handle,
        async ref => {
          await verifyStep(db, auth, admission);
          if (ref?.path === operation.scope.privateRoot) await beforeRootRemoval(db, auth, admission);
        }, async () => binding.projectId === "demo-life-os-p1" && rollout.verified === true);
    admission = Object.freeze({bound, guard});
    value.guard = guard;
    admissions.set(admission, value);
    if (admitted.status !== "COMPLETE") await verifySnapshot(db, admission);
    return admission;
  });
}

function originalOperation(db, auth, admission) {
  return session(db, auth, admission).operation;
}

function cleanupDatabase(db, auth, admission) {
  const value = session(db, auth, admission);
  return circles.withActiveGuard(db, value.operation.uid, value.guard);
}

async function verifySnapshot(db, admission) {
  const value = admission && admissions.get(admission);
  if (!value || value.db !== db) fail();
  return controlled(() => db.runTransaction(async tx => {
    await value.controller.assertOperationTransaction(tx, value.handle);
    const root = await tx.get(db.collection("users").doc(value.operation.uid));
    checkRoot(root, value.operation);
    if (root.exists && root.createTime !== undefined &&
        (!time(root.createTime) || after(root.createTime, admission.bound.deletedAt))) fail();
    const ledger = await tx.get(db.collection("account_birth_decisions").doc(value.operation.uid));
    if (ledger.exists) validate(ledger.data(), admission.bound);
  }));
}

async function verifyStep(db, auth, admission) {
  const value = session(db, auth, admission);
  const user = await lookup(auth, value.operation.uid);
  if (value.sawAbsent && user) fail();
  if (!user) value.sawAbsent = true;
  checkUser(user, value.operation);
  await verifySnapshot(db, admission);
  return user !== null;
}

async function beforeRootRemoval(db, auth, admission) {
  if (await verifyStep(db, auth, admission)) fail();
}

async function finish(db, auth, admission) {
  const value = session(db, auth, admission);
  return controlled(async () => {
    const current = await value.controller.continueOperation(value.handle);
    if (current.status === "COMPLETE") {
      return value.controller.verifyTerminal(value.handle);
    }
    if (current.status !== "IN_PROGRESS") fail();
    const cleanup = await value.controller.authorizeCleanup(value.handle);
    return value.controller.finalizeWithOriginalLedger(cleanup);
  });
}

async function currentState(db, auth, admission) {
  const value = session(db, auth, admission);
  return controlled(async () =>
    (await value.controller.continueOperation(value.handle)).status);
}

// The opaque admission retains the exact Auth lookup used at the SDK boundary.
module.exports = {prepare, verifySnapshot,
  originalOperation: (db, a) => originalOperation(db, admissions.get(a)?.auth, a),
  cleanupDatabase: (db, a) => cleanupDatabase(db, admissions.get(a)?.auth, a),
  currentState: (db, a) => currentState(db, admissions.get(a)?.auth, a),
  verifyStep: (db, a) => verifyStep(db, admissions.get(a)?.auth, a),
  beforeRootRemoval: (db, a) => beforeRootRemoval(db, admissions.get(a)?.auth, a),
  finish: (db, a) => finish(db, admissions.get(a)?.auth, a),
};
