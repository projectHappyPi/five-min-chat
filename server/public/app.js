'use strict';
// 테스트 웹 클라이언트: QR을 띄우고, 앱과 실시간으로 대화한다.

const $ = (id) => document.getElementById(id);
const TOKEN_KEY = 'fmc_token';

const state = {
  me: null,
  settings: null,
  offset: 0, // 서버 시각 - 내 시각
  qr: null,
  rooms: new Map(),
  messages: new Map(),
  current: null,
  reasons: [],
  extRoomId: null,
};

const serverNow = () => Date.now() + state.offset;
const pad = (n) => String(n).padStart(2, '0');
const clock = (ms) => {
  const s = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(s / 60)}:${pad(s % 60)}`;
};
const hm = (t) => {
  const d = new Date(t);
  const h = d.getHours();
  return `${h < 12 ? '오전' : '오후'} ${h % 12 || 12}:${pad(d.getMinutes())}`;
};
const freeLabel = () => {
  const f = state.settings.freeSeconds;
  return f % 60 === 0 ? `${f / 60}분` : `${f}초`;
};
const memoShort = (m) => (!m ? '메모 추가' : m.length > 7 ? m.slice(0, 7) + '…' : m);

function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === false || v == null) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) el.append(k.nodeType ? k : String(k));
  return el;
}

let toastTimer;
function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), 2600);
}

// ---------------------------------------------------------------- 시작

// ---------------------------------------------------------------- 가입 · 로그인
// 1 기기 인증 → 2 간편인증(테스트) → 3 가입(나이·성별 자동 입력) → 자동로그인

const DEVICE_KEY = 'fmc_device';

async function postJson(url, body, headers = {}) {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body || {}) });
  const data = await r.json().catch(() => ({}));
  return { http: r.status, ...data };
}

async function ensureDevice(force = false) {
  let d = force ? null : localStorage.getItem(DEVICE_KEY);
  if (!d) {
    const r = await postJson('/api/device/register', { platform: 'web', model: navigator.platform || 'browser' });
    d = r.deviceToken;
    localStorage.setItem(DEVICE_KEY, d);
  }
  return d;
}

function showAuth(which, stepNo) {
  $('auth').hidden = false;
  for (const id of ['auth-identity', 'auth-signup', 'auth-blocked']) $(id).hidden = id !== which;
  for (let i = 1; i <= 3; i++) $(`step-${i}`).className = i === stepNo ? 'on' : '';
}

function showBlocked(data) {
  const until = data.until ? new Date(data.until).toLocaleDateString('ko-KR') : '';
  $('blocked-text').textContent = `${data.reason ? `사유: ${data.reason}. ` : ''}${until ? `${until}까지 가입과 로그인이 제한돼요.` : ''}`;
  showAuth('auth-blocked', 2);
}

let verificationId = null;

async function boot() {
  const device = await ensureDevice();
  const token = localStorage.getItem(TOKEN_KEY);
  if (token) {
    const r = await fetch('/api/check', { headers: { Authorization: `Bearer ${token}`, 'X-Device-Token': device } });
    if (r.ok) {
      $('auth').hidden = true;
      return start(token);
    }
    localStorage.removeItem(TOKEN_KEY);
    if (r.status === 403) return showBlocked(await r.json());
  }
  showAuth('auth-identity', 2);
}

$('auth-identity').addEventListener('submit', async (e) => {
  e.preventDefault();
  $('auth-error').textContent = '';
  let device = await ensureDevice();
  let st = await postJson('/api/identity/start', {}, { 'X-Device-Token': device });
  if (st.http === 401) {
    device = await ensureDevice(true); // 서버 데이터가 초기화된 경우 기기 인증부터 다시
    st = await postJson('/api/identity/start', {}, { 'X-Device-Token': device });
  }
  const g = document.querySelector('input[name=f-gender]:checked');
  const r = await postJson(
    '/api/identity/complete',
    { verificationId: st.verificationId, mock: { name: $('f-name').value, birth: $('f-birth').value, gender: g && g.value, phone: $('f-phone').value } },
    { 'X-Device-Token': device },
  );
  if (r.http === 403 && r.error === 'blocked') return showBlocked(r);
  if (!r.ok) return ($('auth-error').textContent = r.message || '인증하지 못했어요');
  if (r.status === 'login') {
    localStorage.setItem(TOKEN_KEY, r.token);
    toast('다시 오셨네요. 로그인했어요');
    return boot();
  }
  verificationId = r.verificationId;
  $('p-age').textContent = `만 ${r.profile.age}세 (${r.profile.birthYear}년생)`;
  $('p-gender').textContent = r.profile.gender === 'F' ? '여성' : '남성';
  showAuth('auth-signup', 3);
});

$('t-all').addEventListener('change', (e) => document.querySelectorAll('.t').forEach((c) => (c.checked = e.target.checked)));

$('auth-signup').addEventListener('submit', async (e) => {
  e.preventDefault();
  const r = await postJson(
    '/api/signup',
    { verificationId, agreeTerms: $('t-terms').checked, agreePrivacy: $('t-privacy').checked, agreeMarketing: $('t-marketing').checked },
    { 'X-Device-Token': await ensureDevice() },
  );
  if (!r.ok) return ($('signup-error').textContent = r.message || '가입하지 못했어요');
  localStorage.setItem(TOKEN_KEY, r.token);
  toast('가입했어요. 다음부터는 자동으로 로그인돼요');
  boot();
});

$('blocked-retry').addEventListener('click', () => showAuth('auth-identity', 2));
$('logout').addEventListener('click', () => {
  localStorage.removeItem(TOKEN_KEY);
  location.reload();
});

let socket;
function start(token) {
  if (socket) socket.disconnect();
  socket = io({ auth: { token } });
  socket.call = (ev, data) => new Promise((res) => socket.emit(ev, data || {}, res));

  socket.on('connect_error', (err) => {
    if (err.message === 'unauthorized' || err.message === 'blocked') {
      socket.disconnect();
      boot();
    } else {
      $('conn').textContent = '서버 연결 끊김';
    }
  });
  // 관리자가 차단하거나 다른 기기에서 로그인하면 서버가 연결을 끊는다
  socket.on('disconnect', (reason) => {
    $('conn').textContent = '다시 연결 중…';
    if (reason === 'io server disconnect') boot();
  });
  socket.on('connect', onConnect);
  socket.on('me:update', (u) => setMe(u));
  socket.on('qr:used', ({ roomId, reused }) => {
    toast(reused ? '이미 대화한 상대예요. 기존 대화방을 열었어요' : '상대가 QR을 찍었어요. 대화방이 열렸어요');
    newQr();
    openRoom(roomId);
  });
  socket.on('room:update', (r) => {
    state.offset = r.serverNow - Date.now();
    state.rooms.set(r.id, r);
    renderRooms();
    if (state.current === r.id) renderChat();
  });
  socket.on('msg', ({ roomId, message }) => {
    const list = state.messages.get(roomId);
    if (list && !list.find((m) => m.id === message.id)) list.push(message);
    // 보고 있는 대화방이면 바로 읽음 처리
    if (state.current === roomId && !message.mine && !document.hidden) socket.call('room:read', { roomId });
    if (state.current === roomId) renderMessages();
  });
  socket.on('ext:incoming', ({ roomId, fromNickname }) => {
    toast(`${fromNickname}님이 대화를 더 하고 싶어해요`);
    openExtDialog(roomId);
  });
  socket.on('nick:request', ({ reqId, fromNickname }) => {
    const dlg = $('dlg-nick');
    $('nick-title').textContent = `${fromNickname}님이 닉네임으로 연결을 요청했어요`;
    dlg.onclose = async () => {
      const r = await socket.call('nick:respond', { reqId, accept: dlg.returnValue === 'yes' });
      if (!r.ok) toast(r.message);
      else if (r.room) {
        newQr();
        openRoom(r.room.id);
      }
    };
    dlg.showModal();
  });
}

async function onConnect() {
  $('conn').textContent = '연결됨';
  const me = await socket.call('me');
  state.settings = me.settings;
  state.reportReasons = me.reportReasons || [];
  $('server-url').textContent = me.publicUrl;
  setMe(me.user);
  state.reasons = (await socket.call('reasons:list')).reasons;
  const list = await socket.call('rooms:list');
  state.rooms.clear();
  for (const r of list.rooms) state.rooms.set(r.id, r);
  if (list.rooms[0]) state.offset = list.rooms[0].serverNow - Date.now();
  renderRooms();
  if (state.current) openRoom(state.current);
  newQr();
}

function setMe(u) {
  state.me = u;
  $('me-info').textContent = `${u.gender === 'F' ? '여성' : '남성'} · 만 ${u.age}세`;
  $('nickname').textContent = u.nickname;
  $('coins').textContent = u.coins;
}

// ---------------------------------------------------------------- QR

async function newQr() {
  const r = await socket.call('qr:new');
  if (!r.ok) return;
  state.offset = r.serverNow - Date.now();
  state.qr = r;
  $('qr').innerHTML = r.svg; // 서버가 만든 SVG
  $('qr').title = r.url;
}

let renewedUntil = 0;
function tickQr() {
  if (!state.qr) return;
  const left = state.qr.expiresAt - serverNow();
  if (left <= 0) {
    state.qr = null;
    renewedUntil = Date.now() + 4000;
    newQr(); // 만료되면 알아서 새로 만든다
    return;
  }
  const total = state.settings.qrSeconds * 1000;
  $('qr-clock').textContent = clock(left);
  $('qr-bar').style.width = `${(left / total) * 100}%`;
  $('qr-note').textContent = Date.now() < renewedUntil ? '새 QR로 바뀌었어요' : '';
}

$('reroll').addEventListener('click', async () => {
  if (!confirm(`재화 ${state.settings.rerollCost}개로 닉네임을 다시 뽑을까요?`)) return;
  const r = await socket.call('nick:reroll');
  toast(r.ok ? `새 닉네임: ${r.user.nickname}` : r.message);
});

// ---------------------------------------------------------------- 목록

function badge(r) {
  const t = serverNow();
  if (r.status === 'live' || r.status === 'extended') {
    const left = r.endsAt - t;
    return h('span', { class: `badge ${left <= 60e3 ? 'warn' : 'live'}` }, clock(left));
  }
  const map = { pending: '응답 대기', rejected: '거절됨' };
  if (map[r.status]) return h('span', { class: 'badge' }, map[r.status]);
  const hours = Math.max(0, Math.floor((r.windowEnd - t) / 3600e3));
  return h('span', { class: 'badge' }, `연장 가능 ${hours}시간`);
}

function preview(r) {
  if (r.status === 'rejected' && r.ext) return `${hm(r.ext.rejectedAt)}에 연장${r.ext.mine ? '이 거절됐어요' : '을 거절했어요'}`;
  if (r.status === 'pending' && r.ext) return r.ext.mine ? '상대 응답을 기다리는 중' : '연장 요청이 왔어요';
  return r.lastMessage ? r.lastMessage.text : '대화방이 열렸어요';
}

function renderRooms() {
  const showHidden = $('show-hidden').checked;
  const order = { live: 0, extended: 0, pending: 1, ended: 2, rejected: 2 };
  const list = [...state.rooms.values()]
    .filter((r) => r.status !== 'expired' && r.hidden === showHidden)
    .sort((a, b) => order[a.status] - order[b.status] || (b.lastMessage?.at || b.createdAt) - (a.lastMessage?.at || a.createdAt));
  const ul = $('rooms');
  ul.replaceChildren(
    ...list.map((r) =>
      h('li', {},
        h('button', { 'aria-current': String(state.current === r.id), onclick: () => openRoom(r.id) },
          h('span', { class: 'avatar' }, r.partnerNickname[0]),
          h('span', { class: 'room-main' }, h('b', {}, r.partnerNickname), h('span', {}, preview(r))),
          h('span', { class: 'room-side' }, badge(r), r.unread > 0 ? h('span', { class: 'unread' }, r.unread > 99 ? '99+' : r.unread) : null)))));
  $('rooms-empty').hidden = list.length > 0;
}
$('show-hidden').addEventListener('change', renderRooms);

// ---------------------------------------------------------------- 대화방

async function openRoom(roomId) {
  const r = await socket.call('room:get', { roomId });
  if (!r.ok) return toast(r.message);
  state.current = roomId;
  state.rooms.set(roomId, r.room);
  state.messages.set(roomId, r.messages);
  $('chat-empty').hidden = true;
  $('chat').hidden = false;
  renderRooms();
  renderChat();
  renderMessages();
}

function renderMessages() {
  const list = state.messages.get(state.current) || [];
  const box = $('messages');
  box.replaceChildren(
    h('div', { class: 'msg system' }, `대화방이 열렸어요 · ${freeLabel()} 무료`),
    ...list.map((m) => h('div', { class: `msg ${m.system ? 'system' : m.mine ? 'mine' : 'theirs'}` }, m.text)));
  box.scrollTop = box.scrollHeight;
}

let footKey = '';
function renderChat() {
  const r = state.rooms.get(state.current);
  if (!r) return;
  $('chat-name').textContent = r.partnerNickname;
  $('chat-memo').textContent = '✎ ' + memoShort(r.memo);
  tickChat();

  // 입력 중인 글자가 지워지지 않도록 상태가 바뀔 때만 하단을 다시 그린다
  const key = JSON.stringify([r.id, r.status, r.ext]);
  if (key === footKey) return;
  footKey = key;
  const foot = $('chat-foot');
  const s = state.settings;

  if (r.status === 'live' || r.status === 'extended') {
    const input = h('input', { id: 'msg-input', placeholder: '메시지 입력', maxlength: 500, 'aria-label': '메시지' });
    const send = async () => {
      const text = input.value.trim();
      if (!text) return;
      input.value = '';
      const res = await socket.call('msg:send', { roomId: r.id, text });
      if (!res.ok) toast(res.message);
      input.focus();
    };
    input.addEventListener('keydown', (e) => e.key === 'Enter' && !e.isComposing && send());
    foot.replaceChildren(h('div', { class: 'send-row' }, input, h('button', { class: 'primary', onclick: send }, '보내기')));
    input.focus();
    return;
  }

  if (r.status === 'ended') {
    foot.replaceChildren(
      h('p', { class: 'muted small' }, '대화 시간이 끝났어요. 상대가 수락하면 연장돼요. 거절되면 재화는 돌려받을 수 없어요.'),
      h('button', { class: 'primary wide', onclick: () => requestExt(r.id) }, `연장 요청 보내기 · 재화 ${s.extendCost}개`));
    return;
  }

  if (r.status === 'pending') {
    foot.replaceChildren(
      r.ext.mine
        ? h('p', { class: 'muted' }, `상대 응답을 기다리는 중이에요. ${s.responseTimeoutHours}시간 안에 답이 없으면 재화 ${s.noResponseRefundPct}%를 돌려드려요.`)
        : h('button', { class: 'primary wide', onclick: () => openExtDialog(r.id) }, '연장 요청에 응답하기'));
    return;
  }

  if (r.status === 'rejected') {
    const e = r.ext;
    if (!e.mine) {
      foot.replaceChildren(h('p', { class: 'muted' }, `${hm(e.rejectedAt)}에 거절했어요 · ${e.reasonText}`));
      return;
    }
    const reasonBox = e.reasonLocked
      ? h('div', { class: 'locked' },
          h('span', { class: 'muted small' }, '🔒 거절 사유'),
          h('button', { onclick: () => viewReason(r.id) }, `사유 보기 · 재화 ${s.reasonViewCost}개`))
      : h('div', { class: 'locked' }, h('span', { class: 'muted small' }, '거절 사유'), h('b', {}, e.reasonText));
    const retry = e.retryAt
      ? h('button', { id: 'retry-btn', class: 'primary wide', onclick: () => requestExt(r.id) }, '')
      : h('p', { class: 'muted small' }, '이 대화는 다시 요청할 수 없어요');
    foot.replaceChildren(h('b', {}, `${r.partnerNickname}님이 ${hm(e.rejectedAt)}에 연장을 거절했어요`), reasonBox, retry);
    tickChat();
  }
}

function tickChat() {
  const r = state.rooms.get(state.current);
  if (!r) return;
  const t = serverNow();
  const el = $('chat-clock');
  if (r.status === 'live' || r.status === 'extended') {
    const left = r.endsAt - t;
    el.textContent = `${clock(left)} 남음`;
    el.style.color = left <= 60e3 ? 'var(--warn)' : 'var(--accent)';
  } else {
    el.textContent = { pending: '응답 대기', rejected: '거절됨', ended: '종료됨' }[r.status] || '';
    el.style.color = 'var(--muted)';
  }
  const btn = $('retry-btn');
  if (btn && r.ext && r.ext.retryAt) {
    const wait = r.ext.retryAt - t;
    btn.disabled = wait > 0;
    btn.textContent = wait > 0 ? `다시 요청하기 · ${clock(wait)} 남음` : `다시 요청하기 · 재화 ${state.settings.extendCost}개`;
  }
}

async function requestExt(roomId) {
  const r = await socket.call('ext:request', { roomId });
  toast(r.ok ? '연장 요청을 보냈어요' : r.message);
}

async function viewReason(roomId) {
  const r = await socket.call('ext:viewReason', { roomId });
  if (!r.ok) toast(r.message);
}

// ---------------------------------------------------------------- 연장 응답

function openExtDialog(roomId) {
  const r = state.rooms.get(roomId);
  state.extRoomId = roomId;
  $('ext-title').textContent = `${r ? r.partnerNickname : '상대'}님이 대화를 더 하고 싶어해요`;
  $('ext-sub').textContent = r && r.ext ? `${hm(r.ext.respondBy)}까지 답하지 않으면 요청이 만료돼요` : '';
  $('ext-error').textContent = '';
  $('ext-custom').hidden = true;
  $('ext-custom').value = '';
  $('ext-reasons').replaceChildren(
    ...state.reasons.map((x) => {
      const radio = h('input', { type: 'radio', name: 'reason', value: x.id });
      radio.addEventListener('change', () => ($('ext-custom').hidden = !x.custom));
      return h('label', {}, radio, x.text);
    }));
  $('dlg-ext').showModal();
}

$('ext-accept').addEventListener('click', async () => {
  const r = await socket.call('ext:respond', { roomId: state.extRoomId, accept: true });
  if (!r.ok) return ($('ext-error').textContent = r.message);
  $('dlg-ext').close();
  openRoom(state.extRoomId);
});

$('ext-reject').addEventListener('click', async () => {
  const picked = document.querySelector('input[name=reason]:checked');
  if (!picked) return ($('ext-error').textContent = '거절 사유를 골라 주세요');
  const r = await socket.call('ext:respond', { roomId: state.extRoomId, accept: false, reasonId: picked.value, reasonText: $('ext-custom').value });
  if (!r.ok) return ($('ext-error').textContent = r.message);
  $('dlg-ext').close();
  toast('거절했어요');
});

// ---------------------------------------------------------------- 상세 · 메모

function openDetail() {
  const r = state.rooms.get(state.current);
  if (!r) return;
  $('detail-name').textContent = r.partnerNickname;
  const created = new Date(r.createdAt);
  $('detail-meta').textContent = `${created.getMonth() + 1}월 ${created.getDate()}일 ${hm(r.createdAt)} · ${r.via === 'qr' ? 'QR' : '닉네임'}로 연결 · 만났을 때 닉네임`;
  $('detail-memo').value = r.memo;
  $('memo-count').textContent = r.memo.length;
  $('detail-hide').textContent = r.hidden ? '숨김 해제' : '대화 숨기기';
  $('dlg-detail').showModal();
}
$('chat-name').addEventListener('click', openDetail);
$('chat-memo').addEventListener('click', openDetail);
$('detail-memo').addEventListener('input', (e) => ($('memo-count').textContent = e.target.value.length));
$('detail-save').addEventListener('click', async () => {
  const r = await socket.call('memo:set', { roomId: state.current, text: $('detail-memo').value });
  if (!r.ok) return toast(r.message);
  $('dlg-detail').close();
  toast('메모를 저장했어요');
});
$('detail-hide').addEventListener('click', async () => {
  const r = state.rooms.get(state.current);
  await socket.call('room:hide', { roomId: r.id, hidden: !r.hidden });
  $('dlg-detail').close();
  toast(r.hidden ? '숨김을 해제했어요' : '대화를 숨겼어요');
});

// ---------------------------------------------------------------- 1초마다

setInterval(() => {
  tickQr();
  tickChat();
  if (state.rooms.size) renderRooms();
}, 1000);

boot();

// ---------------------------------------------------------------- 신고

$('detail-report').addEventListener('click', () => {
  $('dlg-detail').close();
  $('report-error').textContent = '';
  $('report-detail').value = '';
  $('report-reasons').replaceChildren(
    ...state.reportReasons.map((t) => h('label', {}, h('input', { type: 'radio', name: 'report-reason', value: t }), t)));
  $('dlg-report').showModal();
});

$('report-send').addEventListener('click', async () => {
  const picked = document.querySelector('input[name=report-reason]:checked');
  if (!picked) return ($('report-error').textContent = '신고 사유를 골라 주세요');
  const r = await socket.call('report', { roomId: state.current, reason: picked.value, detail: $('report-detail').value });
  if (!r.ok) return ($('report-error').textContent = r.message);
  $('dlg-report').close();
  toast('신고했어요. 관리자가 확인할게요');
});
