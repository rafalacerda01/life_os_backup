"use strict";

// Isolated contract and pure reader: no SDK, credentials or production adapter.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const GUARD_KEYS = ["version", "state", "deletionId", "startedAt", "retainUntil"];
const ORIGINS = Object.freeze({reservePreAuth: "PRE_AUTH",
  recordAuthEvent: "AUTH_EVENT", recordLegacyReview: "LEGACY_REVIEW"});
const CODES = new Set(["INPUT_INVALID", "OPERATOR_UNAUTHORIZED",
  "PROVENANCE_UNPROVEN", "IDENTITY_AMBIGUOUS", "AUTH_PRESENT_RECOVERY_BLOCKED",
  "AUTH_ABSENT_CANNOT_PRE_RESERVE", "AUTH_CHANGED_REQUIRES_REVIEW",
  "GUARD_INVALID", "GUARD_COMPLETE", "OPERATION_CONFLICT", "RECORD_INVALID",
  "RESERVATION_CONFLICT", "ORIGIN_CONFLICT", "V1_REVIEW_REQUIRED", "UID_RESERVED"]);

class Refusal extends Error {
  constructor(code) {
    super("Synthetic identity V2 contract refused.");
    this.code = code;
    this.destructiveAuthority = false;
  }
}
function refuse(code) { throw new Refusal(code); }
function exact(value, keys) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Reflect.ownKeys(value).length === keys.length &&
    keys.every((key) => Object.hasOwn(value, key));
}
function millis(value) { return Number.isSafeInteger(value) && value > 0; }
function safeUid(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 &&
    value.trim() === value && !/[\/\u0000-\u001f\u007f]/.test(value) &&
    value !== "." && value !== ".." && !/^__.*__$/.test(value);
}
function outcome(status) {
  return Object.freeze({status, destructiveAuthority: false});
}
function guardValue(snapshot, deletionId, active) {
  const g = snapshot && snapshot.exists && snapshot.data;
  if (!snapshot || snapshot.exists !== true || !exact(g, GUARD_KEYS) ||
      g.version !== 1 || typeof g.deletionId !== "string" || !UUID.test(g.deletionId) ||
      !millis(g.startedAt) ||
      !((g.state === "IN_PROGRESS" && g.retainUntil === null) ||
        (g.state === "COMPLETE" && millis(g.retainUntil) &&
          g.retainUntil > g.startedAt))) refuse("GUARD_INVALID");
  if (g.deletionId !== deletionId) refuse("OPERATION_CONFLICT");
  if (active && g.state !== "IN_PROGRESS") refuse("GUARD_COMPLETE");
  return g;
}
function recordStructure(snapshot) {
  if (!snapshot || typeof snapshot.exists !== "boolean") return "MALFORMED";
  if (!snapshot.exists) return "ABSENT";
  const r = snapshot.data;
  if (!r || typeof r !== "object" || !Object.hasOwn(r, "version")) return "MALFORMED";
  if (r.version !== 1 && r.version !== 2) {
    return Number.isSafeInteger(r.version) && r.version > 0 ? "UNKNOWN_VERSION" : "MALFORMED";
  }
  const v1 = r && r.version === 1;
  if (!exact(r, ["version", "state", "deletionId",
    v1 ? "authCreatedAtMs" : "origin"]) || r.state !== "RESERVED" ||
      typeof r.deletionId !== "string" || !UUID.test(r.deletionId) || (v1 ?
        !millis(r.authCreatedAtMs) : !Object.values(ORIGINS).includes(r.origin))) {
    return "MALFORMED";
  }
  return v1 ? "V1_STRUCTURALLY_VALID" : `V2_${r.origin}`;
}
function recordValue(snapshot, deletionId) {
  const structure = recordStructure(snapshot);
  if (structure === "ABSENT") return null;
  if (structure === "MALFORMED" || structure === "UNKNOWN_VERSION" ||
      (structure === "V1_STRUCTURALLY_VALID" && !millis(snapshot.createTimeMs))) {
    refuse("RECORD_INVALID");
  }
  const r = snapshot.data;
  if (deletionId !== undefined && r.deletionId !== deletionId) {
    refuse("RESERVATION_CONFLICT");
  }
  return r;
}
function authState(value) {
  // Presence is an observation, never an Auth generation identifier.
  if (!exact(value, ["state"]) || !["PRESENT", "ABSENT"].includes(value.state)) {
    refuse("IDENTITY_AMBIGUOUS");
  }
  return value.state;
}

