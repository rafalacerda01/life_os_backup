"use strict";

// Mocks except one synthetic Node child proving the stdout/stderr process boundary.
// No real sockets, Java, emulators or Firebase services.
const test = require("node:test");
const assert = require("node:assert/strict");
const {EventEmitter} = require("node:events");
const {runLauncher} = require("../tools/retired_identity_emulator_run.cjs");
const PRIVATE = "secret-token private-key private@example.invalid /private/path";
const PROJECT = "demo-life-os-d2c02r3";
const flush = async () => {for (let i = 0; i < 50; i++) await Promise.resolve();};
const error = (code = "EACCES") => Object.assign(new Error(PRIVATE), {code});

function fixture(options = {}) {
  const state = {servers: [], children: [], timers: new Map(), out: [], err: [], now: 0,
    authLoads: 0, temporary: 0, portCalls: 0};
  let serial = 0;
  const p = new EventEmitter();
  Object.assign(p, {platform: "win32", version: "v24.17.0", execPath: "C:/test/node.exe",
    argv: ["node", "launcher", ...(options.args || [])], env: {PATH: "test-path",
      GOOGLE_APPLICATION_CREDENTIALS: PRIVATE, FIREBASE_TOKEN: PRIVATE,
      HTTPS_PROXY: PRIVATE, NODE_OPTIONS: PRIVATE, FIREBASE_CONFIG: PRIVATE}});
  const externalSignalListener = () => {};
  p.on("SIGINT", externalSignalListener);
  state.process = p;
  class Server extends EventEmitter {
    constructor(kind) {super(); this.kind = kind; this.closes = 0; this.unrefs = 0;
      this.port = kind === "auth" || options.samePort ? 4001 : 4002; state.servers.push(this);}
    listen(port, host) {
      assert.equal(port, 0); assert.equal(host, "127.0.0.1");
      queueMicrotask(() => {
        if (this.closed) return;
        if (options.interruptAt === this.kind) p.emit("SIGINT");
        else if (options.listenFailure === this.kind) this.emit("error", error());
        else this.emit("listening");
      });
      return this;
    }
    address() {return {port: this.port};}
    closeAllConnections() {
      if (options.connectionCloseFailure === this.kind) throw error("EPERM");
      this.connectionsClosed = true;
    }
    close(callback) {
      this.closes++;
      if (options.closeThrow === this.kind) throw error("EPERM");
      if (options.closeHang === this.kind) return;
      if (options.closeError === this.kind) {callback(error("EPERM")); return;}
      this.closed = true; this.emit("close"); callback();
    }
    unref() {this.unrefs++;}
  }
  class Child extends EventEmitter {
    constructor(kind) {
      super(); this.kind = kind; this.kills = 0; this.unrefs = 0;
      this.connected = kind === "auth-worker";
      this.stdout = new EventEmitter(); this.stderr = new EventEmitter();
      this.stdout.destroy = this.stderr.destroy = () => {};
      state.children.push(this);
    }
    finish(code = 0, signal = null) {
      this.ended = true;
      // A successful simulated runner normally supplies the R3 evidence footer.
      if (this.kind === "runner" && code === 0 && !signal && options.autoEvidence !== false) {
        this.stdout.emit("data", SUMMARY + R3_LINE);
      }
      this.emit("exit", code, signal); this.emit("close", code, signal);
    }
    kill() {
      this.kills++;
      if (options.killThrow === this.kind) throw error("EPERM");
      if (options.stubborn === this.kind) return false;
      if (options.noClose === this.kind) {this.emit("exit", null, "SIGTERM"); return true;}
      if (this.kind === "auth-worker" && this.authServer) {
        const server = this.authServer;
        server.removeAllListeners();
        try {server.closeAllConnections();} catch (e) {this.emit("error", e);}
        try {server.close((e) => {
          if (e) this.emit("error", e);
          else {server.removeAllListeners(); this.finish(null, "SIGTERM");}
        });} catch (e) {this.emit("error", e);}
        return true;
      }
      this.finish(null, "SIGTERM"); return true;
    }
    disconnect() {this.connected = false; this.emit("disconnect");}
    unref() {this.unrefs++;}
  }
  const io = {process: p, homedir: () => "C:/test/home", tmpdir: () => "C:/test/tmp",
    stat: () => {
      if (options.interruptAt === "preflight") p.emit("SIGINT");
      if (options.preflightFailure) throw error("ENOENT");
      return {isFile: () => true};
    },
    mkdtemp: () => {state.temporary++; return "C:/test/tmp/lifeos-r3-emulator-owned";},
    chdir: () => {},
    loadAuth: () => {
      state.authLoads++;
      return {createApp: async (project, mode) => {
        assert.equal(project, PROJECT); assert.equal(mode, 0);
        if (options.authFailure) throw error("EPERM");
        if (options.interruptAt === "app") {p.emit("SIGINT"); throw error();}
        return {};
      }};
    },
    authServer: () => new Server("auth"),
    portServer: () => {
      state.portCalls++;
      if (options.portFailure) throw error("EPERM");
      return new Server("probe");
    },
    spawn: (exe, args, config) => {
      assert.equal(config.windowsHide, true);
      assert.equal(config.env.GCLOUD_PROJECT, PROJECT);
      assert.equal(config.env.GOOGLE_APPLICATION_CREDENTIALS, undefined);
      assert.equal(config.env.FIREBASE_TOKEN, undefined);
      assert.equal(config.env.NODE_OPTIONS, undefined);
      const kind = args[0] === "-jar" ? "java" :
        args[0].endsWith("retired_identity_auth_worker.cjs") ? "auth-worker" : "runner";
      if (options.spawnThrow === kind) throw error();
      const child = new Child(kind); child.exe = exe; child.args = args; child.config = config;
      queueMicrotask(async () => {
        if (options.spawnFailure === kind) {child.emit("error", error()); child.emit("close");}
        else if (options.interruptAt === kind) p.emit("SIGINT");
        else if (kind === "auth-worker") {
          assert.deepEqual(config.stdio, ["ignore", "pipe", "pipe", "ipc"]);
          try {
            // Simulate the dependency in-process only in this fake worker.
            const app = await io.loadAuth().createApp(PROJECT, 0);
            if (child.ended) return;
            const server = io.authServer(app); child.authServer = server;
            server.on("error", (e) => child.emit("message", {version: 1, type: "AUTH_FAILED", category: e.code}));
            server.once("listening", () => {
              if (!options.workerSilent) child.emit("message", Object.hasOwn(options, "authMessage") ?
                options.authMessage : {version: 1, type: "AUTH_READY",
                  project: PROJECT, host: "127.0.0.1", port: server.address().port});
            });
            server.listen(0, "127.0.0.1");
          } catch (e) {
            if (!child.ended) child.emit("message", {version: 1, type: "AUTH_FAILED", category: e.code});
          }
        } else if (kind === "java") {
          if (options.earlyJava) {
            child.stderr.emit("data", PRIVATE + " EADDRINUSE\n"); child.finish(1);
          } else if (!options.notReady) child.stdout.emit("data", "API endpoint:\n");
        }
      });
      return child;
    },
    setTimeout: (fn, ms) => {const id = ++serial; state.timers.set(id, {fn, at: state.now + ms}); return id;},
    clearTimeout: (id) => state.timers.delete(id),
    stdout: (v) => state.out.push(v), stderr: (v) => state.err.push(v)};
  state.io = io;
  state.run = () => {state.work = runLauncher(io); return state.work;};
  state.advance = async (ms) => {
    const end = state.now + ms;
    for (;;) {
      const next = [...state.timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      state.now = next[1].at; state.timers.delete(next[0]); next[1].fn(); await flush();
    }
    state.now = end; await flush();
  };
  state.runner = () => state.children.find((c) => c.kind === "runner");
  state.authWorker = () => state.children.find((c) => c.kind === "auth-worker");
  state.java = () => state.children.find((c) => c.kind === "java");
  state.assertReleased = () => {
    assert.equal(state.timers.size, 0);
    assert.equal(p.listenerCount("SIGINT"), 1); // Unrelated listener is preserved.
    for (const signal of ["SIGTERM", "SIGHUP", "SIGBREAK"]) assert.equal(p.listenerCount(signal), 0);
    for (const r of [...state.servers, ...state.children]) {
      assert.deepEqual(r.eventNames(), []);
      if (r.kind === "auth" || r.kind === "probe") assert.equal(r.closes, 1);
      else {
        assert.ok(r.kills <= 1);
        assert.deepEqual(r.stdout.eventNames(), []); assert.deepEqual(r.stderr.eventNames(), []);
      }
    }
    assert.equal([...state.out, ...state.err].join("").includes(PRIVATE), false);
  };
  return state;
}

test("launcher import is inert and exposes only its unit-test seam", () => {
  assert.deepEqual(Object.keys(require("../tools/retired_identity_emulator_run.cjs")), ["runLauncher"]);
});

for (const [name, options, stage] of [
  ["preflight before Auth", {preflightFailure: true}, "PREFLIGHT_FAILED"],
  ["Auth app initialization", {authFailure: true}, "AUTH_START_FAILED"],
  ["Auth bind", {listenFailure: "auth"}, "AUTH_START_FAILED"],
  ["after Auth before port allocation", {portFailure: true}, "PORT_ALLOCATION_FAILED"],
  ["port bind", {listenFailure: "probe"}, "PORT_ALLOCATION_FAILED"],
  ["synchronous Java spawn", {spawnThrow: "java"}, "FIRESTORE_START_FAILED"],
  ["asynchronous Java spawn", {spawnFailure: "java"}, "FIRESTORE_START_FAILED"],
  ["premature Java exit", {earlyJava: true}, "FIRESTORE_NOT_READY"],
  ["test runner spawn", {spawnFailure: "runner"}, "TEST_RUNNER_FAILED"],
]) test(`launcher failure: ${name}`, async () => {
  const f = fixture(options); assert.equal(await f.run(), 1);
  assert.ok(f.err.some((v) => JSON.parse(v).stage === stage)); f.assertReleased();
});

for (const point of ["preflight", "app", "auth", "probe", "java", "runner"]) {
  test(`interruption during ${point} stops subsequent stages`, async () => {
    const f = fixture({interruptAt: point}); assert.equal(await f.run(), 130);
    if (["preflight", "app", "auth", "probe"].includes(point)) {
      assert.equal(f.java(), undefined); assert.equal(f.runner(), undefined);
    }
    if (point === "preflight") assert.equal(f.authLoads, 0);
    if (point === "preflight") assert.equal(f.temporary, 0);
    f.assertReleased();
  });
}

test("timeout stays 124 after a child exits zero and repeated interruption", async () => {
  const f = fixture(); f.run(); await flush(); assert.ok(f.runner());
  // A synchronous exit during kill would previously overwrite the timeout.
  f.runner().kill = function() {this.kills++; this.finish(0); return true;};
  await f.advance(180000); f.process.emit("SIGINT");
  assert.equal(await f.work, 124); f.assertReleased();
});

test("Firestore readiness deadline is bounded and sanitized", async () => {
  const f = fixture({notReady: true}); f.run(); await flush(); await f.advance(30000);
  assert.equal(await f.work, 1); assert.equal(f.runner(), undefined); f.assertReleased();
});

for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129], ["SIGBREAK", 131]]) {
  test(`controlled ${signal} and repeated cancellation have one cleanup`, async () => {
    const f = fixture(); f.run(); await flush();
    f.process.emit(signal); f.process.emit(signal); f.process.emit("SIGINT");
    assert.equal(await f.work, code);
    assert.equal(f.err.filter((v) => JSON.parse(v).stage === "EXECUTION_INTERRUPTED").length, 1);
    f.assertReleased();
  });
}

