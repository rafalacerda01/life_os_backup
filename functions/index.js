const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {createHash} = require("node:crypto");
const {Timestamp} = require("firebase-admin/firestore");
const circleCleanup = require("./circle_cleanup");
const birthCleanup = require("./birth_ledger_cleanup");

const CIRCLE_SCHEMA_VERSION = 2;
const MAX_CIRCLE_MEMBERS = 30;
const BILLING_ACCOUNT_COLLECTION = "billing_google_accounts";
const BILLING_TOKEN_COLLECTION = "billing_google_tokens";
const BILLING_ACCOUNT_ACTIVE = "ACTIVE";
const BILLING_ACCOUNT_DELETING = "DELETING";
const BILLING_TOKEN_DELETE_PAGE_SIZE = 100;

// Inicializa o Admin SDK
admin.initializeApp();

exports.recordWaterBirth = require("./water_birth_runtime").trigger;

/**
 * Gera o identificador server-only da conta de billing.
 * @param {string} value Valor a resumir.
 * @return {string} SHA-256 hexadecimal lowercase.
 */
function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

/**
 * Valida um account index antes de qualquer mutacao destrutiva.
 * @param {Object|undefined} data Dados persistidos.
 * @param {string} uid UID esperado.
 * @return {Object} Dados validados.
 */
function validateBillingAccount(data, uid) {
  if (!data || typeof data !== "object" || Array.isArray(data) ||
      data.uid !== uid ||
      (data.state !== BILLING_ACCOUNT_ACTIVE &&
        data.state !== BILLING_ACCOUNT_DELETING)) {
    throw new Error("INVALID_BILLING_ACCOUNT_STATE");
  }
  return data;
}

/**
 * Fecha novas admissoes de billing antes da limpeza global.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @return {Promise<Object>} Referencias e hash derivados server-side.
 */
async function ensureBillingDeletionBarrier(db, uid) {
  const accountHash = sha256(uid);
  const accountRef = db.collection(BILLING_ACCOUNT_COLLECTION).doc(accountHash);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(accountRef);
    if (!snapshot.exists) {
      transaction.set(accountRef, {uid, state: BILLING_ACCOUNT_DELETING});
      return;
    }
    const account = validateBillingAccount(snapshot.data(), uid);
    if (account.state === BILLING_ACCOUNT_ACTIVE) {
      transaction.update(accountRef, {state: BILLING_ACCOUNT_DELETING});
    }
  });
  return {accountHash, accountRef};
}

/**
 * Remove indices globais de tokens em paginas limitadas.
 * @param {Object} db Firestore Admin.
 * @param {string} accountHash Hash server-only da conta.
 * @return {Promise<void>} Conclusao da limpeza.
 */
async function cleanupBillingTokenIndexes(db, accountHash) {
  const tokens = db.collection(BILLING_TOKEN_COLLECTION);
  for (;;) {
    const snapshot = await tokens
        .where("accountHash", "==", accountHash)
        .limit(BILLING_TOKEN_DELETE_PAGE_SIZE)
        .get();
    if (!snapshot || !Array.isArray(snapshot.docs)) {
      throw new Error("INVALID_BILLING_TOKEN_QUERY");
    }
    if (snapshot.docs.length === 0) return;
    for (const tokenSnapshot of snapshot.docs) {
      const data = tokenSnapshot.data();
      if (!data || typeof data !== "object" || Array.isArray(data) ||
          data.accountHash !== accountHash) {
        throw new Error("INVALID_BILLING_TOKEN_INDEX");
      }
    }
    await deleteRefs(db, snapshot.docs.map((entry) => entry.ref));
  }
}

/**
 * Remove o account index somente depois de provar a limpeza integral.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {Object} billingCleanup Estado derivado pelo barrier.
 * @return {Promise<void>} Conclusao da finalizacao.
 */
async function finalizeBillingDeletionBarrier(db, uid, billingCleanup) {
  const userRef = db.collection("users").doc(uid);
  const tokenQuery = db.collection(BILLING_TOKEN_COLLECTION)
      .where("accountHash", "==", billingCleanup.accountHash)
      .limit(1);
  await db.runTransaction(async (transaction) => {
    const [accountSnapshot, userSnapshot, tokenSnapshot] = await Promise.all([
      transaction.get(billingCleanup.accountRef),
      transaction.get(userRef),
      transaction.get(tokenQuery),
    ]);
    if (!accountSnapshot.exists) return;
    const account = validateBillingAccount(accountSnapshot.data(), uid);
    if (account.state !== BILLING_ACCOUNT_DELETING || userSnapshot.exists ||
        !tokenSnapshot || !Array.isArray(tokenSnapshot.docs) ||
        tokenSnapshot.docs.length !== 0) {
      throw new Error("BILLING_CLEANUP_INCOMPLETE");
    }
    transaction.delete(billingCleanup.accountRef);
  });
}

/**
 * Retorna se um valor pode ser usado como ID de documento conhecido.
 * @param {*} value Valor recebido do Firestore.
 * @return {boolean} Se o ID e seguro para uso server-side.
 */
