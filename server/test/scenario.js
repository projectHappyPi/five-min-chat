'use strict';
// 전체 흐름 자동 검사.
//   npm test                                   → data.json 파일 저장소로 검사
//   TEST_DATABASE_URL=postgres://... npm test  → PostgreSQL 로 검사 (재시작 후 데이터 유지까지)
const path = require('path');
const os = require('os');
const fs = require('fs');
const assert = require('assert');
const { start } = require('../src/server');
const { io: connect } = require('socket.io-client');

const DB_URL = process.env.TEST_DATABASE_URL || null;
const dataFile = path.join(os.tmpdir(), `fmc-test-${Date.now()}.json`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let BASE;
const adminHeaders = { 'Content-Type': 'application/json', Authorization: 'Basic ' + Buffer.from('admin:test').toString('base64') };

async function boot() {
  const s = await start({ port: 0, databaseUrl: DB_URL, dataFile, adminPassword: 'test', appSecret: 'test-secret', publicUrl: 'http://127.0.0.1', identityProvider: 'mock' });
  BASE = `http://127.0.0.1:${s.port}`;
  return s;
}

async function api(method, p, body, headers = {}) {
  const r = await fetch(BASE + p, { method, headers: { 'Content-Type': 'application/json', ...headers }, body: body ? JSON.stringify(body) : undefined });
  const data = await r.json().catch(() => ({}));
  return { http: r.status, ...data };
}
const admin = (method, p, body) => api(method, '/admin' + p, body, adminHeaders);

const PEOPLE = {
  kim: { name: '김민수', birth: '19950314', gender: 'M', phone: '01012345678' },
  lee: { name: '이서연', birth: '19980702', gender: 'F', phone: '01087654321' },
  park: { name: '박지훈', birth: '19900101', gender: 'M', phone: '01055556666' },
};

async function newDevice(model = 'Pixel 8') {
  const d = await api('POST', '/api/device/register', { platform: 'android', model });
  return d.deviceToken;
}

// 기기 인증 → 간편인증 → (처음이면) 가입
async function auth(person, deviceToken) {
  deviceToken = deviceToken || (await newDevice());
  const h = { 'X-Device-Token': deviceToken };
  const st = await api('POST', '/api/identity/start', {}, h);
  const done = await api('POST', '/api/identity/complete', { verificationId: st.verificationId, mock: person }, h);
  if (done.http !== 200) return { ...done, deviceToken };
  if (done.status === 'login') return { ...done, deviceToken, kind: 'login' };
  const su = await api('POST', '/api/signup', { verificationId: st.verificationId, agreeTerms: true, agreePrivacy: true }, h);
  return { ...su, deviceToken, kind: 'signup', profile: done.profile };
}

function client(token) {
  const s = connect(BASE, { auth: { token }, transports: ['websocket'], reconnection: false });
  s.events = [];
  s.onAny((ev, data) => s.events.push({ ev, data }));
  s.call = (ev, data) => new Promise((res) => s.emit(ev, data || {}, res));
  s.waitFor = async (ev, pred = () => true, ms = 5000) => {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      const i = s.events.findIndex((e) => e.ev === ev && pred(e.data));
      if (i >= 0) return s.events.splice(i, 1)[0].data;
      await sleep(30);
    }
    throw new Error(`이벤트 대기 시간 초과: ${ev}`);
  };
  return new Promise((res, rej) => {
    s.on('connect', () => res(s));
    s.on('connect_error', rej);
  });
}

let passed = 0;
const step = (name) => {
  passed++;
  console.log(`  ✓ ${name}`);
};