for (const options of [{closeThrow: "auth"}, {closeError: "auth"}, {closeHang: "auth"},
  {connectionCloseFailure: "auth"},
  {stubborn: "java"}, {killThrow: "java"}, {noClose: "java"}]) {
  test(`cleanup failure is bounded and cannot publish success: ${JSON.stringify(options)}`, async () => {
    const f = fixture(options); f.run(); await flush(); f.runner().finish(0); await flush();
    await f.advance(3000); assert.equal(await f.work, 1);
    assert.ok(f.err.some((v) => JSON.parse(v).stage === "CLEANUP_FAILED"));
    assert.equal(JSON.parse(f.out.at(-1)).stage, "RESOURCES_NOT_CONFIRMED_STOPPED"); f.assertReleased();
  });
}

test("cancellation while port close is pending keeps its cleanup deadline", async () => {
  const f = fixture({closeHang: "probe"}); f.run(); await flush();
  f.process.emit("SIGINT"); await flush(); await f.advance(3000);
  assert.equal(await f.work, 130); assert.equal(f.java(), undefined); f.assertReleased();
});

test("nonzero test status is preserved", async () => {
  const f = fixture(); f.run(); await flush(); f.runner().finish(17);
  assert.equal(await f.work, 17); f.assertReleased();
});

