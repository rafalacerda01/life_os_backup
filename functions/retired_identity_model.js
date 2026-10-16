"use strict";

// D2-C-02-R2: synthetic contract only. No SDK, credentials, network or adapter.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const RECORD_KEYS = ["version", "state", "deletionId", "authCreatedAtMs"];
const GUARD_KEYS = ["version", "state", "deletionId", "startedAt", "retainUntil"];
const REFUSALS = new Set(["GUARD_INVALID", "OPERATION_CONFLICT", "GUARD_COMPLETE",
  "RECORD_INVALID", "RESERVATION_CONFLICT", "IDENTITY_AMBIGUOUS", "INPUT_INVALID",
  "OPERATOR_UNAUTHORIZED", "AUTH_ABSENT_CANNOT_FIRST_RESERVE", "IDENTITY_CHANGED",
  "UID_RESERVED"]);

class Refusal extends Error {
  constructor(code) {
    super("Synthetic identity contract refused.");
    this.code = code;
  }
}
function refuse(code) {
  throw new Refusal(code);
}
function exact(value, keys) {
  return value !== null && typeof value === "object" &&
    !Array.isArray(value) && Reflect.ownKeys(value).length === keys.length &&
    keys.every((key) => Object.hasOwn(value, key));
}
function millis(value) {
  return Number.isSafeInteger(value) && value > 0;
}
function safeUid(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 &&
    value.trim() === value && !/[\/\u0000-\u001f\u007f]/.test(value) &&
    value !== "." && value !== ".." && !/^__.*__$/.test(value);
}
function outcome(status) {
  // Never echo UID, paths, deletionId, authority, observations or SDK errors.
  return Object.freeze({status, destructiveAuthority: false});
}
function guardValue(snapshot, deletionId, active) {
  const g = snapshot && snapshot.exists && snapshot.data;
  if (!exact(g, GUARD_KEYS) || g.version !== 1 || !UUID.test(g.deletionId) ||
      !millis(g.startedAt) ||
      !((g.state === "IN_PROGRESS" && g.retainUntil === null) ||
        (g.state === "COMPLETE" && millis(g.retainUntil) &&
          g.retainUntil > g.startedAt))) refuse("GUARD_INVALID");
  if (g.deletionId !== deletionId) refuse("OPERATION_CONFLICT");
  if (active && g.state !== "IN_PROGRESS") refuse("GUARD_COMPLETE");
  return g;
}
function reservationValue(snapshot, deletionId) {
  if (!snapshot || typeof snapshot.exists !== "boolean") refuse("RECORD_INVALID");
  if (!snapshot.exists) return null;
  const r = snapshot.data;
  if (!exact(r, RECORD_KEYS) || r.version !== 1 || r.state !== "RESERVED" ||
      !UUID.test(r.deletionId) || !millis(r.authCreatedAtMs) ||
      !millis(snapshot.createTimeMs)) refuse("RECORD_INVALID");
  if (deletionId !== undefined && r.deletionId !== deletionId) {
    refuse("RESERVATION_CONFLICT");
  }
  return r;
}
function authValue(value) {
  if (exact(value, ["state"]) && value.state === "ABSENT") {
    return Object.freeze({state: "ABSENT"});
  }
  if (exact(value, ["state", "createdAtMs"]) && value.state === "PRESENT" &&
      millis(value.createdAtMs)) {
    return Object.freeze({state: "PRESENT", createdAtMs: value.createdAtMs});
  }
  refuse("IDENTITY_AMBIGUOUS");
}
function sameAuth(a, b) {
  return a.state === b.state && a.createdAtMs === b.createdAtMs;
}

/**
 * Only demo projects and synthetic ports. Ports are trusted test collaborators,
 * never request JSON or a production authorization implementation. Millisecond
 * observations are a modelling assumption, not proof of a real Auth generation.
 */
