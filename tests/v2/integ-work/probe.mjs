import Database from '/home/openclaw/.hermes/memos-plugin-research-agent/node_modules/better-sqlite3/lib/index.js';
import { readFileSync } from 'fs';
import crypto from 'crypto';

const DB = process.env.HOME + '/.hermes/memos-state-research-agent/memos-local/memos.db';
const MARKER = readFileSync('/home/openclaw/Coding/Hermes/tests/v2/integ-work/marker.txt', 'utf8').trim();
console.log(`Marker: ${MARKER}`);
const db = new Database(DB);
db.pragma('foreign_keys = ON');
console.log('FK on:', db.pragma('foreign_keys', {simple:true}));
console.log('journal:', db.pragma('journal_mode', {simple:true}));

const now = Date.now();
const sessionKey = `audit:session:${MARKER}`;
const turnId = `turn-${MARKER}`;
const owner = 'agent:integ-audit';

function insertChunk(content, role='user', extra={}) {
  const id = crypto.randomUUID();
  const summary = (extra.summary || content.slice(0,120));
  const hash = crypto.createHash('sha256').update(content).digest('hex');
  db.prepare(`INSERT INTO chunks(id, session_key, turn_id, seq, role, content, kind, summary, created_at, updated_at, content_hash, owner)
              VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`).run(
    id, sessionKey, turnId, extra.seq??0, role, content, 'paragraph', summary, now, now, hash, owner
  );
  const dim = 4;
  const vec = Buffer.alloc(dim*4);
  for (let i=0;i<dim;i++) vec.writeFloatLE(Math.random(), i*4);
  db.prepare(`INSERT INTO embeddings(chunk_id, vector, dimensions, updated_at) VALUES(?,?,?,?)`).run(id, vec, dim, now);
  return id;
}

// === CONTENT FIDELITY ROUND-TRIP ===
console.log('\n=== PROBE A: Content fidelity ===');
const testPayloads = {
  'decimals': '3.141592653589793238462643383279',
  'bigint_overflow': '9007199254740993',
  'emoji': 'Fire: 🔥🔥🔥 Level up 💯',
  'chinese': '中文测试：永和九年，岁在癸丑',
  'arabic_rtl': 'Arabic: مرحبا بالعالم',
  'url_complex': 'https://ex.com/path?a=1&b=2#frag%20space',
  'triple_backtick': 'Code:\n```js\nconst x = `template`;\n```\nend',
  'json_escaped': '{"quote":"she said \\"hi\\"","esc":"\\\\n"}',
  'markdown_pipe': '| a | b |\n| --- | --- |\n| 1 | 2 |',
  'null_byte': `before${String.fromCharCode(0)}after`,
  'control_chars': `CR\rLF\nTAB\tBELL${String.fromCharCode(7)}`,
  'long_line': 'X'.repeat(10000),
  'mixed_newlines': `lf\nCrLf\r\ncr\rnone`,
  'trailing_no_nl': 'no trailing newline',
};

const fidelityResults = {};
for (const [k, v] of Object.entries(testPayloads)) {
  const id = insertChunk(v, 'user', {summary: `fidelity-${k}`});
  const row = db.prepare('SELECT content FROM chunks WHERE id=?').get(id);
  const equal = row.content === v;
  const lenIn = v.length, lenOut = row.content.length;
  fidelityResults[k] = { equal, lenIn, lenOut, bytes_in: Buffer.byteLength(v), bytes_out: Buffer.byteLength(row.content) };
  if (!equal) {
    // find first diff
    let firstDiff = -1;
    for (let i=0;i<Math.max(v.length,row.content.length);i++) if (v[i]!==row.content[i]) { firstDiff=i; break;}
    fidelityResults[k].firstDiffAt = firstDiff;
    fidelityResults[k].diff_preview = `in[${firstDiff}]=${JSON.stringify(v[firstDiff])} out[${firstDiff}]=${JSON.stringify(row.content[firstDiff])}`;
  }
}
console.log(JSON.stringify(fidelityResults, null, 2));