test("timeout remains primary even if cleanup also fails", async () => {
  const f = fixture({stubborn: "java"}); f.run(); await flush();
  await f.advance(180000); await f.advance(3000);
  assert.equal(await f.work, 124); f.assertReleased();
});

test("late Auth acquisition after cancellation cannot start a server", async () => {
  const f = fixture(); let complete;
  f.io.loadAuth = () => ({createApp: () => new Promise((resolve) => {complete = resolve;})});
  f.run(); await flush(); f.process.emit("SIGINT");
  assert.equal(await f.work, 130); complete({}); await flush();
  assert.equal(f.servers.length, 0); assert.equal(f.java(), undefined); f.assertReleased();
  assert.equal(f.runner(), undefined);
});

test("runner exit due to signal cannot become success", async () => {
  const f = fixture(); f.run(); await flush(); f.runner().finish(null, "SIGTERM");
  assert.equal(await f.work, 1); f.assertReleased();
});

test("a Java failure after readiness aborts the pending runner", async () => {
  const f = fixture(); f.run(); await flush(); f.java().finish(9);
  assert.equal(await f.work, 1); assert.equal(f.runner().kills, 1); f.assertReleased();
});

function javaDiagnostic(f) {
  const values = f.err.map((line) => JSON.parse(line)).filter((v) => v.stage === "JAVA_EXIT");
  assert.equal(values.length, 1);
  assert.deepEqual(Object.keys(values[0]).sort(),
      ["stage", "category", "exitCode", "windowsStatusHex", "signal", "closeObserved"].sort());
  return values[0];
}

for (const [code, hex] of [[0, null], [17, null], [-1073741819, "0xC0000005"],
  [3221225477, "0xC0000005"], [4294967295, "0xFFFFFFFF"]]) {
  test(`Java diagnostic preserves original exit code ${code}`, async () => {
    const f = fixture({notReady: true}); f.run(); await flush(); f.java().finish(code);
    assert.equal(await f.work, 1);
    assert.deepEqual(javaDiagnostic(f), {stage: "JAVA_EXIT", category: "JAVA_UNKNOWN",
      exitCode: code, windowsStatusHex: hex, signal: null, closeObserved: true});
    assert.equal(f.runner(), undefined); f.assertReleased();
  });
}

test("Java diagnostic rejects unsafe or arbitrary exit codes and signals", async () => {
  for (const code of [PRIVATE, NaN, Infinity, -2147483649, 4294967296, null]) {
    const f = fixture({notReady: true}); f.run(); await flush(); f.java().finish(code, PRIVATE);
    assert.equal(await f.work, 1);
    const value = javaDiagnostic(f);
    assert.equal(value.exitCode, null); assert.equal(value.windowsStatusHex, null);
    assert.equal(value.signal, "UNKNOWN"); f.assertReleased();
  }
});

for (const [text, category] of [
  ["Unrecognized VM option", "JAVA_INVALID_ARGUMENT"],
  ["java.lang.UnsupportedClassVersionError", "JAVA_CLASS_VERSION"],
  ["Invalid or corrupt jarfile", "JAVA_JAR_INVALID"],
  ["java.nio.file.AccessDeniedException", "JAVA_ACCESS_DENIED"],
  ["java.net.BindException: Address already in use", "JAVA_PORT_FAILURE"],
  ["java.lang.UnsatisfiedLinkError", "JAVA_LINKAGE"],
  ["unclassified failure", "JAVA_UNKNOWN"],
]) test(`Java final pipe data is sanitized and classified as ${category}`, async () => {
  const f = fixture({notReady: true}); f.run(); await flush(); const java = f.java();
  const split = Math.floor(text.length / 2);
  java.stderr.emit("data", PRIVATE + "\n" + text.slice(0, split));
  java.emit("exit", 9, null); await flush();
  assert.equal(f.err.some((line) => JSON.parse(line).stage === "JAVA_EXIT"), false);
  java.stderr.emit("data", text.slice(split) + " " + PRIVATE);
  java.emit("close", 9, null);
  assert.equal(await f.work, 1);
  assert.equal(javaDiagnostic(f).category, category); assert.equal(java.kills, 0);
  assert.equal(f.runner(), undefined); f.assertReleased();
});

test("Java category precedence is deterministic across stdout and stderr", async () => {
  const f = fixture({notReady: true}); f.run(); await flush();
  f.java().stdout.emit("data", "NoClassDefFoundError " + PRIVATE);
  f.java().emit("exit", 2, null); await flush();
  f.java().stderr.emit("data", "UnsupportedClassVersionError " + PRIVATE);
  f.java().emit("close", 2, null);
  assert.equal(await f.work, 1); assert.equal(javaDiagnostic(f).category, "JAVA_CLASS_VERSION");
  f.assertReleased();
});

test("Java does not join error fragments from different streams", async () => {
  const f = fixture({notReady: true}); f.run(); await flush();
  f.java().stdout.emit("data", "Unrecognized ");
  f.java().stderr.emit("data", "VM option " + PRIVATE); f.java().finish(1);
  assert.equal(await f.work, 1); assert.equal(javaDiagnostic(f).category, "JAVA_UNKNOWN");
  f.assertReleased();
});

