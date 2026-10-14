"use strict";

const {createHash} = require("node:crypto");
const {Timestamp} = require("firebase-admin/firestore");
const circles = require("./circle_cleanup");

const RETENTION_MS = 65 * 60 * 1000;
const KEYS = ["version", "uid", "projectId", "tenantId", "authCreatedAt",
  "sourceType", "sourceEventId", "eventAt", "cohort", "decisionId",
  "originalIdentity", "recordedAt", "status"];

/** Fail without any identity, storage or SDK details. */
function fail() {
  throw new Error("BIRTH_CLEANUP_CONFLICT");
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

/**
 * Canonical digest in memory only; never logs/persists identity or its digest.
 * @param {*} value Typed record.
 * @return {*} Stable data.
 */
function canonical(value) {
  if (value instanceof Timestamp) return [value.seconds, value.nanoseconds];
  if (value && typeof value === "object") {
    return Object.keys(value).sort().map((key) => [key, canonical(value[key])]);
  }
  return value;
}

/**
 * @param {Object} tx Transaction, before writes.
 * @param {Object} db Trusted Admin storage.
 * @param {Object} bound Managed deletion.
 * @return {Promise<Object>} Original ledger digest and root presence.
 */
async function inspect(tx, db, bound) {
  const root = await tx.get(db.collection("users").doc(bound.uid));
  const ledger = await tx.get(db.collection("account_birth_decisions")
      .doc(bound.uid));
  // Quarantine a later root, including a possible stale-client write.
  // A late write alone does not prove another Auth generation.
  if (root.exists && root.createTime !== undefined &&
    (!time(root.createTime) || after(root.createTime, bound.deletedAt))) fail();
  if (!ledger.exists) return {digest: null, rootExists: root.exists};
  const record = ledger.data(); validate(record, bound);
  return {digest: createHash("sha256").update(JSON.stringify(canonical(record)))
      .digest("hex"), rootExists: root.exists};
}

/**
 * Trusted SDK onDelete boundary only; not a verifier for arbitrary JSON.
 * Under policy A a missing/coarse creation date is not deletion authority.
 * @param {Object} db Explicit trusted Admin storage.
 * @param {Object} user SDK deletion record.
 * @param {Object} context SDK normalized event context.
 * @param {Function} getUser Trusted Admin lookup, never a client callback.
 * @return {Promise<Object>} Immutable event/guard/snapshot for this attempt.
 */
async function prepare(db, user, context, getUser) {
  if (!user || !uid(user.uid) || !db || typeof db.projectId !== "string" ||
    !context || context.eventType !== "google.firebase.auth.user.delete" ||
    !text(context.eventId, 512) || !context.eventId || !context.resource ||
    context.resource.service !== "firebaseauth.googleapis.com" ||
    context.resource.name !== `projects/${db.projectId}` ||
    (user.tenantId !== undefined && user.tenantId !== null) ||
    typeof getUser !== "function") fail();
  const bound = Object.freeze({uid: user.uid, projectId: db.projectId,
    deletedAt: eventTime(context.timestamp),
    created: metadata(user.metadata && user.metadata.creationTime)});
  if (bound.created && after(bound.created.at, bound.deletedAt)) fail();
  try {
    await getUser(bound.uid);
  } catch (error) {
    if (!error || error.code !== "auth/user-not-found") fail();
    const guard = await circles.beginGuard(db, bound.uid, async (tx) => {
      await inspect(tx, db, bound);
    });
    const digest = await db.runTransaction(async (tx) => {
      await circles.requireGuard(tx, db, bound.uid, guard);
      const remaining = await inspect(tx, db, bound);
      // Older cleanup may have marked COMPLETE without considering this ledger.
      // Reclaim the same deletionId before effects; IN_PROGRESS closes writers.
      if (guard.state === "COMPLETE" &&
        (remaining.digest !== null || remaining.rootExists)) {
        tx.update(db.collection("account_deletion_guards").doc(bound.uid),
            {state: "IN_PROGRESS", retainUntil: null});
      }
      return remaining.digest;
    });
    return Object.freeze({bound, guard, digest});
  }
  // Any existing Auth user is an explicit violation/stale event under policy A.
  fail();
}

/**
 * Only after the existing mandatory Circles/Billing cleanup completed.
 * Atomic PII removal + COMPLETE; a lost reply can replay the same guard.
 * @param {Object} db Trusted Admin storage.
 * @param {Object} admission Result of prepare for this attempt.
 * @return {Promise<void>} Atomic finalization.
 */
async function finish(db, admission) {
  const {bound, guard, digest} = admission;
  if (db.projectId !== bound.projectId || !uid(bound.uid)) fail();
  await db.runTransaction(async (tx) => {
    await circles.requireGuard(tx, db, bound.uid, guard);
    const guardRef = db.collection("account_deletion_guards").doc(bound.uid);
    const currentGuard = await tx.get(guardRef);
    const root = await tx.get(db.collection("users").doc(bound.uid));
    const ledgerRef = db.collection("account_birth_decisions").doc(bound.uid);
    const ledger = await tx.get(ledgerRef);
    if (root.exists) fail();
    if (ledger.exists) {
      validate(ledger.data(), bound);
      const current = createHash("sha256").update(
          JSON.stringify(canonical(ledger.data()))).digest("hex");
      if (current !== digest) fail();
    }
    // Concurrent legitimate cleanup may already have deleted this same ledger.
    if (ledger.exists) tx.delete(ledgerRef);
    if (currentGuard.data().state !== "COMPLETE") {
      tx.update(guardRef, {state: "COMPLETE",
        retainUntil: Timestamp.fromMillis(Date.now() + RETENTION_MS)});
    }
  });
}

module.exports = {prepare, finish};