// === FTS round-trip for these ===
console.log('\n=== PROBE A.2: FTS indexing of special content ===');
for (const k of ['emoji','chinese','long_line','null_byte']) {
  try {
    const q = k==='emoji' ? '🔥' : k==='chinese' ? '永和' : k==='long_line' ? 'X' : 'before';
    const hits = db.prepare(`SELECT c.id FROM chunks c JOIN chunks_fts f ON f.rowid=c.rowid WHERE chunks_fts MATCH ? AND c.session_key=?`).all(q, sessionKey);
    console.log(`fts[${k} -> "${q}"] hits=${hits.length}`);
  } catch(e) { console.log(`fts[${k}] ERROR: ${e.message}`); }
}

// === FK / ORPHAN ===
console.log('\n=== PROBE B: FK integrity (FK ON) ===');
const firstId = Object.values(fidelityResults)[0] && db.prepare('SELECT id FROM chunks WHERE session_key=? LIMIT 1').get(sessionKey).id;
const beforeEmb = db.prepare('SELECT COUNT(*) c FROM embeddings WHERE chunk_id=?').get(firstId).c;
db.prepare('DELETE FROM chunks WHERE id=?').run(firstId);
const afterEmb = db.prepare('SELECT COUNT(*) c FROM embeddings WHERE chunk_id=?').get(firstId).c;
console.log(`delete chunk -> embedding rows: before=${beforeEmb} after=${afterEmb} (CASCADE ${afterEmb===0?'works':'FAILED'})`);

// What happens without FK — separate DB connection without setting pragma
const db2 = new Database(DB);
// db2 has FK OFF by default
console.log('db2 FK:', db2.pragma('foreign_keys', {simple:true}));
// Insert orphan embedding
try {
  const orphanId = 'ORPHAN-' + MARKER;
  db2.prepare(`INSERT INTO embeddings(chunk_id, vector, dimensions, updated_at) VALUES(?,?,?,?)`).run(orphanId, Buffer.alloc(16), 4, now);
  const o = db.prepare('SELECT COUNT(*) c FROM embeddings WHERE chunk_id=?').get(orphanId).c;
  console.log(`Orphan embedding inserted without FK enforcement: ${o===1?'YES -- integrity risk if any client opens DB without pragma':'NO'}`);
  db.prepare('DELETE FROM embeddings WHERE chunk_id=?').run(orphanId);
} catch(e) { console.log('orphan insert failed:', e.message); }
db2.close();

// === CORRUPT EMBEDDING BLOB ===
console.log('\n=== PROBE C: Corrupt embedding blob ===');
const victimId = insertChunk('victim for corrupt test '+MARKER, 'user');
db.prepare('UPDATE embeddings SET vector=?, dimensions=? WHERE chunk_id=?').run(Buffer.from('garbage-not-floats'), 999, victimId);
const v = db.prepare('SELECT dimensions, length(vector) lv FROM embeddings WHERE chunk_id=?').get(victimId);
console.log(`Corrupted row: dims=${v.dimensions} bytes=${v.lv} (stored without validation)`);

// === CONCURRENT UPDATE ===
console.log('\n=== PROBE D: Concurrent update (last-writer-wins) ===');
const conflictId = insertChunk('original content '+MARKER, 'assistant');
const dbA = new Database(DB); dbA.pragma('foreign_keys = ON');
const dbB = new Database(DB); dbB.pragma('foreign_keys = ON');
// sequential writes — no version column, so pure LWW
dbA.prepare('UPDATE chunks SET content=?, updated_at=? WHERE id=?').run('from A', Date.now(), conflictId);
dbB.prepare('UPDATE chunks SET content=?, updated_at=? WHERE id=?').run('from B', Date.now(), conflictId);
const final = db.prepare('SELECT content FROM chunks WHERE id=?').get(conflictId).content;
console.log(`After A then B: content="${final}" (no version field: LWW silently clobbers)`);
dbA.close(); dbB.close();

// Check schema for any version/etag field
const chunkCols = db.prepare("PRAGMA table_info(chunks)").all().map(c=>c.name);
console.log('chunk columns:', chunkCols.join(','));
console.log('has version/etag/revision?', chunkCols.some(c=>/version|etag|revision/i.test(c)));

