'use strict';
// Test process only. Explicit allowlist of two loopback emulator ports, no ADC.
const fs=require('node:fs'),net=require('node:net'),dns=require('node:dns'),{createRequire,syncBuiltinESMExports}=require('node:module');
const hosts=[process.env.FIRESTORE_EMULATOR_HOST,process.env.FIREBASE_AUTH_EMULATOR_HOST];
if(hosts.some(h=>!/^127\.0\.0\.1:[1-9][0-9]{0,4}$/.test(h||'')||Number(h.split(':')[1])>65535)||process.env.GCLOUD_PROJECT!=='demo-life-os'||process.env.GOOGLE_CLOUD_PROJECT!=='demo-life-os')throw Error('DEMO_LOOPBACK_REQUIRED');
for(const k of ['GOOGLE_APPLICATION_CREDENTIALS','FIREBASE_TOKEN','FIREBASE_PRIVATE_KEY','FIREBASE_CLIENT_EMAIL','GOOGLE_OAUTH_ACCESS_TOKEN','FIREBASE_CONFIG','FIREBASE_EMULATOR_HUB','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY'])if(process.env[k]!==undefined)throw Error('EXTERNAL_CONFIGURATION_REFUSED');
const evidence={pid:process.pid,project:'demo-life-os',hosts,connections:0,refused:[],adc:[]};
function deny(k){evidence.refused.push(k);throw Error('NON_EMULATOR_IO_REFUSED:'+k);}
const connect=net.Socket.prototype.connect;
net.Socket.prototype.connect=function(...args){const first=Array.isArray(args[0])?args[0][0]:args[0];const o=typeof first==='object'?first:{port:first,host:args[1]};if(o?.host!=='127.0.0.1'||!hosts.includes(o.host+':'+Number(o.port)))deny('socket');evidence.connections++;return connect.apply(this,args);};
for(const m of [dns,require('node:dns/promises')]){const lookup=m.lookup;m.lookup=function(n,...a){if(n!=='127.0.0.1')deny('dns');return lookup.call(this,n,...a);};if(m.Resolver)for(const k of Object.getOwnPropertyNames(m.Resolver.prototype))if(k.startsWith('resolve')||k==='reverse')m.Resolver.prototype[k]=()=>deny('dns.Resolver');for(const k of Object.keys(m))if(k.startsWith('resolve')||k==='reverse'||k==='lookupService')m[k]=()=>deny('dns.'+k);}
for(const pkg of [require('node:path').resolve(__dirname,'../../backend/package.json'),require('node:path').resolve(__dirname,'../../functions/package.json')]){const {GoogleAuth}=createRequire(pkg)('google-auth-library');for(const k of ['getApplicationDefault','getApplicationDefaultAsync','_getApplicationCredentialsFromFilePath','_tryGetApplicationCredentialsFromWellKnownFile','_tryGetApplicationCredentialsFromEnvironmentVariable'])GoogleAuth.prototype[k]=()=>{evidence.adc.push(k);throw Error('ADC_FORBIDDEN');};}
require('node:dgram').createSocket=()=>deny('udp');if(global.WebSocket)global.WebSocket=class{constructor(){deny('websocket');}};
const fetch=global.fetch;global.fetch=function(u,...rest){const parsed=new URL(typeof u==='string'?u:u.url||u);if(parsed.protocol!=='http:'||!hosts.includes(parsed.host))deny('fetch');return fetch(u,...rest);};syncBuiltinESMExports();
process.on('exit',()=>{fs.writeFileSync(process.env.K01_EVIDENCE_DIR+'/io-'+process.pid+'.json',JSON.stringify(evidence,null,2));if(evidence.refused.length||evidence.adc.length)process.exitCode=1;});
