'use strict';
// Integration arrangement only: actual Auth blocking genesis, origin resolver,
// R5 controller, finite manifest and native MVCC. No injected ownership proof.
const assert=require('node:assert/strict');
let resources;
async function services(){
 if(resources)return resources;
 for(const name of ['FIRESTORE_EMULATOR_HOST','FIREBASE_AUTH_EMULATOR_HOST'])assert.match(process.env[name]||'',/^127\.0\.0\.1:\d+$/,'ISOLATED_AUTH_AND_FIRESTORE_EMULATORS_REQUIRED');
 assert.equal(process.env.GCLOUD_PROJECT,'demo-life-os');
 for(const k of ['GOOGLE_APPLICATION_CREDENTIALS','FIREBASE_PRIVATE_KEY','FIREBASE_CLIENT_EMAIL'])assert.equal(process.env[k],undefined);
 const {initializeApp,deleteApp}=require('firebase-admin/app'),{getAuth}=require('firebase-admin/auth');
 const {Firestore}=require('firebase-admin/firestore'),{GoogleAuth,OAuth2Client}=require('google-auth-library');
 const app=initializeApp({projectId:'demo-life-os'},'original-red-native');
 const owner=new OAuth2Client();owner.setCredentials({access_token:'owner',expiry_date:Date.now()+3600000});
 const db=new Firestore({projectId:'demo-life-os',databaseId:'(default)',host:process.env.FIRESTORE_EMULATOR_HOST,ssl:false,auth:new GoogleAuth({projectId:'demo-life-os',authClient:owner})});
 resources={db,auth:getAuth(app),close:async()=>{try{await db.terminate();}finally{await deleteApp(app);resources=null;}}};return resources;
}
module.exports=async function genuineOriginalOperation({deletionId,peerRoot,peerChild,t}){
 assert.equal(typeof t?.after,'function','TEST_LIFECYCLE_REQUIRED');
 const service=await services();let beforeClose=async()=>{};
 t.after(async()=>{try{await beforeClose();}finally{await service.close();}});
 const {db:store,auth}=service,core=require('../../trusted_account'),control=require('../../deletion_control'),manifest=require('../../account_cleanup_manifest'),{Timestamp}=require('firebase-admin/firestore');
 const email='original-red-'+require('node:crypto').randomUUID()+'@example.invalid';
 const response=await fetch('http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST+'/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-key',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password:'Synthetic-only-19!',returnSecureToken:true})});assert.equal(response.status,200);
 const signup=await response.json(),decoded=await auth.verifyIdToken(signup.idToken,true),uid=signup.localId;
 assert.match(decoded.lifeos_generation,/^[a-f0-9-]{36}$/);
 await core.provision(store,auth,decoded);const user=await auth.getUser(uid),rootPath='users/'+uid,guardPath='account_deletion_guards/'+uid;
 const cache=new Map(),operationLog=[];let tail=Promise.resolve(),lookups=0,recreatedAuth=null;
 const facade={projectId:'demo-life-os',databaseId:'(default)',accountUid:uid,nativeAuth:auth,
  doc:store.doc.bind(store),collection:store.collection.bind(store),collectionGroup:store.collectionGroup.bind(store),
  store:cache,operationLog,fixtureTrace:[{kind:'genuine-blocking-origin-admitted'}],versionedDeletes:[],createTimes:new Map(),
  runTransaction:(callback,...options)=>store.runTransaction(async tx=>{
    const writes=[],nativeGet=tx.get.bind(tx);
    let read=async ref=>{const snapshot=await nativeGet(ref);
      if(ref.path?.includes('/cleanup_manifests/') && ref.path.endsWith('/pages/0') && snapshot.exists && snapshot.data().done===false)facade.fixtureTrace.push({kind:'native-destructive-page-read',path:ref.path});
      return snapshot;};
    const port=new Proxy(tx,{get(t,k){
      if(k==='get')return read;
      if(['create','set','update','delete'].includes(k))return(ref,...args)=>{writes.push(k+':'+ref.path);return t[k](ref,...args);};
      return typeof t[k]==='function'?t[k].bind(t):t[k];
    },set(t,k,v){if(k==='get'){read=v;return true;}return Reflect.set(t,k,v);}});
    const value=await callback(port);return {value,writes};
  },...options).then(result=>{operationLog.push(...result.writes);return result.value;}),
  seed(path,value){tail=tail.then(async()=>{if(path===rootPath){await store.doc(path).delete();await store.doc(path).create(value);}else await store.doc(path).set(value);});},
  flush:()=>tail,
  data:path=>cache.get(path),
  authHook(){lookups++;facade.fixtureTrace.push({kind:'native-auth-lookup',count:lookups});},
  get authUser(){return recreatedAuth;},
  set authUser(value){recreatedAuth=value;tail=tail.then(()=>auth.createUser({uid}));},
  async versionedDelete(ref){facade.versionedDeletes.push(ref.path);return manifest.__nativeRemoveTree(facade.fixtureTreeOptions);},
  async refresh(){
    const paths=[rootPath,rootPath+'/notes/recreated-private',guardPath,'retired_auth_identities/'+uid,peerRoot,peerChild];
    for(const path of paths){const snap=await store.doc(path).get();if(snap.exists)cache.set(path,snap.data());else cache.delete(path);}
  },
 };
 // Ordinary data was created only while ACTIVE, through the normal-writer
 // admission in the same transaction, not copied from a previous generation.
 await core.runAuthenticated(decoded,()=>store.runTransaction(async tx=>{
   await control.assertNormalWriterTransaction(tx,store,uid);
   tx.create(store.doc(rootPath+'/notes/first'),{syntheticOldData:true});
   tx.create(store.doc(rootPath+'/notes/remaining'),{syntheticOldData:true});
 }));
 const proof=await core.resolveDeletion(facade,auth,uid),binding={projectId:facade.projectId,databaseId:facade.databaseId,uid};
 const controller=core.protectController(facade,proof,control.createController({db:facade,binding,clock:()=>Timestamp.now(),uuid:()=>deletionId,ports:{
   getAuthenticatedSubject:async()=>binding,getAuthUser:()=>auth.getUser(uid),
 }}));
 const admitted=await controller.admitBackend();assert.equal(admitted.status,'ADMITTED');
 const operation=controller.originalOperation(admitted.handle);facade.fixtureOriginalOperation=operation;
 const options={db:facade,operation,ref:store.doc(rootPath),assertOperation:tx=>controller.assertOperationTransaction(tx,admitted.handle),authorizeCapture:async()=>{const current=await auth.getUser(uid);return current.customClaims.lifeos_generation===decoded.lifeos_generation;}};
 await manifest.captureTree(options);await manifest.authOutcome(options,'NOT_REQUESTED','DISPATCHED');
 await auth.deleteUser(uid);await manifest.authOutcome(options,'DISPATCHED','CONFIRMED');
 await store.doc(peerRoot).set({syntheticOtherOwner:true});await store.doc(peerChild).set({syntheticOtherData:true});
 facade.nativeDenyRecord=(await store.doc('retired_auth_identities/'+uid).get()).data();
 assert.equal(facade.nativeDenyRecord.deletionId,deletionId);operationLog.length=0;await facade.refresh();
 return {db:facade,uid,rootPath,guardPath,authLookups:()=>lookups,user,set beforeClose(work){beforeClose=work;},
  context:{eventId:'original-red-'+uid,eventType:'google.firebase.auth.user.delete',timestamp:new Date().toISOString(),resource:{service:'firebaseauth.googleapis.com',name:'projects/demo-life-os'},params:{}},
 };
};
