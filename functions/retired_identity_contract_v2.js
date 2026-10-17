"use strict";

// Synthetic contract only: no SDK, environment, credentials or production adapter.
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
function recordValue(snapshot, deletionId) {
  if (!snapshot || typeof snapshot.exists !== "boolean") refuse("RECORD_INVALID");
  if (!snapshot.exists) return null;
  const r = snapshot.data;
  const v1 = r && r.version === 1;
  if (!exact(r, ["version", "state", "deletionId",
    v1 ? "authCreatedAtMs" : "origin"]) || r.state !== "RESERVED" ||
      typeof r.deletionId !== "string" || !UUID.test(r.deletionId) || (v1 ?
        (!millis(r.authCreatedAtMs) || !millis(snapshot.createTimeMs)) :
        (r.version !== 2 || !Object.values(ORIGINS).includes(r.origin)))) {
    refuse("RECORD_INVALID");
  }
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

module.exports = {createSyntheticRetirementContractV2};
