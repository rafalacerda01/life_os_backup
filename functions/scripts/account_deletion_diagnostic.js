"use strict";

const {validateGuard} = require("../circle_cleanup");

const DEFAULTS = Object.freeze({pageSize: 50, maxDocuments: 200,
  olderThanMs: 60 * 60 * 1000});
const MAX_DOCUMENTS = 1000;
const SECRET_ENV = ["GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_KEYFILE_JSON",
  "FIREBASE_TOKEN", "FIREBASE_SERVICE_ACCOUNT", "GOOGLE_ACCESS_TOKEN"];
const DEBUG_ENV = ["DEBUG", "NODE_DEBUG", "GRPC_TRACE", "GRPC_VERBOSITY",
  "GOOGLE_SDK_NODE_LOGGING", "FIRESTORE_LOGGING"];

function refuse() {
  throw new Error("DIAGNOSTIC_CONFIGURATION_REFUSED");
}

function loopback(value) {
  const match = typeof value === "string" &&
    /^127\.0\.0\.1:([1-9][0-9]{0,4})$/.exec(value);
  return !!match && Number(match[1]) <= 65535;
}

// No ADC, CLI login, default project, DNS hostname or production fallback.
function validateIsolation(projectId, env = process.env) {
  if (typeof projectId !== "string" ||
      !/^demo-[a-z0-9](?:[a-z0-9-]{0,23}[a-z0-9])?$/.test(projectId) ||
      !loopback(env.FIRESTORE_EMULATOR_HOST) ||
      !loopback(env.FIREBASE_AUTH_EMULATOR_HOST) ||
      env.FIRESTORE_EMULATOR_HOST === env.FIREBASE_AUTH_EMULATOR_HOST ||
      [...SECRET_ENV, ...DEBUG_ENV].some((key) => !!env[key])) refuse();
  return Object.freeze({projectId,
    firestoreHost: env.FIRESTORE_EMULATOR_HOST,
    authHost: env.FIREBASE_AUTH_EMULATOR_HOST});
}

function validateLimits(input) {
  const value = {...DEFAULTS, ...input};
  if (Object.keys(value).some((key) => !Object.hasOwn(DEFAULTS, key)) ||
      !Number.isSafeInteger(value.pageSize) || value.pageSize < 1 ||
      value.pageSize > 100 || !Number.isSafeInteger(value.maxDocuments) ||
      value.maxDocuments < 1 || value.maxDocuments > MAX_DOCUMENTS ||
      !Number.isSafeInteger(value.olderThanMs) || value.olderThanMs < 60000 ||
      value.olderThanMs > 30 * 24 * 60 * 60 * 1000) refuse();
  return value;
}

function validId(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 &&
    Buffer.byteLength(value, "utf8") <= 128 && value.trim() === value &&
    !value.includes("/") && ![".", ".."].includes(value) &&
    // eslint-disable-next-line no-control-regex
    !/^__.*__$/.test(value) && !/[\u0000-\u001f\u007f]/.test(value);
}

