const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {Timestamp} = require("firebase-admin/firestore");

const CIRCLE_SCHEMA_VERSION = 2;
const MAX_CIRCLE_MEMBERS = 10;
const MAX_CIRCLE_CHALLENGES_TO_SCAN = 240;
const PROCESSED_EVENT_DELETE_PAGE_SIZE = 200;
const MAX_PROCESSED_EVENTS_PER_CHALLENGE = 20000;
const SERVER_DELETING = "SERVER_DELETING";
const CIRCLE_DELETION_COLLECTION = "circle_deletions";
const AUTH_DELETE_ORPHAN_VERSION = 1;
const AUTH_DELETE_ORPHAN_STATE = "AUTH_DELETE_ORPHAN_CLEANUP";

// Inicializa o Admin SDK
admin.initializeApp();

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
  if (!isSafeDocumentId(value)) throw new Error("INVALID_ACCOUNT_STATE");
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
    (circle.memberLimit !== 3 && circle.memberLimit !== 10) ||
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
 * Lista challenges raiz dentro do Circle ativo.
 * @param {Object} circleRef Referencia do Circle.
 * @return {Promise<Array<Object>>} Referencias limitadas de challenges.
 */
async function listChallengeRefs(circleRef) {
  const snapshot = await circleRef
      .collection("challenges")
      .limit(MAX_CIRCLE_CHALLENGES_TO_SCAN + 1)
      .get();
  if (snapshot.docs.length > MAX_CIRCLE_CHALLENGES_TO_SCAN) {
    throw new Error("CIRCLE_CHALLENGE_LIMIT_EXCEEDED");
  }
  return snapshot.docs.map((entry) => entry.ref);
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
 * Remove dados privados de um membro em um challenge.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {Object} challengeRef Referencia do challenge.
 * @return {Promise<void>} Conclusao da limpeza.
 */
async function cleanupChallenge(db, uid, challengeRef) {
  await deleteRefs(db, [challengeRef.collection("progress").doc(uid)]);

  const processedEvents = challengeRef.collection("processed_events");
  let deletedEvents = 0;
  for (;;) {
    const snapshot = await processedEvents
        .where("uid", "==", uid)
        .limit(PROCESSED_EVENT_DELETE_PAGE_SIZE)
        .get();
    if (snapshot.docs.length === 0) return;
    deletedEvents += snapshot.docs.length;
    if (deletedEvents > MAX_PROCESSED_EVENTS_PER_CHALLENGE) {
      throw new Error("PROCESSED_EVENT_LIMIT_EXCEEDED");
    }
    await deleteRefs(db, snapshot.docs.map((entry) => entry.ref));
  }
}

/**
 * Remove os dados do UID em todos os challenges validados.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {Array<Object>} challengeRefs Referencias a processar.
 * @return {Promise<void>} Conclusao da limpeza.
 */
async function cleanupChallenges(db, uid, challengeRefs) {
  for (const challengeRef of challengeRefs) {
    await cleanupChallenge(db, uid, challengeRef);
  }
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
 * Limpa o vinculo de um membro restante sem sobrescrever outro Circle.
 * @param {Object} db Firestore Admin.
 * @param {string} memberUid UID restante.
 * @param {string} circleId Circle sendo removido.
 * @return {Promise<void>} Conclusao da transacao.
 */
function clearMemberCircleReference(db, memberUid, circleId) {
  const userRef = db.collection("users").doc(memberUid);
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(userRef);
    const userData = snapshot.data();
    if (snapshot.exists && userData.activeCircleId === circleId) {
      transaction.update(userRef, {activeCircleId: null});
    }
  });
}

/**
 * Limpa referencias de todos os membros restantes conhecidos.
 * @param {Object} db Firestore Admin.
 * @param {string} deletedUid UID ja excluido do Auth.
 * @param {string} circleId Circle sendo removido.
 * @param {Array<Object>} members Memberships validadas.
 * @return {Promise<void>} Conclusao da limpeza.
 */
async function clearRemainingMemberReferences(
    db, deletedUid, circleId, members) {
  for (const memberSnapshot of members) {
    const memberUid = documentId(memberSnapshot.ref);
    if (memberUid !== deletedUid) {
      await clearMemberCircleReference(db, memberUid, circleId);
    }
  }
}

/**
 * Valida o tombstone permanente da limpeza pos-exclusao de Auth.
 * @param {Object} marker Dados do tombstone existente.
 * @param {string} circleId Circle esperado.
 * @return {void}
 */
