"use strict";

const {randomUUID} = require("node:crypto");
const {FieldValue, Timestamp} = require("firebase-admin/firestore");

const TEST_PROJECT = "demo-life-os";
const STATUS = "RECORDED_COHORT_CLOSED";
const POLICY = "NEW_ACCOUNT_V2_ONLY";
const UUID = new RegExp("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}" +
    "-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
const RECORD_KEYS = ["version", "uid", "projectId", "tenantId",
  "authCreatedAt", "sourceType", "sourceEventId", "eventAt", "cohort",
  "decisionId",
  "originalIdentity", "recordedAt", "status"];

/**
 * Fixed domain error, with no identity or storage details.
 */
class BirthError extends Error {
  /**
 * @param {string} code Sanitized domain code.
 */
  constructor(code) {
    super("Não foi possível registrar a origem da conta.");
    this.code = code;
  }
}

/**
 * @param {string} code Domain code.
 */
function fail(code) {
  throw new BirthError(code);
}

/**
 * @param {*} error Failure.
 * @return {Object} Public-safe error.
 */
function birthError(error) {
  return {code: error instanceof BirthError ? error.code :
    "WATER_BIRTH_STORAGE_UNAVAILABLE",
  message: "Não foi possível registrar a origem da conta."};
}

/**
 * @param {*} v Value.
 * @return {boolean} Plain data object.
 */
function object(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v) &&
    [Object.prototype, null].includes(Object.getPrototypeOf(v));
}

/**
 * @param {*} v Value.
 * @param {Array} keys Keys.
 * @return {boolean} Match.
 */
function exact(v, keys) {
  return object(v) && Object.keys(v).length === keys.length &&
    keys.every((key) => Object.hasOwn(v, key));
}

/**
 * @param {*} v Value.
 * @return {boolean} F-A canonical UID contract.
 */
function uid(v) {
  return typeof v === "string" && v.length > 0 && v.length <= 128 &&
    Buffer.byteLength(v, "utf8") <= 128 && v.trim() === v &&
    !v.includes("/") && ![".", ".."].includes(v) &&
  // eslint-disable-next-line no-control-regex
    !/^__.*__$/.test(v) && !/[\u0000-\u001f\u007f]/.test(v);
}

/**
 * @param {*} v Value.
 * @return {boolean} Auth-era timestamp.
 */
function time(v) {
  return v instanceof Timestamp && v.seconds >= 0 &&
    Number.isFinite(v.toMillis());
}

/**
 * @param {Timestamp} a First.
 * @param {Timestamp} b Second.
 * @return {boolean} Exact ordering, including submillisecond precision.
 */
function after(a, b) {
  return a.seconds > b.seconds ||
    (a.seconds === b.seconds && a.nanoseconds > b.nanoseconds);
}

/**
 * @param {*} v Value.
 * @param {number} max Bound.
 * @return {boolean} Canonical bounded text.
 */
function text(v, max) {
  return typeof v === "string" && v.length <= max && v.trim() === v &&
  // eslint-disable-next-line no-control-regex
    !/[\u0000-\u001f\u007f]/.test(v);
}

/**
 * @param {*} v Value.
 * @param {number} max Bound.
 * @param {*} fallback Missing/empty value.
 * @return {*} Normalized text.
 */
function normalize(v, max, fallback) {
  if (v === null) return fallback;
  if (typeof v !== "string" || v.length > max * 2) {
    fail("WATER_BIRTH_INVALID_ORIGIN");
  }
  // eslint-disable-next-line no-control-regex
  const clean = v.replace(/[\u0000-\u001f\u007f]/g, "").trim();
  if (clean.length > max) fail("WATER_BIRTH_INVALID_ORIGIN");
  return clean || fallback;
}

/**
 * @param {*} v Trusted code result.
 * @return {Object} Immutable context copy.
 */
