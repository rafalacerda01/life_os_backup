'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),{createRequire}=require('node:module');
const path=require('node:path');
const req=createRequire(path.join(__dirname,'package.json'));
const ON=process.env.K01_EMULATOR_TEST==='1';
if(!ON)test('K01 receipt Rules require the isolated demo launcher',{skip:'Run tools/k01/emulator-run.cjs'},()=>{});
if(ON){
const {initializeTestEnvironment,assertFails,assertSucceeds}=req('@firebase/rules-unit-testing');
const {doc,collection,getDoc,getDocs,setDoc,updateDoc,deleteDoc}=req('firebase/firestore');let env;
test.before(async()=>{env=await initializeTestEnvironment({projectId:'demo-life-os',firestore:{rules:fs.readFileSync(path.resolve(__dirname,'../../firestore.rules'),'utf8')}});await env.clearFirestore();});
test.after(async()=>env?.cleanup());
const paths=['retired_auth_identities/k01-A','account_deletion_guards/k01-A','account_deletion_guards/k01-A/control/operation','account_deletion_guards/k01-A/cleanup_manifests/private','account_deletion_guards/k01-A/cleanup_manifests/private/pages/0','account_deletion_guards/k01-A/cleanup_manifests/circle','account_deletion_guards/k01-A/cleanup_manifests/circle/pages/0'];
for(const who of ['k01-A','k01-B',null])for(const path of paths)test('Rules: '+(who||'anonymous')+' cannot read/create/update/delete '+path,async()=>{
 const db=(who?env.authenticatedContext(who):env.unauthenticatedContext()).firestore();
 await env.withSecurityRulesDisabled(async c=>setDoc(doc(c.firestore(),path),{sealed:true}));
 await assertFails(getDoc(doc(db,path)));await assertFails(updateDoc(doc(db,path),{sealed:false}));await assertFails(deleteDoc(doc(db,path)));
 await env.withSecurityRulesDisabled(async c=>{assert.deepEqual((await getDoc(doc(c.firestore(),path))).data(),{sealed:true});await deleteDoc(doc(c.firestore(),path));});
 await assertFails(setDoc(doc(db,path),{forged:true}));
});
for(const who of ['k01-A','k01-B',null])test('Rules: '+(who||'anonymous')+' cannot enumerate sealed manifests or receipt pages',async()=>{
 const db=(who?env.authenticatedContext(who):env.unauthenticatedContext()).firestore();
 await assertFails(getDocs(collection(db,'account_deletion_guards/k01-A/cleanup_manifests')));await assertFails(getDocs(collection(db,'account_deletion_guards/k01-A/cleanup_manifests/private/pages')));
});

}
