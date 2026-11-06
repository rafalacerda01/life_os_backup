"use strict";

const MAX_CIRCLE_CHALLENGES = 240;
const PAGE_SIZE = 200;


function validUid(value) {
  return typeof value === 'string' && value.length > 0 &&
    Buffer.byteLength(value, 'utf8') <= 128 && value.trim() === value &&
    !value.includes('/') && !['.', '..'].includes(value) &&
    !/^__.*__$/.test(value) && ![...value].some(char =>
      char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127);
}

async function readDocument(reader, ref) {
  const snapshot = await reader.get(ref);
  if (!snapshot || typeof snapshot.exists !== 'boolean' ||
      snapshot.ref?.path !== ref.path || typeof snapshot.data !== 'function') {
    throw new Error('MAINTENANCE_READ_UNDETERMINED');
  }
  const data = snapshot.data();
  if (snapshot.exists ? data === undefined || data === null : data !== undefined) {
    throw new Error('MAINTENANCE_READ_UNDETERMINED');
  }
  return snapshot;
}

// Existing origins are DENY-only for these legacy maintenance tools. Absence
// preserves their legacy contract; it never proves generation or grants cleanup.
async function assertLegacyMaintenanceScope(reader, db, uid) {
  if (!validUid(uid)) throw new Error('MAINTENANCE_IDENTITY_INVALID');
  const origin = await readDocument(reader,
      db.doc('trusted_account_origins/' + uid));
  if (origin.exists) throw new Error('TRUSTED_MAINTENANCE_CLOSED');
}

async function isRetired(reader, db, uid) {
  if (!validUid(uid)) throw new Error('MAINTENANCE_IDENTITY_INVALID');
  const controls = [];
  for (const path of ['retired_auth_identities/' + uid,
    'account_deletion_guards/' + uid,
    'account_deletion_guards/' + uid + '/control/operation']) {
    controls.push(await readDocument(reader, db.doc(path)));
  }
  // Presence is deny-only, not proof of cleanup or permission to recover it.
  if (controls.some(snapshot => snapshot.exists)) return true;
  await assertLegacyMaintenanceScope(reader, db, uid);
  return false;
}

async function inspectCircleOwnership(reader, db, circleId) {
  const rootRef = db.doc('circles/' + circleId);
  const root = await readDocument(reader, rootRef);
  const marker = await readDocument(reader, db.doc('circle_deletions/' + circleId));
  const closure = await readDocument(reader, db.doc('circle_cleanup_guards/' + circleId));
  const data = root.data();
  if (!root.exists || !data || data.schemaVersion !== 2 ||
      !validUid(data.adminId) || Object.hasOwn(data, 'deletionState') ||
      marker.exists || closure.exists) return false;
  const admin = await readDocument(reader, rootRef.collection('members').doc(data.adminId));
  if (!admin.exists || admin.data().role !== 'admin' ||
      (Object.hasOwn(admin.data(), 'uid') && admin.data().uid !== data.adminId)) return false;
  return true;
}

function validId(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 &&
    value.trim() === value && !value.includes("/");
}

function inspectCircle(data, actualCount) {
  if (!Number.isSafeInteger(actualCount) || actualCount < 0) {
    throw new Error("INVALID_CHALLENGE_COUNT");
  }
  if (actualCount > MAX_CIRCLE_CHALLENGES) return {status: "OVER_LIMIT", actualCount};
  if (!data || data.schemaVersion !== 2) return {status: "CONFLICT", actualCount};
  const hasCount = Object.hasOwn(data, "challengeCount");
  const hasLastId = Object.hasOwn(data, "lastChallengeId");
  if (!hasCount && !hasLastId) {
    return {status: "CANDIDATE", actualCount,
      patch: {challengeCount: actualCount, lastChallengeId: null}};
  }
  if (!hasCount || !hasLastId || !Number.isInteger(data.challengeCount) ||
      data.challengeCount !== actualCount ||
      !(data.lastChallengeId === null || validId(data.lastChallengeId))) {
    return {status: "CONFLICT", actualCount};
  }
  return {status: "UNCHANGED", actualCount};
}

async function backfillCircle(db, circleRef, {apply = false} = {}) {
  try {
    if (typeof apply !== "boolean" || !validId(circleRef.id) ||
        circleRef.path !== "circles/" + circleRef.id) return {status: "CONFLICT"};
    return await db.runTransaction(async transaction => {
      const circle = await readDocument(transaction, circleRef);
      if (!circle.exists) return {status: "CONFLICT"};
      const data = circle.data();
      if (!data || !validUid(data.adminId)) return {status: "CONFLICT"};
      if (await isRetired(transaction, db, data.adminId)) return {status: "RETIRED"};
      if (!await inspectCircleOwnership(transaction, db, circleRef.id)) return {status: "CONFLICT"};
      // Count every root Challenge, including expired/legacy, in this attempt.
      const challenges = await transaction.get(circleRef.collection("challenges"));
      const result = inspectCircle(data, challenges.size);
      if (!apply || result.status !== "CANDIDATE") return result;
      transaction.update(circleRef, result.patch);
      return {...result, status: "APPLIED"};
    });
  } catch (_) { throw new Error("Circle challenge-count backfill failed closed."); }
}

async function backfillCircles(db, {apply = false} = {}) {
  const {FieldPath} = require("firebase-admin/firestore");
  const results = [];
  let cursor;
  for (;;) {
    let query = db.collection("circles").orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) return results;
    for (const circle of page.docs) {
      results.push({circleId: circle.id, ...await backfillCircle(db, circle.ref, {apply})});
    }
    cursor = page.docs.at(-1);
  }
}

function parseArgs(args) {
  let apply = false;
  let projectId;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === "--apply" && !apply) apply = true;
    else if (arg === "--project" && !projectId) projectId = args[++index];
    else throw new Error("Use --project PROJECT_ID and optional --apply.");
  }
  if (typeof projectId !== "string" || !/^[a-z][a-z0-9-]+$/.test(projectId)) {
    throw new Error("An explicit --project PROJECT_ID is required.");
  }
  return {apply, projectId};
}

async function runCli(args, dependencies = {}) {
  const options = parseArgs(args);
  try {
  const initializeApp = dependencies.initializeApp ?? require("firebase-admin/app").initializeApp;
  const getFirestore = dependencies.getFirestore ?? require("firebase-admin/firestore").getFirestore;
  initializeApp({projectId: options.projectId});
  const results = await backfillCircles(getFirestore(), options);
  const log = dependencies.log ?? console.log;
  log(JSON.stringify({mode: options.apply ? "APPLY" : "DRY_RUN", results}, null, 2));
  return results.some(({status}) => ["CONFLICT", "OVER_LIMIT", "RETIRED"].includes(status)) ? 1 : 0;
  } catch (_) { throw new Error("Maintenance CLI failed closed."); }
}

// Only an explicit CLI invocation initializes Admin; imports/tests never do.
if (require.main === module) {
  runCli(process.argv.slice(2)).then((exitCode) => {
    process.exitCode = exitCode;
  }).catch(() => {
    console.error("Circle challenge-count backfill failed; no automatic recovery performed.");
    process.exitCode = 1;
  });
}

module.exports = {MAX_CIRCLE_CHALLENGES, inspectCircle, backfillCircle, backfillCircles, parseArgs, runCli};
