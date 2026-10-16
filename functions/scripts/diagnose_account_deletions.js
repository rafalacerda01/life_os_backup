"use strict";

const {randomUUID} = require("node:crypto");
const {diagnose, validateIsolation, validateLimits} =
  require("./account_deletion_diagnostic");

function parseArgs(args) {
  const allowed = new Map([["--project", "projectId"],
    ["--page-size", "pageSize"], ["--max-documents", "maxDocuments"],
    ["--older-than-ms", "olderThanMs"]]);
  const result = {limits: {}};
  const seen = new Set();
  for (let i = 0; i < args.length; i += 2) {
    const key = allowed.get(args[i]);
    if (!key || seen.has(key) || !args[i + 1]) throw new Error();
    seen.add(key);
    if (key === "projectId") result.projectId = args[i + 1];
    else {
      if (!/^[1-9][0-9]*$/.test(args[i + 1])) throw new Error();
      result.limits[key] = Number(args[i + 1]);
    }
  }
  return result;
}

async function run(args = process.argv.slice(2), env = process.env) {
  let app;
  let db;
  try {
    const input = parseArgs(args);
    const isolated = validateIsolation(input.projectId, env);
    // Validate limits before initializing any SDK client.
    validateLimits(input.limits);
    // Auth's SDK reads process.env, so a detached environment cannot bind it.
    if (env !== process.env) throw new Error();
    const {initializeApp} = require("firebase-admin/app");
    const {Firestore, FieldPath} = require("firebase-admin/firestore");
    const {GoogleAuth, OAuth2Client} = require("google-auth-library");
    const {getAuth} = require("firebase-admin/auth");
    app = initializeApp({projectId: isolated.projectId,
      credential: {getAccessToken: async () =>
        ({access_token: "owner", expires_in: 3600})}},
    "deletion-diagnostic-" + randomUUID());
    // The standalone SDK export supports emulator owner headers without asking
    // Admin's app-bound Firestore factory to accept a non-ADC credential.
    const owner = new OAuth2Client();
    owner.setCredentials({access_token: "owner",
      expiry_date: Date.now() + 60 * 60 * 1000});
    db = new Firestore({projectId: isolated.projectId,
      host: isolated.firestoreHost, ssl: false,
      auth: new GoogleAuth({projectId: isolated.projectId, authClient: owner})});
    const auth = getAuth(app);
    const guards = db.collection("account_deletion_guards");
    const snapshot = (doc) => doc.exists ? {id: doc.id, data: doc.data(),
      version: doc.updateTime.seconds + ":" + doc.updateTime.nanoseconds} : null;
    const report = await diagnose({...input, env, readers: {
      getGuardPage: async ({afterId, limit}) => {
        let query = guards.orderBy(FieldPath.documentId()).limit(limit);
        if (afterId !== undefined) query = query.startAfter(afterId);
        return (await query.get()).docs.map(snapshot);
      },
      getGuard: async (id) => snapshot(await guards.doc(id).get()),
      getAuthUser: async (id) => ({uid: (await auth.getUser(id)).uid}),
    }});
    return {exitCode: report.truncated || report.counts.inconclusive ? 2 : 0,
      report};
  } catch (_) {
    // No SDK error, path, UID, environment value or argument is printed.
    return {exitCode: 1, report: {status: "DIAGNOSTIC_REFUSED_OR_FAILED"}};
  } finally {
    try {
      if (db) await db.terminate();
      if (app) await require("firebase-admin/app").deleteApp(app);
    } catch (_) { /* No diagnostic authority depends on client disposal. */ }
  }
}

if (require.main === module) {
  run().then(({exitCode, report}) => {
    process.stdout.write(JSON.stringify(report) + "\n");
    process.exitCode = exitCode;
  }, () => {
    process.stdout.write('{"status":"DIAGNOSTIC_REFUSED_OR_FAILED"}\n');
    process.exitCode = 1;
  });
}

module.exports = {run, parseArgs};