function isSafeDocumentId(value) {
  return typeof value === "string" &&
    value.length > 0 &&
    value.length <= 128 &&
    value.trim() === value &&
    !value.includes("/");
}

/**
 * Extrai o ID final de uma referencia Firestore.
 * @param {Object} ref Referencia de documento.
 * @return {string} ID final da referencia.
 */
function documentId(ref) {
  const parts = ref.path.split("/");
  return parts[parts.length - 1];
}

/**
 * Valida o vinculo opcional do usuario com um Circle.
 * @param {Object|undefined} userData Dados do usuario.
 * @return {string|null} ID validado ou ausencia de Circle.
 */
function activeCircleIdFrom(userData) {
  const value = userData ? userData.activeCircleId : undefined;
  if (value === undefined || value === null) return null;
  if (!circleCleanup.storedPathSegment(value) || value.trim() !== value) {
    throw new Error("INVALID_ACCOUNT_STATE");
  }
  return value;
}

/**
 * Valida os campos centrais do schema V2.
 * @param {Object|undefined} circle Dados do Circle.
 * @return {Object} Dados validados.
 */
function validateCircle(circle) {
  if (
    circle === null ||
    typeof circle !== "object" ||
    Array.isArray(circle) ||
    circle.schemaVersion !== CIRCLE_SCHEMA_VERSION ||
    !isSafeDocumentId(circle.adminId) ||
    !Number.isInteger(circle.memberCount) ||
    circle.memberCount < 1 ||
    (circle.memberLimit !== 3 &&
      circle.memberLimit !== 10 &&
      circle.memberLimit !== 30) ||
    circle.memberCount > circle.memberLimit
  ) {
    throw new Error("INVALID_CIRCLE_STATE");
  }
  return circle;
}

/**
 * Valida e materializa os membros retornados por uma query limitada.
 * @param {Object} snapshot Snapshot da query de membros.
 * @param {string} adminId UID administrativo esperado.
 * @param {boolean} requireAdmin Se o documento do admin deve existir.
 * @return {Array<Object>} Documentos validados.
 */
function validateMembers(snapshot, adminId, requireAdmin) {
  const docs = snapshot && Array.isArray(snapshot.docs) ? snapshot.docs : [];
  if (docs.length > MAX_CIRCLE_MEMBERS) {
    throw new Error("CIRCLE_MEMBER_LIMIT_EXCEEDED");
  }

  let hasAdmin = false;
  for (const memberSnapshot of docs) {
    const memberId = documentId(memberSnapshot.ref);
    const member = memberSnapshot.data();
    const role = member ? member.role : undefined;
    if (!isSafeDocumentId(memberId)) {
      throw new Error("INVALID_MEMBER_STATE");
    }
    if (memberId === adminId) {
      if (role !== "admin") throw new Error("INVALID_ADMIN_STATE");
      hasAdmin = true;
    } else if (role !== "member") {
      throw new Error("INVALID_MEMBER_ROLE");
    }
  }

  if (requireAdmin && !hasAdmin) throw new Error("ADMIN_MEMBER_MISSING");
  return docs;
}

/**
 * Executa deletes em um batch pequeno.
 * @param {Object} db Firestore Admin.
 * @param {Array<Object>} refs Referencias a apagar.
 * @return {Promise<void>} Conclusao do commit.
 */
async function deleteRefs(db, refs) {
  if (refs.length === 0) return;
  const batch = db.batch();
  for (const ref of refs) batch.delete(ref);
  await batch.commit();
}

/**
 * Valida ou remove atomicamente o membership de um membro comum.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {string} circleId Circle ativo.
 * @param {boolean} commit Se a remocao deve ser aplicada.
 * @return {Promise<Object>} Referencia do Circle.
 */
function resolveMemberState(db, uid, circleId, commit) {
  const userRef = db.collection("users").doc(uid);
  const circleRef = db.collection("circles").doc(circleId);
  const membersRef = circleRef.collection("members");
  const memberRef = membersRef.doc(uid);

  return db.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    if (!userSnapshot.exists ||
        activeCircleIdFrom(userSnapshot.data()) !== circleId) {
      throw new Error("USER_CIRCLE_CHANGED");
    }

    const circleSnapshot = await transaction.get(circleRef);
    if (!circleSnapshot.exists) throw new Error("CIRCLE_ROOT_MISSING");
    const circle = validateCircle(circleSnapshot.data());
    if (circle.adminId === uid || circle.deletionState !== undefined) {
      throw new Error("INVALID_MEMBER_CIRCLE_STATE");
    }

    const membersSnapshot = await transaction.get(
        membersRef.limit(MAX_CIRCLE_MEMBERS + 1),
    );
    const members = validateMembers(membersSnapshot, circle.adminId, true);
    const memberSnapshot = members.find(
        (entry) => documentId(entry.ref) === uid,
    );

    if (members.length !== circle.memberCount) {
      throw new Error("CIRCLE_MEMBER_COUNT_MISMATCH");
    }
    if (memberSnapshot && memberSnapshot.data().role !== "member") {
      throw new Error("INVALID_MEMBER_ROLE");
    }

    if (commit && memberSnapshot) {
      transaction.delete(memberRef);
      transaction.update(circleRef, {
        memberCount: members.length - 1,
        updatedAt: Timestamp.now(),
      });
    }
    return circleRef;
  });
}