function createSyntheticRetirementModel(options) {
  if (!exact(options, ["projectId", "databaseId", "ports"])) {
    refuse("MODEL_CONFIGURATION_INVALID");
  }
  const {projectId, databaseId, ports} = options;
  if (typeof projectId !== "string" || !/^demo-[a-z0-9][a-z0-9-]{0,48}$/.test(projectId) ||
      typeof databaseId !== "string" ||
      !(databaseId === "(default)" || /^[a-z][a-z0-9-]{2,62}$/.test(databaseId)) ||
      !exact(ports, ["authorize", "observeAuth", "runTransaction"]) ||
      ![ports.authorize, ports.observeAuth, ports.runTransaction]
          .every((fn) => typeof fn === "function")) refuse("MODEL_CONFIGURATION_INVALID");
  // Capture ports: mutating the options object cannot replace collaborators.
  const {authorize, observeAuth, runTransaction} = ports;
  const prefix = `projects/${projectId}/databases/${databaseId}/documents`;
  const paths = (uid) => ({guard: `${prefix}/account_deletion_guards/${uid}`,
    reservation: `${prefix}/retired_auth_identities/${uid}`});

  async function execute(action, input, body) {
    try {
      const keys = action === "CHECK_ADMISSION" ? ["uid", "authority"] :
        ["uid", "deletionId", "authority"];
      if (!exact(input, keys) || !safeUid(input.uid) ||
          (action !== "CHECK_ADMISSION" &&
            (typeof input.deletionId !== "string" || !UUID.test(input.deletionId)))) {
        refuse("INPUT_INVALID");
      }
      // Copy request fields before the first await to prevent caller mutation.
      const uid = input.uid;
      const deletionId = input.deletionId;
      if (await authorize(Object.freeze({action, projectId, databaseId, uid,
        deletionId: deletionId || null}), input.authority) !== true) {
        refuse("OPERATOR_UNAUTHORIZED");
      }
      return await body(uid, deletionId, paths(uid));
    } catch (error) {
      return outcome(error instanceof Refusal && REFUSALS.has(error.code) ?
        error.code : "UNKNOWN_REQUIRES_REREAD");
    }
  }

  async function reserve(input) {
    return execute("RESERVE", input, async (uid, deletionId, p) => {
      const auth = authValue(await observeAuth(Object.freeze({projectId, databaseId, uid})));
      if (auth.state !== "PRESENT") refuse("AUTH_ABSENT_CANNOT_FIRST_RESERVE");
      await runTransaction(async (tx) => {
        const g = guardValue(await tx.get(p.guard), deletionId, true);
        const snapshot = await tx.get(p.reservation);
        const r = reservationValue(snapshot, deletionId);
        if (r && (r.authCreatedAtMs > g.startedAt || snapshot.createTimeMs < g.startedAt)) {
          refuse("RECORD_INVALID");
        }
        if (auth.createdAtMs > g.startedAt ||
            (r && r.authCreatedAtMs !== auth.createdAtMs)) refuse("IDENTITY_CHANGED");
        if (!r) tx.create(p.reservation, {version: 1, state: "RESERVED",
          deletionId, authCreatedAtMs: auth.createdAtMs});
      });
      // Acknowledges only the reservation transaction, never Auth deletion.
      return outcome("RESERVATION_ACKNOWLEDGED");
    });
  }

  async function inspect(input) {
    return execute("INSPECT", input, async (uid, deletionId, p) => {
      const subject = Object.freeze({projectId, databaseId, uid});
      const before = authValue(await observeAuth(subject));
      const status = await runTransaction(async (tx) => {
        const gSnapshot = await tx.get(p.guard);
        const rSnapshot = await tx.get(p.reservation);
        const r = reservationValue(rSnapshot, deletionId);
        if (!r) return "LEGACY_OR_NEW_UNPROVEN";
        const g = guardValue(gSnapshot, deletionId, false);
        if (r.authCreatedAtMs > g.startedAt || rSnapshot.createTimeMs < g.startedAt) {
          refuse("RECORD_INVALID");
        }
        if (before.state === "PRESENT" && before.createdAtMs !== r.authCreatedAtMs) {
          refuse("IDENTITY_CHANGED");
        }
        if (g.state === "COMPLETE") return "TERMINAL_PROOF_REQUIRED";
        return before.state === "PRESENT" ? "AUTH_PRESENT_RECOVERY_BLOCKED" :
          "RESERVED_AUTH_ABSENT_NO_AUTHORITY";
      });
      const after = authValue(await observeAuth(subject));
      if (!sameAuth(before, after)) refuse("IDENTITY_CHANGED");
      return outcome(status);
    });
  }

  async function checkAdmission(input) {
    return execute("CHECK_ADMISSION", input, async (uid, deletionId, p) => {
      await runTransaction(async (tx) => {
        const r = reservationValue(await tx.get(p.reservation));
        if (r) refuse("UID_RESERVED");
      });
      // Missing is not permission: particularly important for legacy accounts.
      return outcome("LEGACY_OR_NEW_UNPROVEN");
    });
  }

  return Object.freeze({reserve, inspect, checkAdmission});
}

module.exports = {createSyntheticRetirementModel};
