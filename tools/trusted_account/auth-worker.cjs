'use strict';
// The real Auth Emulator dispatches its blocking JWT to the real Functions SDK
// HTTP adapter. Tests do not mint the generation claim or write the origin.
const path=require('node:path'),http=require('node:http'),{createRequire}=require('node:module');
const req=createRequire(path.join(process.env.LOCAL_FIREBASE_TOOLS,'package.json'));
if(req('./package.json').version!=='15.24.0')throw Error('REVIEWED_AUTH_EMULATOR_REQUIRED');
const {logger}=req('./lib/logger.js'),{transports}=req('winston');logger.clear();logger.add(new transports.Console({silent:true}));
const freq=createRequire(path.resolve(__dirname,'../../functions/package.json'));
const {Firestore}=freq('firebase-admin/firestore'),{GoogleAuth,OAuth2Client}=freq('google-auth-library');
const owner=new OAuth2Client();owner.setCredentials({access_token:'owner',expiry_date:Date.now()+3600000});
const db=new Firestore({projectId:'demo-life-os',databaseId:'(default)',host:process.env.FIRESTORE_EMULATOR_HOST,ssl:false,auth:new GoogleAuth({projectId:'demo-life-os',authClient:owner})});
const hook=freq('./trusted_account_runtime').createRuntime({firestore:()=>db}).beforeCreate;
const {AgentProjectState}=req('./lib/emulator/auth/state.js'),state=new AgentProjectState('demo-life-os');
// Retain the Admin SDK audience check without disabling token verification.
// This is a loopback URL; the SDK's project audience is part of its path.
const hookPath='/demo-life-os.cloudfunctions.net/trusted-before-create';
state.blockingFunctionsConfig={triggers:{beforeCreate:{functionUri:'http://'+process.env.FIREBASE_AUTH_EMULATOR_HOST+hookPath}}};
let server;
process.on('disconnect',()=>{server?.closeAllConnections();server?.close(async()=>{await db.terminate();process.exit(0);});setTimeout(()=>process.exit(1),2000).unref();});
req('./lib/emulator/auth/server.js').createApp('demo-life-os',2,new Map([['demo-life-os',state]])).then(authApp=>{
 const app=req('express')();
 app.post(hookPath,req('express').json(),hook);
 app.use(authApp);server=http.createServer(app);
 server.listen(Number(process.env.FIREBASE_AUTH_EMULATOR_HOST.split(':')[1]),'127.0.0.1',()=>process.send({ready:true}));
}).catch(()=>process.exit(1));