function validateAuthDeleteOrphanMarker(marker, circleId) {
  if (!marker || Object.keys(marker).length !== 4 ||
      marker.version !== AUTH_DELETE_ORPHAN_VERSION ||
      marker.state !== AUTH_DELETE_ORPHAN_STATE ||
      marker.circleId !== circleId ||
      !(marker.createdAt instanceof Timestamp)) {
    throw new Error("INVALID_ORPHAN_CLEANUP_MARKER");
  }
}

/**
 * Garante o tombstone sem sobrescrever um marker existente.
 * @param {Object} transaction Transacao com todas as leituras concluidas.
 * @param {Object} markerRef Referencia do tombstone.
 * @param {Object} markerSnapshot Snapshot lido na mesma transacao.
 * @param {string} circleId Circle esperado.
 * @return {void}
 */
function ensureAuthDeleteOrphanMarkerInTransaction(
    transaction, markerRef, markerSnapshot, circleId) {
  if (markerSnapshot.exists) {
    validateAuthDeleteOrphanMarker(markerSnapshot.data(), circleId);
    return;
  }
  transaction.set(markerRef, {
    version: AUTH_DELETE_ORPHAN_VERSION,
    state: AUTH_DELETE_ORPHAN_STATE,
    circleId,
    createdAt: Timestamp.now(),
  });
}

/**
 * Marca um Circle administrado pelo UID como server-deleting.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID administrativo excluido.
 * @param {string} circleId Circle ativo.
 * @return {Promise<Array<Object>>} Memberships a desvincular.
 */
function markAdminCircleDeleting(db, uid, circleId) {
  const userRef = db.collection("users").doc(uid);
  const circleRef = db.collection("circles").doc(circleId);
  const markerRef = db.collection(CIRCLE_DELETION_COLLECTION).doc(circleId);
  const membersRef = circleRef.collection("members");

  return db.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    if (!userSnapshot.exists ||
        activeCircleIdFrom(userSnapshot.data()) !== circleId) {
      throw new Error("USER_CIRCLE_CHANGED");
    }

    const circleSnapshot = await transaction.get(circleRef);
    if (!circleSnapshot.exists) throw new Error("CIRCLE_ROOT_MISSING");
    const circle = validateCircle(circleSnapshot.data());
    if (circle.adminId !== uid) throw new Error("CIRCLE_ADMIN_CHANGED");
    if (circle.deletionState !== undefined &&
        circle.deletionState !== SERVER_DELETING) {
      throw new Error("INVALID_DELETION_STATE");
    }

    const markerSnapshot = await transaction.get(markerRef);
    const membersSnapshot = await transaction.get(
        membersRef.limit(MAX_CIRCLE_MEMBERS + 1),
    );
    const isRetry = circle.deletionState === SERVER_DELETING;
    const members = validateMembers(membersSnapshot, uid, !isRetry);
    if ((!isRetry && members.length !== circle.memberCount) ||
        (isRetry && members.length > circle.memberCount)) {
      throw new Error("CIRCLE_MEMBER_COUNT_MISMATCH");
    }

    ensureAuthDeleteOrphanMarkerInTransaction(
        transaction, markerRef, markerSnapshot, circleId,
    );
    if (!isRetry) {
      transaction.update(circleRef, {
        deletionState: SERVER_DELETING,
        updatedAt: Timestamp.now(),
      });
    }
    return members;
  });
}

/**
 * Finaliza o Circle cujo administrador ja foi excluido do Auth.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID administrativo excluido.
 * @param {string} circleId Circle ativo.
 * @return {Promise<void>} Conclusao da exclusao integral.
 */
async function cleanupAdminCircle(db, uid, circleId) {
  const circleRef = db.collection("circles").doc(circleId);
  const members = await markAdminCircleDeleting(db, uid, circleId);
  await clearRemainingMemberReferences(db, uid, circleId, members);
  await db.recursiveDelete(circleRef);
}

/**
 * Reserva um Circle ausente antes de apagar seus descendentes.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {string} circleId Circle ativo.
 * @return {Promise<Array<Object>>} Memberships validadas no claim.
 */
