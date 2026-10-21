"use strict";

const {Timestamp} = require("firebase-admin/firestore");
const {createAuthGenerationReader, AuthGenerationError} =
  require("./water_auth_generation");
const {UserRecordMetadata} = require("firebase-functions/v1/auth");
const {createAccountBirthRecorder, birthError} =
  require("./water_account_birth");

const PROJECT = "demo-life-os";
const MESSAGE = "Não foi possível registrar a origem da conta.";

/** Sanitized adapter failure. */
class AdapterError extends Error {
  /**
   * @param {string} code Safe code.
   */
  constructor(code) {
    super(MESSAGE);
    this.code = code;
  }
}

/**
 * @param {string} code Safe code.
 */
function fail(code) {
  throw new AdapterError(code);
}

/**
 * @param {*} error Failure from adapter or core.
 * @return {Object} Public-safe code/message, never SDK details.
 */
function authBirthError(error) {
  return error instanceof AdapterError ? {code: error.code, message: MESSAGE} :
    birthError(error);
}

/**
 * @param {*} value Value.
 * @return {boolean} Plain object.
 */
function object(value) {
  return value !== null && typeof value === "object" &&
    Object.getPrototypeOf(value) === Object.prototype;
}

/**
 * @param {*} value Value.
 * @param {Array} keys Allowed/required keys.
 * @return {boolean} Exact plain object shape.
 */
function exact(value, keys) {
  return object(value) && Object.keys(value).length === keys.length &&
    keys.every((key) => Object.hasOwn(value, key));
}

/**
 * @param {*} value UID from managed record, never context.auth.
 * @return {boolean} B2-A canonical UID.
 */
function canonicalUid(value) {
  return typeof value === "string" && value.length > 0 &&
    value.length <= 128 && Buffer.byteLength(value, "utf8") <= 128 &&
    value.trim() === value && !value.includes("/") &&
    ![".", ".."].includes(value) && !/^__.*__$/.test(value) &&
    // eslint-disable-next-line no-control-regex
    !/[\u0000-\u001f\u007f]/.test(value);
}

/**
 * Strict RFC3339, retaining only precision actually present in the event.
 * Rejects impossible calendar dates and unsupported leap seconds.
 * @param {*} value Managed timestamp string.
 * @return {Timestamp} Exact supplied timestamp.
 */
function rfc3339(value) {
  const match = typeof value === "string" && value.match(
      new RegExp("^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):" +
        "(\\d{2})(?:\\.(\\d{1,9}))?(Z|[+-]\\d{2}:\\d{2})$"),
  );
  if (!match) fail("WATER_BIRTH_INVALID_ORIGIN");
  const [year, month, day, hour, minute, second] =
    match.slice(1, 7).map(Number);
  const date = new Date(`${match[1]}-${match[2]}-${match[3]}T` +
    `${match[4]}:${match[5]}:${match[6]}.000Z`);
  if (!Number.isFinite(date.getTime()) || date.getUTCFullYear() !== year ||
    date.getUTCMonth() + 1 !== month || date.getUTCDate() !== day ||
    date.getUTCHours() !== hour || date.getUTCMinutes() !== minute ||
    date.getUTCSeconds() !== second) fail("WATER_BIRTH_INVALID_ORIGIN");
  const zone = match[8];
  let offset = 0;
  if (zone !== "Z") {
    const zh = Number(zone.slice(1, 3)); const zm = Number(zone.slice(4));
    if (zh > 23 || zm > 59 || zone === "-00:00") {
      fail("WATER_BIRTH_INVALID_ORIGIN");
    }
    offset = (zh * 60 + zm) * 60 * (zone[0] === "+" ? 1 : -1);
  }
  const seconds = date.getTime() / 1000 - offset;
  if (seconds < 0) fail("WATER_BIRTH_INVALID_ORIGIN");
  try {
    return new Timestamp(seconds, Number((match[7] || "").padEnd(9, "0")));
  } catch (_) {
    fail("WATER_BIRTH_INVALID_ORIGIN");
  }
}

