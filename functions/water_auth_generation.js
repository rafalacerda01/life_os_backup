"use strict";

const {Timestamp} = require("firebase-admin/firestore");
const {UserRecord} = require("firebase-admin/auth");

/** Sanitized failure of an administrative generation read. */
class AuthGenerationError extends Error {
  /** @param {string} code Domain refusal, never an SDK message. */
  constructor(code) {
    super("Não foi possível consultar a origem da conta.");
    this.code = code;
  }
}

/** @param {string} code Safe refusal. */
function fail(code) {
  throw new AuthGenerationError(code);
}

/**
 * @param {*} value JSON object.
 * @return {boolean} Plain object.
 */
function object(value) {
  return value !== null && typeof value === "object" &&
    Object.getPrototypeOf(value) === Object.prototype;
}

/**
 * Exact REST createdAt, documented as an int64 string in milliseconds.
 * No parsing of seconds, rounding, tolerance or inferred fractional digits.
 * @param {*} value API value.
 * @return {Timestamp} Full precision available from the authoritative API.
 */
function createdAt(value) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]{0,14})$/.test(value)) {
    fail("WATER_BIRTH_GENERATION_CONFLICT");
  }
  const millis = Number(value);
  if (!Number.isSafeInteger(millis) || millis > 253402300799999) {
    fail("WATER_BIRTH_GENERATION_CONFLICT");
  }
  return Timestamp.fromMillis(millis);
}

/**
 * Server-owned dependencies only; no HTTP handler or client generation input.
 * Production reuses the SAME App's public Credential.getAccessToken(), never
 * initializes an app, loads credentials, signs custom tokens or grants IAM.
 * The read requires firebaseauth.users.get, like Admin getUser().
 * @param {Object} options Bound Auth/project and optional test transport.
 * @return {Object} Zero-write reader with a bounded read deadline.
 */
function createAuthGenerationReader({auth, projectId,
  emulatorHost = process.env.FIREBASE_AUTH_EMULATOR_HOST,
  fetchImpl = global.fetch, timeoutMillis = 5000}) {
  const emulator = emulatorHost !== undefined;
  if (typeof fetchImpl !== "function" ||
      !Number.isSafeInteger(timeoutMillis) || timeoutMillis < 1 ||
      timeoutMillis > 30000 ||
      (emulator ? projectId !== "demo-life-os" ||
        emulatorHost !== "127.0.0.1:9099" : projectId !== "life-os-27b92")) {
    fail("WATER_BIRTH_INVALID_CONFIGURATION");
  }
  const url = emulator ?
    "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/projects/" +
      "demo-life-os/accounts:lookup" :
    "https://identitytoolkit.googleapis.com/v1/projects/" +
      "life-os-27b92/accounts:lookup";
  const credential = auth?.app?.options?.credential;
  /** Validate identity again after each asynchronous administrative read. */
  function checkAuth() {
    if (!auth || auth.app?.options?.projectId !== projectId ||
        auth.tenantId != null || typeof auth.getUser !== "function" ||
        (!emulator && (!credential ||
          auth.app.options.credential !== credential ||
          typeof credential.getAccessToken !== "function"))) {
      fail("WATER_BIRTH_INVALID_CONFIGURATION");
    }
  }
  checkAuth();

  /**
   * @param {string} uid Original managed event UID.
   * @param {AbortSignal} signal Expiry of this read, not of any write.
   * @return {Promise<Object|null>} Precise generation or confirmed absence.
   */
  async function query(uid, signal) {
    checkAuth();
    if (typeof uid !== "string" || !uid || uid.length > 128 ||
        uid.trim() !== uid ||
        // eslint-disable-next-line no-control-regex
        /[/\u0000-\u001f\u007f]/.test(uid) ||
        [".", ".."].includes(uid) || /^__.*__$/.test(uid)) {
      fail("WATER_BIRTH_GENERATION_CONFLICT");
    }
    let current;
    try {
      current = await auth.getUser(uid);
    } catch (error) {
      if (error?.code === "auth/user-not-found") return null;
      throw error;
    }
    checkAuth();
    signal.throwIfAborted();
    if (!(current instanceof UserRecord) || current.uid !== uid) {
      fail("WATER_BIRTH_GENERATION_CONFLICT");
    }
    if (current.tenantId != null ||
        typeof current.metadata.creationTime !== "string" ||
        !Number.isFinite(Date.parse(current.metadata.creationTime))) {
      fail("WATER_BIRTH_INVALID_ORIGIN");
    }
    // Literal emulator marker only. Never request ADC/personal credentials in
    // emulator mode. In production, use the already-bound App's credential.
    let token = "owner";
    if (!emulator) {
      const access = await credential.getAccessToken();
      checkAuth();
      if (!access || typeof access.access_token !== "string" ||
          !access.access_token || access.access_token === "owner" ||
          /\s/.test(access.access_token) ||
          !Number.isFinite(access.expires_in) || access.expires_in <= 0) {
        fail("WATER_BIRTH_AUTH_UNAVAILABLE");
      }
      token = access.access_token;
    }
    signal.throwIfAborted();
    const response = await fetchImpl(url, {method: "POST", redirect: "error",
      signal, headers: {"Content-Type": "application/json",
        "Authorization": `Bearer ${token}`},
      body: JSON.stringify({localId: [uid]})});
    checkAuth();
    if (!response || response.status !== 200) {
      fail("WATER_BIRTH_AUTH_UNAVAILABLE");
    }
    const body = await response.json();
    checkAuth();
    if (!object(body) ||
        Object.keys(body).some((key) => !["kind", "users"].includes(key)) ||
        (body.kind !== undefined &&
          body.kind !== "identitytoolkit#GetAccountInfoResponse") ||
        !Array.isArray(body.users)) {
      fail("WATER_BIRTH_AUTH_UNAVAILABLE");
    }
    if (body.users.length === 0) return null;
    if (body.users.length !== 1 || !object(body.users[0])) {
      fail("WATER_BIRTH_GENERATION_CONFLICT");
    }
    const user = body.users[0];
    if (user.localId !== uid || Object.hasOwn(user, "tenantId") ||
        Object.hasOwn(user, "projectId")) {
      fail("WATER_BIRTH_GENERATION_CONFLICT");
    }
    const precise = createdAt(user.createdAt);
    // SDK UTC is only an additional consistency check. It never authorizes a
    // match: the unchanged core compares the exact REST milliseconds to event.
    if (precise.toDate().toUTCString() !== current.metadata.creationTime) {
      fail("WATER_BIRTH_GENERATION_CONFLICT");
    }
    return {uid, projectId, tenantId: null, authCreatedAt: precise};
  }

  return Object.freeze({read: async (uid) => {
    const controller = new AbortController();
    let timer;
    const deadline = new Promise((resolve, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new AuthGenerationError("WATER_BIRTH_AUTH_UNAVAILABLE"));
      }, timeoutMillis);
    });
    try {
      return await Promise.race([query(uid, controller.signal), deadline]);
    } catch (error) {
      if (error instanceof AuthGenerationError) throw error;
      fail("WATER_BIRTH_AUTH_UNAVAILABLE");
    } finally {
      clearTimeout(timer);
      controller.abort();
    }
  }});
}

module.exports = {createAuthGenerationReader, AuthGenerationError};