// Read-only normalized snapshots. Never call SDK methods or normalize by rounding.
function classifierData(value) {
  if (value === null || typeof value !== "object") return value;
  if (![Object.prototype, null].includes(Object.getPrototypeOf(value))) return null;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const keys = Reflect.ownKeys(descriptors);
  if (keys.some((key) => typeof key !== "string")) return null;
  if (keys.some((key) => !Object.hasOwn(descriptors[key], "value"))) {
    throw new Error("UNREADABLE_CLASSIFICATION_DATA");
  }
  return Object.fromEntries(keys.map((key) => [key, descriptors[key].value]));
}
function loadedFrame(value) {
  const frame = classifierData(value);
  if (frame && typeof frame === "object" && frame.exists === true) {
    frame.data = classifierData(frame.data);
    if (frame.data && typeof frame.data === "object") {
      for (const key of ["startedAt", "retainUntil"]) {
        if (Object.hasOwn(frame.data, key)) {
          // Explicit null is distinct from unsupported SDK time metadata.
          const raw = frame.data[key];
          frame.data[key] = raw === null ? null : classifierData(raw) ?? undefined;
        }
      }
    }
    if (Object.hasOwn(frame, "createTime")) frame.createTime = classifierData(frame.createTime);
  }
  return frame;
}
function timePair(value) {
  return exact(value, ["seconds", "nanoseconds"]) &&
    Number.isSafeInteger(value.seconds) && value.seconds >= -62135596800 &&
    value.seconds <= 253402300799 && Number.isInteger(value.nanoseconds) &&
    value.nanoseconds >= 0 && value.nanoseconds < 1000000000;
}
function compareTime(a, b) {
  return a.seconds === b.seconds ? Math.sign(a.nanoseconds - b.nanoseconds) :
    Math.sign(a.seconds - b.seconds);
}
function snapshotFrame(value) {
  if (exact(value, ["readError"]) && value.readError === true) return "UNAVAILABLE";
  if (exact(value, ["exists"]) && value.exists === false) return "ABSENT";
  if ((exact(value, ["exists", "data"]) ||
      exact(value, ["exists", "data", "createTime"])) && value.exists === true) {
    return "PRESENT";
  }
  return "MALFORMED";
}
function classification(fields) {
  return Object.freeze({...fields, provenance: "UNPROVEN",
    terminalProof: "NOT_PERFORMED", requiredEvidence: Object.freeze([
      "TRUSTED_PROVENANCE", "IDENTITY_CONTINUITY", "TERMINAL_PROOF",
      ...(fields.v1Context === "INSUFFICIENT" ? ["V1_CONTEXT"] : []),
      ...(fields.guardContext === "INSUFFICIENT" ? ["GUARD_TIME_CONTEXT"] : []),
      ...(fields.guard === "COMPLETE_RETENTION_UNKNOWN" ? ["RETENTION_TIME_CONTEXT"] : []),
      ...(fields.operation !== "MATCH" ? ["OPERATION_BINDING"] : []),
    ]), destructiveAuthority: false, admissionAuthority: false});
}

