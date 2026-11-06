'use strict';
// Standalone validation artifacts; no repository writes, CLI or Cloud credentials.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),net=require('node:net'),{spawn}=require('node:child_process');
if(process.argv.length!==2||process.versions.node.split('.')[0]!=='22')throw Error('NODE22_NO_ARGUMENTS_REQUIRED');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'lifeos-r8-authority-')),profile=path.join(temp,'empty-profile');fs.mkdirSync(profile);
const ROOT=path.resolve(__dirname,'../..');
const out=process.env.TRUSTED_TEST_EVIDENCE_DIR;
if(!out||!path.isAbsolute(out)||path.resolve(out)===ROOT||path.resolve(out).startsWith(ROOT+path.sep))throw Error('EVIDENCE_OUTSIDE_REPOSITORY_REQUIRED');
fs.mkdirSync(out,{recursive:true});const windows=process.env.SystemRoot||'C:/Windows';
const env={SystemRoot:windows,WINDIR:windows,PATH:[path.dirname(process.execPath),path.join(windows,'System32')].join(path.delimiter),HOME:profile,USERPROFILE:profile,APPDATA:profile,LOCALAPPDATA:profile,XDG_CONFIG_HOME:profile,CLOUDSDK_CONFIG:profile,TEMP:temp,TMP:temp,GCLOUD_PROJECT:'demo-life-os',GOOGLE_CLOUD_PROJECT:'demo-life-os',METADATA_SERVER_DETECTION:'none',GCE_METADATA_HOST:'127.0.0.1:1',CI:'true',FIREBASE_CLI_DISABLE_USAGE_REPORTING:'1',K01_EVIDENCE_DIR:out};
const javaExe='C:/Program Files/Android/Android Studio/jbr/bin/java.exe',jar=path.join(os.homedir(),'.cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar');
const tools=path.join(os.homedir(),'AppData/Roaming/npm/node_modules/firebase-tools');
let java,auth,child;const result={project:'demo-life-os',node:process.version,authEmulator:'firebase-tools 15.24.0',firestoreEmulator:'1.22.0',inheritedCredentials:false,managedDeliveryTested:false,webSdk:'12.19.0',nativeSdkExecuted:false,cloudIamEnforced:false};
async function port(){const s=net.createServer();await new Promise((r,j)=>s.once('error',j).listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}
function spawnLogged(exe,args,name,extra={}){const stdout=fs.openSync(path.join(out,name+'.stdout'),'w'),stderr=fs.openSync(path.join(out,name+'.stderr'),'w');const p=spawn(exe,args,{cwd:temp,env,windowsHide:true,stdio:['ignore',stdout,stderr,...(extra.ipc?['ipc']:[])]});fs.closeSync(stdout);fs.closeSync(stderr);return p;}
async function waitPort(p,proc){const start=Date.now();while(Date.now()-start<30000){if(proc.exitCode!==null)throw Error('EMULATOR_EARLY_EXIT');try{await new Promise((r,j)=>{const s=net.connect(p,'127.0.0.1');s.once('connect',()=>{s.end();r();});s.once('error',j);});return;}catch{}await new Promise(r=>setTimeout(r,100));}throw Error('READINESS_TIMEOUT');}
async function stop(p){if(!p||p.exitCode!==null)return;await new Promise(r=>{const t=setTimeout(()=>{p.kill();r();},3000);p.once('close',()=>{clearTimeout(t);r();});if(p===auth&&p.connected)p.disconnect();else p.kill();});}
for(const signal of ['SIGINT','SIGTERM'])process.once(signal,()=>{child?.kill();auth?.kill();java?.kill();process.exitCode=1;});
(async()=>{try{
 const fp=await port(),ap=await port();if(fp===ap)throw Error('DISTINCT_PORTS_REQUIRED');env.FIRESTORE_EMULATOR_HOST='127.0.0.1:'+fp;env.FIREBASE_AUTH_EMULATOR_HOST='127.0.0.1:'+ap;result.hosts=[env.FIRESTORE_EMULATOR_HOST,env.FIREBASE_AUTH_EMULATOR_HOST];
 env.LOCAL_FIREBASE_TOOLS=tools;env.NODE_OPTIONS='--require='+JSON.stringify(path.join(__dirname,'guard.cjs').replace(/\\/g,'/'));
 java=spawnLogged(javaExe,['-Duser.language=en','-Duser.country=US','-Duser.home='+profile,'-jar',jar,'--host','127.0.0.1','--port',String(fp),'--project_id','demo-life-os','--single_project_mode','--single_project_mode_error','--rules',path.join(ROOT,'firestore.trusted.rules')],'firestore');
 auth=spawnLogged(process.execPath,[path.join(__dirname,'auth-worker.cjs')],'auth',{ipc:true});
 await Promise.all([waitPort(fp,java),waitPort(ap,auth)]);
 const stdout=fs.openSync(path.join(out,'auth-firestore.tap'),'w'),stderr=fs.openSync(path.join(out,'auth-firestore.stderr'),'w');
 child=spawn(process.execPath,['--test','--test-concurrency=1','--test-reporter=tap',path.join(ROOT,'functions/test/trusted-account-emulator.test.cjs'),path.join(ROOT,'tools/trusted_account/sdk-boundary.test.cjs'),path.join(ROOT,'tools/trusted_account/r8-authority-boundary.test.cjs'),path.join(ROOT,'backend/test/integration/historical-admission-emulator.test.cjs'),path.join(ROOT,'functions/test/historical-admission-emulator.test.js')],{cwd:temp,env,windowsHide:true,stdio:['ignore',stdout,stderr]});
 const timeout=setTimeout(()=>child.kill(),180000);let exit;try{exit=await new Promise((r,j)=>{child.once('error',j);child.once('close',(code,signal)=>r({code,signal}));});}finally{clearTimeout(timeout);fs.closeSync(stdout);fs.closeSync(stderr);}
 result.exit=exit;const tap=fs.readFileSync(path.join(out,'auth-firestore.tap'),'utf8');result.metrics=Object.fromEntries([...tap.matchAll(/^# (tests|pass|fail|skipped|cancelled) (\d+)\r?$/gm)].map(m=>[m[1],Number(m[2])]));process.exitCode=exit.code||0;
}catch(e){result.error=e.code||e.message;process.exitCode=1;}finally{await stop(child);await stop(auth);await stop(java);result.stopped=[auth,java].every(p=>!p||p.exitCode!==null||p.signalCode!==null);result.io=fs.readdirSync(out).filter(f=>/^io-\d+\.json$/.test(f)).map(f=>JSON.parse(fs.readFileSync(path.join(out,f)))).filter(v=>JSON.stringify(v.hosts)===JSON.stringify(result.hosts));if(!result.stopped||result.io.length<2||result.io.some(v=>v.refused.length||v.adc.length))process.exitCode=1;fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));}})();
