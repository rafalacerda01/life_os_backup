const assert = require("node:assert/strict");
const test = require("node:test");
const {MAX_CIRCLE_CHALLENGES, inspectCircle, backfillCircle, backfillCircles, parseArgs} =
  require("../scripts/backfill-circle-challenge-count");

const legacy = () => ({schemaVersion: 2, adminId: "admin", memberCount: 1,
  memberLimit: 3, updatedAt: "unchanged"});

function fixture(count, root = legacy()) {
  const children = Array.from({length: count}, (_, index) => ({id: `c-${index}`,
    data: () => ({endAt: new Date(0), schemaVersion: index % 2 ? 1 : 2})}));
  const collection = {get: async () => ({size: children.length, docs: children})};
  const ref = {id: "circle", get: async () => ({data: () => root}),
    collection: (name) => {
      assert.equal(name, "challenges");
      return collection;
    }};
  const writes = [];
  const db = {runTransaction: async (callback) => callback({
    get: (target) => target.get(),
    update: (target, patch) => {
      assert.equal(target, ref);
      writes.push(patch);
      Object.assign(root, patch);
    },
    delete: () => assert.fail("No deletions allowed"),
  })};
  return {db, ref, root, writes, children};
}

test("CLI defaults to dry-run and requires explicit project; apply is explicit", () => {
  assert.deepEqual(parseArgs(["--project", "demo-life-os"]), {apply: false, projectId: "demo-life-os"});
  assert.deepEqual(parseArgs(["--apply", "--project", "demo-life-os"]), {apply: true, projectId: "demo-life-os"});
  assert.throws(() => parseArgs([]));
  assert.throws(() => parseArgs(["--project", "demo-life-os", "--unknown"]));
  assert.equal(MAX_CIRCLE_CHALLENGES, 240);
});

for (const count of [0, 7, 240]) {
  test(`dry-run counts all ${count} Challenges, including expired and legacy`, async () => {
    const f = fixture(count);
    const original = {...f.root};
    const result = await backfillCircle(f.db, f.ref);
    assert.deepEqual(result, {status: "CANDIDATE", actualCount: count,
      patch: {challengeCount: count, lastChallengeId: null}});
    assert.deepEqual(f.writes, []);
    assert.deepEqual(f.root, original);
    assert.equal(f.children.length, count);
  });
  test(`apply ${count} updates only metadata and second dry-run is unchanged`, async () => {
    const f = fixture(count);
    const original = {...f.root};
    const children = [...f.children];
    assert.equal((await backfillCircle(f.db, f.ref, {apply: true})).status, "APPLIED");
    assert.deepEqual(f.writes, [{challengeCount: count, lastChallengeId: null}]);
    assert.deepEqual(f.root, {...original, challengeCount: count, lastChallengeId: null});
    assert.deepEqual(f.children, children);
    assert.equal((await backfillCircle(f.db, f.ref)).status, "UNCHANGED");
    assert.equal((await backfillCircle(f.db, f.ref, {apply: true})).status, "UNCHANGED");
    assert.equal(f.writes.length, 1);
  });
}

test("241 documents reports OVER_LIMIT in dry-run and apply without writes or truncation", async () => {
  const f = fixture(241);
  const original = {...f.root};
  for (const apply of [false, true]) {
    assert.deepEqual(await backfillCircle(f.db, f.ref, {apply}), {status: "OVER_LIMIT", actualCount: 241});
  }
  assert.deepEqual(f.root, original);
  assert.deepEqual(f.writes, []);
  assert.equal(f.children.length, 241);
});

for (const [label, fields] of [
  ["partial count", {challengeCount: 0}], ["partial last ID", {lastChallengeId: null}],
  ["divergent count", {challengeCount: 1, lastChallengeId: null}],
  ...[null, "0", -1, 0.5, 241].map(value => [`invalid count ${value}`, {challengeCount: value, lastChallengeId: null}]),
  ...["", " bad ", "x".repeat(129), "bad/id", 7].map(value => [`invalid last ID ${value}`, {challengeCount: 0, lastChallengeId: value}]),
  ["invalid schema", {schemaVersion: 1}],
]) {
  test(`${label} reports CONFLICT without overwriting`, async () => {
    const f = fixture(0, {...legacy(), ...fields});
    const original = {...f.root};
    assert.equal((await backfillCircle(f.db, f.ref, {apply: true})).status, "CONFLICT");
    assert.deepEqual(f.root, original);
    assert.deepEqual(f.writes, []);
  });
}

test("consistent existing fields with a valid last ID remain unchanged", () => {
  assert.equal(inspectCircle({...legacy(), challengeCount: 2, lastChallengeId: "last-id"}, 2).status, "UNCHANGED");
});

test("apply rechecks state inside transaction instead of overwriting a raced migration", async () => {
  const f = fixture(0);
  const run = f.db.runTransaction;
  f.db.runTransaction = (callback) => {
    Object.assign(f.root, {challengeCount: 1, lastChallengeId: "other"});
    return run(callback);
  };
  assert.equal((await backfillCircle(f.db, f.ref, {apply: true})).status, "CONFLICT");
  assert.deepEqual(f.writes, []);
});

test("runner paginates Circles and reports each result without implicit writes", async () => {
  const first = fixture(0);
  const second = fixture(241);
  second.ref.id = "over-limit";
  let cursor;
  let pages = 0;
  first.db.collection = name => {
    assert.equal(name, "circles");
    const query = {
      orderBy: () => query,
      limit: value => {assert.equal(value, 200); return query;},
      startAfter: value => {cursor = value; return query;},
      get: async () => {
        pages++;
        return cursor ? {empty: true, docs: []} : {empty: false, docs: [
          {id: first.ref.id, ref: first.ref}, {id: second.ref.id, ref: second.ref},
        ]};
      },
    };
    return query;
  };
  const results = await backfillCircles(first.db);
  assert.deepEqual(results.map(result => result.status), ["CANDIDATE", "OVER_LIMIT"]);
  assert.equal(pages, 2);
  assert.deepEqual(first.writes, []);
  assert.deepEqual(second.writes, []);
});
