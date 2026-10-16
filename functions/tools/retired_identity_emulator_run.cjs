"use strict";

// Disposable local tests only. No Firebase CLI login, downloads or production mode.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const net = require("node:net");
const {spawn} = require("node:child_process");
const {once} = require("node:events");
const PROJECT = "demo-life-os-d2c02r3";
const ROOT = path.resolve(__dirname, "..");

async function unusedPort() {
  const server = net.createServer();
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function main() {
  if (process.argv.length > 3 || (process.argv[2] && process.argv[2] !== "--all")) {
    throw new Error("ONLY_LOCAL_TEST_MODE_ALLOWED");
  }
  const javaPath = process.env.R3_JAVA_EXE ||
    "C:/Program Files/Android/Android Studio/jbr/bin/java.exe";
  const jarPath = process.env.R3_FIRESTORE_JAR || path.join(os.homedir(),
      ".cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar");
  const toolsPath = process.env.R3_FIREBASE_TOOLS_DIR || path.join(os.homedir(),
      "AppData/Roaming/npm/node_modules/firebase-tools");
  const authPath = path.join(toolsPath, "lib/emulator/auth/server.js");
  for (const file of [javaPath, jarPath, authPath]) {
    if (!path.isAbsolute(file) || !fs.statSync(file).isFile()) {
      throw new Error("EXISTING_LOCAL_EMULATOR_REQUIRED");
    }
  }
  const runtime = fs.mkdtempSync(path.join(os.tmpdir(), "lifeos-r3-emulator-"));
  const safeEnv = Object.fromEntries(["PATH", "SystemRoot", "WINDIR", "TEMP", "TMP"]
      .filter((key) => process.env[key]).map((key) => [key, process.env[key]]));
  Object.assign(safeEnv, {GCLOUD_PROJECT: PROJECT, GOOGLE_CLOUD_PROJECT: PROJECT,
    FIREBASE_CLI_DISABLE_USAGE_REPORTING: "1", CI: "true",
    XDG_CONFIG_HOME: runtime, CLOUDSDK_CONFIG: runtime,
    METADATA_SERVER_DETECTION: "none", GCE_METADATA_HOST: "127.0.0.1:1"});
  for (const key of Object.keys(process.env)) {
    if (!(key in safeEnv)) delete process.env[key];
  }
  Object.assign(process.env, safeEnv);
  process.chdir(runtime);
  const {createApp} = require(authPath);
  // Start the installed Auth emulator directly: no CLI dispatcher/credential lookup.
  const authApp = await createApp(PROJECT, 0);
  const authServer = authApp.listen(0, "127.0.0.1");
  await once(authServer, "listening");
  const authPort = authServer.address().port;
  let firestorePort = await unusedPort();
  if (firestorePort === authPort) firestorePort = await unusedPort();
  const java = spawn(javaPath, ["-jar", jarPath, "--host", "127.0.0.1",
    "--port", String(firestorePort), "--project_id", PROJECT],
  {cwd: runtime, env: safeEnv, windowsHide: true});
  let child;
  const deadline = setTimeout(() => {
    if (child) child.kill();
    java.kill(); authServer.closeAllConnections(); authServer.close();
    process.exitCode = 124;
  }, 180000);
  try {
    await new Promise((resolve, reject) => {
      let tail = "";
      const timeout = setTimeout(() => reject(new Error("EMULATOR_START_TIMEOUT")), 30000);
      const consume = (data) => {
        tail = (tail + data).slice(-12000);
        if (/Dev App Server is now running|API endpoint:/.test(tail)) {
          clearTimeout(timeout); resolve();
        }
      };
      java.stdout.on("data", consume); java.stderr.on("data", consume);
      java.once("error", () => {clearTimeout(timeout); reject(new Error("EMULATOR_START_FAILED"));});
      java.once("exit", () => {clearTimeout(timeout); reject(new Error("EMULATOR_EARLY_EXIT"));});
    });
    const env = {...safeEnv, FIRESTORE_EMULATOR_HOST: `127.0.0.1:${firestorePort}`,
      FIREBASE_AUTH_EMULATOR_HOST: `127.0.0.1:${authPort}`,
      LIFEOS_RETIRED_IDENTITY_EMULATOR_TEST: "1"};
    console.log(JSON.stringify({project: PROJECT, firestore: env.FIRESTORE_EMULATOR_HOST,
      auth: env.FIREBASE_AUTH_EMULATOR_HOST, node: process.version, disposable: true}));
    const args = ["--test", "--test-reporter=tap", ...(process.argv[2] === "--all" ? [] :
      ["test/retired-identity-emulator.test.js"])];
    child = spawn(process.execPath, args, {cwd: ROOT, env, windowsHide: true});
    child.stdout.pipe(process.stdout); child.stderr.pipe(process.stderr);
    process.exitCode = await new Promise((resolve, reject) => {
      child.once("exit", (code) => resolve(code ?? 1)); child.once("error", reject);
    });
  } finally {
    clearTimeout(deadline);
    if (child && child.exitCode === null) child.kill();
    authServer.closeAllConnections();
    await new Promise((resolve) => authServer.close(resolve));
    java.kill();
    if (java.exitCode === null && java.signalCode === null) await once(java, "exit");
    console.log("DISPOSABLE_EMULATORS_STOPPED");
  }
}
main().catch(() => {console.error("LOCAL_EMULATOR_RUN_REFUSED_OR_FAILED"); process.exitCode = 1;});