test("Java close deadline reuses bounded cleanup and never confirms missing close", async () => {
  const f = fixture({notReady: true}); f.run(); await flush();
  let settled = false; f.work.then(() => {settled = true;});
  f.java().emit("exit", 3221225477, null); await flush();
  f.java().stderr.emit("data", PRIVATE + " AccessDeniedException");
  await f.advance(2999); assert.equal(settled, false);
  await f.advance(1); assert.equal(await f.work, 1);
  assert.deepEqual(javaDiagnostic(f), {stage: "JAVA_EXIT", category: "JAVA_ACCESS_DENIED",
    exitCode: 3221225477, windowsStatusHex: "0xC0000005", signal: null, closeObserved: false});
  assert.equal(JSON.parse(f.out.at(-1)).stage, "RESOURCES_NOT_CONFIRMED_STOPPED");
  assert.ok(f.err.some((line) => JSON.parse(line).stage === "CLEANUP_FAILED"));
  assert.equal(f.java().kills, 0); assert.equal(f.java().unrefs, 1); f.assertReleased();
});

test("Java readiness received after exit cannot start the runner or publish success", async () => {
  const f = fixture({notReady: true}); f.run(); await flush();
  f.java().emit("exit", 0, null);
  f.java().stdout.emit("data", "API endpoint:\nDev App Server is now running.\n");
  await flush(); assert.equal(f.runner(), undefined); f.java().emit("close", 0, null);
  assert.equal(await f.work, 1); assert.equal(javaDiagnostic(f).exitCode, 0);
  assert.equal(f.out.some((line) => JSON.parse(line).disposable), false); f.assertReleased();
});

test("Java final output after readiness still diagnoses failure and cleans up the runner", async () => {
  const f = fixture(); f.run(); await flush(); f.java().emit("exit", 5, null); await flush();
  f.java().stderr.emit("data", "NoSuchMethodError " + PRIVATE); f.java().emit("close", 5, null);
  assert.equal(await f.work, 1); assert.equal(javaDiagnostic(f).category, "JAVA_LINKAGE");
  assert.equal(f.runner().kills, 1); f.assertReleased();
});

for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129], ["SIGBREAK", 131]]) {
  test(`Java final diagnostic cannot override earlier ${signal}`, async () => {
    const f = fixture({notReady: true}); f.run(); await flush();
    f.process.emit(signal); f.java().emit("exit", 7, signal); await flush();
    f.java().stderr.emit("data", "UnsupportedClassVersionError " + PRIVATE);
    f.java().emit("close", 7, signal);
    assert.equal(await f.work, code); assert.equal(javaDiagnostic(f).signal, signal);
    assert.equal(JSON.parse(f.err[0]).stage, "EXECUTION_INTERRUPTED"); f.assertReleased();
  });
}

test("Java drain preserves the first failure when interrupted waiting for close", async () => {
  const f = fixture({notReady: true}); f.run(); await flush(); f.java().emit("exit", 3, null);
  await flush(); f.process.emit("SIGINT"); f.java().emit("close", 3, null);
  assert.equal(await f.work, 1); assert.equal(javaDiagnostic(f).exitCode, 3); f.assertReleased();
});

test("Java output during timeout cleanup cannot change 124 or create an unexpected-exit diagnostic", async () => {
  const f = fixture(); f.run(); await flush();
  f.java().kill = function() {
    this.kills++; this.stderr.emit("data", "UnsupportedClassVersionError " + PRIVATE);
    this.finish(7); return true;
  };
  await f.advance(180000); assert.equal(await f.work, 124);
  assert.equal(f.err.some((line) => JSON.parse(line).stage === "JAVA_EXIT"), false); f.assertReleased();
});

async function classifyJavaChunks(stdout, stderr, afterExit = false) {
  const f = fixture({notReady: true}); f.run(); await flush();
  if (afterExit) {f.java().emit("exit", 3221225477, null); await flush();}
  for (const chunk of stdout) f.java().stdout.emit("data", chunk);
  for (const chunk of stderr) f.java().stderr.emit("data", chunk);
  if (afterExit) f.java().emit("close", 3221225477, null);
  else f.java().finish(3221225477);
  assert.equal(await f.work, 1); assert.equal(f.runner(), undefined);
  const diagnostic = javaDiagnostic(f); f.assertReleased(); return diagnostic;
}

const JAVA_LONG_TRANSCRIPT = PRIVATE + "\nUnsupportedClassVersionError\n" + "x".repeat(13001);

test("JAVA-FIX1 recognizes an error before a 13001-character suffix in one chunk", async () => {
  assert.equal((await classifyJavaChunks([], [JAVA_LONG_TRANSCRIPT])).category, "JAVA_CLASS_VERSION");
});

test("JAVA-FIX1 the same transcript has identical diagnostics across chunk sizes", async () => {
  for (const size of [1, 7, 257, 4096, 8192, 20000]) {
    const chunks = [];
    for (let offset = 0; offset < JAVA_LONG_TRANSCRIPT.length; offset += size) {
      chunks.push(JAVA_LONG_TRANSCRIPT.slice(offset, offset + size));
    }
    for (const input of [chunks, chunks.map((chunk) => Buffer.from(chunk))]) {
      assert.deepEqual(await classifyJavaChunks([], input), {stage: "JAVA_EXIT", category: "JAVA_CLASS_VERSION",
        exitCode: 3221225477, windowsStatusHex: "0xC0000005", signal: null, closeObserved: true});
    }
  }
});

test("JAVA-FIX1 recognizes a signature split at every chunk boundary", async () => {
  const signature = "UnsupportedClassVersionError";
  for (let split = 1; split < signature.length; split++) {
    const value = await classifyJavaChunks([], [PRIVATE + "\n" + signature.slice(0, split),
      signature.slice(split) + "\n" + "x".repeat(13001)]);
    assert.equal(value.category, "JAVA_CLASS_VERSION");
  }
});

test("JAVA-FIX1 recognizes signatures crossing internal bounded-segment boundaries", async () => {
  for (const start of [4095, 4083, 4069, 8185]) {
    const text = " ".repeat(start) + "UnsupportedClassVersionError\n" + "x".repeat(13001) + PRIVATE;
    assert.equal((await classifyJavaChunks([text], [])).category, "JAVA_CLASS_VERSION");
  }
});

test("JAVA-FIX1 processes the complete final data between exit and close", async () => {
  assert.equal((await classifyJavaChunks([], [JAVA_LONG_TRANSCRIPT], true)).category, "JAVA_CLASS_VERSION");
});

