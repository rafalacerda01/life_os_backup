"use strict";

const MAX_CIRCLE_CHALLENGES = 240;
const PAGE_SIZE = 200;

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
  async function inspect(reader) {
    const circle = await reader.get(circleRef);
    // Count all root documents, without filtering type, dates or validity.
    const challenges = await reader.get(circleRef.collection("challenges"));
    return inspectCircle(circle.data(), challenges.size);
  }
  if (!apply) return inspect({get: (ref) => ref.get()});
  // Reread the root and collection together; never write from dry-run evidence.
  return db.runTransaction(async (transaction) => {
    const result = await inspect(transaction);
    if (result.status !== "CANDIDATE") return result;
    transaction.update(circleRef, result.patch);
    return {...result, status: "APPLIED"};
  });
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

// Only an explicit CLI invocation initializes Admin; imports/tests never do.
if (require.main === module) {
  (async () => {
    const options = parseArgs(process.argv.slice(2));
    const admin = require("firebase-admin");
    admin.initializeApp({projectId: options.projectId});
    const results = await backfillCircles(admin.firestore(), options);
    console.log(JSON.stringify({mode: options.apply ? "APPLY" : "DRY_RUN", results}, null, 2));
    if (results.some(({status}) => ["CONFLICT", "OVER_LIMIT"].includes(status))) process.exitCode = 1;
  })().catch(() => {
    console.error("Circle challenge-count backfill failed; no automatic recovery performed.");
    process.exitCode = 1;
  });
}

module.exports = {MAX_CIRCLE_CHALLENGES, inspectCircle, backfillCircle, backfillCircles, parseArgs};
