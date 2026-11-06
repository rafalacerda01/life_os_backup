// Pure structural regression checks, not a Firestore Rules compiler/interpreter.
// UNVERIFIED: runtime authorization, evaluation errors, caching, 10/20 budgets and races.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {test} = require('node:test');
const rules = fs.readFileSync(path.resolve(__dirname, '../../firestore.rules'), 'utf8');
function functions(text) {
  const result = {};
  for (const match of text.matchAll(/\bfunction\s+(\w+)\s*\([^)]*\)\s*\{/g)) {
    const start = match.index + match[0].length - 1;
    let depth = 1, quote = '', comment = '', end = start + 1;
    for (; end < text.length && depth; end++) {
      const c = text[end], next = text[end + 1];
      if (comment === '//') {if (c === '\n') comment = ''; continue;}
      if (comment === '/*') {if (c === '*' && next === '/') {comment = ''; end++;} continue;}
      if (quote) {if (c === '\\') end++; else if (c === quote) quote = ''; continue;}
      if (c === '/' && (next === '/' || next === '*')) {comment = c + next; end++; continue;}
      if (c === '"' || c === "'") {quote = c; continue;}
      if (c === '{') depth++;
      if (c === '}') depth--;
    }
    assert.equal(depth, 0);
    result[match[1]] = text.slice(match.index, end).replaceAll('\r\n', '\n');
  }
  return result;
}
const compact = text => text.replace(/\/\/[^\n]*/g, '').replace(/\s+/g, '');
const allows = text => [...text.matchAll(/\ballow\s+([^:]+):\s*if\s+([^;]+);/g)].map(m => compact(m[0]));
const matches = text => text.split(/\r?\n/).filter(l => /^\s*match /.test(l)).map(compact);
const bodies = functions(rules);
const preserved = {
  "validCivilDay": "d95b47e257b7546550d9c37161008f94ad0de088735863d9a51f553f633a5027",
  "isSignedIn": "8ab02b46db8f833c5eefa0d11e8fd5bd518fef3d557e7f7d8c8c11fc9ea07c59",
  "isOwner": "7ea87600fe5eee07818da58b19d780d2eb20834a08c32ae0fde0d031d8e3f4f3",
  "validCircleDocumentId": "d846c3b3cddfeccf08153d0e1286d4e56a2bb8440d01bf682b8a624aab8927f8",
  "circlePath": "30d03db44ef685ac7a648dd58881f64258e3e4aeeb50230a348017705cc9af21",
  "challengePath": "c1338fe3217bcd1196893b793ae3856a92c99a029754ced20e4c5f460a42df60",
  "maxCircleChallenges": "7f24ea7d54e1bd1060dc345d95470bb7c1636fda5b7f71503849f12bfc1aa687",
  "canWriteUserData": "809b92b1f761ca50234d5a18f542a6f6366e28f967de6fd48565c2a61bb5e783",
  "hasWaterProtocolBarrier": "d4a7964e9825d0741dd4cbebb26610f0d8a3245f4019cc663f21817b8cdd2588",
  "circleDeletionPath": "855b2405c23c8ab529313e1e475d3725d2240807a7ae33eb856d4d83299231bd",
  "userPath": "5c7bd13f7171e507879caf88d4d8f6f65496d09e8defeb9758753af42aa5b234",
  "memberPath": "260e8cad895bbb467002f8a932f88a458fadd61990000abb228934c5833db4c8",
  "isCircleAdmin": "0fd1da9a3b957092d8d0cf5600bd1e6d046628920190ae53a0939cebfae6add3",
  "isCircleMember": "8f6d6ae330555cd296a19e9002ccc6675e9f66106b2ba481fad82f2ce472cfa2",
  "isUpdatingOnly": "030c3fda2bf4c23d3ccf454f6936927b693c052cb2f13f61b6130544fe5f30f0",
  "validNewMemberData": "a9d46e4a439b8bcb7589eb3b0326ea5f44e3ee0b62d382d68b6cba9db0289f92",
  "hasNoActiveCircle": "2f18440546c0dd9ffb060ac99cfd09fdf8bb66b7e884d20fbda782d28b01b42b",
  "changesOnlyActiveCircle": "00331c695898f73ce8fed5adecdae513383505cfac98c40bfc19420a6990721d",
  "userActivatesCircle": "9e4426886229f27068cad310f501ad5acda7b963bcea109941fde5b4cfbd00ce",
  "userClearsCircle": "ce880b90f38e33e3fd75d4d7635b737d27a6c487f7384c132592b5622aaf89a8",
  "validActiveCircleUpdate": "7e5834f53f3756ffe67afae90919f5c3d0968e6d933d5a471715b35b40f59e0c",
  "hasTrustedPremium": "a0dd08f2de5f2e8165e0fdf10eb41e1d3b14a9ee86bd73ebd598a6f9ddbb53a7",
  "hasTrustedAdminPremium": "24a6695e83ac958ebfe4e624de32cf0fe167b0ee3484f5834f14da9a17b337c5",
  "validAdminMemberLimit": "84c35bcf8a1e784d78cee1bfdeb217d65297a96e47ace4ec749f6fa355c793c1",
  "effectiveMemberLimit": "23bf247a282d8d1085f600997b162f4cc4d1d57ff887a3c44ec5ec84443b7ac0",
  "validCircleCreate": "d871e9fe7955a86565ec955483adf4eb9d9d07b60c9f4b423d527c085a730fb4",
  "isAtomicJoin": "a3d3b158612750ca9894700978bcafbd7b3f752bd18feef1245085e91f25c128",
  "isAtomicLeave": "fbd91be78eb7bb6ce485984d54a8c38c64cc94d652c7301b26835463a878832e",
  "isValidMemberCreate": "d87fa434ee0b896531cccd803adf68a38635e0b224729b71630a0cabf437d7c5",
  "isAdminTimestampUpdate": "63eea9be9b842c628996e980347c868263bf491e495dba86cdea91546e06ce74",
  "validCircleDelete": "d1420d14143ac5c805cb637234b7c09fcabd3b84a52b25756ed5dfa0f123d13a",
  "validChallengeCounterUpdate": "734238858b6ba67c4123624224bcb37351de54ac894094b8c989158075e8ceb0",
  "isAtomicChallengeCreate": "44261bfb15af5c3bba066130cf24bc0adcf2d36fa5270e689ffa56c17340f8f4",
  "validMemberDelete": "a1a5e2a437a3a32952ec4bdb0ec70779c93646da7d560506c76c7ae8a031e966",
  "validChallengeCreate": "c42b0790314c19ca3edc7e340056ee9c4e81691964772f22830f87577e26f2bb",
  "validUserCreate": "dc170c8af2c58256cfa0879052ed07be560a368f19affeacbf1f72f292d0713c",
  "validUserUpdate": "963a0eb02a3b9f8dca6febeaa88f68777a41d635776ab518772471e83c94c4c3",
  "validCheckinData": "8a1f90ff2b1604a9ec24f1305601cd83b1fed257f1410ab6ac3a77eb779467a8",
  "validFocusLogData": "fa317fb8d3ce2774d711dd344e49db1a0a79937f88378e90c3acdcb82cef152a",
  "validMenstrualCycleData": "0c7e244af7dd1cef6234ac252c6e451a5d4c45d3678d11abbc909e80bfdf6dfd",
  "validHealthData": "b251e258f5a61e93566f5b9a0a4e0125280299e45d43ba79cbb3f5ec275a261d",
  "validStudyInfoData": "b8d17b79ad152784286d6e46ce6e2f0fe3462fc498f7d4d3bb9f77e8ad7349f3",
  "validStudyInfoCreate": "11d570920792982435a7c16490a903203527a63e8538cdc94da9946e63d3a234",
  "validStudyInfoUpdate": "a01b112a599e9985b36a023d0471d8b7d5724e0432d59b2733a34a3f7598c2b7",
  "validReviewQueueCreate": "94f5ce48232980da1afb2d029965c80306780ce2f12fd8571bd3dcb135cfe47c",
  "validNotificationData": "651dac768276644469f86ea0831113f6b47222c605c5e4d4a8800e0e8ca1445f",
  "validPrivacySchema": "320c7970745ec96ddb49cd307e1ef601456d5df4bf6b818b54c36fd15b613cf1",
  "validPrivacyCreate": "a81cdae1337c94c7c28148cd04b7c9432f3e688d3739804b7d47608fcda860fa",
  "validPrivacyUpdate": "7885504ce496a1a83416d76e2201abfa0e33ca607620130e0e8ec3e7535144da"
};
const expectedAllows = [
  "allowread:ifisOwner(userId);",
  "allowcreate:ifcanWriteUserData(userId)&&validUserCreate()&&!exists(/databases/$(database)/documents/account_birth_decisions/$(userId));",
  "allowupdate:ifcanWriteUserData(userId)&&validUserUpdate(userId);",
  "allowdelete:iffalse;",
  "allowread:ifisOwner(userId);",
  "allowcreate,delete:iffalse;",
  "allowupdate:ifcanWriteUserData(userId)&&isUpdatingOnly(['completedDates'])&&request.resource.data.completedDatesislist&&request.resource.data.completedDates.size()<=5000;",
  "allowread:ifisOwner(userId);",
  "allowcreate,delete:iffalse;",
  "allowupdate:ifcanWriteUserData(userId)&&isUpdatingOnly(['isCompleted'])&&request.resource.data.isCompletedisbool;",
  "allowread:ifisOwner(userId);",
  "allowcreate,delete:iffalse;",
  "allowupdate:ifcanWriteUserData(userId)&&isUpdatingOnly(['currentValue','lastReset'])&&(!request.resource.data.diff(resource.data).affectedKeys().hasAny(['currentValue'])||(request.resource.data.currentValueisint&&request.resource.data.currentValue>=0))&&(!request.resource.data.diff(resource.data).affectedKeys().hasAny(['lastReset'])||request.resource.data.lastResetistimestamp);",
  "allowread:ifisOwner(userId);",
  "allowcreate,delete:iffalse;",
  "allowupdate:ifcanWriteUserData(userId)&&!request.resource.data.diff(resource.data).affectedKeys().hasAny(['cardsToReview'])&&isUpdatingOnly(['cardsToReview','progress','streakDays'])&&(!request.resource.data.diff(resource.data).affectedKeys().hasAny(['cardsToReview'])||(request.resource.data.cardsToReviewisint&&request.resource.data.cardsToReview>=0))&&(!request.resource.data.diff(resource.data).affectedKeys().hasAny(['progress'])||(request.resource.data.progressisnumber&&request.resource.data.progress>=0&&request.resource.data.progress<=1))&&(!request.resource.data.diff(resource.data).affectedKeys().hasAny(['streakDays'])||(request.resource.data.streakDaysisint&&request.resource.data.streakDays>=0));",
  "allowread:ifisOwner(userId);",
  "allowcreate,update,delete:iffalse;",
  "allowread:ifisOwner(userId);",
  "allowcreate,update,delete:iffalse;",
  "allowread:ifisOwner(userId);",
  "allowcreate,update:ifcanWriteUserData(userId)&&validCheckinData(checkinId);",
  "allowdelete:iffalse;",
  "allowread:ifisOwner(userId);",
  "allowcreate,update:ifcanWriteUserData(userId)&&validFocusLogData();",
  "allowdelete:iffalse;",
  "allowread:ifisOwner(userId);",
  "allowcreate:ifcanWriteUserData(userId)&&validHealthData()&&(!hasWaterProtocolBarrier(userId)||!request.resource.data.keys().hasAny(['waterIntakeMl']));",
  "allowupdate:ifcanWriteUserData(userId)&&validHealthData()&&(!hasWaterProtocolBarrier(userId)||!request.resource.data.diff(resource.data).affectedKeys().hasAny(['waterIntakeMl']));",
  "allowdelete:iffalse;",
  "allowread:ifisOwner(userId);",
  "allowcreate:iffalse;",
  "allowupdate:iffalse;",
  "allowdelete:iffalse;",
  "allowread:ifisOwner(userId)&&stateId=='main';",
  "allowcreate,update,delete:iffalse;",
  "allowread,create,update,delete:iffalse;",
  "allowread,create,update,delete:iffalse;",
  "allowread:ifisOwner(userId);",
  "allowcreate:iffalse;",
  "allowupdate:iffalse;",
  "allowdelete:iffalse;",
  "allowread:ifisOwner(userId);",
  "allowcreate,update:ifcanWriteUserData(userId)&&validNotificationData(notificationId);",
  "allowdelete:ifcanWriteUserData(userId);",
  "allowread:ifisOwner(userId);",
  "allowcreate:ifcanWriteUserData(userId)&&privacyId=='ai_consent'&&validPrivacyCreate(userId);",
  "allowupdate:ifcanWriteUserData(userId)&&privacyId=='ai_consent'&&validPrivacyUpdate(userId);",
  "allowdelete:iffalse;",
  "allowget:ifisSignedIn();",
  "allowlist:iffalse;",
  "allowcreate:ifisSignedIn()&&validCircleCreate(circleId);",
  "allowupdate:ifcircleMutationAllowed(circleId,resource.data)&&(isAdminTimestampUpdate(circleId)||isAtomicJoin(circleId)||isAtomicLeave(circleId)||validChallengeCounterUpdate(circleId,resource.data,request.resource.data));",
  "allowdelete:iffalse;",
  "allowget:ifisOwner(userId)||isCircleMember(circleId);",
  "allowlist:ifisCircleMember(circleId);",
  "allowcreate:ifmembershipMutationAllowed(circleId)&&isValidMemberCreate(circleId,userId);",
  "allowupdate:iffalse;",
  "allowdelete:ifvalidMemberDelete(circleId,userId);",
  "allowread:ifisCircleMember(circleId);",
  "allowcreate:ifcircleMutationAllowed(circleId,get(circlePath(circleId)).data)&&isCircleAdmin(circleId)&&isCircleMember(circleId)&&!get(circlePath(circleId)).data.keys().hasAny(['deletionState'])&&validChallengeCreate(circleId,challengeId)&&isAtomicChallengeCreate(circleId,challengeId);",
  "allowupdate:iffalse;",
  "allowdelete:iffalse;",
  "allowget:ifisCircleMember(circleId)&&exists(memberPath(circleId,userId));",
  "allowlist:ifisCircleMember(circleId);",
  "allowcreate,update,delete:iffalse;",
  "allowread,write:iffalse;",
  "allowread,write:iffalse;",
  "allowread,write:iffalse;"
];
const expectedMatches = [
  "match/databases/{database}/documents{",
  "match/users/{userId}{",
  "match/habits/{habitId}{",
  "match/tasks/{taskId}{",
  "match/goals/{goalId}{",
  "match/subjects/{subjectId}{",
  "match/medications/{medicationId}{",
  "match/transactions/{transactionId}{",
  "match/checkins/{checkinId}{",
  "match/focus_logs/{focusLogId}{",
  "match/health_info/{healthInfoId}{",
  "match/study_info/{studyInfoId}{",
  "match/study_progress_state/{stateId}{",
  "match/study_progress_events/{eventId}{",
  "match/study_streak_ranges/{rangeId}{",
  "match/review_queue/{reviewId}{",
  "match/notifications/{notificationId}{",
  "match/privacy/{privacyId}{",
  "match/circles/{circleId}{",
  "match/members/{userId}{",
  "match/challenges/{challengeId}{",
  "match/progress/{userId}{",
  "match/processed_events/{eventKey}{",
  "match/circle_deletions/{circleId}{",
  "match/{document=**}{"
];