test("JAVA-FIX1 extensive separate streams preserve precedence without joining signatures", async () => {
  const linkage = "NoSuchMethodError\n" + "x".repeat(13001);
  for (const [stdout, stderr] of [[[linkage], [JAVA_LONG_TRANSCRIPT]], [[JAVA_LONG_TRANSCRIPT], [linkage]]]) {
    assert.equal((await classifyJavaChunks(stdout, stderr)).category, "JAVA_CLASS_VERSION");
  }
  const stdout = " ".repeat(13001) + "UnsupportedClass";
  const stderr = "VersionError\n" + "x".repeat(13001);
  assert.equal((await classifyJavaChunks([stdout], [stderr])).category, "JAVA_UNKNOWN");
});

test("JAVA-FIX1 extensive private output without a signature remains unknown", async () => {
  const text = (PRIVATE + "\n").repeat(20000);
  assert.equal((await classifyJavaChunks([Buffer.from(text)], [text], true)).category, "JAVA_UNKNOWN");
});

test("JAVA-FIX1 word boundaries do not depend on chunks or discarded prefix", async () => {
  const token = "UnsupportedClassVersionError";
  for (const [stdout, stderr] of [[[], [token + "X"]], [[], [token, "X"]],
    [[], [" ".repeat(4096 - token.length) + token + "X"]],
    [[" ".repeat(4096 - 129) + "X" + token + " ".repeat(128 - token.length), "suffix"], []]]) {
    assert.equal((await classifyJavaChunks(stdout, stderr)).category, "JAVA_UNKNOWN");
  }
  assert.equal((await classifyJavaChunks([], [token])).category, "JAVA_CLASS_VERSION");
});

test("JAVA-FIX1 extensive output during timeout and signal cleanup creates no Java diagnostic", async () => {
  for (const reason of ["timeout", "SIGINT", "SIGTERM", "SIGHUP", "SIGBREAK"]) {
    const f = fixture(); f.run(); await flush();
    f.java().kill = function() {
      this.kills++; this.stderr.emit("data", JAVA_LONG_TRANSCRIPT); this.finish(7); return true;
    };
    if (reason === "timeout") await f.advance(180000);
    else f.process.emit(reason);
    const expected = {timeout: 124, SIGINT: 130, SIGTERM: 143, SIGHUP: 129, SIGBREAK: 131}[reason];
    assert.equal(await f.work, expected);
    assert.equal(f.err.some((line) => JSON.parse(line).stage === "JAVA_EXIT"), false); f.assertReleased();
  }
});

for (const code of ["EADDRINUSE", "EACCES", "EPERM", "ENOENT", PRIVATE]) {
  test(`error category uses only the closed allowlist: ${code === PRIVATE ? "opaque" : code}`, async () => {
    const f = fixture(); f.io.stat = () => {throw error(code);};
    assert.equal(await f.run(), 1);
    assert.equal(JSON.parse(f.err[0]).category, code === PRIVATE ? "UNAVAILABLE" : code);
    f.assertReleased();
  });
}

test("only owned resources are touched; terminal summary never leaks child output", async () => {
  const unrelated = {kill() {assert.fail("EXTERNAL_PROCESS_MUST_NOT_BE_KILLED");}};
  const f = fixture(); f.run(); await flush(); const runner = f.runner();
  assert.ok(unrelated); runner.stdout.emit("data", PRIVATE + "\n# pass 25\n");
  runner.stderr.emit("data", PRIVATE);
  runner.stdout.emit("data", '# {"fixtures":24,"boundedOperations":457,"adcAttempts":0,"unexpectedOutboundSockets":0,"project":"' + PROJECT + '","secret":"' + PRIVATE + '"}\n');
  runner.finish(0); assert.equal(await f.work, 0);
  assert.ok(f.out.some((v) => JSON.parse(v).metric === "pass"));
  assert.ok(f.out.some((v) => JSON.parse(v).stage === "R3_ISOLATION")); f.assertReleased();
});

test("default and --all keep the fixed project, environment and test discovery", async () => {
  for (const args of [[], ["--all"]]) {
    const f = fixture({args}); f.run(); await flush(); const runner = f.runner();
    assert.deepEqual(runner.args, ["--test", "--test-reporter=tap", ...(args.length ? [] : ["test/retired-identity-emulator.test.js"])]);
    assert.equal(runner.exe, f.process.execPath);
    assert.match(runner.config.env.FIRESTORE_EMULATOR_HOST, /^127\.0\.0\.1:\d+$/);
    assert.notEqual(runner.config.env.FIRESTORE_EMULATOR_HOST, runner.config.env.FIREBASE_AUTH_EMULATOR_HOST);
    const java = f.java(); assert.equal(java.args.at(-1), PROJECT);
    assert.equal(java.args[java.args.indexOf("--host") + 1], "127.0.0.1");
    runner.finish(0); assert.equal(await f.work, 0); f.assertReleased();
  }
});

test("a real project argument is refused before acquiring resources", async () => {
  const f = fixture({args: ["--project", "life-os-27b92"]});
  assert.equal(await f.run(), 1); assert.equal(f.authLoads, 0); assert.equal(f.temporary, 0); f.assertReleased();
});

test("repeated equal ports fail closed after two probes", async () => {
  const f = fixture({samePort: true}); assert.equal(await f.run(), 1);
  assert.equal(f.portCalls, 2); assert.equal(f.java(), undefined); f.assertReleased();
});

const R3_LINE = '# {"fixtures":24,"boundedOperations":457,"adcAttempts":0,"unexpectedOutboundSockets":0,"project":"' + PROJECT + '"}\n';
const SUMMARY = "# tests 25\n# pass 25\n# fail 0\n# cancelled 0\n";
const EXPECTED_INDICATORS = [
  ...[["tests", 25], ["pass", 25], ["fail", 0], ["cancelled", 0]].map(([metric, value]) =>
    ({stage: "TEST_SUMMARY", metric, value})),
  {stage: "R3_ISOLATION", project: PROJECT, fixtures: 24, boundedOperations: 457,
    adcAttempts: 0, unexpectedOutboundSockets: 0},
  {stage: "TEST_SUMMARY", metric: "skipped", value: 0},
];
function fragments(text, size) {
  const values = [];
  for (let i = 0; i < text.length; i += size) values.push(text.slice(i, i + size));
  return values;
}
async function render(chunks) {
  const f = fixture({autoEvidence: false}); f.run(); await flush();
  for (const chunk of chunks) f.runner().stdout.emit("data", chunk);
  const indicators = f.out.map((v) => JSON.parse(v)).filter((v) =>
    ["TEST_SUMMARY", "R3_ISOLATION"].includes(v.stage));
  f.runner().finish(0); const code = await f.work; f.assertReleased();
  return {indicators, code};
}
const noise = ("# ignored " + PRIVATE + "\n").repeat(400).slice(0, 20000) + "\n";
const transcript = SUMMARY + R3_LINE + noise + "# skipped 0\n";