function claimMissingCircleRoot(db, uid, circleId) {
  const userRef = db.collection("users").doc(uid);
  const circleRef = db.collection("circles").doc(circleId);
  const markerRef = db.collection(CIRCLE_DELETION_COLLECTION).doc(circleId);

  return db.runTransaction(async (transaction) => {
    const userSnapshot = await transaction.get(userRef);
    if (!userSnapshot.exists ||
        activeCircleIdFrom(userSnapshot.data()) !== circleId) {
      throw new Error("USER_CIRCLE_CHANGED");
    }

    const circleSnapshot = await transaction.get(circleRef);
    if (circleSnapshot.exists) throw new Error("CIRCLE_ROOT_REAPPEARED");

    const markerSnapshot = await transaction.get(markerRef);
    const snapshot = await transaction.get(
        circleRef.collection("members").limit(MAX_CIRCLE_MEMBERS + 1),
    );
    const members = snapshot.docs;
    if (members.length > MAX_CIRCLE_MEMBERS) {
      throw new Error("CIRCLE_MEMBER_LIMIT_EXCEEDED");
    }
    for (const memberSnapshot of members) {
      const memberUid = documentId(memberSnapshot.ref);
      const member = memberSnapshot.data();
      const role = member ? member.role : undefined;
      if (!isSafeDocumentId(memberUid) ||
          (role !== "admin" && role !== "member")) {
        throw new Error("INVALID_MEMBER_STATE");
      }
    }

    ensureAuthDeleteOrphanMarkerInTransaction(
        transaction, markerRef, markerSnapshot, circleId,
    );
    return members;
  });
}

/**
 * Finaliza descendentes mantendo o tombstone que bloqueia recriacao.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {string} circleId Circle ativo.
 * @return {Promise<void>} Conclusao da exclusao residual.
 */
async function cleanupMissingCircleRoot(db, uid, circleId) {
  const circleRef = db.collection("circles").doc(circleId);
  const members = await claimMissingCircleRoot(db, uid, circleId);
  await clearRemainingMemberReferences(db, uid, circleId, members);
  // O root estava ausente: nunca apagar um root recriado apos o claim.
  await db.recursiveDelete(circleRef.collection("members"));
  await db.recursiveDelete(circleRef.collection("challenges"));
}

/**
 * Remove membership e dados de challenges de um membro comum.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {string} circleId Circle ativo.
 * @return {Promise<void>} Conclusao da limpeza externa.
 */
async function cleanupNormalMember(db, uid, circleId) {
  const circleRef = await resolveMemberState(db, uid, circleId, false);
  const beforeRefs = await listChallengeRefs(circleRef);
  await resolveMemberState(db, uid, circleId, true);
  const afterRefs = await listChallengeRefs(circleRef);
  const refsByPath = new Map();
  for (const ref of [...beforeRefs, ...afterRefs]) {
    refsByPath.set(ref.path, ref);
  }
  if (refsByPath.size > MAX_CIRCLE_CHALLENGES_TO_SCAN) {
    throw new Error("CIRCLE_CHALLENGE_LIMIT_EXCEEDED");
  }
  await cleanupChallenges(db, uid, [...refsByPath.values()]);
}

/**
 * Resolve e limpa referencias externas do Circle ativo.
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID excluido.
 * @param {Object} userSnapshot Snapshot inicial do usuario.
 * @return {Promise<void>} Conclusao da limpeza externa.
 */
async function cleanupExternalCircleData(db, uid, userSnapshot) {
  const circleId = activeCircleIdFrom(userSnapshot.data());
  if (circleId === null) return;

  const circleRef = db.collection("circles").doc(circleId);
  const circleSnapshot = await circleRef.get();
  if (!circleSnapshot.exists) {
    await cleanupMissingCircleRoot(db, uid, circleId);
    return;
  }

  const circle = validateCircle(circleSnapshot.data());
  if (circle.adminId === uid) {
    await cleanupAdminCircle(db, uid, circleId);
    return;
  }
  await cleanupNormalMember(db, uid, circleId);
}

exports.cleanupUserData = functions
    .runWith({
      failurePolicy: true,
    })
    .auth.user().onDelete(async (user) => {
      const db = admin.firestore();
      const userRef = db.collection("users").doc(user.uid);

      try {
        const userSnapshot = await userRef.get();
        if (userSnapshot.exists) {
          await cleanupExternalCircleData(db, user.uid, userSnapshot);
        }
        await db.recursiveDelete(userRef);
      } catch (_) {
        console.error("[cleanupUserData] Falha na limpeza pós-exclusão.");
        throw new Error("USER_DATA_CLEANUP_FAILED");
      }
    });
