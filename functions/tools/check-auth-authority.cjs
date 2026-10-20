"use strict";
/* eslint-disable require-jsdoc -- Development-only AST inspection helpers. */

// Development-only inspection. No application modules or SDKs are loaded.
const fs = require("node:fs");
const path = require("node:path");
const {Linter} = require("eslint");

const SENSITIVE = new Set([
  "createUser", "importUsers", "deleteUsers", "createCustomToken",
  "setCustomUserClaims", "deleteUser",
]);
const OMIT_DIRS = new Set([
  "node_modules", "test", "tests", "__tests__", "__mocks__", "fixtures",
]);
const AUTHORIZED_PATH = "backend/api/account/delete.js";

function sourcePath(value) {
  const parts = value.replace(/\\/g, "/").split("/");
  return !parts.some((part) => OMIT_DIRS.has(part) || part.startsWith(".")) &&
    !/\.(test|spec)\.[^.]+$/.test(value) &&
    /\.(js|cjs|mjs|jsx|ts|tsx)$/.test(value);
}

function memberName(node) {
  if (!node.computed && node.property.type === "Identifier") {
    return node.property.name;
  }
  if (node.computed && node.property.type === "Literal") {
    return node.property.value;
  }
  if (node.computed && node.property.type === "TemplateLiteral" &&
      node.property.expressions.length === 0) {
    return node.property.quasis[0].value.cooked;
  }
  return null;
}

function approvedDelete(file, node) {
  const call = node.parent;
  if (file !== AUTHORIZED_PATH || node.computed || node.optional ||
      node.object.type !== "Identifier" || node.object.name !== "auth" ||
      call.type !== "CallExpression" || call.callee !== node || call.optional ||
      call.arguments.length !== 1 || call.arguments[0].type !== "Identifier" ||
      call.arguments[0].name !== "uid" ||
      call.parent.type !== "AwaitExpression") {
    return false;
  }
  let owner = call.parent;
  while (owner && !["FunctionDeclaration", "FunctionExpression",
    "ArrowFunctionExpression"].includes(owner.type)) owner = owner.parent;
  return owner && owner.type === "FunctionDeclaration" && owner.async &&
    owner.id && owner.id.name === "deleteAccount";
}

function inspectSource(file, source) {
  const references = [];
  const linter = new Linter();
  linter.defineRule("auth-authority", {
    create() {
      function record(node, method, allowed = false) {
        if (SENSITIVE.has(method)) {
          references.push({file, line: node.loc.start.line, method, allowed});
        }
      }
      return {
        MemberExpression(node) {
          const method = memberName(node);
          record(node, method,
              method === "deleteUser" && approvedDelete(file, node));
        },
        CallExpression(node) {
          if (node.callee.type === "Identifier") {
            record(node, node.callee.name);
          }
        },
        Property(node) {
          if (node.parent.type === "ObjectPattern") {
            const method = node.computed ? node.key.value :
              (node.key.name === undefined ? node.key.value : node.key.name);
            record(node, method);
          }
        },
        ImportSpecifier(node) {
          record(node, node.imported.name === undefined ?
            node.imported.value : node.imported.name);
        },
      };
    },
  });
  const messages = linter.verify(source, {
    parserOptions: {ecmaVersion: "latest", sourceType: "module"},
    rules: {"auth-authority": "error"},
  });
  const errors = messages.map((message) => ({file, line: message.line || 1,
    method: "SOURCE_PARSE_ERROR", message: message.message, allowed: false}));
  return [...errors, ...references];
}

function inspectFiles(files, {requireAuthorizedDelete = true} = {}) {
  const references = [];
  let filesScanned = 0;
  for (const file of files) {
    const name = file.path.replace(/\\/g, "/");
    if (!sourcePath(name)) continue;
    filesScanned++;
    if (/\.(jsx|ts|tsx)$/.test(name)) {
      references.push({file: name, line: 1, method: "UNSUPPORTED_SOURCE",
        allowed: false});
    } else references.push(...inspectSource(name, file.source));
  }
  const authorized = references.filter((ref) => ref.allowed);
  const violations = references.filter((ref) => !ref.allowed);
  // A second identical call inside the allowed function is still a new point.
  if ((requireAuthorizedDelete && authorized.length !== 1) ||
      authorized.length > 1) {
    violations.push({file: AUTHORIZED_PATH, line: 1,
      method: "AUTHORIZED_DELETE_COUNT", count: authorized.length,
      message: "Exactly one approved Auth deletion reference is expected."});
  }
  return {filesScanned, authorized, violations};
}

function inspectRepository(root = path.resolve(__dirname, "../..")) {
  const files = [];
  function visit(directory) {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      if (entry.name.startsWith(".") || OMIT_DIRS.has(entry.name)) continue;
      const absolute = path.join(directory, entry.name);
      const relative = path.relative(root, absolute).replace(/\\/g, "/");
      if (entry.isSymbolicLink()) {
        throw new Error("Review symlink in source scope: " + relative);
      }
      if (entry.isDirectory()) visit(absolute);
      else if (sourcePath(relative)) {
        files.push({path: relative, source: fs.readFileSync(absolute, "utf8")});
      }
    }
  }
  // Both repository roots are required; missing roots fail the scan.
  visit(path.join(root, "functions"));
  visit(path.join(root, "backend"));
  return inspectFiles(files.sort((a, b) => a.path.localeCompare(b.path)));
}

if (require.main === module) {
  const result = inspectRepository();
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
  process.exitCode = result.violations.length ? 1 : 0;
}

module.exports = {inspectFiles, inspectRepository, sourcePath};