test("FIX1 preserves all indicators in a single approximately 20 KB chunk", async () => {
  assert.ok(transcript.length > 20000 && transcript.length < 21000);
  assert.deepEqual((await render([transcript])).indicators, EXPECTED_INDICATORS);
});
test("FIX1 identical transcript produces identical indicators across fragmentations", async () => {
  for (const size of [1, 7, 43, 4096]) {
    assert.deepEqual((await render(fragments(transcript, size))).indicators, EXPECTED_INDICATORS);
  }
  assert.deepEqual((await render([transcript])).indicators, EXPECTED_INDICATORS);
});

test("FIX1 preserves a marker split between chunks and CRLF split at the boundary", async () => {
  const text = (SUMMARY + R3_LINE + "# skipped 0\n").replace(/\n/g, "\r\n");
  const output = await render(fragments(text, 1));
  assert.equal(output.code, 0); assert.deepEqual(output.indicators, EXPECTED_INDICATORS);
});

test("FIX1 discards an entire oversized line before accepting the following valid marker", async () => {
  const output = await render([PRIVATE + "x".repeat(13000) + "\n" + SUMMARY + R3_LINE]);
  assert.equal(output.code, 0); assert.deepEqual(output.indicators, EXPECTED_INDICATORS.slice(0, -1));
});

test("FIX1 never promotes the tail of a discarded line to an independent marker", async () => {
  const output = await render(["x".repeat(12001), "# pass 123\n", SUMMARY, R3_LINE]);
  assert.equal(output.code, 0); assert.deepEqual(output.indicators, EXPECTED_INDICATORS.slice(0, -1));
});

test("FIX1 continuous unterminated output stays discarded until LF and then recovers", async () => {
  const chunks = Array.from({length: 256}, () => PRIVATE + "x".repeat(8192));
  const output = await render([...chunks, R3_LINE, SUMMARY, R3_LINE]);
  // The first R3_LINE is a tail of the oversized line; its LF only resets discard.
  assert.equal(output.code, 0); assert.deepEqual(output.indicators, EXPECTED_INDICATORS.slice(0, -1));
});

test("FIX1 handles UTF-8 byte fragmentation without exposing private noise", async () => {
  const bytes = Buffer.from("# ignorar açã𐐀 " + PRIVATE + "\n" + SUMMARY + R3_LINE);
  const chunks = Array.from({length: bytes.length}, (_, i) => bytes.subarray(i, i + 1));
  const output = await render(chunks);
  assert.equal(output.code, 0); assert.deepEqual(output.indicators, EXPECTED_INDICATORS.slice(0, -1));
});

for (const [name, content] of [
  ["empty stdout", ""], ["TAP without R3", SUMMARY], ["R3 without TAP", R3_LINE],
  ["unterminated R3 marker", SUMMARY + R3_LINE.trimEnd()],
  ["foreign R3 project", SUMMARY + R3_LINE.replace(PROJECT, "demo-other")],
]) test(`FIX1 zero exit is refused with missing evidence: ${name}`, async () => {
  assert.equal((await render([content])).code, 1);
});

for (const [name, content] of [
  ["ADC attempt", SUMMARY + R3_LINE.replace('"adcAttempts":0', '"adcAttempts":1')],
  ["unexpected socket", SUMMARY + R3_LINE.replace('"unexpectedOutboundSockets":0', '"unexpectedOutboundSockets":1')],
  ["no executed fixture", SUMMARY + R3_LINE.replace('"fixtures":24', '"fixtures":0')],
  ["failed summary", SUMMARY.replace("# fail 0", "# fail 1") + R3_LINE],
]) test(`FIX1 zero exit cannot override invalid evidence: ${name}`, async () => {
  assert.equal((await render([content])).code, 1);
});

test("FIX1 validates evidence after final stdout data arriving between exit and close", async () => {
  const f = fixture({autoEvidence: false}); f.run(); await flush();
  f.runner().emit("exit", 0, null); await flush();
  f.runner().stdout.emit("data", SUMMARY + R3_LINE); f.runner().emit("close", 0, null);
  assert.equal(await f.work, 0); f.assertReleased();
});

test("FIX1 Auth console/logger bypass is characterized and test interception is restored", async (t) => {
  const messages = []; const writes = [];
  const originalConsole = console.error; const originalWrite = process.stderr.write;
  const fakeLogger = {log: (_level, text) => process.stderr.write(text + "\n")};
  const consoleMock = t.mock.method(console, "error", (...args) => {messages.push(args);});
  const writeMock = t.mock.method(process.stderr, "write", (chunk) => {writes.push(String(chunk)); return true;});
  const f = fixture(); const load = f.io.loadAuth; let code;
  try {
    f.io.loadAuth = (...args) => {
      console.error(PRIVATE); fakeLogger.log("WARN", PRIVATE);
      return load(...args);
    };
    f.run(); await flush(); f.runner().finish(0); code = await f.work;
  } finally {
    consoleMock.mock.restore(); writeMock.mock.restore();
  }
  assert.equal(code, 0); // Exit zero is not an assertion of Auth output sanitization.
  assert.ok(messages.some((args) => args.includes(PRIVATE)));
  assert.ok(writes.some((value) => value.includes(PRIVATE)));
  assert.equal(console.error, originalConsole); assert.equal(process.stderr.write, originalWrite);
  f.assertReleased(); // Only io.stdout/io.stderr are protected by the launcher's filter.
});

