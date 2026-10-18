"use strict";

// Disposable local tests only. Importing this module never starts a resource.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const net = require("node:net");
const {spawn} = require("node:child_process");
const {StringDecoder} = require("node:string_decoder");
const {parseAuthMessage} = require("./retired_identity_auth_worker.cjs");
const PROJECT = "demo-life-os-d2c02r3";
const ROOT = path.resolve(__dirname, "..");
const CLEANUP_MS = 3000;
const ERROR_CODES = new Set(["EADDRINUSE", "EACCES", "EPERM", "ENOENT"]);

function category(error) {
  try { if (ERROR_CODES.has(error?.code)) return error.code; } catch (_) { /* Opaque error. */ }
  return "UNAVAILABLE";
}

// Explicit dependency seam for unit tests; no new CLI configuration surface.
async function runLauncher(io) {
  const p = io.process;
  const resources = [];
  const listeners = [];
  const timers = new Set();
  const closeTimers = new Set();
  const STOP = Symbol("stopped");
  let releaseStop;
  const stopped = new Promise((resolve) => {releaseStop = resolve;});
  let stopCode = null;
  let result = 1;
  let cleaning = false;
  let cleanupPromise;
  let cleanupFailed = false;
  const evidence = {summary: Object.create(null), r3: false, invalid: false};
  let stage = "PREFLIGHT_FAILED";
  const diagnostic = (name, reason) => io.stderr(JSON.stringify({stage: name, category: reason}) + "\n");
  const info = (value) => io.stdout(JSON.stringify(value) + "\n");
  function cleanupFailure(reason) {
    cleanupFailed = true;
    diagnostic("CLEANUP_FAILED", reason);
  }
  function stop(code, name, reason) {
    if (stopCode !== null) return;
    stopCode = code;
    diagnostic(name, reason);
    releaseStop(STOP);
  }
  function check() { if (stopCode !== null) throw STOP; }
  function on(target, event, callback) {
    target.on(event, callback);
    const remove = () => target.removeListener(event, callback);
    listeners.push(remove);
    return remove;
  }
  function timer(fn, ms, closing = false) {
    const set = closing ? closeTimers : timers;
    const id = io.setTimeout(() => {set.delete(id); fn();}, ms);
    set.add(id);
    return () => {io.clearTimeout(id); set.delete(id);};
  }
  async function wait(work) {
    const pending = Promise.resolve(work);
    pending.catch(() => {}); // A late rejected acquisition after cancellation is still observed.
    check();
    const value = await Promise.race([pending, stopped]);
    check();
    return value;
  }
  function resource(handle, kind, failureStage) {
    let finish;
    const r = {handle, kind, closed: false, exited: false,
      done: new Promise((resolve) => {finish = resolve;})};
    r.finish = () => {r.closed = true; finish();};
    resources.push(r); // Register before listen/await and possible cancellation.
    on(handle, "close", r.finish);
    on(handle, "error", (error) => {
      if (cleaning) cleanupFailure(category(error));
      else stop(1, failureStage, category(error));
    });
    return r;
  }
  async function listen(r) {
    let ready;
    const work = new Promise((resolve) => {ready = resolve;});
    const remove = on(r.handle, "listening", ready);
    try {
      check();
      r.handle.listen(0, "127.0.0.1");
      await wait(work);
      const port = r.handle.address()?.port;
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error();
      return port;
    } finally { remove(); }
  }
  async function closeOwnedResource(r) {
    if (r.closed) return;
    try {
      if (r.kind === "process") {
        if (!r.exited && r.handle.kill() === false && !r.exited) {
          cleanupFailure("TERMINATION_FAILED");
        }
      } else {
        try {r.handle.closeAllConnections?.();} catch (error) {cleanupFailure(category(error));}
        r.handle.close((error) => {
          if (!error || error.code === "ERR_SERVER_NOT_RUNNING") r.finish();
          else cleanupFailure(category(error));
        });
      }
    } catch (error) { cleanupFailure(category(error)); }
    let expire;
    const expired = new Promise((resolve) => {expire = resolve;});
    const cancel = timer(() => expire(STOP), CLEANUP_MS, true);
    try {
      if (await Promise.race([r.done, expired]) === STOP) {
        cleanupFailure("DEADLINE");
        // Release only our handles. Failure is never reported as full shutdown.
        for (const stream of [r.handle.stdout, r.handle.stderr]) {
          try {stream?.destroy();} catch (_) { /* Best effort after deadline. */ }
        }
        try {if (r.authWorker && r.handle.connected) r.handle.disconnect();} catch (_) { /* Own IPC only. */ }
        try {r.handle.unref();} catch (_) { /* Best effort after deadline. */ }
      }
    } finally { cancel(); }
  }
  function closeResource(r) {
    if (!r.closing) r.closing = closeOwnedResource(r);
    return r.closing;
  }
  function cleanup() {
    if (!cleanupPromise) {
      cleaning = true;
      for (const id of timers) io.clearTimeout(id);
      timers.clear();
      // Do not cancel deadlines belonging to a port probe already being closed.
      cleanupPromise = Promise.all(resources.map(closeResource));
    }
    return cleanupPromise;
  }
  function child(exe, args, options, failureStage) {
    check();
    const r = resource(io.spawn(exe, args, options), "process", failureStage);
    let exit;
    r.exit = new Promise((resolve) => {exit = resolve;});
    on(r.handle, "exit", (code, signal) => {
      r.exited = true;
      exit(Number.isInteger(code) && code >= 0 && code <= 255 && !signal ? code : 1);
      if (!cleaning && failureStage === "FIRESTORE_START_FAILED") {
        stop(1, "FIRESTORE_NOT_READY", r.outputCode || "EARLY_EXIT");
      }
      if (!cleaning && failureStage === "AUTH_START_FAILED") stop(1, failureStage, "EARLY_EXIT");
    });
    for (const stream of [r.handle.stdout, r.handle.stderr]) {
      on(stream, "error", (error) => {
        if (cleaning) cleanupFailure(category(error));
        else stop(1, failureStage, category(error));
      });
    }
    return r;
  }
  // Never forward arbitrary child output, errors, payloads or failing assertions.
  function testOutput(stream) {
    const decoder = new StringDecoder("utf8");
    let pending = "";
    let discarding = false;
    function lineComplete(line) {
      const match = /^# (tests|suites|pass|fail|cancelled|skipped|todo) (\d{1,9})$/.exec(line);
      if (match) {
        const value = Number(match[2]);
        evidence.summary[match[1]] = value;
        if (["fail", "cancelled"].includes(match[1]) && value !== 0) evidence.invalid = true;
        info({stage: "TEST_SUMMARY", metric: match[1], value});
      }
      const marker = line.indexOf('{"fixtures":');
      if (marker < 0 || !/^\s*# /.test(line)) return;
      try {
        const v = JSON.parse(line.slice(marker));
        const keys = ["fixtures", "boundedOperations", "adcAttempts", "unexpectedOutboundSockets"];
        if (v.project === PROJECT && keys.every((k) => Number.isSafeInteger(v[k]) && v[k] >= 0)) {
          evidence.r3 = true;
          if (v.fixtures === 0 || v.boundedOperations === 0 ||
              v.adcAttempts !== 0 || v.unexpectedOutboundSockets !== 0) evidence.invalid = true;
          info({stage: "R3_ISOLATION", project: PROJECT,
            ...Object.fromEntries(keys.map((k) => [k, v[k]]))});
        }
      } catch (_) { /* Opaque test output is deliberately discarded. */ }
    }
    on(stream, "data", (data) => {
      const text = typeof data === "string" ? data : decoder.write(data);
      let offset = 0;
      while (offset < text.length) {
        const newline = text.indexOf("\n", offset);
        const end = newline === -1 ? text.length : newline;
        if (!discarding) {
          if (pending.length + end - offset > 12000) {
            pending = "";
            discarding = true; // Remain here until this same line's LF, across chunks.
          } else pending += text.slice(offset, end);
        }
        if (newline === -1) return;
        if (!discarding) lineComplete(pending.endsWith("\r") ? pending.slice(0, -1) : pending);
        pending = "";
        discarding = false;
        offset = newline + 1;
      }
    });
  }
  try {
    for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129],
      ...(p.platform === "win32" ? [["SIGBREAK", 131]] : [])]) {
      on(p, signal, () => stop(code, "EXECUTION_INTERRUPTED", signal));
    }
    timer(() => stop(124, "TEST_TIMEOUT", "DEADLINE"), 180000);
    check();
    if (p.argv.length > 3 || (p.argv[2] && p.argv[2] !== "--all")) throw new Error();
    const javaPath = p.env.R3_JAVA_EXE || "C:/Program Files/Android/Android Studio/jbr/bin/java.exe";
    const jarPath = p.env.R3_FIRESTORE_JAR || path.join(io.homedir(),
        ".cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar");
    const authPath = path.join(p.env.R3_FIREBASE_TOOLS_DIR || path.join(io.homedir(),
        "AppData/Roaming/npm/node_modules/firebase-tools"), "lib/emulator/auth/server.js");
    for (const file of [javaPath, jarPath, authPath]) {
      check();
      if (!path.isAbsolute(file) || !io.stat(file).isFile()) throw new Error();
    }
    check();
    const runtime = io.mkdtemp(path.join(io.tmpdir(), "lifeos-r3-emulator-"));
    const safeEnv = Object.fromEntries(["PATH", "SystemRoot", "WINDIR", "TEMP", "TMP"]
        .filter((key) => p.env[key]).map((key) => [key, p.env[key]]));
    Object.assign(safeEnv, {GCLOUD_PROJECT: PROJECT, GOOGLE_CLOUD_PROJECT: PROJECT,
      FIREBASE_CLI_DISABLE_USAGE_REPORTING: "1", CI: "true",
      XDG_CONFIG_HOME: runtime, CLOUDSDK_CONFIG: runtime,
      METADATA_SERVER_DETECTION: "none", GCE_METADATA_HOST: "127.0.0.1:1"});
    for (const key of Object.keys(p.env)) if (!(key in safeEnv)) delete p.env[key];
    Object.assign(p.env, safeEnv);
    io.chdir(runtime);
    check();
    stage = "AUTH_START_FAILED";
    const auth = child(p.execPath, [path.join(__dirname, "retired_identity_auth_worker.cjs")],
        {cwd: runtime, env: {...safeEnv, R3_FIREBASE_TOOLS_DIR: path.resolve(authPath, "../../../..")},
          stdio: ["ignore", "pipe", "pipe", "ipc"], windowsHide: true}, stage);
    auth.authWorker = true;
    // Auth console/logger data is drained, never parsed or forwarded as status.
    on(auth.handle.stdout, "data", () => {});
    on(auth.handle.stderr, "data", () => {});
    let authReady;
    let admitted = false;
    const readyAuth = new Promise((resolve) => {authReady = resolve;});
    on(auth.handle, "message", (value) => {
      const message = parseAuthMessage(value);
      if (cleaning) {
        cleanupFailure(message?.category || "IPC_INVALID");
        return;
      }
      if (!message || (message.type === "AUTH_READY" && admitted)) stop(1, "AUTH_START_FAILED", "IPC_INVALID");
      else if (message.type === "AUTH_FAILED") stop(1, "AUTH_START_FAILED", message.category);
      else {admitted = true; authReady(message.port);}
    });
    on(auth.handle, "disconnect", () => {if (!cleaning) stop(1, "AUTH_START_FAILED", "IPC_DISCONNECTED");});
    const cancelAuthReady = timer(() => stop(1, "AUTH_START_FAILED", "DEADLINE"), 30000);
    let authPort;
    try {authPort = await wait(readyAuth);} finally {cancelAuthReady();}
    stage = "PORT_ALLOCATION_FAILED";
    let firestorePort;
    for (let attempt = 0; attempt < 2; attempt++) {
      check();
      const probe = resource(io.portServer(), "server", stage);
      firestorePort = await listen(probe);
      await wait(closeResource(probe));
      if (cleanupFailed) throw new Error();
      if (firestorePort !== authPort) break;
    }
    if (firestorePort === authPort) throw new Error();
    stage = "FIRESTORE_START_FAILED";
    const java = child(javaPath, ["-jar", jarPath, "--host", "127.0.0.1",
      "--port", String(firestorePort), "--project_id", PROJECT],
    {cwd: runtime, env: safeEnv, windowsHide: true}, stage);
    let ready;
    const readyPromise = new Promise((resolve) => {ready = resolve;});
    let tail = "";
    const consume = (data) => {
      tail = (tail + String(data)).slice(-12000);
      const code = /\b(EADDRINUSE|EACCES|EPERM)\b/.exec(tail);
      if (code) java.outputCode = code[1];
      if (/Dev App Server is now running|API endpoint:/.test(tail)) ready();
    };
    const removeOut = on(java.handle.stdout, "data", consume);
    const removeErr = on(java.handle.stderr, "data", consume);
    const cancelReady = timer(() => stop(1, "FIRESTORE_NOT_READY", java.outputCode || "DEADLINE"), 30000);
    try {await wait(readyPromise);} finally {cancelReady(); removeOut(); removeErr();}
    const env = {...safeEnv, FIRESTORE_EMULATOR_HOST: `127.0.0.1:${firestorePort}`,
      FIREBASE_AUTH_EMULATOR_HOST: `127.0.0.1:${authPort}`, LIFEOS_RETIRED_IDENTITY_EMULATOR_TEST: "1"};
    check();
    info({project: PROJECT, firestore: env.FIRESTORE_EMULATOR_HOST,
      auth: env.FIREBASE_AUTH_EMULATOR_HOST, node: p.version, disposable: true});
    stage = "TEST_RUNNER_FAILED";
    const args = ["--test", "--test-reporter=tap", ...(p.argv[2] === "--all" ? [] :
      ["test/retired-identity-emulator.test.js"])];
    const runner = child(p.execPath, args, {cwd: ROOT, env, windowsHide: true}, stage);
    testOutput(runner.handle.stdout);
    on(runner.handle.stderr, "data", () => {});
    result = await wait(runner.exit);
    if (result !== 0) diagnostic(stage, "EXIT_NONZERO");
  } catch (error) {
    if (error !== STOP) stop(1, stage, category(error));
  } finally {
    await cleanup();
    for (const remove of listeners) remove();
    for (const id of [...timers, ...closeTimers]) io.clearTimeout(id);
    timers.clear(); closeTimers.clear();
    info({stage: cleanupFailed ? "RESOURCES_NOT_CONFIRMED_STOPPED" : "DISPOSABLE_EMULATORS_STOPPED"});
  }
  // Check only after close/cleanup has drained stdout. Exit may precede final data.
  if (stopCode === null && result === 0 && !cleanupFailed) {
    const s = evidence.summary;
    if (!evidence.r3 || !(s.tests > 0 && s.pass > 0) || s.fail !== 0 || s.cancelled !== 0 || evidence.invalid) {
      result = 1;
      diagnostic("TEST_RUNNER_FAILED", evidence.invalid ? "R3_EVIDENCE_INVALID" : "R3_EVIDENCE_MISSING");
    }
  }
  return stopCode ?? (result === 0 && cleanupFailed ? 1 : result);
}

if (require.main === module) {
  runLauncher({process, stat: fs.statSync, mkdtemp: fs.mkdtempSync,
    homedir: os.homedir, tmpdir: os.tmpdir, chdir: process.chdir,
    portServer: () => net.createServer(), spawn, setTimeout, clearTimeout,
    stdout: (text) => process.stdout.write(text), stderr: (text) => process.stderr.write(text),
  }).then((code) => {process.exitCode = code;}, () => {
    process.stderr.write('{"stage":"CLEANUP_FAILED","category":"UNAVAILABLE"}\n');
    process.exitCode = 1;
  });
}
module.exports = {runLauncher};
