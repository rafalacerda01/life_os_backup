"use strict";
// Emulator-only adapter. No production exports/cleanup triggers are loaded.
const fs = require("node:fs");
const path = require("node:path");
const functions = require("firebase-functions/v1");
const {initializeApp} = require("firebase-admin/app");
const {getAuth} = require("firebase-admin/auth");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {createManagedAuthBirthRecorder, authBirthError} = require("../../../functions/water_auth_birth_adapter");

if (process.env.FUNCTIONS_EMULATOR !== "true" ||
    process.env.GCLOUD_PROJECT !== "demo-life-os" ||
    process.env.FIRESTORE_EMULATOR_HOST !== "127.0.0.1:8089" ||
    process.env.FIREBASE_AUTH_EMULATOR_HOST !== "127.0.0.1:9099" ||
    process.env.GOOGLE_APPLICATION_CREDENTIALS) throw Error("EMULATOR_ONLY");
const file = process.env.LIFE_OS_WATER_DEMO_RUN;
if (!file || !path.isAbsolute(file)) throw Error("HOST_RUN_FILE_REQUIRED");
const run = JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
if (run.projectId !== "demo-life-os" || !Number.isSafeInteger(run.cutoverMillis) ||
    !Number.isSafeInteger(run.birthDelayMillis) || run.birthDelayMillis < 0 ||
    run.birthDelayMillis > 60000) throw Error("SYNTHETIC_RUN_REQUIRED");
const app = initializeApp({projectId:"demo-life-os"});
exports.recordDemoWaterBirth = functions.runWith({timeoutSeconds:120}).auth.user().onCreate(async (user, context) => {
  // The local Auth emulator produces the managed event; the client cannot
  // provide its UID, event context, creation evidence, or eligibility decision.
  if (!user.email?.endsWith("@example.test")) throw Error("SYNTHETIC_EMAIL_REQUIRED");
  await new Promise(resolve => setTimeout(resolve,run.birthDelayMillis));
  const recorder = createManagedAuthBirthRecorder({
    db:getFirestore(app),auth:getAuth(app),projectId:"demo-life-os",
    getManagedEvent:()=>({user,context}),
    cohort:{version:1,id:run.cohortId,policy:"NEW_ACCOUNT_V2_ONLY",state:"CLOSED",
      cutoverAt:Timestamp.fromMillis(run.cutoverMillis)},
  });
  // Sanitized diagnostic of the actual SDK event; never transform or replay it.
  const current = await getAuth(app).getUser(user.uid);
  console.log("DEMO_EVENT_SHAPE", JSON.stringify({
    uid:user.uid,contextKeys:Object.keys(context),eventType:context.eventType,
    resource:context.resource,metadataType:user.metadata?.constructor?.name,
    eventCreatedAt:user.metadata?.creationTime,currentCreatedAt:current.metadata.creationTime,
    eventAt:context.timestamp,providers:user.providerData?.map(p=>p.providerId),
  }));
  try { await recorder.record(); }
  catch(error) {
    console.error("DEMO_BIRTH_REJECTED",authBirthError(error).code);
    throw error;
  }
  console.log("DEMO_BIRTH_RECORDED",user.uid,context.eventId);
});