function compareIds(a, b) {
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

// updateTime detects even a change away from and back to the same guard fields.
function sameSnapshot(before, after) {
  if (!after || before.id !== after.id || typeof before.version !== "string" ||
      !before.version || before.version !== after.version) return false;
  const a = before.data;
  const b = after.data;
  try {
    validateGuard(b);
    return a.version === b.version && a.state === b.state &&
      a.deletionId === b.deletionId &&
      a.startedAt.toMillis() === b.startedAt.toMillis() &&
      a.retainUntil === b.retainUntil;
  } catch (_) { return false; }
}

async function diagnose({projectId, env = process.env, readers,
  nowMillis = Date.now(), limits = {}}) {
  validateIsolation(projectId, env);
  const bound = validateLimits(limits);
  if (!Number.isSafeInteger(nowMillis) || nowMillis < 0 ||
      !readers || typeof readers.getGuardPage !== "function" ||
      typeof readers.getGuard !== "function" ||
      typeof readers.getAuthUser !== "function") refuse();
  const counts = {examined: 0, recentInProgress: 0, oldAuthPresent: 0,
    oldAuthAbsentPotentiallyIncomplete: 0, invalidGuard: 0,
    otherGuardStateObserved: 0, inconclusive: 0};
  const reasons = {guardChanged: 0, authLookupFailed: 0,
    firestoreReadFailed: 0, invalidSnapshot: 0};
  const operations = {guardPageRequests: 0, guardDocumentResults: 0,
    guardRevalidationRequests: 0, authLookupRequests: 0};
  const report = {schemaVersion: 1, mode: "EMULATOR_ONLY",
    scope: "BOUNDED_GUARD_INVENTORY", status: "OBSERVATIONS_ONLY",
    counts, inconclusiveReasons: reasons, operations, truncated: false,
    coverage: "EXHAUSTED", limits: {...bound,
      maximumPageRequests: Math.ceil(bound.maxDocuments / bound.pageSize),
      maximumGuardDocumentReads: 2 * bound.maxDocuments,
      maximumAuthLookups: bound.maxDocuments}};
  const inconclusive = (reason) => {
    counts.inconclusive++;
    reasons[reason]++;
  };
  let cursor;
  while (counts.examined < bound.maxDocuments) {
    const limit = Math.min(bound.pageSize, bound.maxDocuments - counts.examined);
    let page;
    operations.guardPageRequests++;
    try {
      page = await readers.getGuardPage({afterId: cursor, limit});
    } catch (_) {
      reasons.firestoreReadFailed++;
      report.truncated = true;
      report.coverage = "QUERY_FAILED";
      return report;
    }
    // Fail closed on a broken adapter; never process an unbounded response.
    if (!Array.isArray(page) || page.length > limit || page.some((doc, i) =>
      !doc || typeof doc.id !== "string" || !doc.id ||
      (i ? compareIds(page[i - 1].id, doc.id) >= 0 :
        cursor !== undefined && compareIds(cursor, doc.id) >= 0))) {
      reasons.invalidSnapshot++;
      report.truncated = true;
      report.coverage = "INVALID_PAGE";
      return report;
    }
    operations.guardDocumentResults += page.length;
    for (const snapshot of page) {
      counts.examined++;
      let guard;
      try {
        if (!validId(snapshot.id)) throw new Error();
        guard = validateGuard(snapshot.data);
        if (guard.startedAt.toMillis() < 0 ||
            guard.startedAt.toMillis() > nowMillis) throw new Error();
      } catch (_) {
        counts.invalidGuard++;
        continue;
      }
      if (guard.state !== "IN_PROGRESS") {
        // Observing the field never invokes or substitutes the terminal proof.
        counts.otherGuardStateObserved++;
        continue;
      }
      if (nowMillis - guard.startedAt.toMillis() < bound.olderThanMs) {
        counts.recentInProgress++;
        continue;
      }
      if (typeof snapshot.version !== "string" || !snapshot.version) {
        inconclusive("invalidSnapshot");
        continue;
      }
      let authExists;
      operations.authLookupRequests++;
      try {
        const user = await readers.getAuthUser(snapshot.id);
        if (!user || user.uid !== snapshot.id) throw new Error();
        authExists = true;
      } catch (error) {
        if (!error || error.code !== "auth/user-not-found") {
          inconclusive("authLookupFailed");
          continue;
        }
        authExists = false;
      }
      let current;
      operations.guardRevalidationRequests++;
      try {
        current = await readers.getGuard(snapshot.id);
      } catch (_) {
        inconclusive("firestoreReadFailed");
        continue;
      }
      if (!sameSnapshot(snapshot, current)) {
        inconclusive("guardChanged");
        continue;
      }
      counts[authExists ? "oldAuthPresent" :
        "oldAuthAbsentPotentiallyIncomplete"]++;
    }
    if (page.length < limit) return report;
    cursor = page.at(-1).id;
  }
  // No extra lookahead read: an exact full final page is conservatively partial.
  report.truncated = true;
  report.coverage = "LIMIT_REACHED";
  return report;
}

module.exports = {diagnose, validateIsolation, validateLimits, DEFAULTS};