/** Classifies loaded data only. A declared origin is never an attestation. */
function classifyRetiredIdentitySnapshots(input) {
  const fields = {status: "INPUT_INVALID", reservation: "UNDETERMINED",
    guard: "UNDETERMINED", guardContext: "INSUFFICIENT", operation: "UNDETERMINED",
    v1Context: "NOT_APPLICABLE", auth: "AMBIGUOUS"};
  try {
    input = classifierData(input);
    if (!exact(input, ["reservation", "guard", "auth", "expectedDeletionId",
      "expectedOrigin", "now"]) ||
        !(input.expectedDeletionId === null ||
          (typeof input.expectedDeletionId === "string" && UUID.test(input.expectedDeletionId))) ||
        !(input.expectedOrigin === null || Object.values(ORIGINS).includes(input.expectedOrigin))) {
      return classification(fields);
    }
    input = {...input, reservation: loadedFrame(input.reservation),
      guard: loadedFrame(input.guard), auth: classifierData(input.auth),
      now: classifierData(input.now)};
    const rf = snapshotFrame(input.reservation);
    const gf = snapshotFrame(input.guard);
    fields.auth = exact(input.auth, ["state"]) &&
      ["PRESENT", "ABSENT", "AMBIGUOUS", "UNAVAILABLE"].includes(input.auth.state) ?
      input.auth.state : "AMBIGUOUS";
    fields.reservation = rf === "UNAVAILABLE" ? "UNAVAILABLE" :
      rf === "MALFORMED" ? "MALFORMED" : recordStructure(input.reservation);
    fields.guard = gf === "PRESENT" ? "MALFORMED" : gf;
    fields.guardContext = gf === "ABSENT" ? "NOT_APPLICABLE" : "INSUFFICIENT";
    const r = ["V1_STRUCTURALLY_VALID", "V2_PRE_AUTH", "V2_AUTH_EVENT",
      "V2_LEGACY_REVIEW"].includes(fields.reservation) ? input.reservation.data : null;
    const g = gf === "PRESENT" ? input.guard.data : null;
    const validGuard = exact(g, GUARD_KEYS) && g.version === 1 &&
      typeof g.deletionId === "string" && UUID.test(g.deletionId) &&
      ["IN_PROGRESS", "COMPLETE"].includes(g.state) &&
      (g.state === "IN_PROGRESS" ? g.retainUntil === null : g.retainUntil !== null);
    if (validGuard) {
      fields.guard = g.state;
      if (timePair(g.startedAt) && (g.state === "IN_PROGRESS" || timePair(g.retainUntil))) {
        fields.guardContext = compareTime(g.startedAt, {seconds: 0, nanoseconds: 0}) <= 0 ||
          (g.state === "COMPLETE" && compareTime(g.retainUntil, g.startedAt) <= 0) ||
          (timePair(input.now) && compareTime(g.startedAt, input.now) > 0) ?
          "INCONSISTENT" : "CONSISTENT";
      }
      if (g.state === "COMPLETE") {
        fields.guard = fields.guardContext === "CONSISTENT" && timePair(input.now) ?
          compareTime(input.now, g.retainUntil) > 0 ? "COMPLETE_RETENTION_EXPIRED" : "COMPLETE" :
          "COMPLETE_RETENTION_UNKNOWN";
      }
    }
    if ((r && validGuard && r.deletionId !== g.deletionId) ||
        (input.expectedDeletionId !== null &&
          ((r && r.deletionId !== input.expectedDeletionId) ||
            (validGuard && g.deletionId !== input.expectedDeletionId)))) {
      fields.operation = "CONFLICT";
    } else if (r && gf === "ABSENT") fields.operation = "GUARD_MISSING";
    else if (r && validGuard) fields.operation = input.expectedDeletionId === null ? "MATCH_UNBOUND" : "MATCH";
    else if (validGuard && fields.reservation === "ABSENT") fields.operation = "GUARD_ONLY";
    else if (gf === "ABSENT" && fields.reservation === "ABSENT") fields.operation = "UNBOUND";

    if (r && r.version === 1) {
      fields.v1Context = "INSUFFICIENT";
      if (validGuard && fields.guardContext === "CONSISTENT" && timePair(input.reservation.createTime)) {
        // This is consistency of a stored V1 number, never proof of Auth generation.
        const born = {seconds: Math.floor(r.authCreatedAtMs / 1000),
          nanoseconds: (r.authCreatedAtMs % 1000) * 1000000};
        fields.v1Context = timePair(born) && compareTime(born, g.startedAt) <= 0 &&
          compareTime(input.reservation.createTime, g.startedAt) >= 0 ? "CONSISTENT" : "INCONSISTENT";
      }
    }
    if (rf === "UNAVAILABLE" || gf === "UNAVAILABLE" || fields.auth === "UNAVAILABLE") {
      fields.status = "READ_UNAVAILABLE";
    } else if (fields.reservation === "MALFORMED") fields.status = "RECORD_INVALID";
    else if (fields.reservation === "UNKNOWN_VERSION") fields.status = "VERSION_UNSUPPORTED";
    else if (fields.guard === "MALFORMED") fields.status = "GUARD_INVALID";
    else if (fields.auth === "AMBIGUOUS") fields.status = "IDENTITY_AMBIGUOUS";
    else if (fields.operation === "CONFLICT") fields.status = "DELETION_ID_CONFLICT";
    else if (r && r.version === 2 && input.expectedOrigin !== null && r.origin !== input.expectedOrigin) {
      fields.status = "ORIGIN_CONFLICT";
    } else if (fields.operation === "GUARD_MISSING") fields.status = "GUARD_MISSING_REVIEW_REQUIRED";
    else if (fields.guardContext === "INCONSISTENT") fields.status = "GUARD_CONTEXT_INCONSISTENT";
    else if (fields.v1Context === "INCONSISTENT") fields.status = "V1_CONTEXT_INCONSISTENT";
    else if (fields.auth === "PRESENT") fields.status = "AUTH_PRESENT_RECOVERY_BLOCKED";
    else if (fields.guard.startsWith("COMPLETE")) fields.status = "TERMINAL_PROOF_REQUIRED";
    else if (fields.guardContext === "INSUFFICIENT") fields.status = "GUARD_CONTEXT_INSUFFICIENT";
    else if (r && r.version === 1) fields.status = fields.v1Context === "INSUFFICIENT" ?
      "V1_CONTEXT_INSUFFICIENT" : "V1_REVIEW_REQUIRED";
    else if (!r) fields.status = "LEGACY_OR_NEW_UNPROVEN";
    else fields.status = {PRE_AUTH: "PRE_AUTH_PROCEDURE_REVALIDATION_REQUIRED",
      AUTH_EVENT: "MANAGED_AUTH_EVENT_REVALIDATION_REQUIRED",
      LEGACY_REVIEW: "LEGACY_REVIEW_REQUIRED"}[r.origin];
    return classification(fields);
  } catch (_) {
    return classification({...fields, status: "READ_UNAVAILABLE"});
  }
}

