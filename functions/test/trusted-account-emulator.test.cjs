'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),{createRequire}=require('node:module');
const req=createRequire(require('node:path').join(__dirname,'../../backend/package.json')),freq=createRequire(require('node:path').join(__dirname,'../package.json'));
const {initializeApp,deleteApp}=req('firebase-admin/app'),{getAuth}=req('firebase-admin/auth'),{Firestore}=req('firebase-admin/firestore'),{GoogleAuth,OAuth2Client}=req('google-auth-library');
const core=req('./api/account/_trusted_account.cjs');
const app=initializeApp({projectId:'demo-life-os',credential:{getAccessToken:async()=>({access_token:'owner',expires_in:3600})}},'trusted-native');const auth=getAuth(app);
const owner=new OAuth2Client();owner.setCredentials({access_token:'owner',expiry_date:Date.now()+3600000});
const db=new Firestore({projectId:'demo-life-os',databaseId:'(default)',host:process.env.FIRESTORE_EMULATOR_HOST,ssl:false,auth:new GoogleAuth({projectId:'demo-life-os',authClient:owner})});
test.after(async()=>{await db.terminate();await deleteApp(app);});
async function request(method,body){const response=await fetch('http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST+'/identitytoolkit.googleapis.com/v1/accounts:'+method+'?key=demo-key',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const value=await response.json();if(!response.ok)throw Error('AUTH_EMULATOR:'+value.error?.message);return value;}
let serial=0;
async function password(){const email='trusted'+(++serial)+'@example.invalid',password='Synthetic-only-19!';const value=await request('signUp',{email,password,returnSecureToken:true});return{...value,email,password,decoded:await auth.verifyIdToken(value.idToken,true)};}
test('real client signup -> provider blocking hook -> Auth claim -> independent server receipt -> atomic profile',async()=>{
 const f=await password();assert.match(f.decoded.lifeos_generation,/^[a-f0-9-]{36}$/);
 const origin=db.doc('trusted_account_origins/'+f.localId);assert.equal((await origin.get()).data().state,'RESERVED');assert.equal((await db.doc('users/'+f.localId).get()).exists,false);
 assert.deepEqual(await core.provision(db,auth,f.decoded),{state:'READY',generation:f.decoded.lifeos_generation});
 assert.equal((await origin.get()).data().state,'ACTIVE');assert.equal((await db.doc('users/'+f.localId).get()).data()._lifeosGeneration,f.decoded.lifeos_generation);
 const snap=await db.doc('users/'+f.localId).get();await core.provision(db,auth,f.decoded);assert.ok((await db.doc('users/'+f.localId).get()).updateTime.isEqual(snap.updateTime));
 const login=await request('signInWithPassword',{email:f.email,password:f.password,returnSecureToken:true});assert.equal((await auth.verifyIdToken(login.idToken,true)).lifeos_generation,f.decoded.lifeos_generation);
});
test('Google creation uses the same provider-blocking origin, not email or client profile',async()=>{
 const encode=v=>Buffer.from(JSON.stringify(v)).toString('base64url');const oauth=encode({alg:'none',typ:'JWT'})+'.'+encode({iss:'https://accounts.google.com',aud:'demo-client',sub:'google-trusted-'+(++serial),email:'google'+serial+'@example.invalid',email_verified:true,name:'Synthetic Google'})+'.';
 const value=await request('signInWithIdp',{postBody:'id_token='+oauth+'&providerId=google.com',requestUri:'http://localhost',returnSecureToken:true});const decoded=await auth.verifyIdToken(value.idToken,true);assert.ok(decoded.lifeos_generation);await core.provision(db,auth,decoded);assert.equal((await db.doc('trusted_account_origins/'+value.localId).get()).data().generation,decoded.lifeos_generation);
});
test('old private/orphan and peer B survive Admin UID reuse without original claim',async()=>{
 const f=await password();await core.provision(db,auth,f.decoded);await db.doc('users/'+f.localId+'/notes/A').set({owner:'A'});await db.doc('users/'+f.localId+'-B').set({owner:'B'});
 await auth.deleteUser(f.localId);await auth.createUser({uid:f.localId,email:'recreated'+serial+'@example.invalid'});
 await assert.rejects(core.provision(db,auth,f.decoded),e=>e.code==='TRUSTED_ACCOUNT_REVIEW_REQUIRED');
 assert.deepEqual((await db.doc('users/'+f.localId+'/notes/A').get()).data(),{owner:'A'});assert.deepEqual((await db.doc('users/'+f.localId+'-B').get()).data(),{owner:'B'});
});
test('legacy Admin-created identity cannot claim profile or orphan descendants',async()=>{
 const uid='legacy-orphan-trusted';await auth.createUser({uid});await db.doc('users/'+uid+'/missing/parent/deeper/orphan').set({old:true});
 await assert.rejects(core.provision(db,auth,{uid}),e=>e.code==='TRUSTED_ACCOUNT_REVIEW_REQUIRED');assert.equal((await db.doc('users/'+uid+'/missing/parent/deeper/orphan').get()).exists,true);
});
test('reservation fences writers; only verified request generation can write ACTIVE account',async()=>{
 const f=await password(),control=req('./api/account/_deletion_control.cjs');
 const write=()=>db.runTransaction(async tx=>{await control.assertNormalWriterTransaction(tx,db,f.localId);tx.create(db.doc('users/'+f.localId+'/notes/write'),{new:true});});
 await assert.rejects(core.runAuthenticated(f.decoded,write));await core.provision(db,auth,f.decoded);await assert.rejects(write());await assert.rejects(core.runAuthenticated({uid:f.localId,lifeos_generation:'wrong'},write));await core.runAuthenticated(f.decoded,write);assert.equal((await db.doc('users/'+f.localId+'/notes/write').get()).exists,true);
});
test('project/config mismatch is CLOSED before Auth or Firestore effects',async()=>{
 await assert.rejects(core.beforeCreate({projectId:'life-os-27b92',databaseId:'(default)'},{uid:'u'},{}),e=>e.code==='TRUSTED_ACCOUNT_CLOSED');
});

test('residue after reservation causes durable review and cannot be adopted on retry',async()=>{
 const f=await password(),path='users/'+f.localId+'/missing/parent/deeper/orphan';await db.doc(path).set({old:'A'});const snap=await db.doc(path).get();
 await assert.rejects(core.provision(db,auth,f.decoded),e=>e.code==='TRUSTED_ACCOUNT_REVIEW_REQUIRED');
 assert.equal((await db.doc('trusted_account_origins/'+f.localId).get()).data().state,'REVIEW_REQUIRED');assert.ok((await db.doc(path).get()).updateTime.isEqual(snap.updateTime));
 await assert.rejects(core.provision(db,auth,f.decoded));assert.equal((await db.doc('users/'+f.localId).get()).exists,false);
});
test('real token and prototype Rules allow own generation only; client cannot mint provenance',async()=>{
 const web=createRequire(require('node:path').join(__dirname,'../../tools/firestore_rules/package.json'));
 const wa=web('firebase/app'),au=web('firebase/auth'),fw=web('firebase/firestore');
 const f=await password(),client=wa.initializeApp({projectId:'demo-life-os',apiKey:'demo-key',appId:'demo-app'},'trusted-rules');
 const clientAuth=au.getAuth(client);au.connectAuthEmulator(clientAuth,'http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST,{disableWarnings:true});
 const store=fw.getFirestore(client),[host,port]=process.env.FIRESTORE_EMULATOR_HOST.split(':');fw.connectFirestoreEmulator(store,host,Number(port));
 try{
  await au.signInWithEmailAndPassword(clientAuth,f.email,f.password);
  assert.equal((await fw.getDoc(fw.doc(store,'trusted_account_origins/'+f.localId))).data().state,'RESERVED');
  await assert.rejects(fw.getDoc(fw.doc(store,'users/'+f.localId)),e=>e.code==='permission-denied');
  await core.provision(db,auth,f.decoded);
  assert.equal((await fw.getDoc(fw.doc(store,'users/'+f.localId))).data()._lifeosGeneration,f.decoded.lifeos_generation);
  await fw.updateDoc(fw.doc(store,'users/'+f.localId),{displayName:'Trusted name'});
  await assert.rejects(fw.updateDoc(fw.doc(store,'users/'+f.localId),{_lifeosGeneration:'forged'}),e=>e.code==='permission-denied');
  await assert.rejects(fw.setDoc(fw.doc(store,'trusted_account_origins/'+f.localId),{state:'ACTIVE',generation:'forged'}),e=>e.code==='permission-denied');
  const peer='rules-B-'+f.localId;await db.doc('users/'+peer).set({keep:'B'});await assert.rejects(fw.getDoc(fw.doc(store,'users/'+peer)),e=>e.code==='permission-denied');
  const circle='trusted-circle-'+f.localId,batch=fw.writeBatch(store);
  batch.set(fw.doc(store,'circles/'+circle),{name:'Trusted circle',description:'Synthetic',adminId:f.localId,memberCount:1,memberLimit:3,challengeCount:0,lastChallengeId:null,createdAt:fw.serverTimestamp(),updatedAt:fw.serverTimestamp(),schemaVersion:2});
  batch.set(fw.doc(store,'circles/'+circle+'/members/'+f.localId),{role:'admin',displayNameSnapshot:'Trusted name',photoUrlSnapshot:null,joinedAt:fw.serverTimestamp()});batch.update(fw.doc(store,'users/'+f.localId),{activeCircleId:circle});await batch.commit();
  assert.equal((await db.doc('circles/'+circle).get()).data().adminId,f.localId);
 }finally{await au.signOut(clientAuth);await fw.terminate(store);await wa.deleteApp(client);}
});

test('genuine blocking genesis admits complete K01 deletion with immutable origin retirement',async()=>{
 const f=await password();await core.provision(db,auth,f.decoded);
 await core.runAuthenticated(f.decoded,()=>db.runTransaction(async tx=>{await req('./api/account/_deletion_control.cjs').assertNormalWriterTransaction(tx,db,f.localId);tx.create(db.doc('users/'+f.localId+'/notes/original'),{owner:'A'});}));
 await db.doc('users/'+f.localId+'-B').set({keep:'B'});
 const {deleteAccount}=await import(require('node:url').pathToFileURL(req.resolve('./api/account/delete.js')).href);
 assert.deepEqual(await core.runAuthenticated(f.decoded,()=>deleteAccount({db,auth,uid:f.localId})),{body:{deleted:true,circleDeleted:false}});
 await assert.rejects(auth.getUser(f.localId),e=>e.code==='auth/user-not-found');assert.equal((await db.doc('users/'+f.localId).get()).exists,false);
 assert.equal((await db.doc('trusted_account_origins/'+f.localId).get()).data().state,'RETIRED');assert.equal((await db.doc('account_deletion_guards/'+f.localId+'/control/operation').get()).data().state,'COMPLETE');
 assert.deepEqual((await db.doc('users/'+f.localId+'-B').get()).data(),{keep:'B'});
});
test('genuine admission with applied Auth deletion and lost response remains UNKNOWN and cannot redispatch',async()=>{
 const f=await password();await core.provision(db,auth,f.decoded);let calls=0;const ports={app:auth.app,getUser:auth.getUser.bind(auth),deleteUser:async uid=>{calls++;await auth.deleteUser(uid);throw Error('INJECTED_LOST_AUTH_RESPONSE');}};
 const {deleteAccount}=await import(require('node:url').pathToFileURL(req.resolve('./api/account/delete.js')).href);
 for(let i=0;i<2;i++)await assert.rejects(deleteAccount({db,auth:ports,uid:f.localId}),e=>e.code==='ACCOUNT_DELETION_BLOCKED');
 assert.equal(calls,1);assert.equal((await db.doc('users/'+f.localId).get()).exists,true);assert.equal((await db.doc('account_deletion_guards/'+f.localId+'/control/operation').get()).data().state,'IN_PROGRESS');
 const hash=require('node:crypto').createHash('sha256').update('users/'+f.localId).digest('hex');assert.equal((await db.doc('account_deletion_guards/'+f.localId+'/cleanup_manifests/'+hash).get()).data().authOutcome,'UNKNOWN');
});
test('genuine admission reaches real destructive transaction; recreated A/B and DENY survive',async()=>{
 const f=await password();await core.provision(db,auth,f.decoded);const root='users/'+f.localId;await db.doc(root+'/notes/old').set({old:true});await db.doc(root+'-B').set({keep:'B'});
 let reached=0,lookups=0,atPause=0;const ports={app:auth.app,getUser:async uid=>{lookups++;return auth.getUser(uid);},deleteUser:auth.deleteUser.bind(auth)};
 const hash=require('node:crypto').createHash('sha256').update(root).digest('hex'),page='account_deletion_guards/'+f.localId+'/cleanup_manifests/'+hash+'/pages/0';
 const wrapped={projectId:db.projectId,databaseId:db.databaseId,doc:db.doc.bind(db),collection:db.collection.bind(db),collectionGroup:db.collectionGroup.bind(db),runTransaction:(fn,...opts)=>db.runTransaction(tx=>fn(new Proxy(tx,{get(t,k){if(k==='get')return async ref=>{const value=await t.get(ref);if(!reached&&ref.path===page&&value.data()?.done===false){reached++;atPause=lookups;await auth.createUser({uid:f.localId});await db.doc(root).delete();await db.doc(root).create({recreated:'A'});await db.doc(root+'/notes/recreated').set({recreated:'A-child'});}return value;};return typeof t[k]==='function'?t[k].bind(t):t[k];}})),...opts)};
 const {deleteAccount}=await import(require('node:url').pathToFileURL(req.resolve('./api/account/delete.js')).href);
 await assert.rejects(deleteAccount({db:wrapped,auth:ports,uid:f.localId}),e=>e.code==='ACCOUNT_DELETION_BLOCKED');assert.equal(reached,1);assert.equal(lookups,atPause,'preservation must come from transaction versions, not a later Auth lookup');
 assert.deepEqual((await db.doc(root).get()).data(),{recreated:'A'});assert.deepEqual((await db.doc(root+'/notes/recreated').get()).data(),{recreated:'A-child'});assert.deepEqual((await db.doc(root+'-B').get()).data(),{keep:'B'});
 assert.equal((await auth.getUser(f.localId)).uid,f.localId);assert.equal((await db.doc('retired_auth_identities/'+f.localId).get()).exists,true);assert.equal((await db.doc('account_deletion_guards/'+f.localId+'/control/operation').get()).data().state,'IN_PROGRESS');assert.equal((await db.doc('account_deletion_guards/'+f.localId+'/cleanup_manifests/'+hash).get()).data().state,'QUARANTINED');
});

test('genuine original operation resumes in Functions after confirmed Auth reply loss; duplicate and delayed event preserve B',async()=>{
 const f=await password();await core.provision(db,auth,f.decoded);const deletedUser=await auth.getUser(f.localId);let injected=false;
 const wrapped={projectId:db.projectId,databaseId:db.databaseId,doc:db.doc.bind(db),collection:db.collection.bind(db),collectionGroup:db.collectionGroup.bind(db),runTransaction:async(fn,...opts)=>{let confirmed=false;const result=await db.runTransaction(tx=>fn(new Proxy(tx,{get(t,k){if(k==='update')return(ref,data,...args)=>{confirmed ||= data?.authOutcome==='CONFIRMED';return t.update(ref,data,...args);};return typeof t[k]==='function'?t[k].bind(t):t[k];}})),...opts);if(confirmed&&!injected){injected=true;throw Error('INJECTED_LOST_CONFIRMED_REPLY');}return result;}};
 const {deleteAccount}=await import(require('node:url').pathToFileURL(req.resolve('./api/account/delete.js')).href);await assert.rejects(deleteAccount({db:wrapped,auth,uid:f.localId}),e=>e.code==='ACCOUNT_DELETION_BLOCKED');assert.equal(injected,true);
 const {Firestore:FF}=freq('firebase-admin/firestore'),{GoogleAuth:FG,OAuth2Client:FO}=freq('google-auth-library'),o=new FO();o.setCredentials({access_token:'owner',expiry_date:Date.now()+3600000});const fdb=new FF({projectId:'demo-life-os',databaseId:'(default)',host:process.env.FIRESTORE_EMULATOR_HOST,ssl:false,auth:new FG({projectId:'demo-life-os',authClient:o})});
 const Module=require('node:module'),load=Module._load;let callback;
 try{Module._load=function(id,...a){if(id==='firebase-admin')return{initializeApp:()=>{},firestore:()=>fdb,auth:()=>auth};return load.call(this,id,...a);};callback=freq('./index.js').cleanupUserData;}finally{Module._load=load;}
 const context={eventId:'actual-genesis-deletion-'+f.localId,eventType:'google.firebase.auth.user.delete',timestamp:new Date().toISOString(),resource:{service:'firebaseauth.googleapis.com',name:'projects/demo-life-os'}};
 try{
  await callback.run(deletedUser,context);assert.equal((await db.doc('users/'+f.localId).get()).exists,false);const origin=await db.doc('trusted_account_origins/'+f.localId).get();assert.equal(origin.data().state,'RETIRED');
  await callback.run(deletedUser,context);assert.ok((await db.doc('trusted_account_origins/'+f.localId).get()).updateTime.isEqual(origin.updateTime));
  await auth.createUser({uid:f.localId});await db.doc('users/'+f.localId).set({recreated:'B'});await assert.rejects(callback.run(deletedUser,context),/USER_DATA_CLEANUP_FAILED/);assert.deepEqual((await db.doc('users/'+f.localId).get()).data(),{recreated:'B'});assert.equal((await db.doc('account_deletion_guards/'+f.localId+'/control/operation').get()).data().state,'COMPLETE');
 }finally{await fdb.terminate();}
});
test('genuine genesis cleanup removes the contracted private/Circle/Billing scope and leaves independent B',async()=>{
 const f=await password();await core.provision(db,auth,f.decoded);const circle='cleanup-circle-'+f.localId,hash=require('node:crypto').createHash('sha256').update(f.localId).digest('hex'),stamp=req('firebase-admin/firestore').Timestamp.now();
 await core.runAuthenticated(f.decoded,()=>db.runTransaction(async tx=>{await req('./api/account/_deletion_control.cjs').assertNormalWriterTransaction(tx,db,f.localId);
  tx.update(db.doc('users/'+f.localId),{activeCircleId:circle});tx.create(db.doc('circles/'+circle),{name:'Trusted',description:'Synthetic',schemaVersion:2,adminId:f.localId,memberCount:1,memberLimit:3,createdAt:stamp,updatedAt:stamp});
  tx.create(db.doc('circles/'+circle+'/members/'+f.localId),{role:'admin',displayNameSnapshot:'Trusted',photoUrlSnapshot:null,joinedAt:stamp});tx.create(db.doc('circles/'+circle+'/missing/parent/deep/orphan'),{owned:true});
  tx.create(db.doc('billing_google_accounts/'+hash),{uid:f.localId,state:'ACTIVE'});tx.create(db.doc('billing_google_tokens/'+hash),{accountHash:hash});}));
 await db.doc('users/'+f.localId+'-B').set({keep:'B'});
 const {deleteAccount}=await import(require('node:url').pathToFileURL(req.resolve('./api/account/delete.js')).href);assert.deepEqual(await deleteAccount({db,auth,uid:f.localId}),{body:{deleted:true,circleDeleted:true}});
 const manifest=req('./api/account/_cleanup_manifest.cjs');assert.deepEqual(await manifest.inventory(db.doc('users/'+f.localId)),[]);assert.deepEqual(await manifest.inventory(db.doc('circles/'+circle)),[]);assert.equal((await db.doc('billing_google_accounts/'+hash).get()).exists,false);assert.equal((await db.doc('billing_google_tokens/'+hash).get()).exists,false);assert.deepEqual((await db.doc('users/'+f.localId+'-B').get()).data(),{keep:'B'});
});

test('prepared onCreate service consumer provisions actual Auth identity; delayed event cannot restore',async()=>{
 const f=await password(),user=await auth.getUser(f.localId);
 const context={eventType:'google.firebase.auth.user.create',resource:{name:'projects/demo-life-os',service:'firebaseauth.googleapis.com'}};
 await core.provisionCreatedUser(db,auth,user,context);
 const root=db.doc('users/'+f.localId),snap=await root.get();
 await core.provisionCreatedUser(db,auth,user,context);assert.ok((await root.get()).updateTime.isEqual(snap.updateTime));
 await root.delete();await assert.rejects(core.provisionCreatedUser(db,auth,user,context));assert.equal((await root.get()).exists,false);
 assert.equal((await db.doc('trusted_account_origins/'+f.localId).get()).data().state,'ACTIVE');
});
test('concurrent provisioning creates one profile and preserves original server generation',async()=>{
 const f=await password();const values=await Promise.all([core.provision(db,auth,f.decoded),core.provision(db,auth,f.decoded)]);
 assert.deepEqual(values,[{state:'READY',generation:f.decoded.lifeos_generation},{state:'READY',generation:f.decoded.lifeos_generation}]);
 assert.equal((await db.doc('users/'+f.localId).get()).data()._lifeosGeneration,f.decoded.lifeos_generation);
});
test('verified request from divergent project or tenant cannot use an ACTIVE origin',async()=>{
 const f=await password();await core.provision(db,auth,f.decoded);const control=req('./api/account/_deletion_control.cjs');
 for(const decoded of [{...f.decoded,aud:'other-project'},{...f.decoded,firebase:{...f.decoded.firebase,tenant:'other-tenant'}}]){
  await assert.rejects(core.runAuthenticated(decoded,()=>db.runTransaction(tx=>control.assertNormalWriterTransaction(tx,db,f.localId))));
 }
});
