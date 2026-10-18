"use strict";

// Private worker for the existing launcher. No project/configuration commands.
const path = require("node:path");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const {createRequire} = require("node:module");
const PROJECT = "demo-life-os-d2c02r3";
const ERRORS = new Set(["EADDRINUSE", "EACCES", "EPERM", "ENOENT", "UNAVAILABLE",
  "IPC_INVALID", "DEPENDENCY_UNREVIEWED", "LOG_DESTINATION_UNSUPERVISED", "CONFIGURATION_REFUSED"]);
function category(error) {
  try {if (ERRORS.has(error?.code)) return error.code;} catch (_) { /* Opaque error. */ }
  return "UNAVAILABLE";
}
function fail(code) {throw Object.assign(new Error(), {code});}
function exact(value, keys) {
  if (!value || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const entries = Object.getOwnPropertyDescriptors(value);
  return Reflect.ownKeys(entries).length === keys.length && keys.every((k) =>
    entries[k] && Object.hasOwn(entries[k], "value"));
}
function parseAuthMessage(value) {
  try {
    if (exact(value, ["version", "type", "project", "host", "port"]) && value.version === 1 &&
        value.type === "AUTH_READY" && value.project === PROJECT && value.host === "127.0.0.1" &&
        Number.isInteger(value.port) && value.port > 0 && value.port <= 65535) {
      return {type: "AUTH_READY", port: value.port};
    }
    if (exact(value, ["version", "type", "category"]) && value.version === 1 &&
        value.type === "AUTH_FAILED" && ERRORS.has(value.category)) {
      return {type: "AUTH_FAILED", category: value.category};
    }
  } catch (_) { /* No untrusted getters or data are exposed. */ }
  return null;
}

async function runAuthWorker(io) {
  const p = io.process;
  const removers = [];
  let server;
  let finishStop;
  const stopped = new Promise((resolve) => {finishStop = resolve;});
  let requested = false;
  let result = 0;
  let closing;
  let closeTimer;
  let startTimer;
  let reported = false;
  function on(target, event, fn) {target.on(event, fn); removers.push(() => target.removeListener(event, fn));}
  function stop(code, reason) {
    if (requested) return;
    requested = true; result = code;
    if (reason && !reported && p.connected) {
      reported = true;
      try {io.send({version: 1, type: "AUTH_FAILED", category: reason}, () => {});} catch (_) { /* Parent unavailable. */ }
    }
    finishStop();
  }
  function check() {if (requested) throw null;}
  function auditLogging(logging) {
    const transports = logging.logger.transports;
    if (!Array.isArray(transports) || transports.length !== 1 ||
        !transports.every((t) => t instanceof logging.Console && t.silent === true) ||
        logging.events.listenerCount("log") !== 0) fail("LOG_DESTINATION_UNSUPERVISED");
  }
  function close() {
    if (!closing) closing = new Promise((resolve) => {
      if (!server) {resolve(); return;}
      let done = false;
      const finish = () => {if (!done) {done = true; io.clearTimeout(closeTimer); resolve();}};
      closeTimer = io.setTimeout(() => {result ||= 1; finish();}, 3000);
      try {
        try {server.closeAllConnections?.();} catch (_) {result ||= 1;}
        server.close((error) => {
          if (error && error.code !== "ERR_SERVER_NOT_RUNNING") result ||= 1;
          finish();
        });
      } catch (_) {result ||= 1; finish();}
    });
    return closing;
  }
  try {
    const allowed = new Set(["PATH", "SystemRoot", "WINDIR", "TEMP", "TMP", "GCLOUD_PROJECT",
      "GOOGLE_CLOUD_PROJECT", "FIREBASE_CLI_DISABLE_USAGE_REPORTING", "CI", "XDG_CONFIG_HOME",
      "CLOUDSDK_CONFIG", "METADATA_SERVER_DETECTION", "GCE_METADATA_HOST", "R3_FIREBASE_TOOLS_DIR",
      "NODE_CHANNEL_FD", "NODE_CHANNEL_SERIALIZATION_MODE"]);
    if (p.argv.length !== 2 || !p.connected || typeof p.send !== "function" ||
        p.env.GCLOUD_PROJECT !== PROJECT || p.env.GOOGLE_CLOUD_PROJECT !== PROJECT ||
        Object.keys(p.env).some((k) => !allowed.has(k)) ||
        !p.env.XDG_CONFIG_HOME || p.env.XDG_CONFIG_HOME !== p.env.CLOUDSDK_CONFIG ||
        path.resolve(io.cwd()) !== path.resolve(p.env.XDG_CONFIG_HOME) ||
        p.env.GCE_METADATA_HOST !== "127.0.0.1:1" || p.env.METADATA_SERVER_DETECTION !== "none") {
      fail("CONFIGURATION_REFUSED");
    }
    on(p, "message", () => stop(1, "IPC_INVALID")); // No inbound commands, even shutdown/config.
    on(p, "disconnect", () => stop(1));
    for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129],
      ...(p.platform === "win32" ? [["SIGBREAK", 131]] : [])]) on(p, signal, () => stop(code));
    startTimer = io.setTimeout(() => stop(1, "UNAVAILABLE"), 30000);
    const tools = p.env.R3_FIREBASE_TOOLS_DIR || path.join(io.homedir(),
        "AppData/Roaming/npm/node_modules/firebase-tools");
    if (!path.isAbsolute(tools) || io.version(tools) !== "15.24.0") fail("DEPENDENCY_UNREVIEWED");
    const logging = io.logging(tools);
    auditLogging(logging);
    check();
    const appWork = Promise.resolve(io.loadAuth(path.join(tools, "lib/emulator/auth/server.js"))
        .createApp(PROJECT, 0));
    appWork.catch(() => {});
    const app = await Promise.race([appWork, stopped]);
    check(); auditLogging(logging);
    server = io.server(app); // Registered before listen and possible cancellation.
    check();
    let ready;
    const listening = new Promise((resolve) => {ready = resolve;});
    on(server, "error", (error) => stop(1, category(error)));
    on(server, "close", () => {if (!requested) stop(1, "UNAVAILABLE");});
    on(server, "listening", ready);
    server.listen(0, "127.0.0.1");
    await Promise.race([listening, stopped]);
    check(); auditLogging(logging);
    const port = server.address()?.port;
    if (!Number.isInteger(port) || port < 1 || port > 65535) fail("CONFIGURATION_REFUSED");
    io.clearTimeout(startTimer);
    io.send({version: 1, type: "AUTH_READY", project: PROJECT, host: "127.0.0.1", port},
        (error) => {if (error) stop(1, "UNAVAILABLE");});
    await stopped;
  } catch (error) {
    if (!requested) stop(1, category(error));
  } finally {
    io.clearTimeout(startTimer);
    await close();
    for (const remove of removers) remove();
    io.clearTimeout(closeTimer);
  }
  return result;
}

if (require.main === module) {
  runAuthWorker({process, cwd: process.cwd, homedir: os.homedir,
    version: (tools) => JSON.parse(fs.readFileSync(path.join(tools, "package.json"), "utf8")).version,
    logging: (tools) => {
      const localRequire = createRequire(path.join(tools, "package.json"));
      const {logger, vsceLogEmitter} = localRequire("./lib/logger.js");
      return {logger, events: vsceLogEmitter, Console: localRequire("winston").transports.Console};
    },
    loadAuth: (file) => require(file), server: (app) => http.createServer(app),
    send: (value, callback) => process.send(value, callback), setTimeout, clearTimeout,
  }).then((code) => process.exit(code), () => process.exit(1));
}
module.exports = {runAuthWorker, parseAuthMessage};