const {runAuthWorker, parseAuthMessage} = require("../tools/retired_identity_auth_worker.cjs");
const readyMessage = () => ({version: 1, type: "AUTH_READY", project: PROJECT, host: "127.0.0.1", port: 4001});

for (const [name, message] of [
  ["null", null], ["array", []], ["string", PRIVATE], ["extra payload", {...readyMessage(), payload: PRIVATE}],
  ["real project", {...readyMessage(), project: "life-os-27b92"}],
  ["nonloopback", {...readyMessage(), host: "0.0.0.0"}], ["invalid port", {...readyMessage(), port: 65536}],
  ["execution command", {version: 1, type: "EXEC", command: PRIVATE}],
  ["opaque failure", {version: 1, type: "AUTH_FAILED", category: PRIVATE}],
]) test(`R17 refuses malformed or unexpected Auth IPC: ${name}`, async () => {
  assert.equal(parseAuthMessage(message), null);
  const f = fixture({authMessage: message}); assert.equal(await f.run(), 1);
  assert.equal(f.java(), undefined); f.assertReleased();
});

test("R17 duplicate readiness and disconnect fail closed after startup", async () => {
  for (const event of ["message", "disconnect"]) {
    const f = fixture(); f.run(); await flush();
    f.authWorker().emit(event, readyMessage());
    assert.equal(await f.work, 1); assert.equal(f.runner().kills, 1); f.assertReleased();
  }
});
for (const kind of ["spawnThrow", "spawnFailure"]) test(`R17 Auth worker ${kind} is sanitized`, async () => {
  const f = fixture({[kind]: "auth-worker"}); assert.equal(await f.run(), 1);
  assert.equal(f.java(), undefined); f.assertReleased();
});
test("R17 premature Auth worker exit never becomes success", async () => {
  for (const beforeReady of [true, false]) {
    const f = fixture({workerSilent: beforeReady}); f.run(); await flush();
    f.authWorker().finish(0); assert.equal(await f.work, 1);
    // Process exit releases its Auth socket; emulate that local ownership boundary.
    f.authWorker().authServer.removeAllListeners();
    f.authWorker().authServer.close(() => {});
    f.assertReleased();
  }
});
test("R17 Auth readiness has a bounded deadline", async () => {
  const f = fixture({workerSilent: true}); f.run(); await flush(); await f.advance(30000);
  assert.equal(await f.work, 1); assert.equal(f.java(), undefined); f.assertReleased();
});
test("R17 Auth stdout cannot substitute for IPC readiness", async () => {
  const f = fixture({workerSilent: true}); f.run(); await flush();
  f.authWorker().stdout.emit("data", JSON.stringify(readyMessage()) + "\nAPI endpoint:\n");
  await flush(); assert.equal(f.java(), undefined); await f.advance(30000);
  assert.equal(await f.work, 1); f.assertReleased();
});
test("R17 Auth stdout cannot fabricate test evidence", async () => {
  const f = fixture({autoEvidence: false}); f.run(); await flush();
  f.authWorker().stdout.emit("data", SUMMARY + R3_LINE); f.runner().finish(0);
  assert.equal(await f.work, 1);
  assert.equal(f.out.some((v) => JSON.parse(v).stage === "R3_ISOLATION"), false); f.assertReleased();
});
test("R17 unconfirmed Auth child shutdown fails closed and disconnects only its IPC", async () => {
  const f = fixture({stubborn: "auth-worker"}); f.run(); await flush(); f.runner().finish(0);
  await flush(); await f.advance(3000);
  assert.equal(await f.work, 1);
  assert.equal(f.authWorker().kills, 1); assert.equal(f.authWorker().unrefs, 1);
  assert.equal(f.authWorker().connected, false);
  assert.equal(f.timers.size, 0); assert.deepEqual(f.authWorker().eventNames(), []);
  assert.equal(JSON.parse(f.out.at(-1)).stage, "RESOURCES_NOT_CONFIRMED_STOPPED");
  f.authWorker().authServer.removeAllListeners(); // Fake-only remote process remains unconfirmed.
});

function workerFixture(options = {}) {
  const p = new EventEmitter(); const messages = []; const timers = new Map(); let serial = 0;
  const state = {loads: 0, servers: 0, messages, timers, process: p};
  Object.assign(p, {argv: ["node", "auth-worker"], platform: "win32", connected: true, send() {}, env: {
    GCLOUD_PROJECT: PROJECT, GOOGLE_CLOUD_PROJECT: PROJECT, XDG_CONFIG_HOME: "C:/test/temp",
    CLOUDSDK_CONFIG: "C:/test/temp", METADATA_SERVER_DETECTION: "none", GCE_METADATA_HOST: "127.0.0.1:1"}});
  class ConsoleTransport {constructor() {this.silent = true;}}
  const logging = {logger: {transports: [new ConsoleTransport()]}, Console: ConsoleTransport, events: new EventEmitter()};
  const server = new EventEmitter(); server.closes = 0;
  server.listen = (port, host) => {
    assert.equal(port, 0); assert.equal(host, "127.0.0.1");
    queueMicrotask(() => options.bindError ? server.emit("error", error()) : server.emit("listening"));
  };
  server.address = () => ({port: 4001});
  server.closeAllConnections = () => {};
  server.close = (cb) => {server.closes++; if (!options.closeHang) {server.emit("close"); cb();}};
  const io = {process: p, cwd: () => "C:/test/temp", homedir: () => "C:/test/home",
    version: () => options.version || "15.24.0", logging: () => logging,
    loadAuth: () => {state.loads++; return {createApp: async (project, mode) => {
      assert.equal(project, PROJECT); assert.equal(mode, 0);
      if (options.authError) throw error("EPERM");
      if (options.lateLogger) logging.logger.transports.push({file: PRIVATE});
      return {};
    }};},
    server: () => {state.servers++; return server;},
    send: (m, cb) => {messages.push(m); cb(options.sendError ? error() : null);},
    setTimeout: (fn, ms) => {const id = ++serial; timers.set(id, {fn, ms}); return id;},
    clearTimeout: (id) => timers.delete(id)};
  state.io = io; state.logging = logging; state.server = server;
  state.run = () => {state.work = runAuthWorker(io); return state.work;};
  state.expire = async (ms) => {for (const [id, t] of [...timers]) if (t.ms === ms) {
    timers.delete(id); t.fn(); await flush();
  }};
  state.released = () => {
    assert.equal(timers.size, 0); assert.deepEqual(p.eventNames(), []); assert.deepEqual(server.eventNames(), []);
    assert.equal(JSON.stringify(messages).includes(PRIVATE), false);
  };
  return state;
}

