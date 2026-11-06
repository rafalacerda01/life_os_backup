"use strict";

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
  await assertLegacyMaintenanceScope(reader, db, data.adminId);
  const admin = await readDocument(reader, rootRef.collection('members').doc(data.adminId));
  if (!admin.exists || admin.data().role !== 'admin' ||
      (Object.hasOwn(admin.data(), 'uid') && admin.data().uid !== data.adminId)) return false;
  return true;
}

function validId(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 &&
    value.trim() === value && !value.includes("/");
}

function parseProgressPath(path) {
  if (typeof path !== "string") return null;
  const parts = path.split("/");
  if (parts.length !== 6 || parts[0] !== "circles" || parts[2] !== "challenges" ||
      parts[4] !== "progress" || ![parts[1], parts[3]].every(validId) || !validUid(parts[5])) return null;
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

async function inspectProgress(db, progressRef, {apply = false} = {}) {
  const ids = parseProgressPath(progressRef.path);
  if (ids === null || progressRef.id !== ids.uid) return {status: "CONFLICT"};
  const circleRef = db.collection("circles").doc(ids.circleId);
  async function inspect(reader) {
    const progress = await readDocument(reader, progressRef);
    if (!progress.exists) return {status: "UNCHANGED"};
    if (await isRetired(reader, db, ids.uid)) return {status: "RETIRED"};
    if (!await inspectCircleOwnership(reader, db, ids.circleId)) return {status: "CONFLICT"};
    const circle = await readDocument(reader, circleRef);
    const challenge = await readDocument(reader, circleRef.collection("challenges").doc(ids.challengeId));
    const member = await readDocument(reader, circleRef.collection("members").doc(ids.uid));
    if (!circle.exists || circle.data()?.schemaVersion !== 2 ||
        Object.hasOwn(circle.data(), "deletionState") || !challenge.exists ||
        ![1, 2].includes(challenge.data()?.schemaVersion) ||
        Object.hasOwn(challenge.data(), "deletionState") || !validProgress(progress.data(), ids.uid)) {
      return {status: "CONFLICT"};
    }
    if (member.exists && (!['admin', 'member'].includes(member.data()?.role) ||
        (Object.hasOwn(member.data(), 'uid') && member.data().uid !== ids.uid))) return {status: "CONFLICT"};
    return {status: member.exists ? "UNCHANGED" : "CANDIDATE"};
  }
  // Recheck membership and content in the deletion transaction, never trust the scan.
  return db.runTransaction(async transaction => {
    const result = await inspect(transaction);
    if (!apply || result.status !== "CANDIDATE") return result;
    transaction.delete(progressRef);
    return {status: "APPLIED"};
  });
}

async function cleanupProgress(db, progressRef, options = {}) {
  try {
    if (typeof (options.apply === undefined ? false : options.apply) !== 'boolean') throw new Error('INVALID_APPLY');
    return await inspectProgress(db, progressRef, options);
  } catch (_) { throw new Error('Circle progress cleanup failed closed.'); }
}

async function cleanupOrphanProgress(db, {apply = false} = {}) {
  const {FieldPath} = require("firebase-admin/firestore");
  const counts = {CANDIDATE: 0, UNCHANGED: 0, CONFLICT: 0, APPLIED: 0, RETIRED: 0};
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
  try {
  const initializeApp = dependencies.initializeApp ?? require("firebase-admin/app").initializeApp;
  const getFirestore = dependencies.getFirestore ?? require("firebase-admin/firestore").getFirestore;
  initializeApp({projectId: options.projectId});
  const counts = await cleanupOrphanProgress(getFirestore(), options);
  (dependencies.log ?? console.log)(JSON.stringify({mode: options.apply ? "APPLY" : "DRY_RUN", counts}, null, 2));
  return counts.CONFLICT > 0 || counts.RETIRED > 0 || (!options.apply && counts.CANDIDATE > 0) ? 1 : 0;
  } catch (_) { throw new Error("Maintenance CLI failed closed."); }
}

if (require.main === module) {
  runCli(process.argv.slice(2)).then(code => {process.exitCode = code;}).catch(() => {
    console.error("Circle progress cleanup failed; no automatic recovery performed.");
    process.exitCode = 1;
  });
}

module.exports = {parseProgressPath, cleanupProgress, cleanupOrphanProgress, parseArgs, runCli};
