"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {UserRecord} = require("firebase-admin/auth");
const {getApps} = require("firebase-admin/app");
const {createAuthGenerationReader, AuthGenerationError} =
  require("../water_auth_generation");
const UID = "synthetic-precision-owner";
const MILLIS = Date.parse("2026-10-21T18:36:33.946Z");

/** @return {Object} Offline API fixture, no credentials/network. */
function fixture() {
  const f = {calls: [], tokenCalls: 0, sdkCalls: 0};
  f.auth = {app: {options: {projectId: "demo-life-os", credential: {
    getAccessToken: async () => {
      f.tokenCalls++;
      return {access_token: "offline-test-placeholder", expires_in: 3600};
    },
  }}}, getUser: async () => {
    f.sdkCalls++;
    if (f.sdkHook) await f.sdkHook();
    if (f.sdkError) throw f.sdkError;
    return f.current;
  }};
  f.current = new UserRecord({localId: UID, createdAt: String(MILLIS)});
  f.body = {kind: "identitytoolkit#GetAccountInfoResponse",
    users: [{localId: UID, createdAt: String(MILLIS)}]};
  f.options = {auth: f.auth, projectId: "demo-life-os",
    emulatorHost: "127.0.0.1:9099", timeoutMillis: 10,
    fetchImpl: async (url, options) => {
      f.calls.push({url, options});
      if (f.fetchHook) await f.fetchHook();
      return f.response || Response.json(f.body);
    }};
  f.read = () => createAuthGenerationReader(f.options).read(UID);
  return f;
}

/**
 * @param {Object} f Fixture.
 * @param {string} code Safe refusal.
 */
async function refused(f, code) {
  await assert.rejects(f.read(), (error) => {
    assert.ok(error instanceof AuthGenerationError);
    assert.equal(error.code, code);
    assert.equal(error.message,
        "Não foi possível consultar a origem da conta.");
    return true;
  });
}

test("official lookup preserves every supplied millisecond and binds identity",
    async () => {
      const before = getApps().length;
      const f = fixture(); const generation = await f.read();
      assert.equal(generation.authCreatedAt.toMillis(), MILLIS);
      assert.equal(generation.authCreatedAt.nanoseconds, 946000000);
      assert.deepEqual({...generation, authCreatedAt: undefined}, {
        uid: UID, projectId: "demo-life-os", tenantId: null,
        authCreatedAt: undefined});
      assert.equal(f.sdkCalls, 1); assert.equal(f.tokenCalls, 0);
      const {url, options} = f.calls[0];
      assert.equal(url, "http://127.0.0.1:9099/identitytoolkit.googleapis.com/" +
        "v1/projects/demo-life-os/accounts:lookup");
      assert.deepEqual(JSON.parse(options.body), {localId: [UID]});
      assert.equal(options.headers.Authorization, "Bearer owner");
      assert.equal(options.redirect, "error");
      assert.equal(getApps().length, before, "must not initialize another app");
    });

for (const [label, body, code] of [
  ["missing result", {}, "WATER_BIRTH_AUTH_UNAVAILABLE"],
  ["null result", null, "WATER_BIRTH_AUTH_UNAVAILABLE"],
  ["unexpected response field", {users: [], projectId: "other"},
    "WATER_BIRTH_AUTH_UNAVAILABLE"],
  ["unexpected kind", {kind: "other", users: []},
    "WATER_BIRTH_AUTH_UNAVAILABLE"],
  ["users not array", {users: {}}, "WATER_BIRTH_AUTH_UNAVAILABLE"],
  ["ambiguous matches", {users: [{}, {}]}, "WATER_BIRTH_GENERATION_CONFLICT"],
  ["wrong UID", {users: [{localId: "other", createdAt: String(MILLIS)}]},
    "WATER_BIRTH_GENERATION_CONFLICT"],
  ["tenant", {users: [{localId: UID,
    createdAt: String(MILLIS), tenantId: "tenant"}]},
  "WATER_BIRTH_GENERATION_CONFLICT"],
  ["null tenant field", {users: [{localId: UID,
    createdAt: String(MILLIS), tenantId: null}]},
  "WATER_BIRTH_GENERATION_CONFLICT"],
  ["conflicting project field", {users: [{localId: UID,
    createdAt: String(MILLIS), projectId: "other"}]},
  "WATER_BIRTH_GENERATION_CONFLICT"],
]) {
  test(`reject ${label}`, async () => {
    const f = fixture(); f.body = body; await refused(f, code);
    assert.equal(f.tokenCalls, 0);
  });
}

for (const value of [undefined, null, MILLIS, "", " 1792607793946",
  "01792607793946",
  "-1", "1792607793.946", "1.792607793946e12", "253402300800000",
  "9007199254740993", "1792607793"]) {
  test(`reject malformed/truncated createdAt ${String(value)}`, async () => {
    const f = fixture(); f.body.users[0].createdAt = value;
    await refused(f, "WATER_BIRTH_GENERATION_CONFLICT");
  });
}

