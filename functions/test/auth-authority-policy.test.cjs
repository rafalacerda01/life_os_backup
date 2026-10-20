"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const path = require("node:path");
const {inspectFiles, inspectRepository, sourcePath} =
  require("../tools/check-auth-authority.cjs");

/**
 * @param {string} source Synthetic source, never executed.
 * @param {string} file Synthetic repository path.
 * @return {Object} Policy observations.
 */
function inspect(source, file = "backend/api/new-route.js") {
  return inspectFiles([{path: file, source}], {requireAuthorizedDelete: false});
}
const allowed = "export async function deleteAccount({auth, uid}) {" +
  "await auth.deleteUser(uid);}";

test("Auth authority policy: repository has only the approved deletion point",
    () => {
      const result = inspectRepository(path.resolve(__dirname, "../.."));
      assert.deepEqual(result.violations, []);
      assert.ok(result.filesScanned > 0);
      const points = result.authorized.map(
          ({file, method}) => ({file, method}));
      assert.deepEqual(points,
          [{file: "backend/api/account/delete.js", method: "deleteUser"}]);
    });

for (const [method, argument] of [
  ["createUser", "{uid: chosenUid}"],
  ["createUser", "{...unknownInput}"],
  ["createUser", "requestBody"],
  ["importUsers", "users"],
  ["deleteUsers", "uids"],
  ["createCustomToken", "uid"],
  ["setCustomUserClaims", "uid, claims"],
  ["deleteUser", "uid"],
]) {
  test(`Auth authority policy: flags ${method}(${argument})`, () => {
    const result = inspect(`await getAuth().${method}(${argument});`);
    assert.ok(result.violations.some((ref) => ref.method === method));
  });
}

for (const source of [
  "await renamedAdmin.auth()['createCustomToken'](uid);",
  "await auth?.deleteUsers?.(uids);",
  "const remove = auth.deleteUser.bind(auth); await remove(uid);",
  "const {importUsers: load} = auth; await load(users);",
  "import {createCustomToken as mint} from 'firebase-admin/auth'; mint(uid);",
  "await createUser({uid});",
  "await auth[`setCustomUserClaims`](uid, claims);",
]) {
  test(`Auth authority policy: flags alternative form ${source}`, () => {
    assert.ok(inspect(source).violations.length > 0);
  });
}

test("Auth authority policy: ignores comments, text and mock objects", () => {
  const source = "// auth.deleteUser(uid)\n" +
    "const documentation = 'auth.createUser({uid})';\n" +
    "const mock = {deleteUser: async uid => uid};\n" +
    "await auth.getUser(uid);";
  assert.deepEqual(inspect(source).violations, []);
});

test("Auth authority policy: excludes test/mock/docs paths", () => {
  const sources = ["functions/test/fake.js", "backend/__mocks__/auth.js",
    "backend/api/example.test.js", "backend/api/example.spec.cjs",
    "functions/fixtures/fake.js", "functions/docs.md"];
  assert.deepEqual(inspectFiles(sources.map((file) => ({path: file,
    source: "auth.deleteUser(uid)"})), {requireAuthorizedDelete: false}),
  {filesScanned: 0, authorized: [], violations: []});
  assert.equal(sourcePath("functions/new-handler.js"), true);
});

test("Auth authority policy: permits the exact approved deletion", () => {
  const result = inspectFiles([{path: "backend/api/account/delete.js",
    source: allowed}]);
  assert.deepEqual(result.violations, []);
  assert.equal(result.authorized.length, 1);
});

for (const source of [
  allowed.replace("deleteAccount", "otherFunction"),
  allowed.replace("auth.deleteUser", "other.deleteUser"),
  allowed.replace("deleteUser(uid)", "deleteUser(otherUid)"),
  allowed.replace("await auth.deleteUser(uid);",
      "const run = async () => auth.deleteUser(uid); await run();"),
  allowed.replace("await auth.deleteUser(uid);",
      "await auth.deleteUser(uid); await auth.deleteUser(uid);"),
]) {
  test(`Auth authority policy: refuses wider exception ${source}`, () => {
    const result = inspectFiles([
      {path: "backend/api/account/delete.js", source},
    ]);
    assert.ok(result.violations.length > 0);
  });
}

test("Auth authority policy: missing approved deletion fails closed", () => {
  assert.ok(inspectFiles([]).violations.some((ref) =>
    ref.method === "AUTHORIZED_DELETE_COUNT"));
});

test("Auth authority policy: parse errors and new languages fail", () => {
  assert.ok(inspect("export ???").violations.some((ref) =>
    ref.method === "SOURCE_PARSE_ERROR"));
  for (const extension of ["ts", "tsx", "jsx"]) {
    assert.ok(inspect("auth.deleteUser(uid)", "backend/api/new." + extension)
        .violations.some((ref) => ref.method === "UNSUPPORTED_SOURCE"));
  }
});
