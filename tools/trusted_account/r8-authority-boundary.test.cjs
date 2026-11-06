'use strict';
// A-D are separated by actual protocol/call channels, not fictional IAM mocks.
// Emulator owner is not a Cloud least-privilege service account.
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),{fork}=require('node:child_process'),{createRequire}=require('node:module');
const req=createRequire(path.resolve(__dirname,'../../backend/package.json')),web=createRequire(path.resolve(__dirname,'../firestore_rules/package.json'));
const wa=web('firebase/app'),au=web('firebase/auth'),fw=web('firebase/firestore'),{initializeApp,deleteApp}=req('firebase-admin/app'),{getAuth}=req('firebase-admin/auth'),{Firestore}=req('firebase-admin/firestore'),{GoogleAuth,OAuth2Client}=req('google-auth-library');
const core=req('./api/account/_trusted_account.cjs'),r5=req('./api/account/_deletion_control.cjs');
const app=initializeApp({projectId:'demo-life-os',credential:{getAccessToken:async()=>({access_token:'owner',expires_in:3600})}},'r4-fixture-owner'),auth=getAuth(app),owner=new OAuth2Client();owner.setCredentials({access_token:'owner',expiry_date:Date.now()+3600000});
const db=new Firestore({projectId:'demo-life-os',databaseId:'(default)',host:process.env.FIRESTORE_EMULATOR_HOST,ssl:false,auth:new GoogleAuth({projectId:'demo-life-os',authClient:owner})}),[host,port]=process.env.FIRESTORE_EMULATOR_HOST.split(':');let serial=0;
test.after(async()=>{await db.terminate();await deleteApp(app);});
async function timeout(p,ms=12000){let timer;try{return await Promise.race([p,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('R4_TIMEOUT')),ms)})]);}finally{clearTimeout(timer)}}
async function account(){const email='r4-authority-'+(++serial)+'@example.invalid',password='Synthetic-local-19!';const response=await fetch('http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST+'/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-key',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password,returnSecureToken:true})});assert.equal(response.ok,true);const value=await response.json(),decoded=await auth.verifyIdToken(value.idToken,true);await core.provision(db,auth,decoded);return{uid:value.localId,email,password,decoded};}
async function client(f){const app=wa.initializeApp({apiKey:'demo-key',projectId:'demo-life-os',appId:'demo-r4-app'},'r4-client-'+(++serial)),a=au.getAuth(app);au.connectAuthEmulator(a,'http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST,{disableWarnings:true});const store=fw.initializeFirestore(app,{localCache:fw.memoryLocalCache()});fw.connectFirestoreEmulator(store,host,Number(port));await au.signInWithEmailAndPassword(a,f.email,f.password);return{app,a,store,ref:fw.doc(store,'users/'+f.uid),close:async()=>{await fw.terminate(store);await wa.deleteApp(app)}};}
async function writeByProtocol(f,name){return core.runAuthenticated(f.decoded,()=>db.runTransaction(async tx=>{await r5.assertNormalWriterTransaction(tx,db,f.uid);tx.update(db.doc('users/'+f.uid),{displayName:name});}));}

test('A: ordinary client cannot rewrite origin/control, touch B, or manufacture admission',{timeout:25000},async()=>{
 const a=await account(),b=await account(),c=await client(a),peer=await db.doc('users/'+b.uid).get(),origin=await db.doc('trusted_account_origins/'+a.uid).get();try{
 await assert.rejects(fw.updateDoc(fw.doc(c.store,'users/'+b.uid),{displayName:'forbidden A to B'}),e=>e.code==='permission-denied');
 await assert.rejects(fw.setDoc(fw.doc(c.store,'trusted_account_origins/'+a.uid),{attempt:'not-a-proof'}),e=>e.code==='permission-denied');
 await assert.rejects(fw.setDoc(fw.doc(c.store,'account_deletion_guards/'+a.uid+'/control/operation'),{attempt:'not-an-operation'}),e=>e.code==='permission-denied');
 assert.ok((await db.doc('users/'+b.uid).get()).updateTime.isEqual(peer.updateTime));assert.ok((await db.doc('trusted_account_origins/'+a.uid).get()).updateTime.isEqual(origin.updateTime));assert.equal((await db.doc('account_deletion_guards/'+a.uid+'/control/operation').get()).exists,false);
 }finally{await c.close()}
});

test('B: real cooperative protocol is idempotent and refuses R5; restricted Cloud IAM remains unverified',{timeout:25000},async()=>{
 const a=await account(),b=await account(),origin=await db.doc('trusted_account_origins/'+a.uid).get(),peer=await db.doc('users/'+b.uid).get();
 assert.deepEqual(await core.provision(db,auth,a.decoded),{state:'READY',generation:a.decoded.lifeos_generation});assert.ok((await db.doc('trusted_account_origins/'+a.uid).get()).updateTime.isEqual(origin.updateTime));
 await writeByProtocol(a,'valid original operation');assert.equal((await db.doc('users/'+a.uid).get()).data().displayName,'valid original operation');const before=await db.doc('users/'+a.uid).get();
 await db.doc('account_deletion_guards/'+a.uid+'/control/operation').set({fixture:'deny-only'});await assert.rejects(writeByProtocol(a,'must not write'));
 assert.ok((await db.doc('users/'+a.uid).get()).updateTime.isEqual(before.updateTime));assert.ok((await db.doc('users/'+b.uid).get()).updateTime.isEqual(peer.updateTime));assert.ok((await db.doc('trusted_account_origins/'+a.uid).get()).updateTime.isEqual(origin.updateTime));
});

test('C RED: Auth-only actor recreates UID and copies old claim; replacement and old A/B MUST remain protected',{timeout:30000},async()=>{
 const a=await account(),peer=await account(),c=await client(a);let child;try{
 const origin=await db.doc('trusted_account_origins/'+a.uid).get(),peerBefore=await db.doc('users/'+peer.uid).get();await db.doc('users/'+a.uid+'/notes/old-A').set({preserve:'A'});await fw.getDocFromServer(c.ref);await fw.disableNetwork(c.store);
 const pending=fw.updateDoc(c.ref,{displayName:'queued A must not become B'}).then(()=>({status:'fulfilled'}),e=>({status:'rejected',code:e.code}));assert.equal((await fw.getDocFromCache(c.ref)).metadata.hasPendingWrites,true);
 await au.signOut(c.a);await auth.deleteUser(a.uid); // Fixture creates the post-Auth/pre-callback window; C does not need delete.
 const b={uid:a.uid,generation:a.decoded.lifeos_generation,email:'r4-auth-only-'+(++serial)+'@example.invalid',password:'Synthetic-local-19!'};
 child=fork(path.join(__dirname,'r8-auth-channel-worker.cjs'),[],{execArgv:['--require',path.join(__dirname,'r8-auth-channel-guard.cjs')],env:{...process.env},windowsHide:true,stdio:['ignore','ignore','ignore','ipc']});
 const exit=new Promise(resolve=>child.once('exit',(code,signal)=>resolve({code,signal}))),reply=new Promise((resolve,reject)=>{child.once('message',resolve);child.once('error',reject);});child.send(b);const result=await timeout(reply);assert.equal(result.kind,'auth-created-and-old-claim-copied');assert.deepEqual(result.operations,{createUser:1,setCustomUserClaims:1,deleteUser:0});assert.equal((await timeout(exit)).code,0);
 const audit=JSON.parse(fs.readFileSync(path.join(process.env.K01_EVIDENCE_DIR,'auth-channel-'+result.pid+'.json')));assert.equal(audit.allowedHost,process.env.FIREBASE_AUTH_EMULATOR_HOST);assert.ok(audit.connections>0);assert.deepEqual(audit.refused,[]);assert.equal(audit.notAnIamPolicy,true);
 // UI sentinel only. No origin/generation field is created or changed; B is
 // deliberately NOT provisioned or admitted as a trusted new account.
 await db.doc('users/'+a.uid).update({displayName:'B sentinel must survive'});const target=await db.doc('users/'+a.uid).get();await au.signInWithEmailAndPassword(c.a,b.email,b.password);await fw.enableNetwork(c.store);const outcome=await timeout(pending),after=await db.doc('users/'+a.uid).get();
 const observed={outcome,targetPreserved:after.updateTime.isEqual(target.updateTime),displayName:after.data().displayName,originPreserved:(await db.doc('trusted_account_origins/'+a.uid).get()).updateTime.isEqual(origin.updateTime),oldA:(await db.doc('users/'+a.uid+'/notes/old-A').get()).data(),peerPreserved:(await db.doc('users/'+peer.uid).get()).updateTime.isEqual(peerBefore.updateTime),authOnlyChannel:audit.connections>0};
 fs.writeFileSync(path.join(process.env.K01_EVIDENCE_DIR,'scenario-C.json'),JSON.stringify({scenario:'C',observed,cloudIamNegative:'NOT_VERIFIED',noNewProvenanceMinted:true},null,2));
 assert.deepEqual(observed,{outcome:{status:'rejected',code:'permission-denied'},targetPreserved:true,displayName:'B sentinel must survive',originPreserved:true,oldA:{preserve:'A'},peerPreserved:true,authOnlyChannel:true});
 }finally{if(child&&child.exitCode===null&&!child.killed)child.kill();await c.close()}
});

test('D characterization: unrestricted Emulator owner bypasses Rules on a denied probe, not a new origin',{timeout:25000},async()=>{
 const a=await account(),b=await account(),c=await client(a),peer=await db.doc('users/'+b.uid).get(),origin=await db.doc('trusted_account_origins/'+a.uid).get(),probe='authority_probe/r4-unrestricted-owner';try{
 await assert.rejects(fw.setDoc(fw.doc(c.store,probe),{attempt:'client-denied'}),e=>e.code==='permission-denied');
 await db.doc(probe).set({authority:'emulator-owner',notAccountProvenance:true});assert.equal((await db.doc(probe).get()).data().authority,'emulator-owner');
 await assert.rejects(fw.getDocFromServer(fw.doc(c.store,probe)),e=>e.code==='permission-denied');assert.ok((await db.doc('users/'+b.uid).get()).updateTime.isEqual(peer.updateTime));assert.ok((await db.doc('trusted_account_origins/'+a.uid).get()).updateTime.isEqual(origin.updateTime));
 }finally{await c.close()}
});


test('E maintenance MUST refuse trusted cohort counts/Circle mutations without touching legacy or A/B',{timeout:30000},async()=>{
 const a=await account(),peer=await account(),origin=await db.doc('trusted_account_origins/'+a.uid).get(),peerBefore=await db.doc('users/'+peer.uid).get(),circle=db.doc('circles/r4-maint-'+(++serial)),challenge=circle.collection('challenges').doc('legacy-shape'),orphan=challenge.collection('progress').doc('legacy-orphan'),member=circle.collection('ranking').doc('legacy-member');
 // Deliberately legacy-shaped maintenance candidates under a genuine server
 // origin. These resources do not constitute new provenance or admission.
 await db.doc('users/'+a.uid+'/habits/maintenance-candidate').set({fixture:'one'});
 await circle.set({schemaVersion:2,adminId:a.uid,memberCount:2});await circle.collection('members').doc(a.uid).set({role:'admin'});await challenge.set({schemaVersion:2});await orphan.set({value:1});await member.set({role:'member'});
 const counts=await import(require('node:url').pathToFileURL(req.resolve('./scripts/backfill-habits-counts.js')).href),ownership=await import(require('node:url').pathToFileURL(req.resolve('./scripts/backfill-circle-ownership.js')).href),challengeBackfill=require('../../functions/scripts/backfill-circle-challenge-count'),cleanup=require('../../functions/scripts/cleanup-orphan-circle-progress');
 const scoped={doc:db.doc.bind(db),runTransaction:db.runTransaction.bind(db),collectionGroup:group=>db.collectionGroup(group).where(req('firebase-admin/firestore').FieldPath.documentId(),'==',group==='ranking'?member:orphan)};
 const results=[];for(const [name,target,run]of [
 ['counts',db.doc('users/'+a.uid),()=>counts.backfillUserCounts(db,db.doc('users/'+a.uid),{apply:true})],
 ['challenge-count',circle,()=>challengeBackfill.backfillCircle(db,circle,{apply:true})],
 ['orphan-progress',orphan,()=>cleanup.cleanupProgress(db,orphan,{apply:true})],
 ['ownership',member,()=>ownership.backfillCircleOwnership({db:scoped,apply:true,log:()=>{}})]]){
  const before=await target.get();let refused=false;try{await run()}catch{refused=true}const after=await target.get();results.push({name,refused,preserved:after.exists===before.exists&&after.updateTime?.isEqual(before.updateTime)===true});
 }
 const observed={results,originPreserved:(await db.doc('trusted_account_origins/'+a.uid).get()).updateTime.isEqual(origin.updateTime),peerPreserved:(await db.doc('users/'+peer.uid).get()).updateTime.isEqual(peerBefore.updateTime)};
 fs.writeFileSync(path.join(process.env.K01_EVIDENCE_DIR,'scenario-E.json'),JSON.stringify(observed,null,2));
 assert.deepEqual(observed,{results:['counts','challenge-count','orphan-progress','ownership'].map(name=>({name,refused:true,preserved:true})),originPreserved:true,peerPreserved:true});
});
