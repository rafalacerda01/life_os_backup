'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),{createRequire}=require('node:module');
const req=createRequire(require('node:path').join(__dirname,'../../backend/package.json')),freq=createRequire(require('node:path').join(__dirname,'../package.json'));
const {initializeApp,deleteApp}=req('firebase-admin/app'),{getAuth}=req('firebase-admin/auth'),{Firestore,getFirestore}=req('firebase-admin/firestore'),{GoogleAuth,OAuth2Client}=req('google-auth-library');
for(const n of ['FIRESTORE_EMULATOR_HOST','FIREBASE_AUTH_EMULATOR_HOST'])assert.match(process.env[n]||'',/^127\.0\.0\.1:\d+$/);
assert.equal(process.env.GCLOUD_PROJECT,'demo-life-os');
const core=req('./api/account/_trusted_account.cjs');
const app=initializeApp({projectId:'demo-life-os'});const auth=getAuth(app);
const owner=new OAuth2Client();owner.setCredentials({access_token:'owner',expiry_date:Date.now()+3600000});
const db=getFirestore(app);db.settings({host:process.env.FIRESTORE_EMULATOR_HOST,ssl:false,auth:new GoogleAuth({projectId:'demo-life-os',authClient:owner})});
test.after(async()=>{await db.terminate();await deleteApp(app);});
async function request(method,body){const response=await fetch('http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST+'/identitytoolkit.googleapis.com/v1/accounts:'+method+'?key=demo-key',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const value=await response.json();if(!response.ok)throw Error('AUTH_EMULATOR:'+value.error?.message);return value;}
let serial=0;
async function password(){const email='trusted'+(++serial)+'@example.invalid',password='Synthetic-only-19!';const value=await request('signUp',{email,password,returnSecureToken:true});return{...value,email,password,decoded:await auth.verifyIdToken(value.idToken,true)};}

for(const mode of ['documents','bytes'])test('bounded partitioned K01 genuine genesis completes '+mode+' capacity with restart, lost result and retired replay refusal',async t=>{
 const f=await password();await core.provision(db,auth,f.decoded);const root='users/'+f.localId,control=req('./api/account/_deletion_control.cjs');
 const peer=root+'-independent';await db.doc(peer).set({keep:'B'});await db.doc(peer+'/notes/private').set({keep:'B-child'});
 const started=Date.now(),trace=phase=>console.log(JSON.stringify({capacityPhase:phase,mode,elapsedMs:Date.now()-started}));
 const count=mode==='documents'?4101:1101,sourceCount=mode==='documents'?0:count;
 for(let start=0;start<sourceCount;start+=100)await core.runAuthenticated(f.decoded,()=>db.runTransaction(async tx=>{
  await control.assertNormalWriterTransaction(tx,db,f.localId);
  for(let i=start;i<Math.min(start+100,sourceCount);i++){
   const suffix=mode==='documents'?'/notes/n'+i:'/a/'+('x'.repeat(1000)+i)+'/b/'+('y'.repeat(1000))+'/c/'+('z'.repeat(1000))+'/d/'+('w'.repeat(1000));
   tx.create(db.doc(root+suffix),{original:true,index:i});
  }
 }));
 trace('writer-complete');
 const custody=req('./api/_http_generation_custody.cjs'),body={operation:'create_task',taskId:'synthetic-capacity',title:'Capacity task',priority:'low',date:'2026-11-04T12:00:00.000Z'},context={v:2,binding:{v:2,project:'demo-life-os',database:'(default)',tenant:null,uid:f.localId,generation:f.decoded.lifeos_generation},operationId:require('node:crypto').randomBytes(32).toString('hex'),route:'sync',bodyHash:custody.hash(body)};
 const op=()=>custody.parse({headers:{'x-lifeos-operation':Buffer.from(JSON.stringify(context)).toString('base64url')},body},f.decoded,db,'sync');
 const {syncHandler}=await import(require('node:url').pathToFileURL(req.resolve('./api/sync.js')).href);
 const invoke=async(requestBody,requestContext)=>{
  const res={statusCode:200,headers:{},setHeader(k,v){this.headers[k]=v;},status(code){this.statusCode=code;return this;},json(value){this.body=value;return this;},end(){return this;}};
  await syncHandler({method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+f.idToken,'x-firebase-appcheck':'synthetic-capacity-check','x-lifeos-operation':Buffer.from(JSON.stringify(requestContext)).toString('base64url')},body:requestBody},res,
   {verifyIdToken:(token,revoked)=>auth.verifyIdToken(token,revoked),verifyAppCheckToken:async token=>{assert.equal(token,'synthetic-capacity-check');}});
  if(res.statusCode!==200)throw Object.assign(Error('CAPACITY_HTTP_REFUSED:'+res.statusCode+':'+String(res.body?.code)),{status:res.statusCode});
  assert.ok(res.headers['X-LifeOS-Operation-Ack']);return res.body;
 };
 const execute=()=>invoke(body,context);
 await execute(); // The actual gateway confirms commit; discard its client reply.
 if(mode==='documents'){
  const slots=[body.taskId];
  // Three genuine free-tier tasks; do not alter production quota or billing.
  for(let i=1;i<3;i++){
   const create={...body,taskId:'capacity-slot-'+i};slots.push(create.taskId);
   await invoke(create,{...context,operationId:require('node:crypto').randomBytes(32).toString('hex'),bodyHash:custody.hash(create)});
  }
  assert.equal((await db.doc(root).get()).data().tasksCount,slots.length);
  assert.equal(slots.length,3);
  const {syncTaskUpdate}=await import(require('node:url').pathToFileURL(req.resolve('./api/activity/_sync_updates.js')).href);
  // Scale the guarded data plane, not a permissive rate-limit mock. Auth was
  // verified by the provider and gateway above; every kernel attempt rechecks
  // the real origin and all three R5 controls through the production adapter.
  await Promise.all(slots.map(async(taskId,slot)=>{
   for(let i=slot;i<count-slots.length;i+=slots.length){
    const update={operation:'update_task',taskId,isCompleted:false};
    const c={...context,operationId:require('node:crypto').randomBytes(32).toString('hex'),bodyHash:custody.hash(update)};
    const operation=custody.parse({headers:{'x-lifeos-operation':Buffer.from(JSON.stringify(c)).toString('base64url')},body:update},f.decoded,db,'sync');
    await core.runAuthenticated(f.decoded,()=>custody.run(operation,()=>syncTaskUpdate({db:custody.database(db,f.localId),uid:f.localId,body:update})));
   }
  }));
  assert.equal((await db.collection(root+'/_http_operations_v1').get()).size,count);
  trace('4101-real-kernel-receipts');
 }
 const receipt=db.doc(root+'/_http_operations_v1/'+context.operationId),originalReceipt=await receipt.get();assert.equal(originalReceipt.exists,true);
 const {deleteAccount}=await import(require('node:url').pathToFileURL(req.resolve('./api/account/delete.js')).href);
 const hash=require('node:crypto').createHash('sha256').update(root).digest('hex'),headerPath='account_deletion_guards/'+f.localId+'/cleanup_manifests/'+hash;
 let interrupted=false,destructiveLost=false;
 const wrapped={projectId:db.projectId,databaseId:db.databaseId,doc:db.doc.bind(db),collection:db.collection.bind(db),collectionGroup:db.collectionGroup.bind(db),runTransaction:async(fn,...opts)=>{
  let captured=false,deleted=false;const result=await db.runTransaction(tx=>fn(new Proxy(tx,{get(target,k){
   if(k==='update')return(ref,data,...args)=>{captured ||= ref.path===headerPath&&data.capturedPages===1;return target.update(ref,data,...args);};
   if(k==='delete')return(ref,...args)=>{deleted=true;return target.delete(ref,...args);};
   return typeof target[k]==='function'?target[k].bind(target):target[k];
  }})),...opts);
  if(captured&&!interrupted){interrupted=true;throw Error('INJECTED_CAPTURE_REPLY_LOST');}
  if(deleted&&!destructiveLost){destructiveLost=true;throw Error('INJECTED_DELETE_REPLY_LOST');}
  return result;
 }};
 await assert.rejects(deleteAccount({db:wrapped,auth,uid:f.localId}),e=>e.code==='ACCOUNT_DELETION_BLOCKED');
 trace('capture-paused');
 assert.equal(interrupted,true);assert.equal((await auth.getUser(f.localId)).uid,f.localId);assert.ok((await receipt.get()).updateTime.isEqual(originalReceipt.updateTime));
 const staging=(await db.doc(headerPath).get()).data();assert.equal(staging.state,'CAPTURING');assert.equal(staging.version,3);assert.equal(staging.capturedPages,1);
 if(mode==='documents')assert.ok(staging.entryCount>4000);else assert.ok(staging.inventoryBytes>4*1024*1024);
 await assert.rejects(deleteAccount({db:wrapped,auth,uid:f.localId}),e=>e.code==='ACCOUNT_DELETION_BLOCKED');assert.equal(destructiveLost,true);
 trace('destructive-response-lost');
 const sealed=(await db.doc(headerPath).get()).data();assert.equal(sealed.state,'SEALED');assert.ok(sealed.nextPage>=1);assert.equal(sealed.authOutcome,'CONFIRMED');
 // Re-enter the real server flow. Its own resolver/controller must prove the
 // original durable operation; this test supplies no replacement authority.
 assert.deepEqual(await deleteAccount({db:wrapped,auth,uid:f.localId}),{body:{deleted:true,circleDeleted:false}});
 trace('complete');
 assert.equal((await db.doc(root).get()).exists,false);assert.equal((await receipt.get()).exists,false);
 const origin=await db.doc('trusted_account_origins/'+f.localId).get(),deny=await db.doc('retired_auth_identities/'+f.localId).get();
 assert.equal(origin.data().state,'RETIRED');assert.equal(deny.exists,true);assert.equal((await db.doc(headerPath).get()).data().state,'COMPLETE');
 await assert.rejects(execute());
 let callbackReached=false;
 await assert.rejects(core.runAuthenticated(f.decoded,()=>custody.run(op(),()=>custody.transaction(db,f.localId,async()=>{callbackReached=true;return{never:true};}))));assert.equal(callbackReached,false);
 assert.equal((await db.doc(root).get()).exists,false);assert.deepEqual((await db.doc(peer).get()).data(),{keep:'B'});assert.deepEqual((await db.doc(peer+'/notes/private').get()).data(),{keep:'B-child'});
 assert.ok((await deny.ref.get()).updateTime.isEqual(deny.updateTime));
 const pages=await db.doc(headerPath).collection('pages').get();assert.ok(pages.size<=req('./api/account/_cleanup_manifest.cjs').MAX_CAPTURE_PAGES);for(const p of pages.docs){assert.equal(p.data().done,true);assert.ok(Buffer.byteLength(JSON.stringify(p.data()))<128*1024+4096);}
 t.diagnostic(JSON.stringify({mode,count,pageCount:pages.size,inventoryBytes:staging.inventoryBytes,initialCaptureInterrupted:interrupted,destructiveResponseLost:destructiveLost,retiredReplayRefused:true,peerAndDenyPreserved:true}));
});