function context(v) {
  if (!exact(v, ["source", "identity", "cohort"])) {
    fail("WATER_BIRTH_INVALID_ORIGIN");
  }
  const s = v.source;
  const i = v.identity;
  const c = v.cohort;
  if (!exact(s, ["type", "eventId", "projectId", "tenantId", "uid",
    "authCreatedAt", "eventAt"]) || s.type !== "FIREBASE_AUTH_CREATE" ||
    !text(s.eventId, 512) || s.eventId.length === 0 ||
    s.projectId !== TEST_PROJECT || s.tenantId !== null || !uid(s.uid) ||
    !time(s.authCreatedAt) || !time(s.eventAt) ||
    after(s.authCreatedAt, s.eventAt) ||
    !exact(i, ["uid", "email", "displayName", "photoUrl"]) ||
    i.uid !== s.uid) fail("WATER_BIRTH_INVALID_ORIGIN");
  if (!exact(c, ["version", "id", "policy", "state", "cutoverAt"]) ||
    c.version !== 1 || !uid(c.id) || c.policy !== POLICY ||
    c.state !== "CLOSED" || !time(c.cutoverAt)) {
    fail("WATER_BIRTH_COHORT_CLOSED");
  }
  if (after(c.cutoverAt, s.authCreatedAt)) {
    fail("WATER_BIRTH_BEFORE_CUTOVER");
  }
  return {
    uid: s.uid, projectId: s.projectId, tenantId: s.tenantId,
    authCreatedAt: s.authCreatedAt, sourceType: s.type,
    sourceEventId: s.eventId,
    eventAt: s.eventAt,
    cohort: {version: 1, id: c.id, policy: POLICY, state: "CLOSED",
      cutoverAt: c.cutoverAt},
    originalIdentity: {uid: i.uid,
      email: normalize(i.email, 320, ""),
      displayName: normalize(i.displayName, 200, "Novo Usuário"),
      photoUrl: normalize(i.photoUrl, 2048, null)},
  };
}

/**
 * @param {Object} a First.
 * @param {Object} b Second.
 * @return {boolean} Stable event, generation, policy and birth profile.
 */
function same(a, b) {
  return ["uid", "projectId", "tenantId", "sourceType", "sourceEventId"].every(
      (key) => a[key] === b[key],
  ) && a.authCreatedAt.isEqual(b.authCreatedAt) &&
    a.eventAt.isEqual(b.eventAt) &&
    ["version", "id", "policy", "state"].every(
        (key) => a.cohort[key] === b.cohort[key],
    ) && a.cohort.cutoverAt.isEqual(b.cohort.cutoverAt) &&
    JSON.stringify(a.originalIdentity) === JSON.stringify(b.originalIdentity);
}

/**
 * @param {*} v Stored record.
 * @param {Object} bound Trusted context.
 * @param {Timestamp} clock Current clock.
 * @return {boolean} Valid replay.
 */
function validRecord(v, bound, clock) {
  return exact(v, RECORD_KEYS) && v.version === 1 && v.status === STATUS &&
    typeof v.decisionId === "string" && UUID.test(v.decisionId) &&
    time(v.recordedAt) && !after(v.recordedAt, clock) &&
    !after(bound.eventAt, v.recordedAt) &&
    exact(v.cohort, ["version", "id", "policy", "state", "cutoverAt"]) &&
    time(v.cohort.cutoverAt) && time(v.authCreatedAt) && time(v.eventAt) &&
    exact(v.originalIdentity, ["uid", "email", "displayName", "photoUrl"]) &&
    same(v, bound);
}

/**
 * Closed production entry. No event, environment or argument can open it.
 * @return {Promise<void>} Always fails before any IO.
 */
async function recordAccountBirth() {
  fail("WATER_BIRTH_COHORT_CLOSED");
}

/**
 * Test-code seam only: synthetic project, always non-eligible records.
 * Future managed Auth adapter must attest the source and live Auth
 * generation. This function is neither an Auth trigger nor a verifier of
 * arbitrary JSON.
 * @param {Object} options Explicit fake/emulator dependencies.
 * @return {Object} Zero-argument recorder; never an admission producer.
 */