/**
 * Functions metadata may retain ISO precision; Admin v14 UTC loses fractions.
 * Never round a mismatch into a match. A UTC string represents a coarse second,
 * not evidence of a unique Auth generation within that second.
 * @param {*} value SDK creationTime.
 * @return {Timestamp} Supplied creation time without fabricated precision.
 */
function creationTime(value) {
  if (typeof value !== "string") fail("WATER_BIRTH_INVALID_ORIGIN");
  if (/^\d{4}-/.test(value)) return rfc3339(value);
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) || date.toUTCString() !== value ||
    date.getTime() < 0) fail("WATER_BIRTH_INVALID_ORIGIN");
  return Timestamp.fromMillis(date.getTime());
}

/**
 * Default-project Auth only. Undefined/null tenant is the SDK's documented
 * absence, not a tenant fabricated from environment or client claims.
 * @param {Object} user SDK record.
 * @return {null} Supported tenant.
 */
function defaultTenant(user) {
  if (user.tenantId !== undefined && user.tenantId !== null) {
    fail("WATER_BIRTH_INVALID_ORIGIN");
  }
  return null;
}

/**
 * Birth candidates only: password/Google. These providers cannot prove the
 * creation method (Admin may create/link them too). No candidate is eligible.
 * @param {Object} user SDK event record.
 */
function providerPolicy(user) {
  if (!Array.isArray(user.providerData) || user.providerData.length !== 1 ||
    !user.providerData[0] ||
    !["password", "google.com"].includes(user.providerData[0].providerId)) {
    fail("WATER_BIRTH_UNSUPPORTED_PROVIDER");
  }
}

/**
 * Resource.type/labels are optional SDK fields, never UID or admission proof.
 * @param {*} resource SDK resource.
 * @param {string} projectId Bound server project.
 * @return {boolean} Expected Auth project and structurally valid metadata.
 */
function authResource(resource, projectId) {
  return object(resource) && Object.keys(resource).every((key) =>
    ["service", "name", "type", "labels"].includes(key),
  ) && resource.service === "firebaseauth.googleapis.com" &&
    resource.name === `projects/${projectId}` &&
    (resource.type === undefined || typeof resource.type === "string") &&
    (resource.labels === undefined || (object(resource.labels) &&
      Object.values(resource.labels).every((value) =>
        typeof value === "string")));
}

/**
 * Verify the normalized v1 handler contract; never the raw legacy wire form.
 * EventContext has project resource, not an Auth UID/tenant/generation.
 * @param {*} event Result supplied by trusted managed-event test code.
 * @param {Object} cohort Explicit server cohort.
 * @param {string} projectId Bound server project.
 * @return {Object} Existing B2-A contract; identity normalized by that core.
 */
function managedBirth(event, cohort, projectId = PROJECT) {
  if (!exact(event, ["user", "context"])) fail("WATER_BIRTH_INVALID_ORIGIN");
  const {user, context} = event;
  if (!object(user) || !(user.metadata instanceof UserRecordMetadata) ||
    !canonicalUid(user.uid) || !object(context) ||
    !Object.keys(context).every((key) =>
      ["eventId", "eventType", "resource", "timestamp", "params"].includes(key),
    ) || context.eventType !== "google.firebase.auth.user.create" ||
    typeof context.eventId !== "string" || !context.eventId.length ||
    context.eventId.length > 512 ||
    context.eventId.trim() !== context.eventId ||
    // eslint-disable-next-line no-control-regex
    /[\u0000-\u001f\u007f]/.test(context.eventId) ||
    !authResource(context.resource, projectId) ||
    (context.params !== undefined && !exact(context.params, []))) {
    fail("WATER_BIRTH_INVALID_ORIGIN");
  }
  const tenantId = defaultTenant(user);
  providerPolicy(user);
  return {source: {type: "FIREBASE_AUTH_CREATE", eventId: context.eventId,
    projectId, tenantId, uid: user.uid,
    authCreatedAt: creationTime(user.metadata.creationTime),
    eventAt: rfc3339(context.timestamp)},
  identity: {uid: user.uid, email: user.email === undefined ? null : user.email,
    displayName: user.displayName === undefined ? null : user.displayName,
    photoUrl: user.photoURL === undefined ? null : user.photoURL},
  cohort};
}

