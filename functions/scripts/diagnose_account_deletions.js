"use strict";

const {randomUUID, createHash} = require("node:crypto");
const {diagnose, validateIsolation, validateLimits, isCanonicalUid} =
  require("./account_deletion_diagnostic");

function parseArgs(args) {
  const allowed = new Map([["--project", "projectId"],
    ["--page-size", "pageSize"], ["--max-documents", "maxDocuments"],
    ["--older-than-ms", "olderThanMs"], ["--max-pages", "maxPages"],
    ["--max-duration-ms", "maxDurationMs"], ["--manual-pages", "manualPages"]]);
  const result = {limits: {}};
  const seen = new Set();
  for (let i = 0; i < args.length; i += 2) {
    const key = allowed.get(args[i]);
    if (!key || seen.has(key) || !args[i + 1]) throw new Error();
    seen.add(key);
    if (key === "manualPages") {
      if (!["true", "false"].includes(args[i + 1])) throw new Error();
      result.manualPages = args[i + 1] === "true";
    } else if (key === "projectId") result.projectId = args[i + 1];
    else {
      if (!/^[1-9][0-9]*$/.test(args[i + 1])) throw new Error();
      result.limits[key] = Number(args[i + 1]);
    }
  }
  return result;
}

// Reading existence uses the same four deterministic paths as the cleaners.
// The empty field mask excludes private document content from SDK responses.
async function readResidueExistence(db, uid, env = process.env) {
  validateIsolation(db?.projectId, env);
  if (!isCanonicalUid(uid)) throw new Error("DIAGNOSTIC_CONFIGURATION_REFUSED");
  const root = db.collection("users").doc(uid);
  const hash = createHash("sha256").update(uid, "utf8").digest("hex");
  const refs = [root, db.collection("billing_google_accounts").doc(hash),
    root.collection("runtime").doc("account_deletion"),
    db.collection("account_birth_decisions").doc(uid)];
  const docs = await db.getAll(...refs, {fieldMask: []});
  if (!Array.isArray(docs) || docs.length !== refs.length ||
      docs.some((doc, i) => doc.ref.path !== refs[i].path ||
        typeof doc.exists !== "boolean")) throw new Error();
  return {userRoot: docs[0].exists, billingAccount: docs[1].exists,
    accountDeletionRuntime: docs[2].exists, birthLedger: docs[3].exists};
}

async function run(args = process.argv.slice(2), env = process.env) {
  let app;
  let db;
  let prompt;
  const interruption = new AbortController();
  const interrupt = () => interruption.abort();
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
    process.on("SIGINT", interrupt);
    process.on("SIGTERM", interrupt);
    let beforeNextPage;
    if (input.manualPages) {
      prompt = require("node:readline/promises").createInterface({
        input: process.stdin, output: process.stderr});
      prompt.on("close", interrupt);
      beforeNextPage = async () => {
        try {
          const answer = await prompt.question(
              "Enter: proxima pagina; qualquer texto: interromper. ",
              {signal: interruption.signal});
          return answer === "";
        } catch (_) { return false; }
      };
    }
    const guards = db.collection("account_deletion_guards");
    const snapshot = (doc) => doc.exists ? {id: doc.id, data: doc.data(),
      version: doc.updateTime.seconds + ":" + doc.updateTime.nanoseconds} : null;
    const report = await diagnose({...input, env,
      control: {signal: interruption.signal, beforeNextPage}, readers: {
      getGuardPage: async ({afterId, limit}) => {
        let query = guards.orderBy(FieldPath.documentId()).limit(limit);
        if (afterId !== undefined) query = query.startAfter(afterId);
        return (await query.get()).docs.map(snapshot);
      },
      getGuard: async (id) => snapshot(await guards.doc(id).get()),
      getAuthUser: async (id) => ({uid: (await auth.getUser(id)).uid}),
      getResidueExistence: (id) => readResidueExistence(db, id),
    }});
    return {exitCode: report.truncated || report.counts.inconclusive ||
      report.residues.inconclusive || report.residues.candidateChanged ? 2 : 0,
      report};
  } catch (_) {
    // No SDK error, path, UID, environment value or argument is printed.
    return {exitCode: 1, report: {status: "DIAGNOSTIC_REFUSED_OR_FAILED"}};
  } finally {
    interruption.abort();
    if (prompt) prompt.close();
    process.removeListener("SIGINT", interrupt);
    process.removeListener("SIGTERM", interrupt);
    try {
      // An expired read must not keep the CLI waiting for SDK shutdown forever.
      let timer;
      try {
        await Promise.race([(async () => {
          if (db) await db.terminate();
          if (app) await require("firebase-admin/app").deleteApp(app);
        })(), new Promise((resolve) => {timer = setTimeout(resolve, 500);})]);
      } finally {clearTimeout(timer);}
    } catch (_) { /* No diagnostic authority depends on client disposal. */ }
  }
}

if (require.main === module) {
  run().then(({exitCode, report}) => {
    process.stdout.write(JSON.stringify(report) + "\n", () => process.exit(exitCode));
  }, () => {
    process.stdout.write('{"status":"DIAGNOSTIC_REFUSED_OR_FAILED"}\n',
        () => process.exit(1));
  });
}

module.exports = {run, parseArgs, readResidueExistence};