// === CLOCK SKEW ===
console.log('\n=== PROBE E: Clock skew / future timestamps ===');
const futureId = insertChunk('future content '+MARKER, 'user', {summary:'future ts test'});
const future = Date.now() + 365*24*3600*1000; // +1 year
db.prepare('UPDATE chunks SET created_at=?, updated_at=? WHERE id=?').run(future, future, futureId);
const ft = db.prepare('SELECT created_at FROM chunks WHERE id=?').get(futureId).created_at;
console.log(`Future ts accepted: ${ft} (no server validation; Date.now() from client is trusted)`);

// Negative ts
const negId = insertChunk('negative content '+MARKER, 'user');
db.prepare('UPDATE chunks SET created_at=? WHERE id=?').run(-1, negId);
const neg = db.prepare('SELECT created_at FROM chunks WHERE id=?').get(negId).created_at;
console.log(`Negative ts accepted: ${neg}`);

// === DEDUP content_hash ===
console.log('\n=== PROBE F: Content-hash dedup & near-dup merge ===');
const hashCols = chunkCols.filter(c=>c.includes('merge')||c.includes('dedup'));
console.log('merge/dedup columns:', hashCols.join(','));

// Two near-dup rows that differ in one fact — hash will differ
const aliceA = 'Alice is 25 years old and works at ACME.';
const aliceB = 'Alice is 30 years old and works at ACME.';
const ia = insertChunk(aliceA,'user');
const ib = insertChunk(aliceB,'user');
const hashA = db.prepare('SELECT content_hash FROM chunks WHERE id=?').get(ia).content_hash;
const hashB = db.prepare('SELECT content_hash FROM chunks WHERE id=?').get(ib).content_hash;
console.log(`hashA=${hashA?.slice(0,12)} hashB=${hashB?.slice(0,12)} equal=${hashA===hashB}`);
console.log('-> content_hash dedup catches EXACT dup only; semantic dedup is handled by embedding-similarity at ingest');
console.log('-> Merge semantics depend on findDuplicate callers. See dedup_status/dedup_target/merge_history columns.');

// Show dedup schema semantics
const deduped = db.prepare(`SELECT id, dedup_status, dedup_target, dedup_reason, merge_count, merge_history FROM chunks WHERE dedup_status!='active' LIMIT 3`).all();
console.log('existing deduped rows sample:', JSON.stringify(deduped));

// === SOFT DELETE PROPAGATION ===
console.log('\n=== PROBE G: Soft-delete / dedup_status="superseded" ===');
const softId = insertChunk('soft delete target '+MARKER, 'user', {summary:'SOFTDEL '+MARKER});
db.prepare(`UPDATE chunks SET dedup_status='superseded', dedup_target='x', dedup_reason='test' WHERE id=?`).run(softId);
// Check if FTS still indexes it (triggers)
const ftsStill = db.prepare(`SELECT 1 FROM chunks_fts WHERE chunks_fts MATCH ? LIMIT 1`).all('SOFTDEL');
console.log(`After dedup_status=superseded, FTS row STILL present: ${ftsStill.length>0 ? 'YES (FTS triggers do not filter on dedup_status — soft-deleted rows still match FTS queries)' : 'no'}`);
console.log('-> Caller must filter WHERE dedup_status="active" when searching; easy to forget.');

// Check whether embedding row remains
const embStill = db.prepare('SELECT 1 FROM embeddings WHERE chunk_id=?').get(softId);
console.log(`embedding row remains after soft-delete: ${embStill?'YES':'NO'} (still participates in cosine-similarity dedup scans unless caller filters)`);

// === FTS TRIGRAM + CONTROL CHARS ===
console.log('\n=== PROBE H: FTS query with null byte ===');
try {
  const r = db.prepare(`SELECT count(*) c FROM chunks_fts WHERE chunks_fts MATCH ?`).all('before after');
  console.log(`null-byte row matches "before after": ${JSON.stringify(r)}`);
} catch(e){console.log('fts err:', e.message);}

// cleanup — leave rows for evidence inspection, tagged by owner
const inserted = db.prepare('SELECT COUNT(*) c FROM chunks WHERE owner=?').get(owner).c;
console.log(`\nInserted chunks tagged owner=${owner}: ${inserted}`);

db.close();