/**
 * No trigger, no IO, no arguments or env flags can activate production.
 * @return {Promise<void>} Closed refusal.
 */
async function recordManagedAuthBirth() {
  fail("WATER_BIRTH_COHORT_CLOSED");
}

/**
 * Synthetic seam ONLY. getManagedEvent is trusted test code delivering the
 * SDK-constructed (user, context) pair; it is not a JSON attestation service.
 * Auth is explicitly injected and bound to demo-life-os. No default app,
 * credentials, SDK initialization, runtime flag or production factory.
 * @param {Object} options Fake/emulator dependencies and closed cohort.
 * @return {Object} Frozen zero-argument recorder.
 */
function createManagedAuthBirthRecorder(options) {
  if (!object(options) || !Object.keys(options).every((key) =>
    ["db", "auth", "getManagedEvent", "cohort", "now", "projectId",
      "authGenerationReader"]
        .includes(key),
  ) || typeof options.getManagedEvent !== "function" ||
    !exact(options.cohort, ["version", "id", "policy", "state", "cutoverAt"]) ||
    options.cohort.version !== 1 || options.cohort.state !== "CLOSED" ||
    options.cohort.policy !== "NEW_ACCOUNT_V2_ONLY" ||
    !(options.cohort.cutoverAt instanceof Timestamp)) {
    fail("WATER_BIRTH_INVALID_CONFIGURATION");
  }
  const {auth, db, getManagedEvent} = options;
  const projectId = options.projectId || PROJECT;
  const cohort = Object.freeze({...options.cohort});
  const checkAuth = () => {
    if (!auth || !auth.app || !auth.app.options ||
      auth.app.options.projectId !== projectId ||
      (auth.tenantId !== undefined && auth.tenantId !== null) ||
      typeof auth.getUser !== "function") {
      fail("WATER_BIRTH_INVALID_CONFIGURATION");
    }
  };
  checkAuth();
  // Reader is a trusted server/test dependency, never event/client JSON.
  const generationReader = options.authGenerationReader ||
    createAuthGenerationReader({auth, projectId});
  if (!generationReader || typeof generationReader.read !== "function") {
    fail("WATER_BIRTH_INVALID_CONFIGURATION");
  }
  const recorder = createAccountBirthRecorder({db, projectId, now: options.now,
    getTrustedBirth: async () => {
      checkAuth();
      return managedBirth(await getManagedEvent(), cohort, projectId);
    },
    getCurrentAuthGeneration: async (uid) => {
      checkAuth();
      try {
        const current = await generationReader.read(uid);
        checkAuth();
        return current;
      } catch (error) {
        if (error instanceof AdapterError) throw error;
        if (error instanceof AuthGenerationError) fail(error.code);
        fail("WATER_BIRTH_AUTH_UNAVAILABLE");
      }
    }});
  return Object.freeze({record: async (...args) => {
    if (args.length) fail("WATER_BIRTH_INVALID_ORIGIN");
    try {
      return await recorder.record();
    } catch (error) {
      throw new AdapterError(authBirthError(error).code);
    }
  }});
}

module.exports = {recordManagedAuthBirth,
  createAuthBirthAdapterTestHarness, createManagedAuthBirthRecorder,
  authBirthError};

/**
 * @param {Object} options Synthetic demo dependencies.
 * @return {Object} Managed receipt recorder.
 */
function createAuthBirthAdapterTestHarness(options) {
  if (options && Object.hasOwn(options, "projectId")) {
    fail("WATER_BIRTH_INVALID_CONFIGURATION");
  }
  return createManagedAuthBirthRecorder(options);
}
