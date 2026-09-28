"use strict";

const PAGE_SIZE = 200;

function validId(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 &&
    value.trim() === value && !value.includes("/");
}

function parseProgressPath(path) {
  if (typeof path !== "string") return null;
  const parts = path.split("/");
  if (parts.length !== 6 || parts[0] !== "circles" || parts[2] !== "challenges" ||
      parts[4] !== "progress" || ![parts[1], parts[3], parts[5]].every(validId)) return null;
  return {circleId: parts[1], challengeId: parts[3], uid: parts[5]};
}

function validProgress(data, uid) {
  if (!data || !Number.isSafeInteger(data.value) || data.value < 0 ||
      (Object.hasOwn(data, "uid") && data.uid !== uid)) return false;
  for (const field of ["updatedAt", "lastEventAt"]) {
    if (!Object.hasOwn(data, field)) continue;
    try {
      if (!data[field] || typeof data[field].toMillis !== "function" || !Number.isFinite(data[field].toMillis())) return false;
    } catch (_) { return false; }
  }
  return !data.updatedAt || !data.lastEventAt || data.lastEventAt.toMillis() <= data.updatedAt.toMillis();
}

async function cleanupProgress(db, progressRef, {apply = false} = {}) {
  const ids = parseProgressPath(progressRef.path);
  if (ids === null || progressRef.id !== ids.uid) return {status: "CONFLICT"};
  const circleRef = db.collection("circles").doc(ids.circleId);
  async function inspect(reader) {
    const progress = await reader.get(progressRef);
    if (!progress.exists) return {status: "UNCHANGED"};
    const circle = await reader.get(circleRef);
    const challenge = await reader.get(circleRef.collection("challenges").doc(ids.challengeId));
    const member = await reader.get(circleRef.collection("members").doc(ids.uid));
    if (!circle.exists || circle.data()?.schemaVersion !== 2 ||
        Object.hasOwn(circle.data(), "deletionState") || !challenge.exists ||
        ![1, 2].includes(challenge.data()?.schemaVersion) || !validProgress(progress.data(), ids.uid)) {
      return {status: "CONFLICT"};
    }
    return {status: member.exists ? "UNCHANGED" : "CANDIDATE"};
  }
  if (!apply) return inspect({get: ref => ref.get()});
  // Recheck membership and content in the deletion transaction, never trust the scan.
  return db.runTransaction(async transaction => {
    const result = await inspect(transaction);
    if (result.status !== "CANDIDATE") return result;
    transaction.delete(progressRef);
    return {status: "APPLIED"};
  });
}

async function cleanupOrphanProgress(db, {apply = false} = {}) {
  const {FieldPath} = require("firebase-admin/firestore");
  const counts = {CANDIDATE: 0, UNCHANGED: 0, CONFLICT: 0, APPLIED: 0};
  let cursor;
  for (;;) {
    let query = db.collectionGroup("progress").orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) return counts;
    for (const document of page.docs) {
      const result = await cleanupProgress(db, document.ref, {apply});
      counts[result.status]++;
    }
    cursor = page.docs.at(-1);
  }
}

function parseArgs(args) {
  // Share only the strict CLI argument contract; no Firebase initialization on import.
  return require("./backfill-circle-challenge-count").parseArgs(args);
}

async function runCli(args, dependencies = {}) {
  const options = parseArgs(args);
  const initializeApp = dependencies.initializeApp ?? require("firebase-admin/app").initializeApp;
  const getFirestore = dependencies.getFirestore ?? require("firebase-admin/firestore").getFirestore;
  initializeApp({projectId: options.projectId});
  const counts = await cleanupOrphanProgress(getFirestore(), options);
  (dependencies.log ?? console.log)(JSON.stringify({mode: options.apply ? "APPLY" : "DRY_RUN", counts}, null, 2));
  return counts.CONFLICT > 0 || (!options.apply && counts.CANDIDATE > 0) ? 1 : 0;
}

if (require.main === module) {
  runCli(process.argv.slice(2)).then(code => {process.exitCode = code;}).catch(() => {
    console.error("Circle progress cleanup failed; no automatic recovery performed.");
    process.exitCode = 1;
  });
}

module.exports = {parseProgressPath, cleanupProgress, cleanupOrphanProgress, parseArgs, runCli};
