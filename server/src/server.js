'use strict';

/*
 * 5분 채팅 서버
 * - 가입: 기기 인증 → 간편인증(나이·성별 자동 입력) → 약관 동의 → 자동로그인
 * - 1회용 QR, 대화방, 5분 무료 타이머, 닉네임 연결
 * - 연장 요청 / 수락 / 거절(사유 필수) / 재도전 / 사유 열람(재화) / 무응답 환급
 * - 메모, 숨기기, 신고
 * - 관리자: 회원, 대화 내용 조회(열람 기록), 신고, 블랙리스트(CI), 거절 사유, 설정, 접근 기록
 */

const path = require('path');
const os = require('os');
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const { Server } = require('socket.io');
const QRCode = require('qrcode');
const nick = require('./nickname');
const { createStore } = require('./store');
const { kakao, createIdentity, IdentityError, manAge, maskName } = require('./identity');

const DEFAULT_SETTINGS = {
  freeSeconds: 300, // 무료 대화 시간
  qrSeconds: 600, // QR 유효 시간
  extendWindowHours: 24, // 종료 후 연장 요청 가능 시간
  extendMinutes: 30, // 한 번 연장 시 늘어나는 시간
  extendCost: 10, // 연장 요청 재화
  reasonViewCost: 3, // 거절 사유 열람 재화
  rerollCost: 5, // 닉네임 다시 뽑기 재화
  startCoins: 100, // 가입 시 기본 재화 (결제 연동 전 테스트용)
  noResponseRefundPct: 50, // 무응답 시 환급 비율
  responseTimeoutHours: 24, // 연장 요청 응답 대기 시간
  retryWaitSeconds: 3600, // 거절 후 재도전 대기 시간
  minAge: 19, // 가입 가능 나이 (만)
  blacklistDaysNormal: 365, // 블랙리스트 보관 기간: 일반
  blacklistDaysSevere: 1095, // 블랙리스트 보관 기간: 중대
};

const DEFAULT_REASONS = [
  { id: 'r1', text: '지금은 대화를 이어가기 어려워요', retry: true, active: true, custom: false, order: 1 },
  { id: 'r2', text: '짧은 대화로 충분했어요', retry: false, active: true, custom: false, order: 2 },
  { id: 'r3', text: '대화 방식이 저와 맞지 않았어요', retry: false, active: true, custom: false, order: 3 },
  { id: 'r4', text: '기타 (직접 입력)', retry: false, active: true, custom: true, order: 4 },
];

// QR 위에 보이는 내 이모지: 누구나 쓸 수 있는 기본 20개
const FREE_EMOJIS = ['😀', '😎', '🥰', '😍', '🤩', '😇', '🙂', '😜', '🤗', '🥳', '😺', '🐶', '🦊', '🐻', '🐼', '🐰', '🐯', '🌸', '🌈', '🔥'];
// 재화로 사는 이모지 (관리자 화면에서 추가·가격 변경·판매 중지)
const DEFAULT_SHOP = [
  { emoji: '👑', price: 30 },
  { emoji: '💎', price: 30 },
  { emoji: '🦄', price: 20 },
  { emoji: '🌟', price: 15 },
  { emoji: '🍀', price: 15 },
  { emoji: '🎧', price: 15 },
  { emoji: '🐳', price: 20 },
  { emoji: '🪐', price: 25 },
];
// 이모지 한 개(국기·피부색·합성 이모지 포함)인지 확인
const isEmoji = (v) => typeof v === 'string' && v.length <= 16 && [...v].length <= 8 && /^(?:\p{Extended_Pictographic}|\p{Emoji_Component}|\u200d|\ufe0f)+$/u.test(v) && /\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(v);

const REPORT_REASONS = ['욕설·비하', '성적인 내용', '사기·광고', '불쾌한 대화', '기타'];

const ANDROID_PACKAGE = process.env.ANDROID_PACKAGE || 'com.happypi.five_min_chat';
const APP_SCHEME = 'fivechat';

const newId = (bytes = 9) => crypto.randomBytes(bytes).toString('base64url');
const sha = (s) => crypto.createHash('sha256').update(String(s)).digest('base64url');
const now = () => Date.now();

// 비밀번호 단방향 암호화 (scrypt, 무작위 솔트). 형식: scrypt$솔트$해시
function hashPassword(pw) {
  const salt = crypto.randomBytes(16);
  return `scrypt$${salt.toString('base64url')}$${crypto.scryptSync(String(pw), salt, 32).toString('base64url')}`;
}
function verifyPassword(pw, stored) {
  const [alg, salt, hash] = String(stored).split('$');
  if (alg !== 'scrypt' || !salt || !hash) return false;
  const a = crypto.scryptSync(String(pw), Buffer.from(salt, 'base64url'), 32);
  const b = Buffer.from(hash, 'base64url');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function lanAddress() {
  const all = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const i of list || []) if (i.family === 'IPv4' && !i.internal) all.push({ name, address: i.address });
  }
  const skip = /vethernet|wsl|virtual|vmware|docker|vbox|hyper-v|loopback/i;
  const pick =
    all.find((a) => a.address.startsWith('192.168.') && !skip.test(a.name)) ||
    all.find((a) => a.address.startsWith('192.168.')) ||
    all.find((a) => a.address.startsWith('10.') && !skip.test(a.name)) ||
    all.find((a) => !skip.test(a.name)) ||
    all[0];
  return pick ? pick.address : 'localhost';
}

