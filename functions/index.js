const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

// Inicializa o Admin SDK
admin.initializeApp();

exports.cleanupUserData = functions
    .runWith({
      failurePolicy: true,
    })
    .auth.user().onDelete(async (user) => {
      const db = admin.firestore();
      const userRef = db.collection("users").doc(user.uid);

      try {
        // Apaga o documento principal e as subcoleções
        // ignorando limites do client-side
        await db.recursiveDelete(userRef);
      } catch (_) {
        console.error("[cleanupUserData] Falha na limpeza pós-exclusão.");
        throw new Error("USER_DATA_CLEANUP_FAILED");
      }
    });