/**
 * Remove membership e dados de challenges de um membro comum.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {string} circleId Circle ativo.
 * @return {Promise<void>} Conclusao da limpeza externa.
 */
async function cleanupNormalMember(db, uid, circleId) {
  await resolveMemberState(db, uid, circleId, false);
  await resolveMemberState(db, uid, circleId, true);
}

/**
 * Resolve e limpa referencias externas do Circle ativo.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {Object} userSnapshot Snapshot inicial do usuario.
 * @return {Promise<void>} Conclusao da limpeza externa.
 */
async function cleanupExternalCircleData(db, uid, userSnapshot, guard) {
  const circleId = activeCircleIdFrom(userSnapshot.data());
  if (circleId === null) return;

  const circleRef = db.collection("circles").doc(circleId);
  const circleSnapshot = await circleRef.get();
  if (!circleSnapshot.exists) {
    await circleCleanup.cleanupMissingCircle(db, uid, guard, circleId);
    return;
  }

  const circle = validateCircle(circleSnapshot.data());
  if (circle.adminId === uid) {
    await circleCleanup.cleanupOwned(db, uid, guard, true);
    return;
  }
  await cleanupNormalMember(db, uid, circleId);
}

exports.cleanupUserData = functions
    .runWith({
      serviceAccount:
        "life-os-cleanup-runtime@life-os-27b92.iam.gserviceaccount.com",
      failurePolicy: true,
    })
    .auth.user().onDelete(async (user, context) => {
      const db = admin.firestore();
      let admission;
      try {
        admission = await birthCleanup.prepare(db, user, context,
            (uid) => admin.auth().getUser(uid));
        const {guard} = admission;
        const uid = admission.bound.uid;
        if (await birthCleanup.currentState(db, admission) === "COMPLETE") {
          await birthCleanup.finish(db, admission);
          return;
        }
        const cleanupDb = birthCleanup.cleanupDatabase(db, admission);
        const userRef = db.collection("users").doc(uid);
        const operation = birthCleanup.originalOperation(db, admission);
        let billingCleanup;
        const prepared = await circleCleanup.treeState(db, uid, guard, userRef, true);
        if (prepared === null &&
            !(await circleCleanup.capturePermitted(db, uid, guard))) {
          // Production has no certified post-Auth capture policy. The existing
          // demo-only rollout seam remains available to historical fixtures.
          await circleCleanup.captureTree(db, uid, guard, userRef);
          throw new Error("ACCOUNT_CLEANUP_REVIEW_REQUIRED");
        }
        if (prepared !== null) {
          if (operation.origin === "PRE_AUTH" && prepared.authOutcome !== "CONFIRMED") throw new Error("ACCOUNT_AUTH_OUTCOME_UNKNOWN");
          billingCleanup = {accountHash: operation.scope.billingAccountHash,
            accountRef: db.collection(BILLING_ACCOUNT_COLLECTION).doc(operation.scope.billingAccountHash)};
          await circleCleanup.verifyReferences(cleanupDb, uid);
        } else {
        await birthCleanup.verifyStep(db, admission);
        billingCleanup = await ensureBillingDeletionBarrier(cleanupDb, uid);
        await cleanupBillingTokenIndexes(cleanupDb, billingCleanup.accountHash);
        await circleCleanup.cleanupPendingMarkers(cleanupDb, uid, guard);
        const userSnapshot = await userRef.get();
        if (userSnapshot.exists) {
          await cleanupExternalCircleData(cleanupDb, uid, userSnapshot, guard);
        }
        await circleCleanup.cleanupOwned(cleanupDb, uid, guard, true);
        await circleCleanup.cleanupMemberships(cleanupDb, uid, guard);
        await circleCleanup.cleanupHistory(cleanupDb, uid, guard);
        await circleCleanup.verifyReferences(cleanupDb, uid);
        await cleanupDb.runTransaction(async (transaction) => {
          await circleCleanup.requireGuard(transaction, db, uid, guard);
          await circleCleanup.assertEmpty(transaction, db, uid);
        });
        }
        // The original operation and Auth absence are rechecked before removal.
        // An unrestricted Admin can still recreate Auth after the last lookup.
        await birthCleanup.beforeRootRemoval(db, admission);
        await cleanupDb.deleteTree(userRef);
        await birthCleanup.verifyStep(db, admission);
        await finalizeBillingDeletionBarrier(cleanupDb, uid, billingCleanup);
        await birthCleanup.finish(db, admission);
      } catch (error) {
        if (error && error.code === "ACCOUNT_CLEANUP_COMPLETE" && admission) {
          try {
            await birthCleanup.finish(db, admission);
            return;
          } catch (_) {
            // Historical residues fail closed; no automatic reopening here.
          }
        }
        console.error("[cleanupUserData] Falha na limpeza pós-exclusão.");
        throw new Error("USER_DATA_CLEANUP_FAILED");
      }
    });