for (const [name, mutate] of [
  ["real project", (f) => {f.process.env.GCLOUD_PROJECT = "life-os-27b92";}],
  ["credentials", (f) => {f.process.env.GOOGLE_APPLICATION_CREDENTIALS = PRIVATE;}],
  ["arbitrary CLI", (f) => {f.process.argv.push("--project", "life-os-27b92");}],
  ["no IPC", (f) => {f.process.connected = false;}],
  ["foreign cwd", (f) => {f.io.cwd = () => "C:/different";}],
  ["Node preload", (f) => {f.process.env.NODE_OPTIONS = PRIVATE;}],
]) test(`R17 worker refuses configuration before Auth load: ${name}`, async () => {
  const f = workerFixture(); mutate(f); assert.equal(await f.run(), 1);
  assert.equal(f.loads, 0); assert.equal(f.servers, 0); f.released();
});
for (const [name, prepare] of [
  ["file transport", (f) => f.logging.logger.transports.push({filename: PRIVATE})],
  ["network/custom transport", (f) => {f.logging.logger.transports = [{}];}],
  ["active console transport", (f) => {f.logging.logger.transports[0].silent = false;}],
  ["alternate emitter", (f) => f.logging.events.on("log", () => {})],
]) test(`R17 unsupervised log destination blocks Auth: ${name}`, async () => {
  const f = workerFixture(); prepare(f); assert.equal(await f.run(), 1);
  assert.equal(f.loads, 0); assert.equal(f.messages[0].category, "LOG_DESTINATION_UNSUPERVISED"); f.released();
});
test("R17 unreviewed Firebase Tools version is refused", async () => {
  const f = workerFixture({version: "99.0.0"}); assert.equal(await f.run(), 1);
  assert.equal(f.loads, 0); assert.equal(f.messages[0].category, "DEPENDENCY_UNREVIEWED"); f.released();
});
test("R17 log destination added during Auth initialization is refused", async () => {
  const f = workerFixture({lateLogger: true}); assert.equal(await f.run(), 1);
  assert.equal(f.servers, 0); assert.equal(f.messages[0].category, "LOG_DESTINATION_UNSUPERVISED"); f.released();
});
for (const options of [{authError: true}, {bindError: true}, {sendError: true}]) {
  test(`R17 worker startup error is sanitized: ${JSON.stringify(options)}`, async () => {
    const f = workerFixture(options); assert.equal(await f.run(), 1); f.released();
  });
}
test("R17 worker accepts no inbound IPC command and closes once", async () => {
  const f = workerFixture(); f.run(); await flush(); assert.equal(f.messages[0].type, "AUTH_READY");
  f.process.emit("message", {type: "EXEC", command: PRIVATE}); f.process.emit("message", readyMessage());
  assert.equal(await f.work, 1); assert.equal(f.server.closes, 1); f.released();
});
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129], ["SIGBREAK", 131]]) {
  test(`R17 worker ${signal} cleans up without changing the first result`, async () => {
    const f = workerFixture(); f.run(); await flush(); f.process.emit(signal); f.process.emit("SIGINT");
    assert.equal(await f.work, code); assert.equal(f.server.closes, 1); f.released();
  });
}
test("R17 worker cleanup cannot wait indefinitely", async () => {
  const f = workerFixture({closeHang: true}); f.run(); await flush(); f.process.emit("disconnect");
  await flush(); await f.expire(3000); assert.equal(await f.work, 1); f.released();
});
test("R17 worker cancels a pending startup without late server acquisition", async () => {
  const f = workerFixture(); let release;
  f.io.loadAuth = () => ({createApp: () => new Promise((resolve) => {release = resolve;})});
  f.run(); await flush(); f.process.emit("SIGINT"); assert.equal(await f.work, 130);
  release({}); await flush(); assert.equal(f.servers, 0); f.released();
});
test("R17 worker startup timeout is bounded without a readiness message", async () => {
  const f = workerFixture(); f.io.loadAuth = () => ({createApp: () => new Promise(() => {})});
  f.run(); await flush(); await f.expire(30000);
  assert.equal(await f.work, 1); assert.equal(f.servers, 0);
  assert.equal(f.messages.filter((m) => m.type === "AUTH_READY").length, 0); f.released();
});

test("R17 real synthetic child console/logger output never reaches launcher output", {timeout: 10000}, async (t) => {
  const {spawn} = require("node:child_process");
  const f = fixture(); const fakeSpawn = f.io.spawn; let child; let started;
  const runnerStarted = new Promise((resolve) => {started = resolve;});
  const source = 'const {Console}=require("node:console");' +
    'console.log(' + JSON.stringify(PRIVATE) + ');console.error(' + JSON.stringify(PRIVATE) + ');' +
    'new Console(process.stdout,process.stderr).error(' + JSON.stringify(PRIVATE) + ');' +
    'process.send(' + JSON.stringify(readyMessage()) + ');process.on("message",()=>{});';
  t.after(() => {if (child && child.exitCode === null && child.signalCode === null) child.kill();});
  f.io.spawn = (exe, args, options) => {
    if (args[0].endsWith("retired_identity_auth_worker.cjs")) {
      // The mock launcher's temporary cwd does not exist on disk; this child only logs/uses IPC.
      child = spawn(process.execPath, ["-e", source], {...options, cwd: __dirname}); return child;
    }
    const result = fakeSpawn(exe, args, options);
    if (result.kind === "runner") started(result);
    return result;
  };
  f.run(); const runner = await Promise.race([runnerStarted, f.work.then(() => {
    throw new Error("SYNTHETIC_AUTH_CHILD_FAILED: " + f.err.join(""));
  })]); runner.finish(0);
  assert.equal(await f.work, 0); f.assertReleased();
  assert.ok(child.exitCode !== null || child.signalCode !== null);
  for (const output of [...f.out, ...f.err]) assert.equal(output.includes(PRIVATE), false);
});
