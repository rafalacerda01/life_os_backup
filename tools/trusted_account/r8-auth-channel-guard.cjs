'use strict';
// Network restriction for a synthetic Auth-only actor. This is NOT Firebase IAM.
// The R3 demo/ADC guard is also inherited through NODE_OPTIONS.
const fs=require('node:fs'),path=require('node:path'),net=require('node:net'),{syncBuiltinESMExports}=require('node:module');
const host=process.env.FIREBASE_AUTH_EMULATOR_HOST;
if(process.env.GCLOUD_PROJECT!=='demo-life-os'||!/^127\.0\.0\.1:[1-9][0-9]{0,4}$/.test(host||''))throw Error('DEMO_AUTH_LOOPBACK_REQUIRED');
const audit={pid:process.pid,project:'demo-life-os',allowedHost:host,connections:0,refused:[],notAnIamPolicy:true};
const connect=net.Socket.prototype.connect;net.Socket.prototype.connect=function(...args){const first=Array.isArray(args[0])?args[0][0]:args[0],o=typeof first==='object'?first:{port:first,host:args[1]};if(o?.host+':'+Number(o.port)!==host){audit.refused.push('non-auth-socket');throw Error('AUTH_CHANNEL_ONLY');}audit.connections++;return connect.apply(this,args);};
const fetch=global.fetch;global.fetch=function(value,...rest){const u=new URL(typeof value==='string'?value:value.url||value);if(u.protocol!=='http:'||u.host!==host){audit.refused.push('non-auth-fetch');throw Error('AUTH_CHANNEL_ONLY');}return fetch(value,...rest);};syncBuiltinESMExports();
process.on('exit',()=>{fs.writeFileSync(path.join(process.env.K01_EVIDENCE_DIR,'auth-channel-'+process.pid+'.json'),JSON.stringify(audit,null,2));if(audit.refused.length)process.exitCode=1;});
