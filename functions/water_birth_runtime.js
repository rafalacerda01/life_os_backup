"use strict";
const functions = require("firebase-functions/v1");
const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {Timestamp} = require("firebase-admin/firestore");
const {WATER_COHORT, requireOpenCohort} = require("./water_policy.cjs");
const {createManagedAuthBirthRecorder} = require("./water_auth_birth_adapter");
// No UID creation/import, custom token, PEM or additional Admin initialization.
/**
 * Persist managed creation evidence after the server cohort is approved.
 * @param {Object} user Managed Auth record.
 * @param {Object} context Managed v1 event context.
 */
async function record(user, context) {
  if (WATER_COHORT.state !== "OPEN") return;
  const db = getFirestore();
  const policy = requireOpenCohort(WATER_COHORT, db.projectId);
  const recorder = createManagedAuthBirthRecorder({
    db, auth: getAuth(), projectId: policy.projectId,
    getManagedEvent: () => ({user, context}),
    cohort: {version: 1, id: policy.id, policy: policy.policy, state: "CLOSED",
      cutoverAt: Timestamp.fromMillis(policy.cutoverMillis)},
  });
  // Receipt persists creation evidence. Admission is decided separately.
  await recorder.record();
}
exports.trigger = functions.runWith({
  serviceAccount:
    "life-os-cleanup-runtime@life-os-27b92.iam.gserviceaccount.com",
  failurePolicy: true,
}).auth.user().onCreate(record);
