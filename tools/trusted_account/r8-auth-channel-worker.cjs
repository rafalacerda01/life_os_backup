'use strict';
// No Firestore client or credentials are supplied to this adversarial actor.
// It copies a genuine OLD claim only as an attack; it never provisions B.
const path=require('node:path'),{createRequire}=require('node:module');
const req=createRequire(path.resolve(__dirname,'../../backend/package.json'));
const {initializeApp,deleteApp}=req('firebase-admin/app'),{getAuth}=req('firebase-admin/auth');
if(process.env.GCLOUD_PROJECT!=='demo-life-os')throw Error('DEMO_REQUIRED');
process.once('message',async input=>{let app;try{
 if(typeof input.uid!=='string'||typeof input.generation!=='string'||!input.email?.endsWith('@example.invalid'))throw Error('SYNTHETIC_INPUT_REQUIRED');
 app=initializeApp({projectId:'demo-life-os',credential:{getAccessToken:async()=>({access_token:'owner',expires_in:3600})}},'r4-auth-only');const auth=getAuth(app);
 await auth.createUser({uid:input.uid,email:input.email,password:input.password});
 await auth.setCustomUserClaims(input.uid,{lifeos_generation:input.generation});
 await deleteApp(app);app=null;
 process.send({kind:'auth-created-and-old-claim-copied',pid:process.pid,operations:{createUser:1,setCustomUserClaims:1,deleteUser:0}},()=>process.disconnect());
 }catch{if(app)await deleteApp(app);process.exitCode=1;process.send({kind:'auth-worker-failed'},()=>process.disconnect());}
});
