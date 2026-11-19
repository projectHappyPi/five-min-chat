'use strict';

/*
 * 저장소
 * - DATABASE_URL 이 있으면 PostgreSQL (배포용, Neon 무료 요금제)
 * - 없으면 data.json 파일 (PC에서 혼자 테스트할 때)
 *
 * 서버는 시작할 때 데이터를 전부 메모리에 올리고, 바뀐 것만 뒤에서 저장한다.
 * 테스트·초기 운영 규모(수천 명)에 맞춘 단순한 구조이고, 서버는 한 대만 띄운다는 전제다.
 */

const fs = require('fs');

const KINDS = ['users', 'devices', 'rooms', 'blacklist', 'reports', 'reasons'];

function emptyDb() {
  return { settings: {}, reasons: [], users: {}, devices: {}, rooms: {}, messages: {}, blacklist: {}, reports: {} };
}

// ---------------------------------------------------------------- PostgreSQL

class PgStore {
  constructor(url) {
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
      create table if not exists admin_logs (
        id bigserial primary key,
        at bigint not null,
        admin text not null,
        action text not null,
        target text,
        detail jsonb
      );
    `);
    const db = emptyDb();
    const { rows } = await this.pool.query('select kind, id, data from kv');
    for (const r of rows) {
      if (r.kind === 'settings') db.settings = r.data;
      else if (r.kind === 'reasons') db.reasons.push(r.data);
      else if (db[r.kind]) db[r.kind][r.id] = r.data;
    }
    const msgs = await this.pool.query('select room_id, data from messages order by created_at');
    for (const m of msgs.rows) (db.messages[m.room_id] = db.messages[m.room_id] || []).push(m.data);
    return db;
  }

  put(kind, obj) {
    this.dirty.set(`${kind}\u0000${obj.id}`, { kind, obj });
  }

  putSettings(settings) {
    this.dirty.set('settings\u0000main', { kind: 'settings', obj: { id: 'main', ...settings } });
  }

  addMessage(m) {
    this.queue = this.queue
      .then(() => this.pool.query('insert into messages (id, room_id, data, created_at) values ($1,$2,$3,$4) on conflict (id) do nothing', [m.id, m.roomId, m, m.at]))
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
          await this.pool.query(
            'insert into kv (kind, id, data, updated_at) values ($1,$2,$3,now()) on conflict (kind, id) do update set data = excluded.data, updated_at = now()',
            [kind, String(obj.id), data],
          );
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

class FileStore {
  constructor(file) {
    this.file = file;
    this.kind = 'file';
    this.timer = null;
    this.logList = [];
  }

  async init() {
    const db = emptyDb();
    if (fs.existsSync(this.file)) {
      try {
        const raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
        Object.assign(db, raw);
        this.logList = raw.adminLogs || [];
        delete db.adminLogs;
      } catch (e) {
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
    fs.writeFileSync(this.file, JSON.stringify(out, (k, v) => (k === '_last' ? undefined : v)));
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

function createStore({ databaseUrl, dataFile }) {
  return databaseUrl ? new PgStore(databaseUrl) : new FileStore(dataFile);
}

module.exports = { createStore };
