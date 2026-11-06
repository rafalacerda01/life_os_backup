'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),{createRequire}=require('node:module'),path=require('node:path'),http=require('node:http'),{createHash}=require('node:crypto');
const req=createRequire(path.resolve(__dirname,'../../backend/package.json'));
const {initializeApp,deleteApp}=req('firebase-admin/app'),{getAuth}=req('firebase-admin/auth'),{getFirestore}=req('firebase-admin/firestore');
const core=req('./api/account/_trusted_account.cjs'),custody=req('./api/_http_generation_custody.cjs');
const {GoogleAuth,OAuth2Client}=req('google-auth-library');
const owner=new OAuth2Client();owner.setCredentials({access_token:'owner',expiry_date:Date.now()+3600000});
const app=initializeApp({projectId:'demo-life-os'}),auth=getAuth(app),db=getFirestore(app);
// Explicit synthetic Emulator owner only. The guard rejects ADC resolution.
db.settings({host:process.env.FIRESTORE_EMULATOR_HOST,ssl:false,auth:new GoogleAuth({projectId:'demo-life-os',authClient:owner})});
const handlers=new Map();let server,serial=0;
const APP_CHECK='synthetic-app-check-port';
const runtime={getServices:()=>({auth,db}),verifyAppCheckToken:async t=>{if(t!==APP_CHECK)throw Error('INVALID_SYNTHETIC_APPCHECK');},verifyIdToken:(t,r)=>auth.verifyIdToken(t,r)};
// This port is a strict simulated App Check verifier; no App Check Emulator exists.
// Auth verification, blocking genesis, gateways and Firestore transactions are real.
test.before(async()=>{
 for(const route of ['activity/task-complete','focus/start','focus/finish','focus/cancel','focus/status','sync'])handlers.set(route,(await import(require('node:url').pathToFileURL(req.resolve('./api/'+route+'.js')).href)).default);
 server=http.createServer(async(incoming,out)=>{
  let data='';for await(const chunk of incoming)data+=chunk;
  let body;try{body=JSON.parse(data);}catch{out.writeHead(400);out.end('{}');return;}
  const route=incoming.url.replace(/^\/api\//,''),handler=handlers.get(route);
  if(!handler){out.writeHead(404);out.end('{}');return;}
  const res={statusCode:200,setHeader:(k,v)=>out.setHeader(k,v),status(s){this.statusCode=s;return this;},json(b){out.statusCode=this.statusCode;out.setHeader('Content-Type','application/json');out.end(JSON.stringify(b));return this;},end(){out.statusCode=this.statusCode;out.end();return this;}};
  try{await handler({method:incoming.method,headers:incoming.headers,body},res,runtime);}catch{out.statusCode=500;out.end('{}');}
 });await new Promise(r=>server.listen(Number(process.env.R5_HTTP_HOST.split(':')[1]),'127.0.0.1',r));
});
test.after(async()=>{if(server)await new Promise(r=>server.close(r));await db.terminate();await deleteApp(app);});
async function authRequest(method,body){const r=await fetch('http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST+'/identitytoolkit.googleapis.com/v1/accounts:'+method+'?key=demo-key',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});assert.equal(r.status,200);return r.json();}
async function account(){const email='r5-http-'+(++serial)+'@example.invalid',password='Synthetic-only-19!';const f=await authRequest('signUp',{email,password,returnSecureToken:true});f.decoded=await auth.verifyIdToken(f.idToken,true);await core.provision(db,auth,f.decoded);f.email=email;f.password=password;return f;}
function context(f,route,body,key){return{v:2,binding:{v:2,project:'demo-life-os',database:'(default)',tenant:null,uid:f.localId,generation:f.decoded.lifeos_generation},operationId:createHash('sha256').update(f.localId+'/'+key).digest('hex'),route,bodyHash:custody.hash(body)};}
async function call(f,route,body,key='one',options={}){
 const c=options.context??context(f,route,body,key);
 const response=await fetch('http://'+process.env.R5_HTTP_HOST+'/api/'+route,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+(options.token??f.idToken),'X-Firebase-AppCheck':options.appCheck??APP_CHECK,...(options.omit?{}:{'X-LifeOS-Operation':Buffer.from(custody.canonical(c)).toString('base64url')})},body:JSON.stringify(body)});
 const result={status:response.status,body:await response.json(),ack:response.headers.get('x-lifeos-operation-ack')};
 if(result.ack){const ack=JSON.parse(Buffer.from(result.ack,'base64url'));assert.deepEqual({...ack,operationReplay:undefined},{...c,status:result.status,responseHash:custody.hash(result.body),operationReplay:undefined});assert.equal(typeof ack.operationReplay,'boolean');result.replay=ack.operationReplay;}
 return result;
}
const taskBody=id=>({operation:'create_task',taskId:id,title:'Synthetic task',priority:'low',date:'2026-11-02T12:00:00.000Z'});
async function task(f,id='task'){const r=await call(f,'sync',taskBody(id),'create/'+id);assert.equal(r.status,200,JSON.stringify(r.body));assert.ok(r.ack);return r;}
function receipt(f,key){return db.doc('users/'+f.localId+'/_http_operations_v1/'+createHash('sha256').update(f.localId+'/'+key).digest('hex'));}

test('real HTTP Sync: original identity, immutable receipt, response loss replay and one quota mutation',async()=>{
 const f=await account(),r=await task(f);const snap=await db.doc('users/'+f.localId+'/tasks/task').get(),rr=await call(f,'sync',taskBody('task'),'create/task');
 assert.equal(rr.status,200);assert.equal(rr.replay,true);assert.deepEqual(rr.body,r.body);assert.ok((await db.doc('users/'+f.localId+'/tasks/task').get()).updateTime.isEqual(snap.updateTime));assert.equal((await db.doc('users/'+f.localId).get()).data().tasksCount,1);assert.ok((await receipt(f,'create/task').get()).exists);
});
test('real HTTP concurrent same operation replays atomically; independent B untouched',async()=>{
 const f=await account(),b=await account();await db.doc('users/'+b.localId+'/tasks/B').set({keep:'B'});
 const replies=await Promise.all([call(f,'sync',taskBody('task'),'race'),call(f,'sync',taskBody('task'),'race')]);for(let n=0;n<replies.length;n++) { const initial=replies[n];assert.ok([200,503].includes(initial.status),JSON.stringify(initial));if(initial.status===503) {assert.equal(initial.ack,null);replies[n]=await call(f,'sync',taskBody('task'),'race');}assert.equal(replies[n].status,200,JSON.stringify(replies[n]));}assert.equal(replies.filter(r=>r.replay).length,1);assert.equal((await db.doc('users/'+f.localId).get()).data().tasksCount,1);assert.deepEqual((await db.doc('users/'+b.localId+'/tasks/B').get()).data(),{keep:'B'});
});
test('real HTTP A intent cannot use B token or wrong project/database/tenant/generation',async()=>{
 const f=await account(),b=await account(),body=taskBody('task'),c=context(f,'sync',body,'deny');
 const switched=await call(f,'sync',body,'deny',{token:b.idToken,context:c});assert.equal(switched.status,409);assert.equal(switched.ack,null);
 for(const [field,value]of [['project','demo-other'],['database','other'],['tenant','other'],['generation',b.decoded.lifeos_generation]]){const bad=structuredClone(c);bad.binding[field]=value;assert.equal((await call(f,'sync',body,'deny',{context:bad})).status,409);}
 assert.equal((await db.doc('users/'+f.localId+'/tasks/task').get()).exists,false);assert.equal((await db.doc('users/'+b.localId+'/tasks/task').get()).exists,false);
});
test('real HTTP generation claim without operation context is refused; bad App Check and Auth stay mandatory',async()=>{
 const f=await account(),body=taskBody('task');assert.equal((await call(f,'sync',body,'noctx',{omit:true})).status,409);
 assert.equal((await call(f,'sync',body,'badapp',{appCheck:'invalid'})).status,401);assert.equal((await call(f,'sync',body,'badauth',{token:'invalid'})).status,401);assert.equal((await db.doc('users/'+f.localId+'/tasks/task').get()).exists,false);
});
test('real HTTP same UID recreated without original generation cannot dispatch original intent',async()=>{
 const f=await account();await task(f);await auth.deleteUser(f.localId);const email='replacement-r5-'+serial+'@example.invalid';await auth.createUser({uid:f.localId,email,password:f.password});
 const replacement=await authRequest('signInWithPassword',{email,password:f.password,returnSecureToken:true});await db.doc('users/'+f.localId+'/tasks/B').set({keep:'B'});
 const r=await call(f,'sync',{operation:'update_task',taskId:'task',isCompleted:true},'old',{token:replacement.idToken});assert.equal(r.status,409);assert.deepEqual((await db.doc('users/'+f.localId+'/tasks/B').get()).data(),{keep:'B'});assert.equal((await db.doc('users/'+f.localId+'/tasks/task').get()).data().isCompleted,false);
});
test('real HTTP missing or divergent origin fails before domain mutation and ACK',async()=>{
 for(const mode of ['missing','generation','state']){const f=await account(),ref=db.doc('trusted_account_origins/'+f.localId);if(mode==='missing')await ref.delete();else await ref.update(mode==='state'?{state:'REVIEW_REQUIRED'}:{generation:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'});
  const r=await call(f,'sync',taskBody('task'),'invalid');assert.notEqual(r.status,200);assert.equal(r.ack,null);assert.equal((await db.doc('users/'+f.localId+'/tasks/task').get()).exists,false);assert.equal((await receipt(f,'invalid').get()).exists,false);
 }
});
for(const suffix of ['guard','retired','control'])test('real HTTP R5 '+suffix+' fences receipt replay',async()=>{
 const f=await account();await task(f);const p=suffix==='retired'?'retired_auth_identities/'+f.localId:'account_deletion_guards/'+f.localId+(suffix==='control'?'/control/operation':'');await db.doc(p).set({hold:true});
 const r=await call(f,'sync',taskBody('task'),'create/task');assert.notEqual(r.status,200);assert.equal(r.ack,null);assert.equal((await db.doc('users/'+f.localId).get()).data().tasksCount,1);
});
test('real native transaction ABORTED retry rechecks controls before callback effects',async()=>{
 const f=await account(),body={targetId:'task',targetType:'TASK',plannedDurationSeconds:60};await task(f);let entered=false,attempts=0;
 // Explicit ABORTED fault, not a claimed Cloud concurrency/IAM guarantee.
 // First callback plans real native writes and receipt, then rolls back. The
 // control is installed before the SDK's second callback acquires read locks.
 const wrapped={projectId:db.projectId,databaseId:db.databaseId,collection:db.collection.bind(db),runTransaction:(cb,...opts)=>db.runTransaction(async tx=>{
  attempts++;
  if(attempts===2)await db.doc('account_deletion_guards/'+f.localId+'/control/operation').set({hold:true});
  const result=await cb(tx); entered=true;
  if(attempts===1){const error=new Error('INJECTED_ABORTED');error.code=10;throw error;}
  return result;
 },...opts)};
 const handler=handlers.get('focus/start'),out={statusCode:200,headers:{},setHeader(k,v){this.headers[k]=v;},status(s){this.statusCode=s;return this;},json(b){this.body=b;return this;}};
 await handler({method:'POST',headers:{authorization:'Bearer '+f.idToken,'x-firebase-appcheck':APP_CHECK,'x-lifeos-operation':Buffer.from(custody.canonical(context(f,'focus/start',body,'retry'))).toString('base64url')},body},out,{...runtime,getServices:()=>({auth,db:wrapped}),checkRateLimit:async()=>true});
 assert.ok(entered);assert.ok(attempts>=2);assert.equal(out.statusCode,503);assert.equal((await db.doc('users/'+f.localId+'/tasks/task').get()).data().isCompleted,false);assert.equal((await receipt(f,'retry').get()).exists,false);assert.equal((await db.collection('users/'+f.localId+'/verified_focus_sessions').get()).size,0);
});
test('real HTTP Activity task completion and replay preserve event/time and independent B',async()=>{
 const f=await account();await task(f);const completed=await call(f,'sync',{operation:'update_task',taskId:'task',isCompleted:true},'mark-completed');assert.equal(completed.status,200,JSON.stringify(completed));const body={taskId:'task'},first=await call(f,'activity/task-complete',body,'complete'),again=await call(f,'activity/task-complete',body,'complete');assert.equal(first.status,200,JSON.stringify(first));assert.ok(first.ack);assert.equal(again.replay,true);assert.deepEqual(again.body,first.body);assert.equal((await db.doc('users/'+f.localId+'/tasks/task').get()).data().isCompleted,true);
});
test('real HTTP Focus start response loss then cancel then retry cannot create a second session',async()=>{
 const f=await account();await task(f);const body={targetId:'task',targetType:'TASK',plannedDurationSeconds:60},first=await call(f,'focus/start',body,'start');assert.equal(first.status,200,JSON.stringify(first));
 const cancel=await call(f,'focus/cancel',{sessionId:first.body.sessionId},'cancel');assert.equal(cancel.status,200,JSON.stringify(cancel));const retry=await call(f,'focus/start',body,'start');assert.equal(retry.replay,true);assert.deepEqual(retry.body,first.body);assert.equal((await db.collection('users/'+f.localId+'/verified_focus_sessions').get()).size,1);assert.equal((await db.doc('users/'+f.localId+'/runtime/active_focus').get()).exists,false);
 const cancelled=await call(f,'focus/cancel',{sessionId:first.body.sessionId},'cancel');assert.equal(cancelled.replay,true);assert.deepEqual(cancelled.body,cancel.body);
});
test('real HTTP changed body for existing operation cannot mutate or replace receipt',async()=>{
 const f=await account();await task(f);const before=await receipt(f,'create/task').get(),r=await call(f,'sync',taskBody('B'),'create/task');assert.notEqual(r.status,200);assert.equal(r.ack,null);assert.equal((await db.doc('users/'+f.localId+'/tasks/B').get()).exists,false);assert.ok((await receipt(f,'create/task').get()).updateTime.isEqual(before.updateTime));
});
test('real HTTP unreviewed multiphase Sync stays CLOSED without sealing/chunk effects',async()=>{
 const f=await account(),r=await call(f,'sync',{operation:'delete_subject',subjectId:'A'},'closed');assert.equal(r.status,409);assert.equal(r.body.code,'HTTP_CUSTODY_ROUTE_CLOSED');assert.equal((await receipt(f,'closed').get()).exists,false);
});
test('real HTTP Focus finish after real elapsed duration commits once and replays',async()=>{
 const f=await account();await task(f);const first=await call(f,'focus/start',{targetId:'task',targetType:'TASK',plannedDurationSeconds:60},'start');assert.equal(first.status,200,JSON.stringify(first));
 await new Promise(r=>setTimeout(r,61000));const body={sessionId:first.body.sessionId},finish=await call(f,'focus/finish',body,'finish');assert.equal(finish.status,200,JSON.stringify(finish));assert.ok(finish.ack);assert.equal(finish.body.verifiedDurationSeconds,60);
 const again=await call(f,'focus/finish',body,'finish');assert.equal(again.replay,true);assert.deepEqual(again.body,finish.body);assert.equal((await db.doc('users/'+f.localId+'/verified_focus_sessions/'+first.body.sessionId).get()).data().status,'COMPLETED');
});

test('Flutter real transport and encrypted-database abstraction integrate with actual HTTP gateways and Emulators',async()=>{
 const f=await account(),os=require('node:os'),fs=require('node:fs'),{spawn}=require('node:child_process');
 const file=path.join(os.tmpdir(),'r5-ephemeral-auth-fixture.json');
 fs.writeFileSync(file,JSON.stringify({uid:f.localId,generation:f.decoded.lifeos_generation,token:f.idToken,baseUrl:'http://'+process.env.R5_HTTP_HOST}));
 const out=fs.openSync(path.join(process.env.K01_EVIDENCE_DIR,'flutter-emulator.jsonl'),'w'),err=fs.openSync(path.join(process.env.K01_EVIDENCE_DIR,'flutter-emulator.stderr'),'w');
 try{
  const child=spawn('C:/src/flutter/bin/cache/dart-sdk/bin/dart.exe',['--packages=C:/src/flutter/packages/flutter_tools/.dart_tool/package_config.json','C:/src/flutter/bin/cache/flutter_tools.snapshot','test','--no-pub','--machine','tools/trusted_account/flutter_http_emulator_test.dart'],{cwd:path.resolve(__dirname,'../..'),env:{...process.env,R5_FLUTTER_FIXTURE:file,'PROGRAMFILES(X86)':'C:/Program Files (x86)',PROGRAMFILES:'C:/Program Files',ProgramW6432:'C:/Program Files',ANDROID_HOME:'C:/Users/Rafa/AppData/Local/Android/Sdk',PATH:process.env.PATH+path.delimiter+'C:/Program Files/Git/cmd',PATHEXT:'.COM;.EXE;.BAT;.CMD',COMSPEC:path.join(process.env.SystemRoot,'System32/cmd.exe'),FLUTTER_SUPPRESS_ANALYTICS:'true',DART_SUPPRESS_ANALYTICS:'true'},windowsHide:true,stdio:['ignore',out,err]});
  const timer=setTimeout(()=>child.kill(),90000);const code=await new Promise((r,j)=>{child.once('error',j);child.once('close',r);});clearTimeout(timer);assert.equal(code,0,'Flutter real HTTP integration; see sanitized test logs');
  assert.equal((await db.doc('users/'+f.localId+'/tasks/flutter-task').get()).data().isCompleted,true);
  assert.equal((await db.collection('users/'+f.localId+'/_http_operations_v1').get()).size,5);
  assert.equal((await db.collection('users/'+f.localId+'/verified_focus_sessions').get()).size,1);
  assert.equal((await db.doc('users/'+f.localId+'/runtime/active_focus').get()).exists,false);
 }finally{fs.closeSync(out);fs.closeSync(err);fs.unlinkSync(file);}
});

test('real HTTP simultaneous A/B use separate resources and receipts',async()=>{
 const a=await account(),b=await account();await Promise.all([task(a,'shared'),task(b,'shared')]);
 for(const f of [a,b]){assert.equal((await db.doc('users/'+f.localId).get()).data().tasksCount,1);assert.equal((await db.collection('users/'+f.localId+'/_http_operations_v1').get()).size,1);}
});
test('prototype Rules deny client reads/writes of HTTP receipts even to same proven origin',async()=>{
 const f=await account();await task(f);const web=createRequire(path.resolve(__dirname,'../firestore_rules/package.json')),wa=web('firebase/app'),au=web('firebase/auth'),fw=web('firebase/firestore');
 const app=wa.initializeApp({projectId:'demo-life-os',apiKey:'demo-key',appId:'demo-app'},'r5-receipt-rules'),clientAuth=au.getAuth(app);au.connectAuthEmulator(clientAuth,'http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST,{disableWarnings:true});
 const store=fw.getFirestore(app),[host,port]=process.env.FIRESTORE_EMULATOR_HOST.split(':');fw.connectFirestoreEmulator(store,host,Number(port));
 try {await au.signInWithEmailAndPassword(clientAuth,f.email,f.password);const ref=fw.doc(store,receipt(f,'create/task').path);await assert.rejects(fw.getDocFromServer(ref),e=>e.code==='permission-denied');await assert.rejects(fw.setDoc(ref,{version:1,forged:true}),e=>e.code==='permission-denied');assert.equal((await receipt(f,'create/task').get()).data().version,1);}finally{await fw.terminate(store);await wa.deleteApp(app);}
});

test('each admitted Sync kernel confirms and replays with actual origin, receipts and tombstones',async()=>{
 const f=await account(),today=new Date().toISOString().slice(0,10),bodies=[taskBody('task'),
  {operation:'update_task',taskId:'task',isCompleted:true},
  {operation:'delete_task',taskId:'task'},
  {operation:'create_habit',habitId:'habit',title:'Synthetic habit',completedDates:[]},
  {operation:'update_habit',habitId:'habit',completedDates:[]},
  {operation:'update_habit_completion',habitId:'habit',completedDates:[today],competitiveCompletionId:require('node:crypto').randomUUID()},
  {operation:'delete_habit',habitId:'habit'}];
 for(const body of bodies){const key='all/'+body.operation,first=await call(f,'sync',body,key);assert.equal(first.status,200,JSON.stringify(first));assert.ok(first.ack);const replay=await call(f,'sync',body,key);assert.equal(replay.status,200,JSON.stringify(replay));assert.equal(replay.replay,true);assert.deepEqual(replay.body,first.body);}
 const user=(await db.doc('users/'+f.localId).get()).data();assert.equal(user.tasksCount,0);assert.equal(user.habitsCount,0);assert.equal((await db.doc('users/'+f.localId+'/tasks/task').get()).exists,false);assert.equal((await db.doc('users/'+f.localId+'/habits/habit').get()).exists,false);assert.equal((await db.collection('users/'+f.localId+'/_http_operations_v1').get()).size,7);
});

test('operation ID alias across genuine same-generation clients MUST apply the later intent before ACK',async()=>{
 const f=await account();await task(f,'shared');const fs=require('node:fs'),os=require('node:os'),{spawn}=require('node:child_process');
 const fixture=path.join(os.tmpdir(),'audit-ephemeral-demo-token.json'),evidenceFile=path.join(process.env.K01_EVIDENCE_DIR,'operation-id-evidence.json');
 fs.writeFileSync(fixture,JSON.stringify({uid:f.localId,generation:f.decoded.lifeos_generation,token:f.idToken,baseUrl:'http://'+process.env.R5_HTTP_HOST,evidenceFile}));
 const out=fs.openSync(path.join(process.env.K01_EVIDENCE_DIR,'flutter-diagnostic.jsonl'),'w'),err=fs.openSync(path.join(process.env.K01_EVIDENCE_DIR,'flutter-diagnostic.stderr'),'w');
 try{
  const child=spawn('C:/src/flutter/bin/cache/dart-sdk/bin/dart.exe',['--packages=C:/src/flutter/packages/flutter_tools/.dart_tool/package_config.json','C:/src/flutter/bin/cache/flutter_tools.snapshot','test','--no-pub','--machine',path.join(__dirname,'operation_identity_emulator_test.dart')],{cwd:'C:/life_os',env:{...process.env,R5_FLUTTER_FIXTURE:fixture,'PROGRAMFILES(X86)':'C:/Program Files (x86)',PROGRAMFILES:'C:/Program Files',ProgramW6432:'C:/Program Files',ANDROID_HOME:'C:/Users/Rafa/AppData/Local/Android/Sdk',PATH:process.env.PATH+path.delimiter+'C:/Program Files/Git/cmd',PATHEXT:'.COM;.EXE;.BAT;.CMD',COMSPEC:path.join(process.env.SystemRoot,'System32/cmd.exe'),FLUTTER_SUPPRESS_ANALYTICS:'true',DART_SUPPRESS_ANALYTICS:'true'},windowsHide:true,stdio:['ignore',out,err]});
  const timer=setTimeout(()=>child.kill(),60000);const code=await new Promise((r,j)=>{child.once('error',j);child.once('close',r);});clearTimeout(timer);assert.equal(code,0,'Diagnostic Flutter execution must finish, without fabricated Auth authority');
  const evidence=JSON.parse(fs.readFileSync(evidenceFile));evidence.remoteIsCompleted=(await db.doc('users/'+f.localId+'/tasks/shared').get()).data().isCompleted;evidence.receipts=(await db.collection('users/'+f.localId+'/_http_operations_v1').get()).size;fs.writeFileSync(evidenceFile,JSON.stringify(evidence,null,2));
  assert.equal(evidence.bSuccess,true);assert.equal(evidence.bSynced,true);
  assert.equal(evidence.sameOperationId,false,'Different installations must not alias');
  assert.deepEqual(evidence.rowIds,[1,1,1]);
  assert.equal(new Set([...evidence.operationIds,evidence.cContext.operationId]).size,3);
  assert.equal(evidence.cSynced,false,'D3 has not dispatched yet');
  assert.equal(evidence.remoteIsCompleted,true,'A later legitimate B intent was ACKed but remote task remained false');
  const third=await call(f,'sync',{operation:'update_task',taskId:'shared',isCompleted:false},'unused',{context:evidence.cContext});
  assert.equal(third.status,200);assert.equal(third.replay,false);assert.ok(third.ack);
  assert.equal((await db.doc('users/'+f.localId+'/tasks/shared').get()).data().isCompleted,false);
  const retry=await call(f,'sync',{operation:'update_task',taskId:'shared',isCompleted:false},'unused',{context:evidence.cContext});
  assert.equal(retry.replay,true);
 }finally{fs.closeSync(out);fs.closeSync(err);fs.unlinkSync(fixture);}
});

test('expanded single-transaction kernels use genuine origin, decimal values and immutable receipts',async()=>{
 const f=await account(),b=await account();await db.doc('users/'+b.localId+'/notes/keep').create({owner:'B'});
 const bodies=[
  {operation:'create_transaction',transactionId:'money',title:'Decimal',amount:12.34,type:'expense',category:'Food',date:'2026-11-03T12:00:00.000Z'},
  {operation:'delete_transaction',transactionId:'money'},
  {operation:'create_goal',goalId:'goal',title:'Goal',period:'DIÁRIA',targetValue:7,createdAt:'2026-11-03T12:00:00.000Z'},
  {operation:'delete_goal',goalId:'goal'},
  {operation:'create_medication',medicationId:'med',name:'Medicine',startDate:'2026-11-03T12:00:00.000Z',durationDays:null,endDate:null},
  {operation:'delete_medication',medicationId:'med'},
  {operation:'create_subject',subjectId:'study',title:'Study',hasExam:false,examDate:null},
  {operation:'create_review_card',version:1,cardId:'card',subjectId:'study',question:'Question',answer:'Answer',createdAt:'2026-11-03T12:00:00.000Z'},
  {operation:'apply_study_review',cardId:'card',subjectId:'study',occurredAt:'2026-11-03T12:01:00.000Z',timeZoneOffsetMinutes:0},
  {operation:'apply_study_activity',mutationId:'cccccccc-cccc-4ccc-8ccc-cccccccccccc',subjectId:'study',progressDelta:0.05,occurredAt:'2026-11-03T12:02:00.000Z',timeZoneOffsetMinutes:0},
  {operation:'apply_study_progress_reset',mutationId:'dddddddd-dddd-4ddd-8ddd-dddddddddddd',occurredAt:'2026-11-03T12:03:00.000Z'},
 ];
 for(const body of bodies){
   const key='expanded/'+body.operation,first=await call(f,'sync',body,key);
   assert.equal(first.status,200,JSON.stringify({operation:body.operation,...first}));assert.ok(first.ack);
   if(body.operation==='create_transaction')assert.equal((await db.doc('users/'+f.localId+'/transactions/money').get()).data().amount,12.34);
   if(body.operation==='create_review_card')assert.equal((await db.doc('users/'+f.localId+'/study_info/main').get()).data().reviewQueue,1);
   if(body.operation==='apply_study_review')assert.equal((await db.doc('users/'+f.localId+'/study_info/main').get()).data().reviewQueue,0);
   if(body.operation==='apply_study_activity'){
     assert.equal((await db.doc('users/'+f.localId+'/study_info/main').get()).data().progress,0.1);
     assert.ok((await receipt(f,key).get()).data().result.includes('"date"'));
   }
   const again=await call(f,'sync',body,key);assert.equal(again.status,200);assert.equal(again.replay,true);assert.deepEqual(again.body,first.body);
 }
 assert.deepEqual((await db.doc('users/'+b.localId+'/notes/keep').get()).data(),{owner:'B'});
 const user=(await db.doc('users/'+f.localId).get()).data();for(const key of ['transactionsCount','goalsCount','medicationsCount'])assert.equal(user[key],0);
 assert.equal((await db.collection('users/'+f.localId+'/_http_operations_v1').get()).size,bodies.length);
 // Neither unreviewed updates nor multiphase deletion fall through to SDK.
 const denied=await call(f,'sync',{operation:'delete_subject',subjectId:'study'},'not-admitted');assert.equal(denied.status,409);assert.equal(denied.ack,null);
});

test('Focus reconciliation is a fresh R5-fenced read, not a cached start receipt',async()=>{
 const f=await account(),b=await account();await task(f);
 const start=await call(f,'focus/start',{targetId:'task',targetType:'TASK',plannedDurationSeconds:60},'status/start');assert.equal(start.status,200);
 const body={sessionId:start.body.sessionId},key='status/read';
 const before=(await db.collection('users/'+f.localId+'/_http_operations_v1').get()).size;
 const first=await call(f,'focus/status',body,key);assert.equal(first.status,200);assert.equal(first.body.status,'RUNNING');assert.ok(first.body.remainingSeconds<=60&&first.body.remainingSeconds>=0);
 assert.equal((await db.collection('users/'+f.localId+'/_http_operations_v1').get()).size,before);
 assert.equal((await call(b,'focus/status',body,key)).status,404);
 assert.equal((await call(f,'focus/cancel',body,'status/cancel')).status,200);
 const after=await call(f,'focus/status',body,key);assert.equal(after.status,200);assert.equal(after.replay,false);assert.equal(after.body.status,'CANCELLED');assert.equal(after.body.remainingSeconds,0);
 assert.equal((await call(f,'focus/start',{targetId:'task',targetType:'TASK',plannedDurationSeconds:60},'status/start')).body.status,'RUNNING','historical command receipt stays immutable; the controller must reconcile');
 for(const path of ['account_deletion_guards/'+f.localId,'retired_auth_identities/'+f.localId,'account_deletion_guards/'+f.localId+'/control/operation']){
   await db.doc(path).set({hold:true});const denied=await call(f,'focus/status',body,key);assert.notEqual(denied.status,200);assert.equal(denied.ack,null);await db.doc(path).delete();
 }
 assert.equal((await db.doc('users/'+b.localId).get()).data().tasksCount,0);
});

test('Flutter essential single-transaction modules round-trip through genuine HTTP and original Sync ACKs',async()=>{
 const f=await account(),os=require('node:os'),fs=require('node:fs'),{spawn}=require('node:child_process');
 const file=path.join(os.tmpdir(),'r5-ephemeral-auth-fixture.json');
 fs.writeFileSync(file,JSON.stringify({uid:f.localId,generation:f.decoded.lifeos_generation,token:f.idToken,baseUrl:'http://'+process.env.R5_HTTP_HOST}));
 const out=fs.openSync(path.join(process.env.K01_EVIDENCE_DIR,'flutter-emulator.jsonl'),'w'),err=fs.openSync(path.join(process.env.K01_EVIDENCE_DIR,'flutter-emulator.stderr'),'w');
 try{
  const child=spawn('C:/src/flutter/bin/cache/dart-sdk/bin/dart.exe',['--packages=C:/src/flutter/packages/flutter_tools/.dart_tool/package_config.json','C:/src/flutter/bin/cache/flutter_tools.snapshot','test','--no-pub','--machine','tools/trusted_account/module_http_emulator_test.dart'],{cwd:path.resolve(__dirname,'../..'),env:{...process.env,R5_FLUTTER_FIXTURE:file,'PROGRAMFILES(X86)':'C:/Program Files (x86)',PROGRAMFILES:'C:/Program Files',ProgramW6432:'C:/Program Files',ANDROID_HOME:'C:/Users/Rafa/AppData/Local/Android/Sdk',PATH:process.env.PATH+path.delimiter+'C:/Program Files/Git/cmd',PATHEXT:'.COM;.EXE;.BAT;.CMD',COMSPEC:path.join(process.env.SystemRoot,'System32/cmd.exe'),FLUTTER_SUPPRESS_ANALYTICS:'true',DART_SUPPRESS_ANALYTICS:'true'},windowsHide:true,stdio:['ignore',out,err]});
  const timer=setTimeout(()=>child.kill(),90000);const code=await new Promise((r,j)=>{child.once('error',j);child.once('close',r);});clearTimeout(timer);assert.equal(code,0,'Flutter real HTTP integration; see sanitized test logs');
  const info=(await db.doc('users/'+f.localId+'/study_info/main').get()).data();assert.equal(info.reviewQueue,0);assert.equal(info.progress,0);
  assert.equal((await db.doc('users/'+f.localId+'/subjects/study').get()).exists,true);
  assert.equal((await db.doc('users/'+f.localId+'/review_queue/card').get()).exists,true);
  for(const [collection,id] of [['transactions','money'],['goals','goal'],['medications','med']])assert.equal((await db.doc('users/'+f.localId+'/'+collection+'/'+id).get()).exists,false);
  assert.equal((await db.collection('users/'+f.localId+'/_http_operations_v1').get()).size,12);
  const checkins=await db.collection('users/'+f.localId+'/checkins').get();assert.equal(checkins.size,1);assert.equal(checkins.docs[0].data().energy,1.25);assert.equal(checkins.docs[0].data().focus,2.5);assert.equal(checkins.docs[0].data().motivation,3.75);
 }finally{fs.closeSync(out);fs.closeSync(err);fs.unlinkSync(file);}
});


test('ambiguous v1 HTTP contexts are refused without replay, domain writes or ACK',async()=>{
 const f=await account(),body=taskBody('legacy');const old=context(f,'sync',body,'v1');old.v=1;
 const before=(await db.doc('users/'+f.localId).get()).data();
 const reply=await call(f,'sync',body,'v1',{context:old});assert.equal(reply.status,409);assert.equal(reply.body.code,'HTTP_LEGACY_OPERATION_REVIEW_REQUIRED');assert.equal(reply.ack,null);
 assert.deepEqual((await db.doc('users/'+f.localId).get()).data(),before);
 assert.equal((await db.doc('users/'+f.localId+'/tasks/legacy').get()).exists,false);assert.equal((await receipt(f,'v1').get()).exists,false);
 // Receipt bytes from an earlier protocol are retained, never adopted.
 const current=await task(f),ref=receipt(f,'create/task'),saved=await ref.get();
 const prior={...saved.data(),context:{...saved.data().context,v:1}};
 await ref.set(prior);const request=context(f,'sync',taskBody('task'),'create/task');request.v=1;
 const replay=await call(f,'sync',taskBody('task'),'create/task',{context:request});assert.equal(replay.status,409);assert.equal(replay.ack,null);assert.deepEqual((await ref.get()).data(),prior);
 assert.equal((await db.doc('users/'+f.localId).get()).data().tasksCount,1);assert.ok(current.ack);
});

test('notification HTTP preserves a newer occurrence across deletion replay and replacement',async()=>{
 const f=await account(),other=await account(),id='habit_daily',{Timestamp}=req('firebase-admin/firestore'),due=new Timestamp(1760000000,123456789),key=JSON.stringify([1,id,'habits',due.seconds*1000000+123456]);
 const ref=db.doc('users/'+f.localId+'/notifications/'+id),peer=db.doc('users/'+other.localId+'/notifications/'+id),body={operation:'delete_notification',notificationId:id,occurrenceKey:key};
 await ref.set({moduleType:'habits',dueDate:due});await peer.set({keep:'B'});
 const first=await call(f,'sync',body,'notification/delete');assert.equal(first.status,200);assert.equal(first.body.outcome,'DELETED');assert.ok(first.ack);assert.equal((await ref.get()).exists,false);
 await ref.set({moduleType:'habits',dueDate:new Timestamp(due.seconds,123457000),newOccurrence:true});const version=(await ref.get()).updateTime;
 const replay=await call(f,'sync',body,'notification/delete');assert.equal(replay.replay,true);assert.equal(replay.body.outcome,'DELETED');assert.ok((await ref.get()).updateTime.isEqual(version));
 const obsolete=await call(f,'sync',body,'notification/old-distinct-intent');assert.equal(obsolete.status,200);assert.equal(obsolete.body.outcome,'OBSOLETE');assert.ok((await ref.get()).updateTime.isEqual(version));assert.deepEqual((await peer.get()).data(),{keep:'B'});
});
test('notification HTTP unknown occurrence has no ACK or receipt and R5 blocks every delete',async()=>{
 for(const mode of ['unknown','guard','retired','control']){
  const f=await account(),id='habit_daily',ref=db.doc('users/'+f.localId+'/notifications/'+id),{Timestamp}=req('firebase-admin/firestore'),due=Timestamp.fromMillis(1760000000000),key=JSON.stringify([1,id,'habits',due.toMillis()*1000]),body={operation:'delete_notification',notificationId:id,occurrenceKey:key};
  await ref.set({moduleType:'habits',dueDate:mode==='unknown'?null:due});const version=(await ref.get()).updateTime;
  if(mode!=='unknown')await db.doc(mode==='retired'?'retired_auth_identities/'+f.localId:'account_deletion_guards/'+f.localId+(mode==='control'?'/control/operation':'')).set({blocked:true});
  const r=await call(f,'sync',body,'notification/deny');assert.notEqual(r.status,200);if(mode==='unknown'){assert.equal(r.status,503);assert.equal(r.body.code,'NOTIFICATION_OCCURRENCE_UNPROVEN');}assert.equal(r.ack,null);assert.ok((await ref.get()).updateTime.isEqual(version));assert.equal((await receipt(f,'notification/deny').get()).exists,false);
 }
});

test('Check-in HTTP preserves finite decimals, replay and independent B',async()=>{
 const f=await account(),b=await account(),body={operation:'upsert_checkin',checkInId:'2026-11-04',energy:1.25,focus:2.5,motivation:3.75},ref=db.doc('users/'+f.localId+'/checkins/2026-11-04'),peer=db.doc('users/'+b.localId+'/checkins/2026-11-04');await peer.set({keep:'B'});
 const first=await call(f,'sync',body,'checkin/first');assert.equal(first.status,200);assert.ok(first.ack);assert.equal((await ref.get()).data().energy,1.25);const stamp=(await ref.get()).updateTime;
 const replay=await call(f,'sync',body,'checkin/first');assert.equal(replay.replay,true);assert.ok((await ref.get()).updateTime.isEqual(stamp));
 const newer=await call(f,'sync',{...body,focus:0.05},'checkin/newer');assert.equal(newer.status,200);await call(f,'sync',body,'checkin/first');assert.equal((await ref.get()).data().focus,0.05);assert.deepEqual((await peer.get()).data(),{keep:'B'});
});
test('Check-in HTTP invalid dates and R5 have no domain write or false ACK',async()=>{
 for(const mode of ['invalid','guard','retired','control']){
  const f=await account(),body={operation:'upsert_checkin',checkInId:mode==='invalid'?'2026-02-30':'2026-11-04',energy:1.25,focus:2.5,motivation:3.75};
  if(mode!=='invalid')await db.doc(mode==='retired'?'retired_auth_identities/'+f.localId:'account_deletion_guards/'+f.localId+(mode==='control'?'/control/operation':'')).set({blocked:true});
  const r=await call(f,'sync',body,'checkin/deny');assert.notEqual(r.status,200);if(mode==='invalid')assert.equal(r.status,400);assert.equal(r.ack,null);assert.equal((await db.doc('users/'+f.localId+'/checkins/'+body.checkInId).get()).exists,false);assert.equal((await receipt(f,'checkin/deny').get()).exists,false);
 }
});