function createSyntheticRetirementContractV2(options) {
  if (!exact(options, ["projectId", "databaseId", "ports"])) {
    refuse("MODEL_CONFIGURATION_INVALID");
  }
  const {projectId, databaseId, ports} = options;
  if (typeof projectId !== "string" ||
      !/^demo-[a-z0-9][a-z0-9-]{0,48}$/.test(projectId) ||
      typeof databaseId !== "string" ||
      !(databaseId === "(default)" || /^[a-z][a-z0-9-]{2,62}$/.test(databaseId)) ||
      !exact(ports, ["authorize", "attestOrigin", "observeAuth", "runTransaction"]) ||
      ![ports.authorize, ports.attestOrigin, ports.observeAuth, ports.runTransaction]
          .every((fn) => typeof fn === "function")) {
    refuse("MODEL_CONFIGURATION_INVALID");
  }
  // Collaborators are trusted synthetic code, not a public callback API.
  const {authorize, attestOrigin, observeAuth, runTransaction} = ports;
  const prefix = `projects/${projectId}/databases/${databaseId}/documents`;
  const paths = (uid) => ({guard: `${prefix}/account_deletion_guards/${uid}`,
    record: `${prefix}/retired_auth_identities/${uid}`});

  async function execute(action, input, body) {
    try {
      const origin = ORIGINS[action] || null;
      const keys = action === "checkAdmission" ? ["uid", "authority"] :
        ["uid", "deletionId", "authority", ...(origin ? ["evidence"] : [])];
      if (!exact(input, keys) || !safeUid(input.uid) ||
          (action !== "checkAdmission" &&
            (typeof input.deletionId !== "string" || !UUID.test(input.deletionId)))) {
        refuse("INPUT_INVALID");
      }
      const {uid, deletionId, authority, evidence} = input;
      const scope = Object.freeze({action, origin, projectId, databaseId, uid,
        deletionId: deletionId || null});
      if (await authorize(scope, authority) !== true) refuse("OPERATOR_UNAUTHORIZED");
      if (origin && await attestOrigin(scope, evidence) !== true) {
        refuse("PROVENANCE_UNPROVEN");
      }
      return await body(scope, paths(uid));
    } catch (error) {
      return outcome(error instanceof Refusal && CODES.has(error.code) ?
        error.code : "UNKNOWN_REQUIRES_REREAD");
    }
  }

  async function record(action, input) {
    return execute(action, input, async (scope, p) => {
      const before = authState(await observeAuth(scope));
      if (scope.origin === "PRE_AUTH" && before !== "PRESENT") {
        refuse("AUTH_ABSENT_CANNOT_PRE_RESERVE");
      }
      if (scope.origin !== "PRE_AUTH" && before !== "ABSENT") {
        refuse("AUTH_PRESENT_RECOVERY_BLOCKED");
      }
      await runTransaction(async (tx) => {
        guardValue(await tx.get(p.guard), scope.deletionId, true);
        const r = recordValue(await tx.get(p.record), scope.deletionId);
        if (r && r.version === 1) refuse("V1_REVIEW_REQUIRED");
        if (r && r.origin !== scope.origin) refuse("ORIGIN_CONFLICT");
        if (!r) tx.create(p.record, {version: 2, state: "RESERVED",
          deletionId: scope.deletionId, origin: scope.origin});
      });
      const after = authState(await observeAuth(scope));
      if (before !== after) refuse("AUTH_CHANGED_REQUIRES_REVIEW");
      // Even PRE_AUTH acknowledges storage only, not generation or deletion order.
      return outcome(scope.origin === "LEGACY_REVIEW" ?
        "LEGACY_REVIEW_RECORDED_INCONCLUSIVE" : `${scope.origin}_RECORD_ACKNOWLEDGED`);
    });
  }

  async function inspect(input) {
    return execute("inspect", input, async (scope, p) => {
      const before = authState(await observeAuth(scope));
      const status = await runTransaction(async (tx) => {
        const gs = await tx.get(p.guard);
        const r = recordValue(await tx.get(p.record), scope.deletionId);
        if (!gs || typeof gs.exists !== "boolean") refuse("GUARD_INVALID");
        if (!gs.exists) {
          if (r) refuse("GUARD_INVALID");
          return "LEGACY_REVIEW_REQUIRED";
        }
        const g = guardValue(gs, scope.deletionId, false);
        if (g.state === "COMPLETE") return "TERMINAL_PROOF_REQUIRED";
        if (r && r.version === 1) return "V1_REVIEW_REQUIRED";
        if (before === "PRESENT") return "AUTH_PRESENT_RECOVERY_BLOCKED";
        if (!r || r.origin === "LEGACY_REVIEW") return "LEGACY_REVIEW_REQUIRED";
        return r.origin === "PRE_AUTH" ? "PRE_AUTH_PROCEDURE_REVALIDATION_REQUIRED" :
          "MANAGED_AUTH_EVENT_REVALIDATION_REQUIRED";
      });
      if (before !== authState(await observeAuth(scope))) {
        refuse("AUTH_CHANGED_REQUIRES_REVIEW");
      }
      return outcome(status);
    });
  }

  async function checkAdmission(input) {
    return execute("checkAdmission", input, async (scope, p) => {
      await runTransaction(async (tx) => {
        if (recordValue(await tx.get(p.record))) refuse("UID_RESERVED");
      });
      return outcome("LEGACY_OR_NEW_UNPROVEN");
    });
  }
  return Object.freeze({
    reservePreAuth: (input) => record("reservePreAuth", input),
    recordAuthEvent: (input) => record("recordAuthEvent", input),
    recordLegacyReview: (input) => record("recordLegacyReview", input),
    inspect, checkAdmission,
  });
}

module.exports = {createSyntheticRetirementContractV2, classifyRetiredIdentitySnapshots};
