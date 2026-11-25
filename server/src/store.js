'use strict';

/*
 * 저장소
 * - DATABASE_URL 이 있으면 PostgreSQL (배포용, Supabase)
 * - 없으면 data.json 파일 (PC에서 혼자 테스트할 때)
 *
 * 암호화 (키: DB_CRYPTO_KEY, 기본값 testkey)
 * - PostgreSQL: pgcrypto 확장(오라클 DBMS_CRYPTO 와 같은 역할)의 pgp_sym_encrypt(AES-256)로
 *   대화 메시지와 개인정보가 든 행을 통째로 암호화해 enc 열에 저장한다. 키 없이 DB를 조회하면 암호문만 보인다.
 *   키는 DB에 저장하지 않고 서버 환경변수로만 두고, 조회할 때마다 파라미터로 넘긴다.
 *     예) select pgp_sym_decrypt(enc, 'testkey')::jsonb from messages;
 * - 파일 저장: data.json 전체를 AES-256-GCM 으로 암호화한다.
 *
 * 서버는 시작할 때 데이터를 전부 메모리에 올리고, 바뀐 것만 뒤에서 저장한다.
 * 테스트·초기 운영 규모(수천 명)에 맞춘 단순한 구조이고, 서버는 한 대만 띄운다는 전제다.
 */

const fs = require('fs');
const crypto = require('crypto');

// 암호화하지 않는 종류: 운영 설정, 거절 사유 문구, 이모지 상점 (개인정보가 아님)
const PLAIN_KINDS = new Set(['settings', 'reasons', 'emojiShop']);
const CIPHER = 'cipher-algo=aes256';

class CryptoKeyError extends Error {}

const KINDS = ['users', 'devices', 'rooms', 'blacklist', 'reports', 'reasons', 'emojiShop', 'emojiRequests'];

function emptyDb() {
  return { settings: {}, reasons: [], users: {}, devices: {}, rooms: {}, messages: {}, blacklist: {}, reports: {}, emojiShop: {}, emojiRequests: {} };
}

// ---------------------------------------------------------------- PostgreSQL

class PgStore {
  constructor(url, key) {
    this.key = key;
    const { Pool } = require('pg');
    const local = /localhost|127\.0\.0\.1|\/tmp|host=\//.test(url);
    this.pool = new Pool({ connectionString: url, max: 4, idleTimeoutMillis: 30000, ssl: local ? false : { rejectUnauthorized: false } });
    // Neon 무료 요금제는 쉬는 동안 연결을 끊는다. 끊긴 연결 때문에 서버가 죽지 않게 한다
    this.pool.on('error', (e) => console.error('DB 연결이 끊겼어요 (다음 요청 때 다시 연결):', e.message));
    this.dirty = new Map(); // `${kind}\u0000${id}` -> obj
    this.queue = Promise.resolve();
    this.timer = setInterval(() => this.flush(), 250);
    this.timer.unref();
    this.kind = 'postgres';
    this.encryption = 'pgcrypto AES-256';
  }