test("inconsistent SDK and REST dates are rejected", async () => {
  const f = fixture(); f.body.users[0].createdAt = String(MILLIS + 1000);
  await refused(f, "WATER_BIRTH_GENERATION_CONFLICT");
});
test("disappearance between SDK and REST returns absence", async () => {
  const f = fixture(); f.body = {users: []}; assert.equal(await f.read(), null);
});
test("SDK user-not-found requires no REST/token request", async () => {
  const f = fixture(); f.sdkError = {code: "auth/user-not-found"};
  assert.equal(await f.read(), null); assert.equal(f.calls.length, 0);
});
test("SDK unavailable fails without fallback", async () => {
  const f = fixture(); f.sdkError = new Error("private SDK detail");
  await refused(f, "WATER_BIRTH_AUTH_UNAVAILABLE");
  assert.equal(f.calls.length, 0);
});
for (const status of [301, 400, 401, 403, 404, 429, 500, 503]) {
  test(`HTTP ${status} never authorizes a generation`, async () => {
    const f = fixture(); f.response = new Response("{}", {status});
    await refused(f, "WATER_BIRTH_AUTH_UNAVAILABLE");
  });
}
test("truncated JSON fails safely", async () => {
  const f = fixture(); f.response = new Response("{\"users\":[");
  await refused(f, "WATER_BIRTH_AUTH_UNAVAILABLE");
});

for (const host of ["localhost:9099", "127.0.0.1:9098", "example.test:9099",
  "http://127.0.0.1:9099", "127.0.0.1:9099/path", "", null]) {
  test(`invalid emulator host is refused before any lookup: ${host}`, () => {
    const f = fixture(); f.options.emulatorHost = host;
    assert.throws(() => createAuthGenerationReader(f.options), {
      code: "WATER_BIRTH_INVALID_CONFIGURATION"});
    assert.equal(f.sdkCalls, 0); assert.equal(f.calls.length, 0);
    assert.equal(f.tokenCalls, 0);
  });
}
test("production project cannot be paired with an emulator", () => {
  const f = fixture(); f.options.projectId = "life-os-27b92";
  f.auth.app.options.projectId = "life-os-27b92";
  assert.throws(() => createAuthGenerationReader(f.options), {
    code: "WATER_BIRTH_INVALID_CONFIGURATION"});
  assert.equal(f.sdkCalls, 0); assert.equal(f.tokenCalls, 0);
});
test("bound project is rechecked after a pending SDK read", async () => {
  const f = fixture(); f.sdkHook = async () => {
    f.auth.app.options.projectId = "life-os-27b92";
  };
  await refused(f, "WATER_BIRTH_INVALID_CONFIGURATION");
  assert.equal(f.calls.length, 0); assert.equal(f.tokenCalls, 0);
});
test("bound project is rechecked after REST", async () => {
  const f = fixture(); f.fetchHook = async () => {
    f.auth.app.options.projectId = "other";
  };
  await refused(f, "WATER_BIRTH_INVALID_CONFIGURATION");
});

for (const step of ["sdkHook", "fetchHook", "json"]) {
  test(`deadline covers ${step} without allowing a late result`, async (t) => {
    t.mock.timers.enable({apis: ["setTimeout"]});
    const f = fixture(); const entered = Promise.withResolvers();
    const release = Promise.withResolvers();
    const hold = async () => {
      entered.resolve(); await release.promise;
    };
    if (step === "json") {
      f.response = {status: 200, json: async () => {
        await hold(); return f.body;
      }};
    } else f[step] = hold;
    const result = refused(f, "WATER_BIRTH_AUTH_UNAVAILABLE");
    await entered.promise; t.mock.timers.tick(10); await result;
    release.resolve(); await Promise.resolve(); await Promise.resolve();
    assert.equal(f.tokenCalls, 0);
    if (step === "sdkHook") assert.equal(f.calls.length, 0);
  });
}

test("production transport uses only the same public App credential (mocked)",
    async () => {
      const prior = process.env.FIREBASE_AUTH_EMULATOR_HOST;
      delete process.env.FIREBASE_AUTH_EMULATOR_HOST;
      try {
        const f = fixture(); f.options.emulatorHost = undefined;
        f.options.projectId = "life-os-27b92";
        f.auth.app.options.projectId = "life-os-27b92";
        const value = await f.read();
        assert.equal(value.authCreatedAt.toMillis(), MILLIS);
        assert.equal(f.tokenCalls, 1);
        assert.equal(f.calls[0].url,
            "https://identitytoolkit.googleapis.com/v1/projects/" +
              "life-os-27b92/accounts:lookup");
        assert.equal(f.calls[0].options.headers.Authorization,
            "Bearer offline-test-placeholder");
      } finally {
        if (prior === undefined) delete process.env.FIREBASE_AUTH_EMULATOR_HOST;
        else process.env.FIREBASE_AUTH_EMULATOR_HOST = prior;
      }
    });
