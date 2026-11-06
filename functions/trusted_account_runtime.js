"use strict";
const functions = require("firebase-functions/v1");
const genesis = require("./trusted_account");
// Prepared handlers only. index.js does not export these as deployed triggers.
// The isolated Cloud binding/SA/invoker and project remain unconfigured/CLOSED.
function createRuntime(admin) {
  return Object.freeze({beforeCreate: functions.auth.user().beforeCreate(async (user, context) => {
    try { return await genesis.beforeCreate(admin.firestore(), user, context); }
    catch (_) { throw new functions.auth.HttpsError("permission-denied", "TRUSTED_ACCOUNT_CLOSED_OR_REVIEW"); }
  }), onCreate: functions.auth.user().onCreate(async (user, context) => {
    // Managed service event, not a manufactured ID token. Delayed/repeated
    // creation cannot restore a partial, deleting or retired namespace.
    await genesis.provisionCreatedUser(admin.firestore(), admin.auth(), user, context);
  })});
}
module.exports = Object.freeze({createRuntime});