  // pgcrypto 함수 이름 (Supabase 는 extensions 스키마에 설치돼 있다)
  async setupCrypto() {
    try {
      await this.pool.query('create extension if not exists pgcrypto');
    } catch (e) {
      // 권한이 없어도 이미 설치돼 있으면 괜찮다
    }
    const { rows } = await this.pool.query("select n.nspname as schema from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pgcrypto'");
    if (!rows.length) throw new Error('DB에 pgcrypto 확장이 없어요. Supabase > Database > Extensions 에서 pgcrypto 를 켜 주세요');
    const sch = '"' + rows[0].schema.replace(/"/g, '""') + '"';
    this.enc = `${sch}.pgp_sym_encrypt`;
    this.dec = `${sch}.pgp_sym_decrypt`;
  }

  async checkKey() {
    const { rows } = await this.pool.query("select enc from kv where kind = '_crypto' and id = 'check'");
    if (!rows.length) {
      await this.pool.query(`insert into kv (kind, id, data, enc) values ('_crypto', 'check', null, ${this.enc}('ok', $1, '${CIPHER}'))`, [this.key]);
      return;
    }
    try {
      await this.pool.query(`select ${this.dec}(enc, $1) from kv where kind = '_crypto' and id = 'check'`, [this.key]);
    } catch (e) {
      throw new CryptoKeyError('DB 암호화 키(DB_CRYPTO_KEY)가 저장할 때 쓴 키와 달라요. 키를 확인해 주세요');
    }
  }

  // 예전에 평문으로 저장된 행을 한 번 암호화한다
  async encryptOldRows() {
    const kinds = ['users', 'devices', 'rooms', 'blacklist', 'reports', 'emojiRequests'];
    const a = await this.pool.query(
      `update kv set enc = ${this.enc}(data::text, $1, '${CIPHER}'), data = null where data is not null and kind = any($2::text[])`,
      [this.key, kinds],
    );
    const b = await this.pool.query(`update messages set enc = ${this.enc}(data::text, $1, '${CIPHER}'), data = null where data is not null`, [this.key]);
    if (a.rowCount || b.rowCount) console.log(`기존 데이터 암호화: 행 ${a.rowCount}개, 메시지 ${b.rowCount}개`);
  }

  async init() {
    await this.pool.query(`
      create table if not exists kv (
        kind text not null,
        id text not null,
        data jsonb not null,
        updated_at timestamptz not null default now(),
        primary key (kind, id)
      );
      create table if not exists messages (
        id text primary key,
        room_id text not null,
        data jsonb not null,
        created_at bigint not null
      );
      create index if not exists messages_room on messages (room_id, created_at);
      alter table kv add column if not exists enc bytea;
      alter table kv alter column data drop not null;
      alter table messages add column if not exists enc bytea;
      alter table messages alter column data drop not null;
      create table if not exists admin_logs (
        id bigserial primary key,
        at bigint not null,
        admin text not null,
        action text not null,
        target text,
        detail jsonb
      );
    `);
    await this.setupCrypto();
    await this.checkKey();
    await this.encryptOldRows();
    const db = emptyDb();
    const { rows } = await this.pool.query(
      `select kind, id, case when enc is null then data else ${this.dec}(enc, $1)::jsonb end as data from kv where kind <> '_crypto'`,
      [this.key],
    );
    for (const r of rows) {
      if (r.kind === 'settings') db.settings = r.data;
      else if (r.kind === 'reasons') db.reasons.push(r.data);
      else if (db[r.kind]) db[r.kind][r.id] = r.data;
    }
    const msgs = await this.pool.query(
      `select room_id, case when enc is null then data else ${this.dec}(enc, $1)::jsonb end as data from messages order by created_at`,
      [this.key],
    );
    for (const m of msgs.rows) (db.messages[m.room_id] = db.messages[m.room_id] || []).push(m.data);
    return db;
  }

  // 무료 DB가 오래 쉬면 일시정지되므로, 서버 깨우기 요청 때 DB도 한 번 건드린다
  async ping() {
    await this.pool.query('select 1');
    return true;
  }

  put(kind, obj) {
    this.dirty.set(`${kind}\u0000${obj.id}`, { kind, obj });
  }

  putSettings(settings) {
    this.dirty.set('settings\u0000main', { kind: 'settings', obj: { id: 'main', ...settings } });
  }

  addMessage(m) {
    this.queue = this.queue
      .then(() =>
        this.pool.query(
          `insert into messages (id, room_id, data, enc, created_at) values ($1, $2, null, ${this.enc}($3::text, $5, '${CIPHER}'), $4) on conflict (id) do nothing`,
          [m.id, m.roomId, JSON.stringify(m), m.at, this.key],
        ),
      )
      .catch((e) => console.error('메시지 저장 실패', e.message));
  }

  flush() {
    if (!this.dirty.size) return this.queue;
    const batch = [...this.dirty.values()];
    this.dirty.clear();
    this.queue = this.queue
      .then(async () => {
        for (const { kind, obj } of batch) {
          const { _last, ...data } = obj;
          if (PLAIN_KINDS.has(kind)) {
            await this.pool.query(
              'insert into kv (kind, id, data, enc, updated_at) values ($1,$2,$3,null,now()) on conflict (kind, id) do update set data = excluded.data, enc = null, updated_at = now()',
              [kind, String(obj.id), data],
            );
          } else {
            await this.pool.query(
              `insert into kv (kind, id, data, enc, updated_at) values ($1, $2, null, ${this.enc}($3::text, $4, '${CIPHER}'), now())
               on conflict (kind, id) do update set data = null, enc = excluded.enc, updated_at = now()`,
              [kind, String(obj.id), JSON.stringify(data), this.key],
            );
          }
        }
      })
      .catch((e) => console.error('저장 실패', e.message));
    return this.queue;
  }

  log(entry) {
    this.queue = this.queue
      .then(() => this.pool.query('insert into admin_logs (at, admin, action, target, detail) values ($1,$2,$3,$4,$5)', [entry.at, entry.admin, entry.action, entry.target || null, entry.detail || null]))
      .catch((e) => console.error('관리자 기록 실패', e.message));
  }

  async logs(limit = 200) {
    await this.queue;
    const { rows } = await this.pool.query('select at, admin, action, target, detail from admin_logs order by id desc limit $1', [limit]);
    return rows.map((r) => ({ ...r, at: Number(r.at) }));
  }

  async close() {
    clearInterval(this.timer);
    await this.flush();
    await this.queue;
    await this.pool.end();
  }
}

// ---------------------------------------------------------------- 파일

// data.json 전체를 AES-256-GCM 으로 암호화 (키는 scrypt 로 늘린다)
function fileKey(key) {
  return crypto.scryptSync(String(key), 'five-min-chat/data.json', 32);
}
function sealJson(obj, key) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', fileKey(key), iv);
  const data = Buffer.concat([c.update(JSON.stringify(obj), 'utf8'), c.final()]);
  return JSON.stringify({ enc: 'aes-256-gcm', iv: iv.toString('base64'), tag: c.getAuthTag().toString('base64'), data: data.toString('base64') });
}
function openJson(text, key) {
  const raw = JSON.parse(text);
  if (raw.enc !== 'aes-256-gcm') return raw; // 예전 평문 파일
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', fileKey(key), Buffer.from(raw.iv, 'base64'));
    d.setAuthTag(Buffer.from(raw.tag, 'base64'));
    return JSON.parse(Buffer.concat([d.update(Buffer.from(raw.data, 'base64')), d.final()]).toString('utf8'));
  } catch (e) {
    throw new CryptoKeyError('data.json 암호화 키(DB_CRYPTO_KEY)가 저장할 때 쓴 키와 달라요');
  }
}