(async () => {
  console.log(`  저장소: ${DB_URL ? 'PostgreSQL' : '파일'}`);
  let srv = await boot();
  await admin('PUT', '/api/settings', { freeSeconds: 2, retryWaitSeconds: 1, extendMinutes: 1 });

  // ---------------- 가입
  const noDevice = await api('POST', '/api/identity/start', {});
  assert.strictEqual(noDevice.http, 401);
  const dt = await newDevice();
  const h = { 'X-Device-Token': dt };
  const st = await api('POST', '/api/identity/start', {}, h);
  const badBirth = await api('POST', '/api/identity/complete', { verificationId: st.verificationId, mock: { ...PEOPLE.kim, birth: '19951341' } }, h);
  assert.strictEqual(badBirth.error, 'birth');
  const kid = await api('POST', '/api/identity/complete', { verificationId: st.verificationId, mock: { name: '최아이', birth: '20100505', gender: 'F', phone: '01011112222' } }, h);
  assert.strictEqual(kid.error, 'underage');
  step('기기 인증 없이는 간편인증 불가, 잘못된 생년월일·미성년자 거부');

  const st2 = await api('POST', '/api/identity/start', {}, h);
  const done = await api('POST', '/api/identity/complete', { verificationId: st2.verificationId, mock: PEOPLE.kim }, h);
  assert.strictEqual(done.status, 'signup');
  assert.strictEqual(done.profile.gender, 'M');
  assert.strictEqual(done.profile.birthYear, 1995);
  assert.ok(done.profile.age >= 30);
  const noTerms = await api('POST', '/api/signup', { verificationId: st2.verificationId, agreeTerms: true }, h);
  assert.strictEqual(noTerms.error, 'terms');
  const kim = await api('POST', '/api/signup', { verificationId: st2.verificationId, agreeTerms: true, agreePrivacy: true }, h);
  assert.ok(kim.token && kim.user.gender === 'M' && kim.user.birthYear === 1995 && kim.user.coins === 100);
  step('간편인증 결과로 나이·성별 자동 입력, 필수 약관 동의 후 가입');

  const chk = await api('GET', '/api/check', null, { Authorization: `Bearer ${kim.token}`, 'X-Device-Token': dt });
  assert.ok(chk.ok && chk.user.nickname);
  const chkOther = await api('GET', '/api/check', null, { Authorization: `Bearer ${kim.token}`, 'X-Device-Token': await newDevice() });
  assert.strictEqual(chkOther.http, 401);
  step('자동로그인: 세션은 가입한 기기에서만 유효');

  const kimAgain = await auth(PEOPLE.kim);
  assert.strictEqual(kimAgain.kind, 'login');
  assert.strictEqual(kimAgain.user.id, kim.user.id);
  const oldSession = await api('GET', '/api/check', null, { Authorization: `Bearer ${kim.token}`, 'X-Device-Token': dt });
  assert.strictEqual(oldSession.http, 401);
  step('같은 사람이 새 기기에서 인증하면 같은 계정으로 로그인, 예전 기기는 로그아웃 (1계정 1기기)');

  const lee = await auth(PEOPLE.lee);
  assert.strictEqual(lee.user.gender, 'F');
  const A = await client(lee.token); // 웹(QR 보여주는 쪽) 역할
  const B = await client(kimAgain.token); // 앱 역할
  const unauth = await client('wrong').catch((e) => e);
  assert.ok(unauth instanceof Error);
  step('세션 없는 소켓 접속 거부');

  // ---------------- QR 대화
  let qr = await A.call('qr:new');
  assert.ok(qr.ok && qr.svg.includes('<svg') && qr.url.endsWith(qr.token));
  assert.strictEqual((await A.call('join', { token: qr.token })).error, 'self');
  let j = await B.call('join', { token: qr.token });
  assert.ok(j.ok && j.room.status === 'live' && j.room.partnerNickname === lee.user.nickname);
  assert.strictEqual((await A.waitFor('qr:used')).roomId, j.room.id);
  assert.strictEqual((await B.call('join', { token: qr.token })).error, 'invalid');
  step('QR 스캔으로 대화방 생성, QR 1회용');

  const roomId = j.room.id;
  await B.call('msg:send', { roomId, text: '안녕하세요' });
  const got = await A.waitFor('msg', (d) => d.roomId === roomId);
  assert.strictEqual(got.message.text, '안녕하세요');
  await B.call('msg:send', { roomId, text: '아까 카페에서 만났죠' });
  const unreadUpd = await A.waitFor('room:update', (d) => d.id === roomId && d.unread === 2);
  assert.ok(unreadUpd);
  assert.strictEqual((await B.call('rooms:list')).rooms.find((r) => r.id === roomId).unread, 0);
  assert.strictEqual((await A.call('room:get', { roomId })).room.unread, 0);
  await B.call('msg:send', { roomId, text: '반가워요' });
  await A.waitFor('room:update', (d) => d.id === roomId && d.unread === 1);
  await A.call('room:read', { roomId });
  assert.strictEqual((await A.call('rooms:list')).rooms.find((r) => r.id === roomId).unread, 0);
  step('안 읽은 메시지 수: 상대 메시지만 세고, 대화방을 열거나 보고 있으면 0');
  await A.call('memo:set', { roomId, text: '고양이 키우는 카페 단골' });
  assert.strictEqual((await A.call('room:get', { roomId })).room.memo, '고양이 키우는 카페 단골');
  assert.strictEqual((await B.call('room:get', { roomId })).room.memo, '');
  step('실시간 메시지, 메모는 나만 보임');

  await B.waitFor('room:update', (d) => d.id === roomId && d.status === 'ended', 6000);
  assert.strictEqual((await B.call('msg:send', { roomId, text: '늦었나요' })).error, 'not_live');
  step('무료 시간(테스트 2초) 뒤 종료, 종료 후 메시지 거부');

  // ---------------- 연장
  let rq = await B.call('ext:request', { roomId });
  assert.ok(rq.ok && rq.room.status === 'pending');
  await A.waitFor('ext:incoming');
  assert.strictEqual((await B.waitFor('me:update')).coins, 90);
  assert.strictEqual((await A.call('ext:respond', { roomId, accept: false })).error, 'reason');
  await A.call('ext:respond', { roomId, accept: false, reasonId: 'r1' });
  let gb = await B.call('room:get', { roomId });
  assert.ok(gb.room.status === 'rejected' && gb.room.ext.reasonLocked && gb.room.ext.reasonText === null && gb.room.ext.rejectedAt > 0);
  const view = await B.call('ext:viewReason', { roomId });
  assert.strictEqual(view.reasonText, '지금은 대화를 이어가기 어려워요');
  assert.strictEqual((await B.call('me')).user.coins, 87);
  step('연장 요청 재화 10, 사유 없는 거절 차단, 사유 열람 재화 3');

  assert.strictEqual((await B.call('ext:request', { roomId })).error, 'retry_wait');
  await sleep(1100);
  rq = await B.call('ext:request', { roomId });
  assert.strictEqual(rq.room.ext.attempt, 2);
  await A.call('ext:respond', { roomId, accept: false, reasonId: 'r1' });
  assert.strictEqual((await B.call('ext:request', { roomId })).error, 'cannot_extend');
  step('재도전은 대기 후 한 번만');

  // 같은 사람이 다시 QR을 찍으면 기존 대화방
  await A.call('room:hide', { roomId, hidden: true });
  qr = await A.call('qr:new');
  const again = await B.call('join', { token: qr.token });
  assert.ok(again.ok && again.reused && again.room.id === roomId);
  const usedAgain = await A.waitFor('qr:used', (d) => d.roomId === roomId);
  assert.strictEqual(usedAgain.reused, true);
  assert.strictEqual((await A.call('room:get', { roomId })).room.hidden, false);
  assert.ok((await A.call('room:get', { roomId })).messages.find((m) => m.system && m.text.includes('다시 연결')));
  assert.strictEqual(Object.keys((await admin('GET', '/api/rooms')).rooms).length, 1);
  step('같은 사람이 다시 QR을 찍으면 새 방 대신 기존 대화방이 열리고 숨김도 풀림');

  // 연장 가능 기간이 지나 만료된 뒤에는 새 대화방
  await admin('PUT', '/api/settings', { extendWindowHours: 0.0003 });
  await B.waitFor('room:update', (d) => d.id === roomId && d.status === 'expired', 6000);
  await admin('PUT', '/api/settings', { extendWindowHours: 24 });

  qr = await A.call('qr:new');
  j = await B.call('join', { token: qr.token });
  const room3 = j.room.id;
  assert.ok(!j.reused && room3 !== roomId);
  await B.waitFor('room:update', (d) => d.id === room3 && d.status === 'ended', 6000);
  await A.call('ext:request', { roomId: room3 });
  const acc = await B.call('ext:respond', { roomId: room3, accept: true });
  assert.ok(acc.ok && acc.room.status === 'extended');
  assert.ok((await A.call('msg:send', { roomId: room3, text: '연장됐네요' })).ok);
  step('연장 수락 시 대화 재개');

  // ---------------- 신고
  const rep = await A.call('report', { roomId: room3, reason: '불쾌한 대화', detail: '반복해서 연락처를 요구함' });
  assert.ok(rep.ok);
  assert.strictEqual((await A.call('report', { roomId: room3, reason: '기타' })).error, 'already_reported');
  assert.strictEqual((await A.call('rooms:list')).rooms.find((r) => r.id === room3).hidden, true);
  const reports = await admin('GET', '/api/reports');
  assert.ok(reports.reports.find((r) => r.roomId === room3 && r.target === kimAgain.user.nickname));
  step('신고하면 관리자 신고 목록에 올라가고, 신고자 목록에서는 숨겨짐');

  // ---------------- 관리자: 대화 조회, 블랙리스트
  const rooms = await admin('GET', '/api/rooms?reported=1');
  assert.strictEqual(rooms.rooms.length, 1);
  const chat = await admin('GET', `/api/rooms/${room3}?reason=신고 확인`);
  assert.ok(chat.messages.find((m) => m.text === '연장됐네요' && m.from === lee.user.nickname));
  const logs = await admin('GET', '/api/logs');
  assert.ok(logs.logs.find((l) => l.action === 'view_chat' && l.target === room3));
  assert.strictEqual((await api('GET', '/admin/api/rooms')).http, 401);
  step('관리자 대화 내용 조회, 열람 기록 남음, 인증 없으면 401');

  const users = await admin('GET', '/api/users');
  const kimRow = users.users.find((u) => u.id === kimAgain.user.id);
  assert.ok(kimRow.nameMasked === '김*수' && kimRow.gender === 'M' && kimRow.reports === 1);
  const bl = await admin('POST', '/api/blacklist', { userId: kimRow.id, reason: '불쾌한 대화 신고 확인', grade: 'normal' });
  assert.ok(bl.id && bl.expiresAt > Date.now() + 360 * 86400e3);
  await sleep(200);
  assert.ok(!B.connected);
  assert.strictEqual((await api('GET', '/api/check', null, { Authorization: `Bearer ${kimAgain.token}`, 'X-Device-Token': kimAgain.deviceToken })).http, 401);
  const blocked = await auth(PEOPLE.kim);
  assert.strictEqual(blocked.error, 'blocked');
  assert.ok(blocked.until > Date.now());
  step('블랙리스트 등록 즉시 접속 끊김, 다른 기기로 다시 인증해도 가입·로그인 차단');

  await admin('POST', `/api/blacklist/${bl.id}/release`, { reason: '문의 확인 후 해제' });
  const back = await auth(PEOPLE.kim);
  assert.strictEqual(back.kind, 'login');
  const list = await admin('GET', '/api/blacklist');
  assert.ok(list.blacklist[0].releaseReason === '문의 확인 후 해제' && list.blacklist[0].ciHash === undefined);
  step('블랙리스트 해제 후 다시 로그인, 관리자 화면에 CI 노출 없음');

  // ---------------- 닉네임 연결
  const K = await client(back.token);
  qr = await A.call('qr:new');
  assert.strictEqual((await K.call('join', { token: qr.token })).error, 'reported_pair');
  step('신고한 적이 있는 상대와는 QR로 다시 연결되지 않음');

  const park = await auth(PEOPLE.park);
  const C = await client(park.token);
  // A의 QR을 다른 사람이 써서 소모시킨 뒤에는 닉네임 연결이 안 된다
  const tmp = await auth({ name: '정하늘', birth: '19920909', gender: 'F', phone: '01033334444' });
  const T = await client(tmp.token);
  const qrT = await A.call('qr:new');
  await T.call('join', { token: qrT.token });
  assert.strictEqual((await C.call('nick:connect', { nickname: lee.user.nickname })).error, 'nick_not_waiting');
  await A.call('qr:new');
  assert.ok((await C.call('nick:connect', { nickname: lee.user.nickname })).ok);
  const nreq = await A.waitFor('nick:request');
  const nres = await A.call('nick:respond', { reqId: nreq.reqId, accept: true });
  assert.ok(nres.ok && nres.room.via === 'nickname');
  assert.strictEqual((await C.waitFor('nick:result')).accepted, true);
  step('닉네임 연결은 상대 QR이 열려 있을 때만, 상대 수락 후 생성');

  // ---------------- 무응답 환급
  await admin('PUT', '/api/settings', { responseTimeoutHours: 0.0004 });
  qr = await A.call('qr:new');
  j = await C.call('join', { token: qr.token });
  const room5 = j.room.id;
  await C.waitFor('room:update', (d) => d.id === room5 && d.status === 'ended', 6000);
  const before = (await C.call('me')).user.coins;
  await C.call('ext:request', { roomId: room5 });
  await C.waitFor('room:update', (d) => d.id === room5 && d.status === 'expired', 7000);
  assert.strictEqual((await C.call('me')).user.coins, before - 10 + 5);
  step('무응답이면 방 만료, 재화 50% 환급');

  const join = await (await fetch(`${BASE}/j/abc`)).text();
  assert.ok(join.includes('intent://join/abc') && join.includes('com.happypi.five_min_chat'));
  step('QR 링크 페이지가 앱 열기 링크 제공');

  // ---------------- 재시작 후에도 데이터 유지
  for (const c of [A, B, C, K, T]) c.close();
  await srv.close();
  srv = await boot();
  const after = await api('GET', '/api/check', null, { Authorization: `Bearer ${back.token}`, 'X-Device-Token': back.deviceToken });
  assert.ok(after.ok);
  const chat2 = await admin('GET', `/api/rooms/${room3}`);
  assert.ok(chat2.messages.find((m) => m.text === '연장됐네요'));
  const rs = await admin('GET', '/api/settings');
  assert.strictEqual(rs.settings.freeSeconds, 2);
  step('서버를 다시 켜도 회원·대화·설정·자동로그인 유지');

  await srv.close();
  console.log(`\n  모두 통과 (${passed}개)`);
  fs.rmSync(dataFile, { force: true });
  process.exit(0);
})().catch((e) => {
  console.error('\n  실패:', e);
  fs.rmSync(dataFile, { force: true });
  process.exit(1);
});