for (const [name, digest] of Object.entries(preserved)) {
  test('reviewed validator body (unaltered except P1 contracts): ' + name, () => {
    assert.equal(crypto.createHash('sha256').update(bodies[name]).digest('hex'), digest);
  });
}
test('structural inventory contains exactly the original helpers plus two mutation gates', t => {
  t.diagnostic('UNVERIFIED: compilation, real authorizations, cache/budgets and races; no functional suite executed.');
  assert.deepEqual(Object.keys(bodies).sort(), [...Object.keys(preserved), 'accountDeletionBlocked',
    'circleMutationAllowed', 'membershipMutationAllowed'].sort());
});
test('presence-only R5 predicate has exactly three OR checks, without expiry/state fallback', () => {
  assert.equal(compact(bodies.accountDeletionBlocked), compact(
    'function accountDeletionBlocked(userId) { return ' +
    'exists(/databases/$(database)/documents/retired_auth_identities/$(userId)) || ' +
    'exists(/databases/$(database)/documents/account_deletion_guards/$(userId)) || ' +
    'exists(/databases/$(database)/documents/account_deletion_guards/$(userId)/control/operation); }'));
});
test('ownership and R5 remain AND prerequisites for private writes', () => {
  assert.equal(compact(bodies.canWriteUserData), 'functioncanWriteUserData(userId){returnisOwner(userId)&&!accountDeletionBlocked(userId);}');
});
test('every allow matches the reviewed R5 surface and four narrow Study restrictions', () => {
  assert.deepEqual(allows(rules), expectedAllows);
});
test('match surface is unchanged, including recursive default denial', () => {
  assert.deepEqual(matches(rules), expectedMatches);
  assert.match(rules, /match \/\{document=\*\*\} \{\s*allow read, write: if false;/);
});
test('entire original Circle update OR is dominated by the common mutation gate', () => {
  const rootUpdate = allows(rules).find(a => a.startsWith('allowupdate:ifcircleMutationAllowed'));
  assert.equal(rootUpdate, 'allowupdate:ifcircleMutationAllowed(circleId,resource.data)&&(isAdminTimestampUpdate(circleId)||isAtomicJoin(circleId)||isAtomicLeave(circleId)||validChallengeCounterUpdate(circleId,resource.data,request.resource.data));');
});
test('actor and original owner R5, both closing paths and original schema gate mutations', () => {
  assert.equal(compact(bodies.circleMutationAllowed), compact(
    "function circleMutationAllowed(circleId, data) { return isSignedIn() && validCircleDocumentId(circleId) && validCircleDocumentId(data.adminId) && !accountDeletionBlocked(request.auth.uid) && (data.adminId == request.auth.uid || !accountDeletionBlocked(data.adminId)) && data.schemaVersion == 2 && !data.keys().hasAny(['deletionState']) && !exists(circleDeletionPath(circleId)) && !exists(/databases/$(database)/documents/circle_cleanup_guards/$(circleId)); }"));
});
test('membership obtains existing owner before writes, new owner only from atomic post-state', () => {
  assert.equal(compact(bodies.membershipMutationAllowed), compact(
    'function membershipMutationAllowed(circleId) { let data = exists(circlePath(circleId)) ? get(circlePath(circleId)).data : getAfter(circlePath(circleId)).data; return circleMutationAllowed(circleId, data); }'));
});
test('Challenge retains explicit admin, membership, schema and atomic counter validators', () => {
  assert.ok(allows(rules).some(a => a.startsWith('allowcreate:ifcircleMutationAllowed(circleId,get(circlePath(circleId)).data)&&isCircleAdmin(circleId)&&isCircleMember(circleId)') &&
    a.includes('validChallengeCreate(circleId,challengeId)&&isAtomicChallengeCreate(circleId,challengeId)')));
});
test('root creation keeps original owner, membership, atomic profile and Premium requirements', () => {
  for (const text of ['request.resource.data.adminId == request.auth.uid', 'validAdminMemberLimit', 'userActivatesCircle', 'existsAfter', 'getAfter']) assert.ok(bodies.validCircleCreate.includes(text), text);
  assert.ok(bodies.userActivatesCircle.includes('!accountDeletionBlocked(userId)'));
});
test('membership delete still requires root deletion that Client SDK cannot grant', () => {
  assert.ok(bodies.validMemberDelete.includes('!existsAfter(circlePath(circleId))'));
  assert.ok(allows(rules).includes('allowdelete:iffalse;'));
  assert.ok(allows(rules).includes('allowdelete:ifvalidMemberDelete(circleId,userId);'));
});
test('birth, Water and Free/Premium schemas are unchanged original helper fingerprints', () => {
  for (const name of ['hasWaterProtocolBarrier', 'validUserCreate', 'validUserUpdate',
    'hasTrustedPremium', 'hasTrustedAdminPremium', 'validAdminMemberLimit', 'effectiveMemberLimit']) assert.ok(preserved[name]);
});
test('private write inventory remains explicitly owner/R5 gated, with no broad write grants', () => {
  const predicates = allows(rules);
  assert.equal(predicates.filter(a => a.includes('canWriteUserData(userId)')).length, 14);
  assert.ok(!predicates.some(a => /allow(?:read,)?write:if(?!false;)/.test(a)));
  for (const pathName of ['medications', 'transactions', 'study_progress_state', 'study_progress_events', 'study_streak_ranges']) {
    assert.ok(expectedMatches.some(m => m.includes('/' + pathName + '/')));
  }
});
test('static suite imports only builtins and does not import or execute functional tests', () => {
  const source = fs.readFileSync(__filename, 'utf8');
  const imports = [...source.matchAll(/require\(['"]([^'"]+)['"]\)/g)].map(m => m[1]);
  assert.deepEqual(imports, ['node:fs', 'node:path', 'node:assert/strict', 'node:crypto', 'node:test']);
});

// Structural checks only: match extraction is not a Rules compiler or evaluator.
function studyMatch(header) {
  const marker = 'match ' + header + ' {';
  assert.equal(rules.split(marker).length, 2, 'exactly one reviewed match: ' + header);
  const start = rules.indexOf(marker) + marker.length;
  let depth = 1, quote = '', comment = '', end = start;
  for (; end < rules.length && depth; end++) {
    const c = rules[end], next = rules[end + 1];
    if (comment === '//') {if (c === '\n') comment = ''; continue;}
    if (comment === '/*') {if (c === '*' && next === '/') {comment = ''; end++;} continue;}
    if (quote) {if (c === '\\') end++; else if (c === quote) quote = ''; continue;}
    if (c === '/' && (next === '/' || next === '*')) {comment = c + next; end++; continue;}
    if (c === '"' || c === "'") {quote = c; continue;}
    if (c === '{') depth++;
    if (c === '}') depth--;
  }
  assert.equal(depth, 0, 'balanced reviewed match');
  return rules.slice(start, end - 1);
}
const reviewBlock = () => studyMatch('/review_queue/{reviewId}');
const studyInfoBlock = () => studyMatch('/study_info/{studyInfoId}');
const subjectBlock = () => studyMatch('/subjects/{subjectId}');

test('C review_queue has owner read and unconditional create/update/delete denial', () => {
  assert.deepEqual(allows(reviewBlock()), ['allowread:ifisOwner(userId);',
    'allowcreate:iffalse;', 'allowupdate:iffalse;', 'allowdelete:iffalse;']);
  assert.ok(!reviewBlock().includes('validReviewQueueCreate()'));
});
test('C study_info has no Client write field left, including non-main ids', () => {
  assert.deepEqual(allows(studyInfoBlock()), ['allowread:ifisOwner(userId);',
    'allowcreate:iffalse;', 'allowupdate:iffalse;', 'allowdelete:iffalse;']);
  assert.ok(!studyInfoBlock().includes('validStudyInfoCreate()'));
  assert.ok(!studyInfoBlock().includes('validStudyInfoUpdate()'));
});
test('C cardsToReview immutability is an AND before the unchanged Subject validators', () => {
  const update = allows(subjectBlock()).find(a => a.startsWith('allowupdate:'));
  assert.ok(update.startsWith("allowupdate:ifcanWriteUserData(userId)&&!request.resource.data.diff(resource.data).affectedKeys().hasAny(['cardsToReview'])&&isUpdatingOnly(['cardsToReview','progress','streakDays'])"));
  assert.ok(update.includes('request.resource.data.cardsToReviewisint&&request.resource.data.cardsToReview>=0'));
  assert.ok(update.includes('request.resource.data.progressisnumber&&request.resource.data.progress>=0&&request.resource.data.progress<=1'));
  assert.ok(update.includes('request.resource.data.streakDaysisint&&request.resource.data.streakDays>=0'));
  assert.equal(allows(subjectBlock()).length, 3);
  assert.deepEqual(allows(subjectBlock()).slice(0, 2), ['allowread:ifisOwner(userId);', 'allowcreate,delete:iffalse;']);
});
test('C own get/list retain read ownership even when retirement blocks writes', () => {
  for (const block of [reviewBlock(), studyInfoBlock(), subjectBlock()]) {
    const reads = allows(block).filter(a => a.startsWith('allowread:'));
    assert.deepEqual(reads, ['allowread:ifisOwner(userId);']);
    assert.equal(/allow(?:get|list):/.test(compact(block)), false);
  }
  assert.equal(compact(bodies.isOwner), 'functionisOwner(userId){returnisSignedIn()&&request.auth.uid==userId;}');
});
test('C receipts have no specific match or recursive positive grant, including descendants', () => {
  assert.ok(!matches(rules).some(m => m.includes('study_card_create_receipts')));
  assert.ok(!rules.includes('study_card_create_receipts'));
  assert.deepEqual(expectedMatches.filter(m => m.includes('=**')), ['match/{document=**}{']);
  assert.deepEqual(allows(studyMatch('/{document=**}')), ['allowread,write:iffalse;']);
  // Full exact allow and match inventories above rule out another positive
  // wildcard match; default DENY is not interpreted as overriding an ALLOW.
  assert.deepEqual(matches(rules), expectedMatches);
});
test('C three R5 controls remain inaccessible via complete reviewed match inventory', () => {
  for (const collection of ['retired_auth_identities', 'account_deletion_guards']) {
    assert.ok(!matches(rules).some(m => m.includes('/' + collection + '/')));
  }
  for (const path of ['retired_auth_identities/$(userId)', 'account_deletion_guards/$(userId)',
    'account_deletion_guards/$(userId)/control/operation']) assert.ok(bodies.accountDeletionBlocked.includes(path));
  assert.deepEqual(allows(studyMatch('/{document=**}')), ['allowread,write:iffalse;']);
});
test('C no request field, email, Premium, version or Circle membership reopens Study authority', () => {
  for (const block of [reviewBlock(), studyInfoBlock(), subjectBlock()]) {
    assert.equal(/request\.auth\.token|email|isPremium|creationProtocolVersion|isCircleMember|exists\(/.test(compact(block)), false);
  }
});
test('C Subject update adds no document lookup beyond unchanged owner/R5 helper', () => {
  assert.equal(/\b(?:get|getAfter|exists|existsAfter)\s*\(/.test(subjectBlock()), false);
  assert.equal((bodies.accountDeletionBlocked.match(/\bexists\(/g) || []).length, 3);
  assert.equal((compact(subjectBlock()).match(/canWriteUserData\(userId\)/g) || []).length, 1);
});
