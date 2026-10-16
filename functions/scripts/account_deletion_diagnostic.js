"use strict";

const {validateGuard} = require("../circle_cleanup");
const {performance} = require("node:perf_hooks");

const DEFAULTS = Object.freeze({pageSize: 50, maxDocuments: 200,
  olderThanMs: 60 * 60 * 1000, maxPages: 20, maxDurationMs: 30000});
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
      !Number.isSafeInteger(value.maxPages) || value.maxPages < 1 ||
      value.maxPages > 100 || !Number.isSafeInteger(value.maxDurationMs) ||
      value.maxDurationMs < 1000 || value.maxDurationMs > 60000 ||
      !Number.isSafeInteger(value.olderThanMs) || value.olderThanMs < 60000 ||
      value.olderThanMs > 30 * 24 * 60 * 60 * 1000) refuse();
  return value;
}

class DiagnosticStop extends Error {
  constructor(reason) {
    super("DIAGNOSTIC_STOPPED");
    this.reason = reason;
  }
}

function createBudget(bound, control) {
  const clock = control.clock || (() => performance.now());
  const schedule = control.schedule || setTimeout;
  const cancel = control.cancel || clearTimeout;
  const signal = control.signal;
  const start = clock();
  if (!Number.isFinite(start)) refuse();
  const remaining = () => bound.maxDurationMs - (clock() - start);
  const check = () => {
    if (signal?.aborted) throw new DiagnosticStop("INTERRUPTED");
    const left = remaining();
    if (!Number.isFinite(left) || left <= 0) throw new DiagnosticStop("TIME_LIMIT");
  };
  const wait = async (read) => {
    check();
    let timer;
    let abort;
    try {
      return await new Promise((resolve, reject) => {
        timer = schedule(() => reject(new DiagnosticStop("TIME_LIMIT")), remaining());
        abort = () => reject(new DiagnosticStop("INTERRUPTED"));
        signal?.addEventListener("abort", abort, {once: true});
        // Both branches stay handled if an SDK result arrives after the budget.
        Promise.resolve().then(() => {check(); return read();}).then((value) => {
          check(); return value;
        }).then(resolve, reject);
      });
    } finally {
      cancel(timer);
      if (abort) signal?.removeEventListener("abort", abort);
    }
  };
  return {check, wait};
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
  nowMillis = Date.now(), limits = {}, control = {}}) {
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
    firestoreReadFailed: 0, invalidSnapshot: 0, residueReadFailed: 0,
    timeLimitExceeded: 0, interrupted: 0};
  const operations = {guardPageRequests: 0, guardDocumentResults: 0,
    guardRevalidationRequests: 0, authLookupRequests: 0,
    residueBatchRequests: 0, residueDocumentRequests: 0};
  const residues = {detected: 0, noneObservedInLimitedScope: 0,
    inconclusive: 0, candidateChanged: 0};
  const residueEvidence = {userRoot: 0, billingAccount: 0,
    accountDeletionRuntime: 0, birthLedger: 0};
  const maximumPageRequests = Math.min(bound.maxPages,
      Math.ceil(bound.maxDocuments / bound.pageSize));
  const maximumExamined = Math.min(bound.maxDocuments,
      bound.pageSize * bound.maxPages);
  const report = {schemaVersion: 2, mode: "EMULATOR_ONLY",
    scope: "BOUNDED_GUARD_INVENTORY", status: "OBSERVATIONS_ONLY",
    snapshotConsistency: "NOT_GLOBAL_SNAPSHOT",
    counts, residues, residueEvidence, inconclusiveReasons: reasons,
    operations, truncated: false, coverageInconclusive: false,
    coverage: "EXHAUSTED", limits: {...bound,
      maximumPageRequests, maximumExamined,
      maximumGuardDocumentReads: 3 * maximumExamined,
      maximumResidueDocumentReads: 4 * maximumExamined,
      maximumAuthLookups: 2 * maximumExamined,
      estimatedMaximumFirestoreReads: 7 * maximumExamined + maximumPageRequests}};
  const budget = createBudget(bound, control);
  const read = (kind, action) => {
    budget.check();
    operations[kind]++;
    return budget.wait(action);
  };
  const partial = (coverage) => {
    report.truncated = true;
    report.coverageInconclusive = true;
    report.coverage = coverage;
    return report;
  };
  const inconclusive = (reason) => {
    counts.inconclusive++;
    reasons[reason]++;
  };
  const lookupAuth = async (id) => {
    try {
      const user = await read("authLookupRequests", () => readers.getAuthUser(id));
      if (!user || user.uid !== id) throw new Error();
      return true;
    } catch (error) {
      if (error instanceof DiagnosticStop) throw error;
      if (error?.code === "auth/user-not-found") return false;
      throw error;
    }
  };
  let cursor;
  let activeCandidate = false;
  let activeResidue = false;
  try {
    while (counts.examined < bound.maxDocuments) {
      budget.check();
      if (operations.guardPageRequests >= bound.maxPages) return partial("PAGE_LIMIT");
      if (cursor !== undefined && control.beforeNextPage) {
        let proceed;
        try { proceed = await budget.wait(control.beforeNextPage); } catch (error) {
          if (error instanceof DiagnosticStop) throw error;
          throw new DiagnosticStop("INTERRUPTED");
        }
        if (proceed !== true) throw new DiagnosticStop("INTERRUPTED");
      }
      const limit = Math.min(bound.pageSize, bound.maxDocuments - counts.examined);
      let page;
      try {
        page = await read("guardPageRequests", () =>
          readers.getGuardPage({afterId: cursor, limit}));
      } catch (error) {
        if (error instanceof DiagnosticStop) throw error;
        reasons.firestoreReadFailed++;
        return partial("QUERY_FAILED");
      }
      // Fail closed on a broken adapter; never process an unbounded response.
      if (!Array.isArray(page) || page.length > limit || page.some((doc, i) =>
        !doc || typeof doc.id !== "string" || !doc.id ||
        (i ? compareIds(page[i - 1].id, doc.id) >= 0 :
          cursor !== undefined && compareIds(cursor, doc.id) >= 0))) {
        reasons.invalidSnapshot++;
        return partial("INVALID_PAGE");
      }
      operations.guardDocumentResults += page.length;
      for (const snapshot of page) {
        budget.check();
        activeCandidate = false;
        activeResidue = false;
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
        activeCandidate = true;
        let authExists;
        try {
          authExists = await lookupAuth(snapshot.id);
        } catch (error) {
          if (error instanceof DiagnosticStop) throw error;
          inconclusive("authLookupFailed");
          activeCandidate = false;
          continue;
        }
        let current;
        try {
          current = await read("guardRevalidationRequests", () =>
            readers.getGuard(snapshot.id));
        } catch (error) {
          if (error instanceof DiagnosticStop) throw error;
          inconclusive("firestoreReadFailed");
          activeCandidate = false;
          continue;
        }
        if (!sameSnapshot(snapshot, current)) {
          inconclusive("guardChanged");
          activeCandidate = false;
          continue;
        }
        counts[authExists ? "oldAuthPresent" :
          "oldAuthAbsentPotentiallyIncomplete"]++;
        activeCandidate = false;
        if (authExists) continue;
        activeResidue = true;
        let evidence;
        try {
          evidence = await read("residueBatchRequests", () => {
            operations.residueDocumentRequests += 4;
            return readers.getResidueExistence(snapshot.id);
          });
          const keys = Object.keys(residueEvidence);
          if (!evidence || Object.keys(evidence).length !== keys.length ||
              keys.some((key) => typeof evidence[key] !== "boolean")) throw new Error();
        } catch (error) {
          if (error instanceof DiagnosticStop) throw error;
          reasons.residueReadFailed++;
          residues.inconclusive++;
          activeResidue = false;
          continue;
        }
        try {
          if (await lookupAuth(snapshot.id)) {
            residues.candidateChanged++;
            activeResidue = false;
            continue;
          }
        } catch (error) {
          if (error instanceof DiagnosticStop) throw error;
          reasons.authLookupFailed++;
          residues.inconclusive++;
          activeResidue = false;
          continue;
        }
        try {
          current = await read("guardRevalidationRequests", () =>
            readers.getGuard(snapshot.id));
        } catch (error) {
          if (error instanceof DiagnosticStop) throw error;
          reasons.firestoreReadFailed++;
          residues.inconclusive++;
          activeResidue = false;
          continue;
        }
        if (!sameSnapshot(snapshot, current)) {
          residues.candidateChanged++;
        } else {
          let detected = false;
          for (const key of Object.keys(residueEvidence)) {
            if (evidence[key]) {residueEvidence[key]++; detected = true;}
          }
          residues[detected ? "detected" : "noneObservedInLimitedScope"]++;
        }
        activeResidue = false;
      }
      budget.check();
      if (page.length < limit) return report;
      cursor = page.at(-1).id;
    }
    // No extra lookahead read: an exact full final page is conservatively partial.
    return partial("LIMIT_REACHED");
  } catch (error) {
    if (!(error instanceof DiagnosticStop)) throw error;
    if (activeCandidate) counts.inconclusive++;
    if (activeResidue) residues.inconclusive++;
    reasons[error.reason === "TIME_LIMIT" ? "timeLimitExceeded" : "interrupted"]++;
    return partial(error.reason);
  }
}

module.exports = {diagnose, validateIsolation, validateLimits, DEFAULTS,
  isCanonicalUid: validId};
