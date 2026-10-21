// Local debug transport, reusing the actual backend operations unchanged.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(path.join(root,'backend/package.json'));
const {initializeApp} = require('firebase-admin/app');
const {getAuth} = require('firebase-admin/auth');
const {getFirestore} = require('firebase-admin/firestore');
const {createWaterLifecycle,waterLifecycleError} = await import('../../backend/api/health/_water_lifecycle.js');
const {syncWater,waterErrorResponse} = await import('../../backend/api/health/_sync_water.js');
const {createWaterGoals,goalErrorResponse} = await import('../../backend/api/health/_water_goal.js');
if (!process.version.startsWith('v22.') || process.env.GCLOUD_PROJECT !== 'demo-life-os' ||
    process.env.FIRESTORE_EMULATOR_HOST !== '127.0.0.1:8089' ||
    process.env.FIREBASE_AUTH_EMULATOR_HOST !== '127.0.0.1:9099' ||
    process.env.GOOGLE_APPLICATION_CREDENTIALS) throw Error('EMULATOR_ONLY');
const run = JSON.parse(fs.readFileSync(process.env.LIFE_OS_WATER_DEMO_RUN,'utf8').replace(/^\uFEFF/,''));
if (run.projectId !== 'demo-life-os' || !/^[a-z][a-z0-9-]{0,63}$/.test(run.cohortId) ||
    !Number.isSafeInteger(run.cutoverMillis) || run.cutoverMillis > Date.now()) throw Error('SYNTHETIC_RUN_REQUIRED');
const app=initializeApp({projectId:'demo-life-os'});
const auth=getAuth(app),db=getFirestore(app);
if(db.projectId !== 'demo-life-os') throw Error('PROJECT_BLOCKED');
// These are test-host dependencies, never production policy or remote flags.
// True means this synthetic run exercises the admission branch; it is NOT
// evidence of production IAM enforcement or remote writer fences.
const cohort=Object.freeze({version:1,id:run.cohortId,projectId:'demo-life-os',
  policy:'NEW_ACCOUNT_V2_ONLY',state:'OPEN',cutoverMillis:run.cutoverMillis,
  administrativePolicyVerified:true,writerFencesVerified:true});
const lifecycle=createWaterLifecycle({db,auth,cohort,enabled:true});
const goals=createWaterGoals({db,cohort,enabled:true});
function reply(res,status,body) {
  res.writeHead(status,{'content-type':'application/json','cache-control':'no-store'});
  res.end(JSON.stringify(body));
}
const server=http.createServer(async(req,res)=>{
  if(req.socket.remoteAddress !== '127.0.0.1' && req.socket.remoteAddress !== '::ffff:127.0.0.1') {
    return reply(res,403,{code:'LOOPBACK_ONLY'});
  }
  if(req.method==='GET' && req.url==='/__health') return reply(res,200,
    {projectId:'demo-life-os',isolated:true,runId:run.runId});
  if(req.method!=='POST' || req.url!=='/api/sync') return reply(res,404,{code:'NOT_FOUND'});
  let operation;
  try {
    if(req.headers['x-firebase-appcheck'] !== 'isolated-emulator-only') return reply(res,401,{code:'DEMO_ATTESTATION_REQUIRED'});
    const bearer=req.headers.authorization;
    if(typeof bearer!=='string' || !bearer.startsWith('Bearer ')) return reply(res,401,{code:'AUTHENTICATION_REQUIRED'});
    const token=await auth.verifyIdToken(bearer.slice(7));
    if(token.aud!=='demo-life-os' || token.iss!=='https://securetoken.google.com/demo-life-os' ||
        token.firebase?.sign_in_provider!=='password' || !token.email?.endsWith('@example.test')) {
      return reply(res,403,{code:'SYNTHETIC_IDENTITY_REQUIRED'});
    }
    let bytes=0,parts=[];
    for await(const part of req) {bytes+=part.length;if(bytes>65536)throw Error('BODY_LIMIT');parts.push(part);}
    const body=JSON.parse(Buffer.concat(parts).toString('utf8'));
    operation=body.operation;
    let result;
    if(operation==='bootstrap_water') result=await lifecycle.bootstrap(token.uid,body);
    else if(operation==='set_water_goal') {await lifecycle.ensureAccount(token.uid);result=await goals.set(token.uid,body);}
    else if(operation==='increment_water' || operation==='reconcile_water') {
      await lifecycle.ensureDay(token.uid,body.healthDay);
      const snapshot=await syncWater({db,userId:token.uid,body,enabled:true});
      // Match the existing production endpoint envelope; keep strict client ACK.
      result={success:true,operation,...snapshot};
    } else return reply(res,400,{code:'WATER_OPERATION_ONLY'});
    console.log(JSON.stringify({event:'response',runId:run.runId,uid:token.uid,operation,status:200}));
    reply(res,200,result);
  } catch(error) {
    const mapped=operation==='set_water_goal' ? goalErrorResponse(error) :
      operation==='increment_water' || operation==='reconcile_water' ? waterErrorResponse(error) : waterLifecycleError(error);
    console.log(JSON.stringify({event:'response',runId:run.runId,operation,status:mapped.status,code:mapped.body.code}));
    reply(res,mapped.status,mapped.body);
  }
});
server.requestTimeout=10000;
server.listen(8789,'127.0.0.1',()=>console.log(JSON.stringify({event:'listening',projectId:'demo-life-os',port:8789,runId:run.runId})));
for(const signal of ['SIGINT','SIGTERM']) process.on(signal,()=>server.close(()=>{db.terminate().finally(()=>process.exit(0));}));
