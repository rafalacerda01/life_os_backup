const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

// Inicializa o Admin SDK
admin.initializeApp();

exports.cleanupUserData = functions.auth.user().onDelete(async (user) => {
  const uid = user.uid;
  const db = admin.firestore();
  const userRef = db.collection("users").doc(uid);

  console.log(
      `[v1] Iniciando exclusão em cascata para: ${uid}`,
  );

  try {
    // Apaga o documento principal e as subcoleções
    // ignorando limites do client-side
    await db.recursiveDelete(userRef);

    console.log(
        `[v1] Erradicação concluída para o usuário: ${uid}`,
    );
  } catch (error) {
    console.error(`[v1] Erro na exclusão:`, error);
  }
});