function createAccountBirthTestHarness(options) {
  if (!object(options) || !Object.keys(options).every((key) =>
    ["db", "getTrustedBirth", "getCurrentAuthGeneration", "now"].includes(key),
  ) || !options.db || options.db.projectId !== TEST_PROJECT ||
    typeof options.db.collection !== "function" ||
    typeof options.db.runTransaction !== "function" ||
    typeof options.getTrustedBirth !== "function" ||
    typeof options.getCurrentAuthGeneration !== "function" ||
    (options.now !== undefined && typeof options.now !== "function")) {
    fail("WATER_BIRTH_INVALID_CONFIGURATION");
  }
  const {db, getTrustedBirth, getCurrentAuthGeneration} = options;
  const now = options.now || (() => Timestamp.now());
  return Object.freeze({record: async (...args) => {
    if (db.projectId !== TEST_PROJECT) {
      fail("WATER_BIRTH_INVALID_CONFIGURATION");
    }
    if (args.length) fail("WATER_BIRTH_INVALID_ORIGIN");
    const bound = context(await getTrustedBirth());
    const root = db.collection("users").doc(bound.uid);
    const record = db.collection("account_birth_decisions").doc(bound.uid);
    const guard = db.collection("account_deletion_guards").doc(bound.uid);
    let candidateId;
    return db.runTransaction(async (tx) => {
      if (db.projectId !== TEST_PROJECT) {
        fail("WATER_BIRTH_INVALID_CONFIGURATION");
      }
      if (!same(bound, context(await getTrustedBirth()))) {
        fail("WATER_BIRTH_CONFLICT");
      }
      const clock = now();
      if (!time(clock) || after(bound.eventAt, clock)) {
        fail("WATER_BIRTH_INVALID_ORIGIN");
      }
      // null means a trusted Admin user-not-found result.
      // Network failures must throw.
      const current = await getCurrentAuthGeneration(bound.uid);
      if (current === null) fail("WATER_BIRTH_AUTH_NOT_FOUND");
      if (!exact(current, ["uid", "projectId", "tenantId",
        "authCreatedAt"]) ||
        current.uid !== bound.uid || current.projectId !== bound.projectId ||
        current.tenantId !== bound.tenantId || !time(current.authCreatedAt) ||
        !current.authCreatedAt.isEqual(bound.authCreatedAt)) {
        fail("WATER_BIRTH_GENERATION_CONFLICT");
      }
      const existing = await tx.get(record);
      const guardDoc = await tx.get(guard);
      const rootDoc = await tx.get(root);
      const deletion = await tx.get(
          root.collection("runtime").doc("account_deletion"),
      );
      const eligibility = await tx.get(
          root.collection("water_protocol").doc("eligibility"),
      );
      const proof = await tx.get(
          root.collection("runtime").doc("water_admission"),
      );
      if (guardDoc.exists || deletion.exists) {
        fail("WATER_ACCOUNT_DELETING");
      }
      if (rootDoc.exists || eligibility.exists || proof.exists) {
        fail("WATER_BIRTH_CONFLICT");
      }
      if (existing.exists) {
        if (!validRecord(existing.data(), bound, clock)) {
          fail("WATER_BIRTH_CONFLICT");
        }
        return {uid: bound.uid, decisionId: existing.data().decisionId,
          alreadyRecorded: true, eligible: false};
      }
      if (!candidateId) candidateId = randomUUID();
      tx.create(record, {...bound, version: 1, decisionId: candidateId,
        recordedAt: FieldValue.serverTimestamp(), status: STATUS});
      return {uid: bound.uid, decisionId: candidateId,
        alreadyRecorded: false, eligible: false};
    });
  }});
}

module.exports = {
  recordAccountBirth, createAccountBirthTestHarness, birthError,
};