async function start(opts = {}) {
  const PORT = Number(opts.port ?? process.env.PORT ?? 3000);
  const ADMIN_PASSWORD = opts.adminPassword || process.env.ADMIN_PASSWORD || 'admin1234';
  const APP_SECRET = opts.appSecret || process.env.APP_SECRET || 'dev-secret-change-me';
  const PUBLIC_URL = (opts.publicUrl || process.env.PUBLIC_URL || process.env.RENDER_EXTERNAL_URL || `http://${lanAddress()}:${PORT}`).replace(/\/$/, '');
  const identityKind = opts.identityProvider || process.env.IDENTITY_PROVIDER || 'mock';
  const identity = createIdentity(identityKind, { portoneSecret: process.env.PORTONE_API_SECRET });
  // 카카오 로그인 가입. KAKAO_APP_ID(카카오 디벨로퍼스 앱 ID)가 있어야 실제 카카오 토큰을 확인한다
  const kakaoIdentity = kakao({ appId: opts.kakaoAppId || process.env.KAKAO_APP_ID, allowMock: identityKind === 'mock' });

  if (process.env.NODE_ENV === 'production' && (ADMIN_PASSWORD === 'admin1234' || APP_SECRET === 'dev-secret-change-me')) {
    throw new Error('배포 환경에서는 ADMIN_PASSWORD 와 APP_SECRET 을 꼭 바꿔야 해요');
  }

  // 저장 데이터 암호화 키. DB에는 저장하지 않는다 (지금은 테스트 키 testkey)
  const CRYPTO_KEY = opts.cryptoKey || process.env.DB_CRYPTO_KEY || 'testkey';
  if (process.env.NODE_ENV === 'production' && CRYPTO_KEY === 'testkey') {
    console.warn('주의: DB 암호화 키가 테스트 키(testkey)예요. 정식 운영 전에 DB_CRYPTO_KEY 를 긴 무작위 값으로 바꾸세요');
  }
  const store = createStore({
    databaseUrl: opts.databaseUrl ?? process.env.DATABASE_URL,
    dataFile: opts.dataFile || process.env.DATA_FILE || path.join(__dirname, '..', 'data.json'),
    cryptoKey: CRYPTO_KEY,
  });
  const db = await store.init();
  db.settings = { ...DEFAULT_SETTINGS, ...db.settings };
  delete db.settings.id;
  if (!db.reasons.length) {
    db.reasons = DEFAULT_REASONS.map((r) => ({ ...r }));
    db.reasons.forEach((r) => store.put('reasons', r));
  }
  store.putSettings(db.settings);
  if (!Object.keys(db.emojiShop).length) {
    DEFAULT_SHOP.forEach((e, i) => {
      const item = { id: newId(6), emoji: e.emoji, price: e.price, active: true, order: i + 1, createdAt: now() };
      db.emojiShop[item.id] = item;
      store.put('emojiShop', item);
    });
  }

  const S = () => db.settings;
  const ciHashOf = (ci) => crypto.createHmac('sha256', APP_SECRET).update(String(ci)).digest('base64url');

  // 빠른 조회용 색인 (메모리)
  const userByToken = new Map(); // tokenHash -> userId
  const deviceByToken = new Map(); // tokenHash -> deviceId
  const userByCi = new Map(); // ciHash -> userId
  for (const u of Object.values(db.users)) {
    if (u.tokenHash) userByToken.set(u.tokenHash, u.id);
    if (u.ciHash) userByCi.set(u.ciHash, u.id);
  }
  for (const d of Object.values(db.devices)) deviceByToken.set(d.tokenHash, d.id);

  const qrTokens = new Map(); // token -> { userId, expiresAt }
  const nickRequests = new Map(); // reqId -> { from, to, expiresAt }
  const verifications = new Map(); // verificationId -> { deviceId, expiresAt, pending }

  const saveUser = (u) => store.put('users', u);
  const saveRoom = (r) => store.put('rooms', r);

  // ---------------------------------------------------------------- 사용자

  function ensureNickname(user) {
    const week = nick.weekKey();
    if (user.nicknameWeek === week && user.nickname) return user;
    const taken = new Set(Object.values(db.users).filter((u) => u.nicknameWeek === week).map((u) => u.nickname));
    user.nickname = nick.generate(taken);
    user.nicknameWeek = week;
    saveUser(user);
    return user;
  }

  function publicUser(u) {
    ensureNickname(u);
    return { id: u.id, nickname: u.nickname, coins: u.coins, gender: u.gender, age: manAge(u.birth), birthYear: +u.birth.slice(0, 4), lang: u.lang || null, emoji: emojiOf(u) };
  }

  // ---------------------------------------------------------------- 이모지
  const emojiOf = (u) => (u && u.emoji) || '🙂';
  const shopItems = () => Object.values(db.emojiShop).sort((x, y) => (x.order || 0) - (y.order || 0) || x.createdAt - y.createdAt);
  const canUseEmoji = (u, e) => FREE_EMOJIS.includes(e) || (u.ownedEmojis || []).includes(e);
  function emojiCatalog(u) {
    const owned = u.ownedEmojis || [];
    return {
      current: emojiOf(u),
      coins: u.coins,
      free: FREE_EMOJIS,
      shop: shopItems()
        .filter((i) => i.active || owned.includes(i.emoji))
        .map((i) => ({ id: i.id, emoji: i.emoji, price: i.price, owned: owned.includes(i.emoji), onSale: !!i.active })),
      requests: Object.values(db.emojiRequests)
        .filter((r) => r.userId === u.id)
        .sort((x, y) => y.createdAt - x.createdAt)
        .slice(0, 20)
        .map((r) => ({ id: r.id, emoji: r.emoji, note: r.note, status: r.status, answer: r.answer || null, createdAt: r.createdAt })),
    };
  }
  const pushRoomsOf = (u) => Object.values(db.rooms).forEach((r) => (r.a === u.id || r.b === u.id) && pushRoom(r));

  // 대화방에서 고를 수 있는 언어 (앱의 번역 엔진 ML Kit 코드와 같다)
  const LANGS = ['ko', 'en', 'ja', 'zh', 'vi', 'th', 'id', 'es', 'fr', 'de', 'ru', 'pt'];
  const cleanLang = (v) => (LANGS.includes(String(v || '')) ? String(v) : null);
  // 보낸 번역본: { lang, text } — 받는 사람 언어로 앱이 번역해서 보낸다
  function cleanTr(tr) {
    if (!tr || typeof tr !== 'object') return null;
    const lang = cleanLang(tr.lang);
    const text = String(tr.text || '').trim().slice(0, 1000);
    return lang && text ? { lang, text } : null;
  }

  function findByNickname(name) {
    const week = nick.weekKey();
    return Object.values(db.users).find((u) => u.nicknameWeek === week && u.nickname === name);
  }

  function spend(user, amount) {
    if (user.coins < amount) return false;
    user.coins -= amount;
    saveUser(user);
    return true;
  }

  function activeBlock(ciHash) {
    if (!ciHash) return null;
    return Object.values(db.blacklist).find((b) => b.ciHash === ciHash && !b.releasedAt && b.expiresAt > now()) || null;
  }

  function issueSession(user, device) {
    // 1계정 1기기: 다른 기기에 묶여 있었다면 그 기기의 로그인을 끊는다
    if (user.deviceId && user.deviceId !== device.id && db.devices[user.deviceId]) {
      db.devices[user.deviceId].userId = null;
      store.put('devices', db.devices[user.deviceId]);
    }
    // 이 기기에 다른 계정이 묶여 있었다면 그 계정의 로그인도 끊는다
    if (device.userId && device.userId !== user.id && db.users[device.userId]) {
      const other = db.users[device.userId];
      if (other.tokenHash) userByToken.delete(other.tokenHash);
      other.tokenHash = null;
      other.deviceId = null;
      saveUser(other);
      io.in(`u:${other.id}`).disconnectSockets(true);
    }
    if (user.tokenHash) userByToken.delete(user.tokenHash);
    io.in(`u:${user.id}`).disconnectSockets(true);
    const token = newId(24);
    user.tokenHash = sha(token);
    user.deviceId = device.id;
    user.lastLoginAt = now();
    userByToken.set(user.tokenHash, user.id);
    device.userId = user.id;
    saveUser(user);
    store.put('devices', device);
    return token;
  }

  function revokeUser(user) {
    if (user.tokenHash) userByToken.delete(user.tokenHash);
    user.tokenHash = null;
    saveUser(user);
    io.in(`u:${user.id}`).disconnectSockets(true);
  }

  // ---------------------------------------------------------------- 대화방

  const partnerOf = (room, uid) => (room.a === uid ? room.b : room.a);
  const liveEnd = (room) => Math.max(room.freeEnd, room.extendedUntil || 0);

  function roomState(room, t = now()) {
    if (room.closed) return { status: 'expired' };
    const end = liveEnd(room);
    if (t < end) return { status: room.extendedUntil && t >= room.freeEnd ? 'extended' : 'live', endsAt: end };
    const windowEnd = end + S().extendWindowHours * 3600e3;
    const ext = room.ext;
    if (ext && ext.status === 'pending') return { status: 'pending', endedAt: end, windowEnd };
    if (t >= windowEnd) return { status: 'expired', endedAt: end };
    if (ext && ext.status === 'rejected') return { status: 'rejected', endedAt: end, windowEnd };
    return { status: 'ended', endedAt: end, windowEnd };
  }

  function retryAt(ext) {
    if (!ext || ext.status !== 'rejected' || !ext.retryAllowed || ext.attempt >= 2) return null;
    return ext.rejectedAt + S().retryWaitSeconds * 1000;
  }

  function summary(room, uid) {
    const st = roomState(room);
    const msgs = db.messages[room.id] || [];
    const last = [...msgs].reverse().find((m) => !m.system);
    const ext = room.ext;
    let extInfo = null;
    if (ext) {
      const mine = ext.requester === uid;
      extInfo = {
        mine,
        status: ext.status,
        attempt: ext.attempt,
        requestedAt: ext.requestedAt,
        respondBy: ext.requestedAt + S().responseTimeoutHours * 3600e3,
        rejectedAt: ext.rejectedAt || null,
        // 거절한 사람은 자기가 고른 사유를 그대로 보고, 요청자는 재화를 써야 본다
        reasonText: !mine || ext.reasonViewed ? ext.reasonText || null : null,
        reasonLocked: mine && ext.status === 'rejected' && !ext.reasonViewed,
        retryAt: mine ? retryAt(ext) : null,
      };
    }
    return {
      id: room.id,
      partnerNickname: room.a === uid ? room.nickB : room.nickA,
      partnerEmoji: emojiOf(db.users[room.a === uid ? room.b : room.a]),
      myLang: (room.lang && room.lang[uid]) || null,
      partnerLang: (room.lang && room.lang[room.a === uid ? room.b : room.a]) || null,
      via: room.via,
      createdAt: room.createdAt,
      memo: room.memos[uid] || '',
      hidden: !!room.hidden[uid],
      reported: !!(room.reportedBy && room.reportedBy[uid]),
      status: st.status,
      endsAt: st.endsAt || null,
      endedAt: st.endedAt || null,
      windowEnd: st.windowEnd || null,
      ext: extInfo,
      lastMessage: last ? { text: shownText(last, uid, room), at: last.at, mine: last.from === uid } : null,
      unread: msgs.filter((m) => !m.system && m.from !== uid && m.at > ((room.readAt && room.readAt[uid]) || 0)).length,
      serverNow: now(),
    };
  }

  const msgView = (m, uid) => ({ id: m.id, text: m.text, lang: m.lang || null, tr: m.tr || null, at: m.at, system: !!m.system, mine: m.from === uid });
  const messagesFor = (roomId, uid) => (db.messages[roomId] || []).map((m) => msgView(m, uid));

  // 목록 미리보기: 상대 메시지는 내 언어 번역본이 있으면 그걸 보여준다
  function shownText(m, uid, room) {
    const myLang = room.lang && room.lang[uid];
    if (m.from !== uid && m.tr && m.tr.lang === myLang) return m.tr.text;
    return m.text;
  }

  function pushRoom(room) {
    room._last = roomState(room).status;
    for (const uid of [room.a, room.b]) io.to(`u:${uid}`).emit('room:update', summary(room, uid));
  }

  const pushMe = (user) => io.to(`u:${user.id}`).emit('me:update', publicUser(user));

  function addMessage(room, from, text, system = false, extra = {}) {
    const m = { id: newId(6), roomId: room.id, from, system, text, at: now() };
    if (extra.lang) m.lang = extra.lang;
    if (extra.tr) m.tr = extra.tr;
    (db.messages[room.id] = db.messages[room.id] || []).push(m);
    store.addMessage(m);
    for (const uid of [room.a, room.b]) {
      io.to(`u:${uid}`).emit('msg', { roomId: room.id, message: msgView(m, uid) });
    }
    return m;
  }

  // 두 사람 사이에 아직 끝나지 않은 대화방 (만료 전이면 종료·거절 상태도 포함)
  function openRoomBetween(x, y) {
    return Object.values(db.rooms).find((r) => ((r.a === x && r.b === y) || (r.a === y && r.b === x)) && roomState(r).status !== 'expired') || null;
  }

  // 둘 중 한 명이라도 상대를 신고한 적이 있으면 다시 연결하지 않는다
  function pairReported(x, y) {
    return Object.values(db.rooms).some(
      (r) => ((r.a === x && r.b === y) || (r.a === y && r.b === x)) && r.reportedBy && Object.keys(r.reportedBy).length > 0,
    );
  }

  /** 같은 사람과 다시 연결하면 새 방 대신 기존 대화방을 연다 */
  function connectPair(ownerId, guestId, via) {
    const existing = openRoomBetween(ownerId, guestId);
    if (existing) {
      existing.hidden[ownerId] = false;
      existing.hidden[guestId] = false;
      saveRoom(existing);
      addMessage(existing, null, via === 'qr' ? 'QR로 다시 연결됐어요' : '닉네임으로 다시 연결됐어요', true);
      pushRoom(existing);
      return { room: existing, reused: true };
    }
    return { room: createRoom(ownerId, guestId, via), reused: false };
  }

  function createRoom(ownerId, guestId, via) {
    const owner = ensureNickname(db.users[ownerId]);
    const guest = ensureNickname(db.users[guestId]);
    const t = now();
    const room = {
      id: newId(8),
      a: owner.id,
      b: guest.id,
      nickA: owner.nickname,
      nickB: guest.nickname,
      via,
      createdAt: t,
      freeEnd: t + S().freeSeconds * 1000,
      extendedUntil: null,
      ext: null,
      closed: false,
      memos: {},
      hidden: {},
      reportedBy: {},
      readAt: {},
      lang: {}, // 사용자별 대화 언어. 대화방에 처음 들어갈 때 고른다
    };
    db.rooms[room.id] = room;
    db.messages[room.id] = [];
    saveRoom(room);
    pushRoom(room);
    return room;
  }

  function consumeQrOf(userId) {
    for (const [tok, q] of qrTokens) if (q.userId === userId) qrTokens.delete(tok);
  }

  function activeQrOf(userId) {
    for (const q of qrTokens.values()) if (q.userId === userId && q.expiresAt > now()) return q;
    return null;
  }

  // ---------------------------------------------------------------- HTTP

  const app = express();
  app.set('trust proxy', 1);
  app.disable('x-powered-by');
  app.use(express.json({ limit: '50kb' }));

  // 기본 보안 헤더: 다른 사이트에 끼워 넣기 금지, 파일 형식 추측 금지, 외부 스크립트 금지, HTTPS 강제
  app.use((req, res, next) => {
    res.set({
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
      'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
      'Content-Security-Policy':
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    });
    if (req.secure) res.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    if (req.path.startsWith('/admin') || req.path.startsWith('/api')) res.set('Cache-Control', 'no-store');
    next();
  });

  // 아주 단순한 요청 제한 (IP당 분당 120회)
  const hits = new Map();
  app.use('/api', (req, res, next) => {
    const key = req.ip;
    const t = now();
    const h = hits.get(key) || { n: 0, reset: t + 60e3 };
    if (t > h.reset) Object.assign(h, { n: 0, reset: t + 60e3 });
    h.n += 1;
    hits.set(key, h);
    if (h.n > 120) return res.status(429).json({ error: 'too_many', message: '요청이 너무 많아요. 잠시 뒤 다시 시도해 주세요' });
    next();
  });

  const bad = (res, status, error, message, extra = {}) => res.status(status).json({ ok: false, error, message, ...extra });

  function deviceOf(req) {
    const t = req.headers['x-device-token'];
    const id = t && deviceByToken.get(sha(t));
    return id ? db.devices[id] : null;
  }

  function sessionOf(req) {
    const t = (req.headers.authorization || '').replace(/^Bearer /, '');
    const id = t && userByToken.get(sha(t));
    return id ? db.users[id] : null;
  }

  app.get('/health', async (req, res) => {
    let dbOk = true;
    try {
      await store.ping();
    } catch (e) {
      dbOk = false;
    }
    res.status(dbOk ? 200 : 503).json({ ok: dbOk, store: store.kind, encryption: store.encryption });
  });

  // 1단계: 기기 인증. 앱을 처음 켤 때 이 기기 전용 비밀 토큰을 받아 보안 저장소에 둔다.
  app.post('/api/device/register', (req, res) => {
    const b = req.body || {};
    const token = newId(24);
    const device = {
      id: newId(8),
      tokenHash: sha(token),
      platform: String(b.platform || 'unknown').slice(0, 20),
      model: String(b.model || '').slice(0, 60),
      createdAt: now(),
      userId: null,
    };
    db.devices[device.id] = device;
    deviceByToken.set(device.tokenHash, device.id);
    store.put('devices', device);
    res.json({ ok: true, deviceId: device.id, deviceToken: token });
  });

  // 2단계: 간편인증 시작
  app.post('/api/identity/start', (req, res) => {
    const device = deviceOf(req);
    if (!device) return bad(res, 401, 'device', '기기 인증부터 다시 해 주세요');
    const id = newId(12);
    verifications.set(id, { deviceId: device.id, expiresAt: now() + 10 * 60e3, pending: null });
    res.json({ ok: true, verificationId: id, provider: identity.name, label: identity.label });
  });

  // 간편인증 결과 확인 → 기존 회원이면 바로 로그인, 처음이면 가입 확인 단계로
  app.post('/api/identity/complete', async (req, res) => {
    const device = deviceOf(req);
    if (!device) return bad(res, 401, 'device', '기기 인증부터 다시 해 주세요');
    const vid = String((req.body && req.body.verificationId) || '');
    const v = verifications.get(vid);
    if (!v || v.deviceId !== device.id || v.expiresAt < now()) return bad(res, 400, 'verification', '인증 시간이 지났어요. 다시 시도해 주세요');
    let result;
    try {
      result = req.body && req.body.kakao ? await kakaoIdentity.verify(req.body) : await identity.verify(vid, req.body);
    } catch (e) {
      if (e instanceof IdentityError) return bad(res, 400, e.code, e.message);
      throw e;
    }
    const ciHash = ciHashOf(result.ci);
    const block = activeBlock(ciHash);
    if (block) {
      verifications.delete(vid);
      return bad(res, 403, 'blocked', '이용이 제한된 계정이에요', { until: block.expiresAt, reason: block.reason });
    }
    const age = manAge(result.birth);
    if (age < S().minAge) {
      verifications.delete(vid);
      return bad(res, 403, 'underage', `만 ${S().minAge}세 이상만 가입할 수 있어요`);
    }
    const existingId = userByCi.get(ciHash);
    if (existingId) {
      verifications.delete(vid);
      const user = db.users[existingId];
      const token = issueSession(user, device);
      return res.json({ ok: true, status: 'login', token, user: publicUser(user) });
    }
    v.pending = { ciHash, birth: result.birth, gender: result.gender, nameMasked: maskName(result.name), provider: result.provider || identity.name };
    res.json({ ok: true, status: 'signup', verificationId: vid, profile: { birthYear: +result.birth.slice(0, 4), age, gender: result.gender } });
  });

  // 3단계: 가입 (나이·성별은 인증 결과로 자동 입력, 약관 동의만 받는다)
  app.post('/api/signup', (req, res) => {
    const device = deviceOf(req);
    if (!device) return bad(res, 401, 'device', '기기 인증부터 다시 해 주세요');
    const b = req.body || {};
    const v = verifications.get(String(b.verificationId || ''));
    if (!v || !v.pending || v.deviceId !== device.id || v.expiresAt < now()) return bad(res, 400, 'verification', '인증 시간이 지났어요. 다시 인증해 주세요');
    if (!b.agreeTerms || !b.agreePrivacy) return bad(res, 400, 'terms', '필수 약관에 동의해 주세요');
    verifications.delete(String(b.verificationId));
    const p = v.pending;
    if (userByCi.has(p.ciHash)) return bad(res, 409, 'exists', '이미 가입된 사람이에요. 다시 인증해 주세요');
    const user = {
      id: newId(8),
      ciHash: p.ciHash,
      birth: p.birth,
      gender: p.gender,
      nameMasked: p.nameMasked,
      provider: p.provider,
      coins: S().startCoins,
      createdAt: now(),
      agreedAt: now(),
      marketing: !!b.agreeMarketing,
    };
    db.users[user.id] = user;
    userByCi.set(user.ciHash, user.id);
    ensureNickname(user);
    const token = issueSession(user, device);
    res.json({ ok: true, status: 'signup', token, user: publicUser(user) });
  });

  // 자동로그인 확인: 세션 토큰이 이 기기에 묶여 있고 제한되지 않았는지
  app.get('/api/check', (req, res) => {
    const user = sessionOf(req);
    const device = deviceOf(req);
    if (!user || !device || user.deviceId !== device.id) return bad(res, 401, 'session', '다시 인증해 주세요');
    const block = activeBlock(user.ciHash);
    if (block) return bad(res, 403, 'blocked', '이용이 제한된 계정이에요', { until: block.expiresAt, reason: block.reason });
    user.lastSeenAt = now();
    saveUser(user);
    res.json({ ok: true, user: publicUser(user) });
  });

  // QR을 기본 카메라로 찍었을 때 열리는 페이지: 앱을 열어 준다
  app.get('/j/:token', (req, res) => {
    const token = String(req.params.token).replace(/[^A-Za-z0-9_-]/g, '');
    const server = encodeURIComponent(PUBLIC_URL);
    const deep = `${APP_SCHEME}://join/${token}?server=${server}`;
    const intent = `intent://join/${token}?server=${server}#Intent;scheme=${APP_SCHEME};package=${ANDROID_PACKAGE};end`;
    res.type('html').send(`<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>5분 채팅 열기</title>
<style>
:root{color-scheme:light dark;--bg:#f5f5f2;--fg:#17181b;--muted:#5e6068;--accent:#3553d1;--on:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#121316;--fg:#ececef;--muted:#a2a4ad;--accent:#8fa8ff;--on:#10152b}}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--fg);font-family:system-ui,sans-serif}
main{max-width:360px;padding:24px;text-align:center}
a.btn{display:block;margin-top:20px;padding:16px;border-radius:14px;background:var(--accent);color:var(--on);text-decoration:none;font-weight:700}
p{color:var(--muted);line-height:1.6}
</style></head><body><main>
<h1>대화방으로 이동</h1>
<p>앱이 열리지 않으면 아래 버튼을 눌러 주세요.<br>앱이 없다면 먼저 설치한 뒤, 앱 안의 스캔으로 다시 찍어 주세요.</p>
<a class="btn" id="open" href="${intent}">앱에서 열기</a>
</main>
<script>
if(!/Android/i.test(navigator.userAgent)){document.getElementById('open').href=${JSON.stringify(deep)};}
setTimeout(function(){location.href=document.getElementById('open').href;},300);
</script></body></html>`);
  });

  // ---------------------------------------------------------------- 관리자

  // 관리자 비밀번호: ADMIN_PASSWORD_HASH(scrypt 단방향 해시)가 있으면 그걸로만 확인한다.
  // 만드는 법: node src/hash-password.js '비밀번호'
  const ADMIN_HASH = process.env.ADMIN_PASSWORD_HASH || hashPassword(ADMIN_PASSWORD);
  const adminFails = new Map(); // ip -> { n, first, until }
  const adminOk = new Map(); // sha(인증 헤더) -> 만료 시각
  function adminAuth(req, res, next) {
    const ip = req.ip;
    const f = adminFails.get(ip);
    if (f && f.until > now()) {
      return res.status(429).send(`로그인 실패가 많아 ${Math.ceil((f.until - now()) / 60e3)}분 동안 잠겼어요`);
    }
    const [type, b64] = (req.headers.authorization || '').split(' ');
    if (type === 'Basic' && b64) {
      const [u, ...rest] = Buffer.from(b64, 'base64').toString().split(':');
      // scrypt 는 일부러 느리므로, 맞은 로그인은 10분 동안 기억해 화면 이동마다 다시 계산하지 않는다
      const key = sha(b64);
      if (adminOk.get(key) > now()) return next();
      if (u === 'admin' && verifyPassword(rest.join(':'), ADMIN_HASH)) {
        adminFails.delete(ip);
        adminOk.set(key, now() + 10 * 60e3);
        return next();
      }
      // 틀리면 세고, 15분 안에 5번 틀리면 15분 잠근다
      const g = f && f.first > now() - 15 * 60e3 ? f : { n: 0, first: now(), until: 0 };
      g.n += 1;
      if (g.n >= 5) {
        g.until = now() + 15 * 60e3;
        store.log({ at: now(), admin: '-', action: 'admin_login_failed', target: ip, detail: { locked: true } });
      }
      adminFails.set(ip, g);
    }
    res.set('WWW-Authenticate', 'Basic realm="five-min-chat admin", charset="UTF-8"').status(401).send('관리자 로그인이 필요해요');
  }

  const audit = (action, target, detail) => store.log({ at: now(), admin: 'admin', action, target: target || null, detail: detail || null });

  function adminUser(u) {
    ensureNickname(u);
    const block = activeBlock(u.ciHash);
    const device = u.deviceId && db.devices[u.deviceId];
    return {
      id: u.id,
      nickname: u.nickname,
      nameMasked: u.nameMasked,
      provider: u.provider === 'kakao' ? '카카오' : '간편인증',
      gender: u.gender,
      age: manAge(u.birth),
      birthYear: +u.birth.slice(0, 4),
      coins: u.coins,
      createdAt: u.createdAt,
      lastSeenAt: u.lastSeenAt || u.lastLoginAt || null,
      device: device ? `${device.platform} ${device.model}`.trim() : null,
      blocked: block ? { id: block.id, until: block.expiresAt, reason: block.reason } : null,
      reports: Object.values(db.reports).filter((r) => r.targetId === u.id).length,
    };
  }

  function adminRoom(r) {
    const st = roomState(r).status;
    const msgs = db.messages[r.id] || [];
    return {
      id: r.id,
      a: { id: r.a, nickname: r.nickA },
      b: { id: r.b, nickname: r.nickB },
      via: r.via,
      createdAt: r.createdAt,
      status: st,
      messageCount: msgs.filter((m) => !m.system).length,
      lastAt: msgs.length ? msgs[msgs.length - 1].at : null,
      reports: Object.values(db.reports).filter((x) => x.roomId === r.id).length,
    };
  }

  const adminRouter = express.Router();
  adminRouter.use(adminAuth);

  adminRouter.get('/', (req, res) => res.sendFile(path.join(__dirname, '..', 'public', 'admin.html')));

  adminRouter.get('/api/overview', (req, res) => {
    const day = now() - 24 * 3600e3;
    const rooms = Object.values(db.rooms);
    let todayMessages = 0;
    for (const list of Object.values(db.messages)) for (const m of list) if (!m.system && m.at > day) todayMessages++;
    res.json({
      publicUrl: PUBLIC_URL,
      store: store.kind,
      encryption: store.encryption,
      identity: identity.name,
      kakao: !!(opts.kakaoAppId || process.env.KAKAO_APP_ID),
      users: Object.keys(db.users).length,
      newUsersToday: Object.values(db.users).filter((u) => u.createdAt > day).length,
      liveRooms: rooms.filter((r) => ['live', 'extended'].includes(roomState(r).status)).length,
      roomsToday: rooms.filter((r) => r.createdAt > day).length,
      todayMessages,
      openReports: Object.values(db.reports).filter((r) => r.status === 'open').length,
      activeBlacklist: Object.values(db.blacklist).filter((b) => !b.releasedAt && b.expiresAt > now()).length,
      pendingEmojiRequests: Object.values(db.emojiRequests).filter((r) => r.status === 'pending').length,
      settings: S(),
    });
  });

  adminRouter.get('/api/users', (req, res) => {
    const q = String(req.query.q || '').trim();
    const list = Object.values(db.users)
      .map(adminUser)
      .filter((u) => !q || u.nickname.includes(q) || (u.nameMasked || '').includes(q) || u.id === q)
      .sort((x, y) => y.createdAt - x.createdAt);
    res.json({ users: list });
  });

  adminRouter.post('/api/users/:id/coins', (req, res) => {
    const u = db.users[req.params.id];
    if (!u) return res.status(404).json({ error: '없는 회원이에요' });
    const delta = Math.trunc(Number(req.body.delta));
    if (!Number.isFinite(delta)) return res.status(400).json({ error: '숫자를 입력해 주세요' });
    u.coins = Math.max(0, u.coins + delta);
    saveUser(u);
    pushMe(u);
    audit('coins', u.id, { delta, nickname: u.nickname });
    res.json(adminUser(u));
  });

  adminRouter.get('/api/rooms', (req, res) => {
    const q = String(req.query.q || '').trim();
    const reportedOnly = req.query.reported === '1';
    const list = Object.values(db.rooms)
      .map(adminRoom)
      .filter((r) => (!q || r.a.nickname.includes(q) || r.b.nickname.includes(q) || r.a.id === q || r.b.id === q) && (!reportedOnly || r.reports > 0))
      .sort((x, y) => (y.lastAt || y.createdAt) - (x.lastAt || x.createdAt))
      .slice(0, 300);
    res.json({ rooms: list });
  });

  // 대화 내용 열람: 열람할 때마다 기록을 남긴다
  adminRouter.get('/api/rooms/:id', (req, res) => {
    const r = db.rooms[req.params.id];
    if (!r) return res.status(404).json({ error: '없는 대화방이에요' });
    audit('view_chat', r.id, { a: r.nickA, b: r.nickB, reason: String(req.query.reason || '').slice(0, 100) || null });
    res.json({
      room: adminRoom(r),
      ext: r.ext,
      messages: (db.messages[r.id] || []).map((m) => ({
        id: m.id,
        at: m.at,
        system: !!m.system,
        text: m.text,
        lang: m.lang || null,
        tr: m.tr || null,
        from: m.system ? null : m.from === r.a ? r.nickA : r.nickB,
        fromId: m.from,
      })),
      reports: Object.values(db.reports).filter((x) => x.roomId === r.id),
    });
  });

  adminRouter.get('/api/reports', (req, res) => {
    const list = Object.values(db.reports)
      .map((r) => ({
        ...r,
        reporter: db.users[r.reporterId] ? db.users[r.reporterId].nickname : '-',
        target: db.users[r.targetId] ? db.users[r.targetId].nickname : '-',
        targetBlocked: db.users[r.targetId] ? !!activeBlock(db.users[r.targetId].ciHash) : false,
      }))
      .sort((x, y) => (x.status === y.status ? y.createdAt - x.createdAt : x.status === 'open' ? -1 : 1));
    res.json({ reports: list, reasons: REPORT_REASONS });
  });

  adminRouter.put('/api/reports/:id', (req, res) => {
    const r = db.reports[req.params.id];
    if (!r) return res.status(404).json({ error: '없는 신고예요' });
    if (req.body.status) r.status = req.body.status === 'done' ? 'done' : 'open';
    if (req.body.note !== undefined) r.note = String(req.body.note).slice(0, 300);
    r.handledAt = now();
    store.put('reports', r);
    audit('report', r.id, { status: r.status, note: r.note });
    res.json(r);
  });

  adminRouter.get('/api/blacklist', (req, res) => {
    const list = Object.values(db.blacklist)
      .map((b) => ({ ...b, ciHash: undefined, active: !b.releasedAt && b.expiresAt > now(), purged: !b.ciHash }))
      .sort((x, y) => (x.active === y.active ? x.expiresAt - y.expiresAt : x.active ? -1 : 1));
    res.json({ blacklist: list });
  });

  adminRouter.post('/api/blacklist', (req, res) => {
    const u = db.users[req.body.userId];
    if (!u) return res.status(404).json({ error: '없는 회원이에요' });
    const reason = String(req.body.reason || '').trim().slice(0, 200);
    if (!reason) return res.status(400).json({ error: '차단 사유를 입력해 주세요' });
    if (activeBlock(u.ciHash)) return res.status(409).json({ error: '이미 차단된 회원이에요' });
    const grade = req.body.grade === 'severe' ? 'severe' : 'normal';
    const days = Number(req.body.days) || (grade === 'severe' ? S().blacklistDaysSevere : S().blacklistDaysNormal);
    const b = {
      id: newId(6),
      ciHash: u.ciHash,
      userId: u.id,
      nickname: u.nickname,
      gender: u.gender,
      birthYear: +u.birth.slice(0, 4),
      reason,
      grade,
      createdAt: now(),
      expiresAt: now() + days * 86400e3,
      by: 'admin',
      reportId: req.body.reportId || null,
    };
    db.blacklist[b.id] = b;
    store.put('blacklist', b);
    revokeUser(u); // 바로 로그아웃
    audit('blacklist_add', u.id, { nickname: u.nickname, reason, grade, days });
    res.json({ ...b, ciHash: undefined });
  });

  adminRouter.post('/api/blacklist/:id/release', (req, res) => {
    const b = db.blacklist[req.params.id];
    if (!b) return res.status(404).json({ error: '없는 항목이에요' });
    const reason = String(req.body.reason || '').trim().slice(0, 200);
    if (!reason) return res.status(400).json({ error: '해제 사유를 입력해 주세요' });
    b.releasedAt = now();
    b.releaseReason = reason;
    store.put('blacklist', b);
    audit('blacklist_release', b.userId, { nickname: b.nickname, reason });
    res.json({ ...b, ciHash: undefined });
  });

  adminRouter.post('/api/blacklist/:id/extend', (req, res) => {
    const b = db.blacklist[req.params.id];
    if (!b || b.releasedAt || !b.ciHash) return res.status(404).json({ error: '연장할 수 없는 항목이에요' });
    const days = Math.trunc(Number(req.body.days));
    if (!(days > 0)) return res.status(400).json({ error: '연장할 일수를 입력해 주세요' });
    b.expiresAt = Math.max(b.expiresAt, now()) + days * 86400e3;
    store.put('blacklist', b);
    audit('blacklist_extend', b.userId, { nickname: b.nickname, days });
    res.json({ ...b, ciHash: undefined });
  });

  adminRouter.get('/api/settings', (req, res) => res.json({ settings: S(), reasons: [...db.reasons].sort((x, y) => x.order - y.order) }));

  adminRouter.put('/api/settings', (req, res) => {
    const changed = {};
    for (const k of Object.keys(DEFAULT_SETTINGS)) {
      if (req.body[k] === undefined) continue;
      const v = Number(req.body[k]);
      if (!Number.isFinite(v) || v < 0) return res.status(400).json({ error: `${k} 값이 올바르지 않아요` });
      if (db.settings[k] !== v) changed[k] = v;
      db.settings[k] = v;
    }
    store.putSettings(db.settings);
    if (Object.keys(changed).length) audit('settings', null, changed);
    res.json(S());
  });

  adminRouter.post('/api/reasons', (req, res) => {
    const text = String(req.body.text || '').trim().slice(0, 60);
    if (!text) return res.status(400).json({ error: '사유 문구를 입력해 주세요' });
    const order = Math.max(0, ...db.reasons.map((r) => r.order)) + 1;
    const r = { id: newId(5), text, retry: !!req.body.retry, active: true, custom: !!req.body.custom, order };
    db.reasons.push(r);
    store.put('reasons', r);
    audit('reason_add', r.id, { text });
    res.json(r);
  });

  adminRouter.put('/api/reasons/:id', (req, res) => {
    const r = db.reasons.find((x) => x.id === req.params.id);
    if (!r) return res.status(404).json({ error: '없는 사유예요' });
    if (req.body.text !== undefined) {
      const t = String(req.body.text).trim().slice(0, 60);
      if (!t) return res.status(400).json({ error: '사유 문구를 입력해 주세요' });
      r.text = t;
    }
    for (const k of ['retry', 'active', 'custom']) if (req.body[k] !== undefined) r[k] = !!req.body[k];
    if (req.body.move === 'up' || req.body.move === 'down') {
      const list = [...db.reasons].sort((x, y) => x.order - y.order);
      const i = list.indexOf(r);
      const j = req.body.move === 'up' ? i - 1 : i + 1;
      if (j >= 0 && j < list.length) {
        [list[i].order, list[j].order] = [list[j].order, list[i].order];
        store.put('reasons', list[j]);
      }
    }
    store.put('reasons', r);
    audit('reason_edit', r.id, req.body);
    res.json(r);
  });

  adminRouter.get('/api/logs', async (req, res) => res.json({ logs: await store.logs(300) }));

  // ---- 이모지: 사용자 신청 검토, 상점(재화 이모지) 관리
  adminRouter.get('/api/emoji', (req, res) => {
    const requests = Object.values(db.emojiRequests)
      .sort((x, y) => (x.status === 'pending' ? 0 : 1) - (y.status === 'pending' ? 0 : 1) || y.createdAt - x.createdAt)
      .slice(0, 300)
      .map((r) => ({ ...r, nickname: (db.users[r.userId] && db.users[r.userId].nickname) || r.nickname }));
    const owners = {};
    for (const u of Object.values(db.users)) for (const e of u.ownedEmojis || []) owners[e] = (owners[e] || 0) + 1;
    res.json({
      free: FREE_EMOJIS,
      shop: shopItems().map((i) => ({ ...i, owners: owners[i.emoji] || 0 })),
      requests,
      pending: requests.filter((r) => r.status === 'pending').length,
    });
  });

  adminRouter.post('/api/emoji/shop', (req, res) => {
    const b = req.body || {};
    const emoji = String(b.emoji || '').trim();
    const price = Math.round(Number(b.price));
    if (!isEmoji(emoji)) return bad(res, 400, 'emoji', '이모지 한 개를 넣어 주세요');
    if (!(price >= 0 && price <= 100000)) return bad(res, 400, 'price', '가격을 확인해 주세요');
    if (FREE_EMOJIS.includes(emoji) || shopItems().some((i) => i.emoji === emoji)) return bad(res, 409, 'exists', '이미 있는 이모지예요');
    const item = { id: newId(6), emoji, price, active: true, order: shopItems().length + 1, createdAt: now() };
    db.emojiShop[item.id] = item;
    store.put('emojiShop', item);
    audit('emoji_add', item.id, { emoji, price });
    res.json({ ok: true, item });
  });

  adminRouter.post('/api/emoji/shop/:id', (req, res) => {
    const item = db.emojiShop[req.params.id];
    if (!item) return bad(res, 404, 'not_found', '없는 이모지예요');
    const b = req.body || {};
    if (b.price !== undefined) {
      const price = Math.round(Number(b.price));
      if (!(price >= 0 && price <= 100000)) return bad(res, 400, 'price', '가격을 확인해 주세요');
      item.price = price;
    }
    if (b.active !== undefined) item.active = !!b.active;
    store.put('emojiShop', item);
    audit('emoji_edit', item.id, { emoji: item.emoji, price: item.price, active: item.active });
    res.json({ ok: true, item });
  });

  // 신청 처리: 승인하면 상점에 바로 올라가고(가격 지정), 신청자에게 그 이모지를 선물할 수 있다
  adminRouter.post('/api/emoji/requests/:id', (req, res) => {
    const r = db.emojiRequests[req.params.id];
    if (!r) return bad(res, 404, 'not_found', '없는 신청이에요');
    const b = req.body || {};
    const answer = String(b.answer || '').trim().slice(0, 200);
    if (b.action === 'approve') {
      const emoji = String(b.emoji || r.emoji || '').trim();
      const price = Math.round(Number(b.price));
      if (!isEmoji(emoji)) return bad(res, 400, 'emoji', '상점에 올릴 이모지를 넣어 주세요');
      if (!(price >= 0 && price <= 100000)) return bad(res, 400, 'price', '가격을 확인해 주세요');
      let item = shopItems().find((i) => i.emoji === emoji);
      if (!FREE_EMOJIS.includes(emoji)) {
        if (!item) {
          item = { id: newId(6), emoji, price, active: true, order: shopItems().length + 1, createdAt: now(), fromRequest: r.id };
          db.emojiShop[item.id] = item;
        } else {
          Object.assign(item, { price, active: true });
        }
        store.put('emojiShop', item);
      }
      const u = db.users[r.userId];
      if (b.gift && u && !FREE_EMOJIS.includes(emoji)) {
        u.ownedEmojis = u.ownedEmojis || [];
        if (!u.ownedEmojis.includes(emoji)) u.ownedEmojis.push(emoji);
        saveUser(u);
        pushMe(u);
      }
      Object.assign(r, { status: 'approved', emoji, answer: answer || (b.gift ? '신청하신 이모지를 선물로 드렸어요' : '상점에 추가했어요'), doneAt: now() });
    } else if (b.action === 'reject') {
      Object.assign(r, { status: 'rejected', answer: answer || '이번에는 추가하기 어려워요', doneAt: now() });
    } else {
      return bad(res, 400, 'action', '처리 방법을 골라 주세요');
    }
    store.put('emojiRequests', r);
    audit('emoji_request_' + r.status, r.id, { emoji: r.emoji, answer: r.answer });
    res.json({ ok: true, request: r });
  });

  app.use('/admin', adminRouter);
  app.get('/admin.html', (req, res) => res.redirect('/admin'));
  app.use(express.static(path.join(__dirname, '..', 'public'), { index: 'index.html' }));

  app.use((err, req, res, next) => {
    console.error(err);
    res.status(500).json({ ok: false, error: 'server', message: '서버 오류가 났어요' });
  });

  // ---------------------------------------------------------------- 소켓

  const server = http.createServer(app);
  const io = new Server(server, { cors: { origin: '*' } });

  io.use((socket, next) => {
    const token = socket.handshake.auth && socket.handshake.auth.token;
    const id = token && userByToken.get(sha(token));
    const user = id && db.users[id];
    if (!user) return next(new Error('unauthorized'));
    if (activeBlock(user.ciHash)) return next(new Error('blocked'));
    socket.data.uid = user.id;
    next();
  });

  const ERR = {
    not_found: '대화방을 찾을 수 없어요',
    invalid: 'QR이 이미 사용됐거나 올바르지 않아요',
    expired: 'QR이 만료됐어요. 상대에게 새 QR을 보여 달라고 해 주세요',
    self: '내 QR은 내가 찍을 수 없어요',
    not_live: '대화 시간이 끝났어요',
    bad_lang: '지원하지 않는 언어예요',
    too_fast: '메시지를 너무 빨리 보내고 있어요. 잠시 뒤 보내 주세요',
    emoji_locked: '아직 쓸 수 없는 이모지예요',
    emoji_bad: '이모지 한 개만 넣어 주세요',
    emoji_note: '원하는 이모지나 설명을 적어 주세요',
    emoji_many: '검토 중인 신청이 5개예요. 결과가 나온 뒤 다시 신청해 주세요',
    empty: '메시지를 입력해 주세요',
    coins: '재화가 부족해요',
    cannot_extend: '지금은 연장을 요청할 수 없어요',
    not_pending: '응답할 연장 요청이 없어요',
    reason: '거절 사유를 골라 주세요',
    reason_text: '거절 사유를 직접 입력해 주세요',
    nick_not_found: '그 닉네임을 쓰는 사람이 없어요',
    nick_not_waiting: '상대가 QR 화면을 열어 둔 상태에서만 연결할 수 있어요',
    request_gone: '연결 요청이 만료됐어요',
    retry_wait: '아직 다시 요청할 수 없어요',
    partner_blocked: '상대가 이용 제한 중이라 연결할 수 없어요',
    reported_pair: '신고한 적이 있는 상대와는 다시 연결할 수 없어요',
    report_reason: '신고 사유를 골라 주세요',
    already_reported: '이미 신고한 대화예요',
  };

  const fail = (ack, code) => typeof ack === 'function' && ack({ ok: false, error: code, message: ERR[code] || code });
  const ok = (ack, data = {}) => typeof ack === 'function' && ack({ ok: true, ...data });
  const memberRoom = (roomId, uid) => {
    const room = db.rooms[roomId];
    return room && (room.a === uid || room.b === uid) ? room : null;
  };

  io.on('connection', (socket) => {
    const uid = socket.data.uid;
    const me = () => db.users[uid];
    socket.join(`u:${uid}`);

    socket.on('me', (_, ack) => ok(ack, { user: publicUser(me()), settings: S(), publicUrl: PUBLIC_URL, reportReasons: REPORT_REASONS }));

    socket.on('emoji:list', (_, ack) => ok(ack, emojiCatalog(me())));

    // 내 이모지 바꾸기 (기본 이모지 또는 산 이모지)
    socket.on('emoji:set', ({ emoji } = {}, ack) => {
      const u = me();
      if (!isEmoji(emoji) || !canUseEmoji(u, emoji)) return fail(ack, 'emoji_locked');
      u.emoji = emoji;
      saveUser(u);
      pushMe(u);
      pushRoomsOf(u);
      ok(ack, emojiCatalog(u));
    });

    // 재화로 이모지 사기. 산 이모지는 바로 내 이모지로 바뀐다
    socket.on('emoji:buy', ({ id } = {}, ack) => {
      const u = me();
      const item = db.emojiShop[String(id || '')];
      if (!item || !item.active) return fail(ack, 'not_found');
      u.ownedEmojis = u.ownedEmojis || [];
      if (!u.ownedEmojis.includes(item.emoji)) {
        if (!spend(u, item.price)) return fail(ack, 'coins');
        u.ownedEmojis.push(item.emoji);
      }
      u.emoji = item.emoji;
      saveUser(u);
      pushMe(u);
      pushRoomsOf(u);
      ok(ack, emojiCatalog(u));
    });

    // 관리자에게 이모지 신청 (원하는 이모지 + 설명)
    socket.on('emoji:request', ({ emoji, note } = {}, ack) => {
      const u = me();
      const e = emoji ? String(emoji).trim() : '';
      const n = String(note || '').trim().slice(0, 200);
      if (e && !isEmoji(e)) return fail(ack, 'emoji_bad');
      if (!e && n.length < 2) return fail(ack, 'emoji_note');
      const pending = Object.values(db.emojiRequests).filter((r) => r.userId === u.id && r.status === 'pending').length;
      if (pending >= 5) return fail(ack, 'emoji_many');
      const r = { id: newId(6), userId: u.id, nickname: u.nickname, emoji: e || null, note: n, status: 'pending', createdAt: now() };
      db.emojiRequests[r.id] = r;
      store.put('emojiRequests', r);
      ok(ack, emojiCatalog(u));
    });

    socket.on('nick:reroll', (_, ack) => {
      const u = me();
      if (!spend(u, S().rerollCost)) return fail(ack, 'coins');
      u.nicknameWeek = null;
      ensureNickname(u);
      pushMe(u);
      ok(ack, { user: publicUser(u) });
    });

    socket.on('qr:new', async (_, ack) => {
      consumeQrOf(uid);
      const token = newId(9);
      const expiresAt = now() + S().qrSeconds * 1000;
      qrTokens.set(token, { userId: uid, expiresAt });
      const url = `${PUBLIC_URL}/j/${token}`;
      const svg = await QRCode.toString(url, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' });
      ok(ack, { token, url, expiresAt, serverNow: now(), svg });
    });

    socket.on('join', ({ token } = {}, ack) => {
      const q = qrTokens.get(String(token || ''));
      if (!q) return fail(ack, 'invalid');
      if (q.expiresAt <= now()) {
        qrTokens.delete(token);
        return fail(ack, 'expired');
      }
      if (q.userId === uid) return fail(ack, 'self');
      if (activeBlock(db.users[q.userId].ciHash)) return fail(ack, 'partner_blocked');
      if (pairReported(q.userId, uid)) return fail(ack, 'reported_pair');
      qrTokens.delete(token); // 1회용
      const { room, reused } = connectPair(q.userId, uid, 'qr');
      io.to(`u:${q.userId}`).emit('qr:used', { roomId: room.id, reused });
      ok(ack, { room: summary(room, uid), reused });
    });

    socket.on('nick:connect', ({ nickname } = {}, ack) => {
      const target = findByNickname(String(nickname || '').trim());
      if (!target) return fail(ack, 'nick_not_found');
      if (target.id === uid) return fail(ack, 'self');
      if (!activeQrOf(target.id)) return fail(ack, 'nick_not_waiting');
      if (pairReported(target.id, uid)) return fail(ack, 'reported_pair');
      const reqId = newId(6);
      nickRequests.set(reqId, { from: uid, to: target.id, expiresAt: now() + 60e3 });
      io.to(`u:${target.id}`).emit('nick:request', { reqId, fromNickname: ensureNickname(me()).nickname });
      ok(ack, { reqId });
    });

    socket.on('nick:respond', ({ reqId, accept } = {}, ack) => {
      const r = nickRequests.get(reqId);
      if (!r || r.to !== uid || r.expiresAt < now()) return fail(ack, 'request_gone');
      nickRequests.delete(reqId);
      if (!accept) {
        io.to(`u:${r.from}`).emit('nick:result', { accepted: false });
        return ok(ack);
      }
      consumeQrOf(uid);
      const { room, reused } = connectPair(uid, r.from, 'nickname');
      io.to(`u:${r.from}`).emit('nick:result', { accepted: true, roomId: room.id, reused });
      io.to(`u:${uid}`).emit('qr:used', { roomId: room.id, reused });
      ok(ack, { room: summary(room, uid), reused });
    });

    socket.on('rooms:list', (_, ack) => {
      const list = Object.values(db.rooms)
        .filter((r) => (r.a === uid || r.b === uid) && roomState(r).status !== 'expired')
        .map((r) => summary(r, uid));
      ok(ack, { rooms: list });
    });

    function markRead(room) {
      room.readAt = room.readAt || {};
      room.readAt[uid] = now();
      saveRoom(room);
    }

    // 대화방을 열면 읽음 처리
    socket.on('room:get', ({ roomId } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      markRead(room);
      const s = summary(room, uid);
      io.to(`u:${uid}`).emit('room:update', s);
      ok(ack, { room: s, messages: messagesFor(room.id, uid) });
    });

    // 대화방을 보고 있는 동안 새 메시지가 오면 앱이 읽음을 알린다
    socket.on('room:read', ({ roomId } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      markRead(room);
      io.to(`u:${uid}`).emit('room:update', summary(room, uid));
      ok(ack);
    });

    // 이 대화방에서 쓰는 내 언어. 다음 대화방의 기본값으로도 기억한다
    socket.on('room:lang', ({ roomId, lang } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      const l = cleanLang(lang);
      if (!l) return fail(ack, 'bad_lang');
      room.lang = room.lang || {};
      room.lang[uid] = l;
      saveRoom(room);
      const user = db.users[uid];
      if (user && user.lang !== l) {
        user.lang = l;
        saveUser(user);
        pushMe(user);
      }
      pushRoom(room);
      ok(ack, { room: summary(room, uid) });
    });

    socket.on('msg:send', ({ roomId, text, tr } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      const st = roomState(room).status;
      if (st !== 'live' && st !== 'extended') return fail(ack, 'not_live');
      const t = String(text || '').trim().slice(0, 500);
      if (!t) return fail(ack, 'empty');
      // 도배 막기: 10초에 20개까지
      const tnow = now();
      socket.data.sent = (socket.data.sent || []).filter((x) => x > tnow - 10e3);
      if (socket.data.sent.length >= 20) return fail(ack, 'too_fast');
      socket.data.sent.push(tnow);
      const m = addMessage(room, uid, t, false, { lang: (room.lang && room.lang[uid]) || null, tr: cleanTr(tr) });
      for (const u of [room.a, room.b]) io.to(`u:${u}`).emit('room:update', summary(room, u));
      ok(ack, { id: m.id });
    });

    socket.on('memo:set', ({ roomId, text } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      room.memos[uid] = String(text || '').slice(0, 100);
      saveRoom(room);
      io.to(`u:${uid}`).emit('room:update', summary(room, uid));
      ok(ack);
    });

    socket.on('room:hide', ({ roomId, hidden } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      room.hidden[uid] = !!hidden;
      saveRoom(room);
      io.to(`u:${uid}`).emit('room:update', summary(room, uid));
      ok(ack);
    });

    // 신고: 관리자 신고 목록으로 가고, 신고한 사람 목록에서는 대화가 숨겨진다
    socket.on('report', ({ roomId, reason, detail } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      if (!REPORT_REASONS.includes(reason)) return fail(ack, 'report_reason');
      room.reportedBy = room.reportedBy || {};
      if (room.reportedBy[uid]) return fail(ack, 'already_reported');
      const r = {
        id: newId(6),
        roomId: room.id,
        reporterId: uid,
        targetId: partnerOf(room, uid),
        reason,
        detail: String(detail || '').trim().slice(0, 300),
        createdAt: now(),
        status: 'open',
      };
      db.reports[r.id] = r;
      store.put('reports', r);
      room.reportedBy[uid] = r.id;
      room.hidden[uid] = true;
      saveRoom(room);
      io.to(`u:${uid}`).emit('room:update', summary(room, uid));
      ok(ack);
    });

    socket.on('reasons:list', (_, ack) => {
      ok(ack, {
        reasons: db.reasons
          .filter((r) => r.active)
          .sort((x, y) => x.order - y.order)
          .map((r) => ({ id: r.id, text: r.text, custom: !!r.custom })),
      });
    });

    socket.on('ext:request', ({ roomId } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      const st = roomState(room).status;
      const prev = room.ext;
      let attempt = 1;
      if (st === 'rejected') {
        // 재도전: 요청했던 사람만, 허용된 사유일 때, 대기 시간이 지난 뒤 한 번
        const at = prev.requester === uid ? retryAt(prev) : null;
        if (!at) return fail(ack, 'cannot_extend');
        if (now() < at) return fail(ack, 'retry_wait');
        attempt = prev.attempt + 1;
      } else if (st !== 'ended') {
        return fail(ack, 'cannot_extend');
      }
      const u = me();
      if (!spend(u, S().extendCost)) return fail(ack, 'coins');
      room.ext = { requester: uid, requestedAt: now(), attempt, status: 'pending', cost: S().extendCost };
      saveRoom(room);
      pushMe(u);
      pushRoom(room);
      io.to(`u:${partnerOf(room, uid)}`).emit('ext:incoming', { roomId: room.id, fromNickname: room.a === uid ? room.nickA : room.nickB });
      ok(ack, { room: summary(room, uid) });
    });

    socket.on('ext:respond', ({ roomId, accept, reasonId, reasonText } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      const ext = room.ext;
      if (!ext || ext.status !== 'pending' || ext.requester === uid) return fail(ack, 'not_pending');
      if (accept) {
        room.extendedUntil = now() + S().extendMinutes * 60e3;
        room.ext = null;
        saveRoom(room);
        addMessage(room, null, `대화가 ${S().extendMinutes}분 연장됐어요`, true);
        pushRoom(room);
        return ok(ack, { room: summary(room, uid) });
      }
      const reason = db.reasons.find((r) => r.id === reasonId && r.active);
      if (!reason) return fail(ack, 'reason');
      let text = reason.text;
      if (reason.custom) {
        text = String(reasonText || '').trim().slice(0, 100);
        if (!text) return fail(ack, 'reason_text');
      }
      Object.assign(ext, { status: 'rejected', rejectedAt: now(), reasonId: reason.id, reasonText: text, retryAllowed: !!reason.retry, reasonViewed: false });
      saveRoom(room);
      pushRoom(room);
      ok(ack, { room: summary(room, uid) });
    });

    socket.on('ext:viewReason', ({ roomId } = {}, ack) => {
      const room = memberRoom(roomId, uid);
      if (!room) return fail(ack, 'not_found');
      const ext = room.ext;
      if (!ext || ext.status !== 'rejected' || ext.requester !== uid) return fail(ack, 'not_found');
      if (!ext.reasonViewed) {
        const u = me();
        if (!spend(u, S().reasonViewCost)) return fail(ack, 'coins');
        ext.reasonViewed = true;
        saveRoom(room);
        pushMe(u);
      }
      const s = summary(room, uid);
      io.to(`u:${uid}`).emit('room:update', s);
      ok(ack, { room: s, reasonText: ext.reasonText });
    });
  });

  // ---------------------------------------------------------------- 주기 작업

  const tick = setInterval(() => {
    const t = now();
    for (const [tok, q] of qrTokens) if (q.expiresAt <= t) qrTokens.delete(tok);
    for (const [id, r] of nickRequests) if (r.expiresAt <= t) nickRequests.delete(id);
    for (const [id, v] of verifications) if (v.expiresAt <= t) verifications.delete(id);

    for (const room of Object.values(db.rooms)) {
      if (room.closed) continue;
      const ext = room.ext;
      // 무응답: 방은 만료되고 일부 환급
      if (ext && ext.status === 'pending' && t > ext.requestedAt + S().responseTimeoutHours * 3600e3) {
        const u = db.users[ext.requester];
        const refund = Math.floor((ext.cost * S().noResponseRefundPct) / 100);
        if (u && refund > 0) {
          u.coins += refund;
          saveUser(u);
          pushMe(u);
        }
        ext.status = 'timeout';
        room.closed = true;
        saveRoom(room);
      }
      const st = roomState(room, t).status;
      // 한 번 만료된 대화방은 설정이 바뀌어도 되살아나지 않게 닫아 둔다
      if (st === 'expired' && !room.closed) {
        room.closed = true;
        saveRoom(room);
      }
      if (st !== room._last) pushRoom(room);
    }
  }, 1000);

  // 보관 기간이 지난 블랙리스트는 CI를 지워 다시 가입할 수 있게 한다 (10분마다 확인)
  function purgeBlacklist() {
    for (const b of Object.values(db.blacklist)) {
      if (b.ciHash && (b.releasedAt || b.expiresAt <= now())) {
        b.ciHash = null;
        b.purgedAt = now();
        store.put('blacklist', b);
        store.log({ at: now(), admin: 'system', action: 'blacklist_purge', target: b.userId, detail: { nickname: b.nickname } });
      }
    }
  }
  purgeBlacklist();
  const purge = setInterval(purgeBlacklist, 10 * 60e3);

  await new Promise((resolve) => server.listen(PORT, '0.0.0.0', resolve));

  async function close() {
    clearInterval(tick);
    clearInterval(purge);
    io.close();
    await new Promise((r) => server.close(() => r()));
    await store.close();
  }

  return { server, io, store, close, publicUrl: PUBLIC_URL, port: server.address().port, adminDefault: ADMIN_PASSWORD === 'admin1234', identity: identity.name };
}

module.exports = { start, DEFAULT_SETTINGS, hashPassword, verifyPassword };
