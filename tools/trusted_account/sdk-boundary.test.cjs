'use strict';
// Real installed Web SDK + real Auth/Firestore Emulators. This does not execute
// Android/iOS. Admin actions below are adversarial/synthetic, not new-cohort proof.
const test=require('node:test'),assert=require('node:assert/strict'),path=require('node:path'),{createRequire}=require('node:module');
const req=createRequire(path.resolve(__dirname,'../../backend/package.json')),web=createRequire(path.resolve(__dirname,'../firestore_rules/package.json'));
const wa=web('firebase/app'),au=web('firebase/auth'),fw=web('firebase/firestore');
const {initializeApp,deleteApp}=req('firebase-admin/app'),{getAuth}=req('firebase-admin/auth'),{Firestore}=req('firebase-admin/firestore'),{GoogleAuth,OAuth2Client}=req('google-auth-library');
const core=req('./api/account/_trusted_account.cjs'),r5=req('./api/account/_deletion_control.cjs');
const app=initializeApp({projectId:'demo-life-os',credential:{getAccessToken:async()=>({access_token:'owner',expires_in:3600})}},'sdk-boundary-admin'),auth=getAuth(app),owner=new OAuth2Client();owner.setCredentials({access_token:'owner',expiry_date:Date.now()+3600000});
const db=new Firestore({projectId:'demo-life-os',databaseId:'(default)',host:process.env.FIRESTORE_EMULATOR_HOST,ssl:false,auth:new GoogleAuth({projectId:'demo-life-os',authClient:owner})});
const [host,port]=process.env.FIRESTORE_EMULATOR_HOST.split(':');let serial=0;const ga='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
test.after(async()=>{await db.terminate();await deleteApp(app);});
const timeout=async(p,ms=12000)=>{let t;try{return await Promise.race([p,new Promise((_,j)=>{t=setTimeout(()=>j(Error('SDK_BOUNDARY_TIMEOUT')),ms)})])}finally{clearTimeout(t)}};
async function request(method,body){const res=await fetch('http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST+'/identitytoolkit.googleapis.com/v1/accounts:'+method+'?key=demo-key',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});if(!res.ok)throw Error('AUTH_TEST_REQUEST_REFUSED');return res.json();}
async function account(){const email='sdk-boundary-'+(++serial)+'@example.invalid',password='Synthetic-local-19!',value=await request('signUp',{email,password,returnSecureToken:true}),decoded=await auth.verifyIdToken(value.idToken,true);await core.provision(db,auth,decoded);return{uid:value.localId,email,password,decoded};}
async function client(f, name){const app=wa.initializeApp({apiKey:'demo-key',projectId:'demo-life-os',appId:'demo-sdk-app'},name ?? 'sdk-boundary-'+(++serial)),a=au.getAuth(app);au.connectAuthEmulator(a,'http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST,{disableWarnings:true});const store=fw.initializeFirestore(app,{localCache:fw.memoryLocalCache()}),ref=fw.doc(store,'users/'+f.uid);fw.connectFirestoreEmulator(store,host,Number(port));await au.signInWithEmailAndPassword(a,f.email,f.password);return{app,a,store,ref,close:async()=>{await fw.terminate(store);await wa.deleteApp(app)}};}
async function queued(c,name='A offline'){await fw.getDocFromServer(c.ref);await fw.disableNetwork(c.store);let complete=false;const outcome=fw.updateDoc(c.ref,{displayName:name}).then(()=>{complete=true;return{status:'fulfilled'}},e=>{complete=true;return{status:'rejected',code:e.code}});const local=await fw.getDocFromCache(c.ref);assert.equal(local.metadata.hasPendingWrites,true);assert.equal(local.data().displayName,name);assert.equal(complete,false);return{outcome,complete:()=>complete};}
async function writer(decoded,uid,name='gateway'){return core.runAuthenticated(decoded,()=>db.runTransaction(async tx=>{await r5.assertNormalWriterTransaction(tx,db,uid);tx.update(db.doc('users/'+uid),{displayName:name});}));}

test('SDK offline A -> login B: no false ACK, queue stays with A, B preserved, legitimate A resumes', {timeout:25000},async()=>{
 const a=await account(),b=await account(),c=await client(a);try{
  const old=await db.doc('users/'+a.uid).get(),peer=await db.doc('users/'+b.uid).get(),q=await queued(c);
  await au.signOut(c.a);await au.signInWithEmailAndPassword(c.a,b.email,b.password);await fw.enableNetwork(c.store);
  await fw.getDocFromServer(fw.doc(c.store,'users/'+b.uid));assert.equal(q.complete(),false);assert.ok((await db.doc('users/'+a.uid).get()).updateTime.isEqual(old.updateTime));assert.ok((await db.doc('users/'+b.uid).get()).updateTime.isEqual(peer.updateTime));
  await au.signOut(c.a);await au.signInWithEmailAndPassword(c.a,a.email,a.password);assert.deepEqual(await timeout(q.outcome),{status:'fulfilled'});assert.equal((await db.doc('users/'+a.uid).get()).data().displayName,'A offline');assert.ok((await db.doc('users/'+b.uid).get()).updateTime.isEqual(peer.updateTime));
 }finally{await c.close()}
});

test('same UID recreated without genesis: SDK replays old A queue but Rules/gateway deny; A/B evidence preserved',{timeout:25000},async()=>{
 const a=await account(),c=await client(a);try{
  const origin=await db.doc('trusted_account_origins/'+a.uid).get();await db.doc('users/'+a.uid+'/notes/A').set({preserve:'A'});const q=await queued(c);await au.signOut(c.a);await auth.deleteUser(a.uid);
  const b={uid:a.uid,email:'sdk-recreated-'+(++serial)+'@example.invalid',password:'Synthetic-local-19!'};await auth.createUser(b);await db.doc('users/'+a.uid).set({displayName:'B protected',_lifeosGeneration:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'});const snapshot=await db.doc('users/'+a.uid).get();
  const login=await au.signInWithEmailAndPassword(c.a,b.email,b.password),decoded=await auth.verifyIdToken(await login.user.getIdToken());await fw.enableNetwork(c.store);
  assert.deepEqual(await timeout(q.outcome),{status:'rejected',code:'permission-denied'});await assert.rejects(writer(decoded,a.uid));assert.ok((await db.doc('users/'+a.uid).get()).updateTime.isEqual(snapshot.updateTime));assert.deepEqual((await db.doc('users/'+a.uid+'/notes/A').get()).data(),{preserve:'A'});assert.ok((await db.doc('trusted_account_origins/'+a.uid).get()).updateTime.isEqual(origin.updateTime));
 }finally{await c.close()}
});

test('changed generation while offline: original write and gateway retry cannot use the new token',{timeout:25000},async()=>{
 const a=await account(),c=await client(a);try{const original=await db.doc('users/'+a.uid).get(),q=await queued(c);await auth.setCustomUserClaims(a.uid,{lifeos_generation:ga});await c.a.currentUser.getIdToken(true);const decoded=await auth.verifyIdToken(await c.a.currentUser.getIdToken());await fw.enableNetwork(c.store);assert.deepEqual(await timeout(q.outcome),{status:'rejected',code:'permission-denied'});await assert.rejects(writer(decoded,a.uid));assert.ok((await db.doc('users/'+a.uid).get()).updateTime.isEqual(original.updateTime));}finally{await c.close()}
});

for(const control of ['retired_auth_identities','account_deletion_guards','account_deletion_guards/UID/control/operation'])test('pending SDK/gateway writes obey R5 '+control,{timeout:25000},async()=>{
 const a=await account(),c=await client(a);try{const original=await db.doc('users/'+a.uid).get(),q=await queued(c),p=control.includes('/UID/')?control.replace('/UID/','/'+a.uid+'/'):control+'/'+a.uid;await db.doc(p).set({malformed:true});await fw.enableNetwork(c.store);assert.deepEqual(await timeout(q.outcome),{status:'rejected',code:'permission-denied'});await assert.rejects(writer(a.decoded,a.uid));assert.ok((await db.doc('users/'+a.uid).get()).updateTime.isEqual(original.updateTime));}finally{await c.close()}
});

test('legacy Auth without server generation cannot send SDK writes or gateway mutations',{timeout:25000},async()=>{
 const legacy={uid:'sdk-legacy-'+(++serial),email:'sdk-legacy-'+serial+'@example.invalid',password:'Synthetic-local-19!'};await auth.createUser(legacy);await db.doc('users/'+legacy.uid).set({displayName:'Legacy protected'});const original=await db.doc('users/'+legacy.uid).get(),c=await client(legacy);try{await assert.rejects(fw.updateDoc(c.ref,{displayName:'unauthorized'}),e=>e.code==='permission-denied');await assert.rejects(writer(await auth.verifyIdToken(await c.a.currentUser.getIdToken()),legacy.uid));assert.ok((await db.doc('users/'+legacy.uid).get()).updateTime.isEqual(original.updateTime));}finally{await c.close()}
});

test('real SDK memory cache crosses Auth sessions; server read denies A to B (cache is not proof)',{timeout:25000},async()=>{
 const a=await account(),b=await account(),c=await client(a);try{const known=await fw.getDocFromServer(c.ref);await fw.disableNetwork(c.store);await au.signOut(c.a);await au.signInWithEmailAndPassword(c.a,b.email,b.password);const cached=await fw.getDocFromCache(c.ref);assert.equal(cached.metadata.fromCache,true);assert.deepEqual(cached.data(),known.data());await fw.enableNetwork(c.store);await assert.rejects(fw.getDocFromServer(c.ref),e=>e.code==='permission-denied');}finally{await c.close()}
});

test('waitForPendingWrites rejects on Auth change; it does not confirm the original operation',{timeout:25000},async()=>{
 const a=await account(),b=await account(),c=await client(a);try{const q=await queued(c);const drain=fw.waitForPendingWrites(c.store).then(()=>({ok:true}),e=>({ok:false,code:e.code}));await au.signOut(c.a);assert.equal((await timeout(drain)).ok,false);assert.equal(q.complete(),false);await au.signInWithEmailAndPassword(c.a,b.email,b.password);await fw.enableNetwork(c.store);await fw.getDocFromServer(fw.doc(c.store,'users/'+b.uid));assert.equal(q.complete(),false);}finally{await c.close()}
});

// Deliberately RED: an unrestricted Admin can copy the old claim into recreated
// Auth. This is not a supported genesis. Neither client UID nor Rules can prove
// non-reuse against that authority. Keep this oracle; do not call its failure GO.
test('RED_R8: reused Auth UID with copied old generation MUST preserve the replacement profile',{timeout:25000},async()=>{
 const a=await account(),c=await client(a);try{const q=await queued(c,'old A must not become B');await au.signOut(c.a);await auth.deleteUser(a.uid);const b={uid:a.uid,email:'sdk-privileged-'+(++serial)+'@example.invalid',password:'Synthetic-local-19!'};await auth.createUser(b);await auth.setCustomUserClaims(a.uid,{lifeos_generation:a.decoded.lifeos_generation});await db.doc('users/'+a.uid).set({displayName:'B must survive',_lifeosGeneration:a.decoded.lifeos_generation});const before=await db.doc('users/'+a.uid).get();await au.signInWithEmailAndPassword(c.a,b.email,b.password);await fw.enableNetwork(c.store);const result=await timeout(q.outcome),after=await db.doc('users/'+a.uid).get();assert.deepEqual({result,preserved:after.updateTime.isEqual(before.updateTime),displayName:after.data().displayName},{result:{status:'rejected',code:'permission-denied'},preserved:true,displayName:'B must survive'});}finally{await c.close()}
});


test('real Web SDK process death loses volatile dispatch but never ACKs or mutates server; original intent may resume',{timeout:25000},async()=>{
 const a=await account(),before=await db.doc('users/'+a.uid).get();const child=require('node:child_process').fork(path.join(__dirname,'sdk-boundary-worker.cjs'),[],{env:{...process.env},windowsHide:true,stdio:['ignore','ignore','ignore','ipc']});
 try{const queued=await timeout(new Promise((resolve,reject)=>{child.once('message',resolve);child.once('error',reject);child.once('exit',()=>reject(Error('WORKER_EXIT_BEFORE_PENDING')));child.send({uid:a.uid,email:a.email,password:a.password});}));assert.deepEqual(queued,{type:'pending',ack:false});await new Promise(resolve=>{child.once('exit',resolve);child.kill();});assert.ok((await db.doc('users/'+a.uid).get()).updateTime.isEqual(before.updateTime));
 const c=await client(a,'sdk-process-boundary');try{await fw.disableNetwork(c.store);await assert.rejects(fw.getDocFromCache(c.ref),e=>e.code==='unavailable');await fw.enableNetwork(c.store);assert.ok((await db.doc('users/'+a.uid).get()).updateTime.isEqual(before.updateTime));await fw.updateDoc(c.ref,{displayName:'explicit replay of original intent'});assert.equal((await db.doc('users/'+a.uid).get()).data().displayName,'explicit replay of original intent');}finally{await c.close()}
 }finally{if(child.exitCode===null&&!child.killed)child.kill();}
});

test('multiple actual SDK listeners can emit A cache after switching to B; cache is never admission',{timeout:25000},async()=>{
 const a=await account(),b=await account(),c=await client(a);const stop=[];try{const old=await fw.getDocFromServer(c.ref);await fw.disableNetwork(c.store);await au.signOut(c.a);await au.signInWithEmailAndPassword(c.a,b.email,b.password);
 const first=()=>timeout(new Promise((resolve,reject)=>{stop.push(fw.onSnapshot(c.ref,{includeMetadataChanges:true},snapshot=>{if(snapshot.exists())resolve({cache:snapshot.metadata.fromCache,data:snapshot.data()})},reject));}));
 const results=await Promise.all([first(),first()]);for(const r of results){assert.equal(r.cache,true);assert.deepEqual(r.data,old.data());}
 for(const unsubscribe of stop)unsubscribe();stop.length=0;await fw.enableNetwork(c.store);await assert.rejects(fw.getDocFromServer(c.ref),e=>e.code==='permission-denied');
 }finally{for(const unsubscribe of stop)unsubscribe();await c.close()}
});
