"use strict";

// No real timers, sockets, Java, child processes or Firebase services.
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
      this.stdout = new EventEmitter(); this.stderr = new EventEmitter();
      this.stdout.destroy = this.stderr.destroy = () => {};
      state.children.push(this);
    }
    finish(code = 0, signal = null) {
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
      this.finish(null, "SIGTERM"); return true;
    }
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
      const kind = args[0] === "-jar" ? "java" : "runner";
      if (options.spawnThrow === kind) throw error();
      const child = new Child(kind); child.exe = exe; child.args = args; child.config = config;
      queueMicrotask(() => {
        if (options.spawnFailure === kind) {child.emit("error", error()); child.emit("close");}
        else if (options.interruptAt === kind) p.emit("SIGINT");
        else if (kind === "java") {
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
    if (["preflight", "app", "auth", "probe"].includes(point)) assert.equal(f.children.length, 0);
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
  assert.equal(await f.work, 130); assert.equal(f.children.length, 0); f.assertReleased();
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
  assert.equal(f.servers.length, 0); assert.equal(f.children.length, 0); f.assertReleased();
});

test("runner exit due to signal cannot become success", async () => {
  const f = fixture(); f.run(); await flush(); f.runner().finish(null, "SIGTERM");
  assert.equal(await f.work, 1); f.assertReleased();
});

test("a Java failure after readiness aborts the pending runner", async () => {
  const f = fixture(); f.run(); await flush(); f.children[0].finish(9);
  assert.equal(await f.work, 1); assert.equal(f.runner().kills, 1); f.assertReleased();
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
    const java = f.children[0]; assert.equal(java.args.at(-1), PROJECT);
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
  assert.equal(f.portCalls, 2); assert.equal(f.children.length, 0); f.assertReleased();
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