class FileStore {
  constructor(file, key) {
    this.file = file;
    this.key = key;
    this.encryption = 'AES-256-GCM (파일 전체)';
    this.kind = 'file';
    this.timer = null;
    this.logList = [];
  }

  async init() {
    const db = emptyDb();
    if (fs.existsSync(this.file)) {
      try {
        const raw = openJson(fs.readFileSync(this.file, 'utf8'), this.key);
        Object.assign(db, raw);
        this.logList = raw.adminLogs || [];
        delete db.adminLogs;
      } catch (e) {
        if (e instanceof CryptoKeyError) throw e;
        console.error(`${this.file} 을 읽지 못해 새로 시작합니다:`, e.message);
      }
    }
    for (const k of KINDS) if (k !== 'reasons' && !db[k]) db[k] = {};
    this.db = db;
    return db;
  }

  schedule() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.writeNow(), 300);
  }

  writeNow() {
    clearTimeout(this.timer);
    const out = { ...this.db, adminLogs: this.logList.slice(-2000) };
    const clean = JSON.parse(JSON.stringify(out, (k, v) => (k === '_last' ? undefined : v)));
    fs.writeFileSync(this.file, sealJson(clean, this.key));
  }

  async ping() {
    return true;
  }

  put() {
    this.schedule();
  }

  putSettings() {
    this.schedule();
  }

  addMessage() {
    this.schedule();
  }

  log(entry) {
    this.logList.push(entry);
    this.schedule();
  }

  async logs(limit = 200) {
    return this.logList.slice(-limit).reverse();
  }

  async close() {
    this.writeNow();
  }
}

function createStore({ databaseUrl, dataFile, cryptoKey }) {
  const key = String(cryptoKey || 'testkey');
  return databaseUrl ? new PgStore(databaseUrl, key) : new FileStore(dataFile, key);
}

module.exports = { createStore, CryptoKeyError, openJson };
