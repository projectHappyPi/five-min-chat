'use strict';

/*
 * 간편인증(본인확인) 제공자
 *
 * - mock    : 테스트용. 앱의 테스트 인증 화면에서 이름·생년월일·성별·휴대폰 번호를 받아
 *             같은 입력이면 같은 사람(CI)으로 취급한다. 계약 없이 전체 흐름을 시험할 수 있다.
 * - portone : 포트원(PortOne) V2 본인인증. PASS·카카오 등 간편인증 결과(CI, 생년월일, 성별)를
 *             서버에서 포트원 API로 다시 조회해 확인한다. 사업자등록과 본인인증 채널 계약 후
 *             PORTONE_API_SECRET 를 넣고 IDENTITY_PROVIDER=portone 으로 바꾸면 된다.
 *             (앱 쪽 인증창 연동은 계약 시점에 추가)
 *
 * 어떤 제공자든 결과는 { ci, name, birth: 'YYYYMMDD', gender: 'M'|'F' } 로 맞춘다.
 */

const crypto = require('crypto');

class IdentityError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function validDate(yyyymmdd) {
  if (!/^\d{8}$/.test(yyyymmdd)) return false;
  const y = +yyyymmdd.slice(0, 4);
  const m = +yyyymmdd.slice(4, 6);
  const d = +yyyymmdd.slice(6, 8);
  const dt = new Date(Date.UTC(y, m - 1, d));
  return y >= 1900 && dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d;
}

const mock = {
  name: 'mock',
  label: '테스트 인증',
  async verify(_verificationId, body) {
    const f = (body && body.mock) || {};
    const name = String(f.name || '').trim();
    const birth = String(f.birth || '').replace(/\D/g, '');
    const gender = f.gender === 'F' ? 'F' : f.gender === 'M' ? 'M' : null;
    const phone = String(f.phone || '').replace(/\D/g, '');
    if (name.length < 2 || name.length > 20) throw new IdentityError('name', '이름을 확인해 주세요');
    if (!validDate(birth)) throw new IdentityError('birth', '생년월일 8자리를 확인해 주세요 (예: 19950314)');
    if (!gender) throw new IdentityError('gender', '성별을 골라 주세요');
    if (!/^01\d{8,9}$/.test(phone)) throw new IdentityError('phone', '휴대폰 번호를 확인해 주세요');
    const ci = 'MOCK-' + crypto.createHash('sha256').update(`${name}|${birth}|${phone}`).digest('base64url');
    return { ci, name, birth, gender };
  },
};

function portone(apiSecret) {
  return {
    name: 'portone',
    label: '간편인증',
    async verify(verificationId) {
      if (!apiSecret) throw new IdentityError('config', '본인인증 설정이 끝나지 않았어요');
      const res = await fetch(`https://api.portone.io/identity-verifications/${encodeURIComponent(verificationId)}`, {
        headers: { Authorization: `PortOne ${apiSecret}` },
      });
      if (!res.ok) throw new IdentityError('verify', '본인인증 결과를 확인하지 못했어요');
      const data = await res.json();
      const v = data.identityVerification || data;
      if (v.status !== 'VERIFIED' || !v.verifiedCustomer) throw new IdentityError('verify', '본인인증이 완료되지 않았어요');
      const c = v.verifiedCustomer;
      return {
        ci: c.ci,
        name: c.name,
        birth: String(c.birthDate || '').replace(/\D/g, ''),
        gender: c.gender === 'FEMALE' ? 'F' : 'M',
      };
    },
  };
}

/*
 * 카카오 로그인으로 가입
 * - 앱이 카카오 SDK로 받은 액세스 토큰을 서버가 카카오 API로 다시 확인한다
 *   (토큰이 우리 앱(KAKAO_APP_ID)에서 발급됐는지 확인 → 회원정보 조회)
 * - 출생연도·생일·성별은 카카오 동의항목(비즈 앱 + 심사)이 켜져 있어야 받을 수 있다
 * - 주의: 카카오 출생연도는 사용자가 직접 입력한 값이라 성인 인증으로는 약하다
 * - 같은 사람 판단은 CI 대신 카카오 회원번호로 한다 (KAKAO:회원번호)
 */
function kakao({ appId, allowMock } = {}) {
  async function kapi(path, token) {
    const res = await fetch(`https://kapi.kakao.com${path}`, { headers: { Authorization: `Bearer ${token}` } });
    if (!res.ok) throw new IdentityError('kakao', '카카오 로그인 정보를 확인하지 못했어요. 다시 시도해 주세요');
    return res.json();
  }

  // 생일(MMDD)이 없으면 그해 12월 31일로 계산한다 (나이를 가장 어리게 잡아 미성년자 가입을 막는다)
  function toProfile(id, birthyear, birthday, gender, nickname) {
    const y = String(birthyear || '').replace(/\D/g, '');
    const md = String(birthday || '').replace(/\D/g, '');
    if (!/^\d{4}$/.test(y)) throw new IdentityError('kakao_scope', '카카오 계정의 출생연도 제공에 동의해야 가입할 수 있어요');
    const birth = y + (/^\d{4}$/.test(md) ? md : '1231');
    if (!validDate(birth)) throw new IdentityError('kakao_scope', '카카오 계정의 생일 정보를 확인해 주세요');
    const g = gender === 'female' || gender === 'F' ? 'F' : gender === 'male' || gender === 'M' ? 'M' : null;
    if (!g) throw new IdentityError('kakao_scope', '카카오 계정의 성별 제공에 동의해야 가입할 수 있어요');
    return { ci: `KAKAO:${id}`, name: String(nickname || '카카오').slice(0, 20), birth, gender: g, provider: 'kakao' };
  }

  return {
    name: 'kakao',
    async verify(body) {
      const k = (body && body.kakao) || {};
      if (k.mock) {
        if (!allowMock) throw new IdentityError('kakao', '테스트용 카카오 가입은 테스트 서버에서만 쓸 수 있어요');
        const id = String(k.mock.kakaoId || '').replace(/\D/g, '');
        if (!/^\d{3,20}$/.test(id)) throw new IdentityError('kakao', '카카오 회원번호(숫자)를 입력해 주세요');
        return toProfile(id, k.mock.birthyear, k.mock.birthday, k.mock.gender, k.mock.nickname);
      }
      const token = String(k.accessToken || '');
      if (!token) throw new IdentityError('kakao', '카카오 로그인 정보가 없어요');
      if (!appId) throw new IdentityError('config', '서버에 카카오 로그인 설정(KAKAO_APP_ID)이 없어요');
      const info = await kapi('/v1/user/access_token_info', token);
      if (String(info.app_id) !== String(appId)) throw new IdentityError('kakao', '다른 앱에서 받은 카카오 로그인이에요');
      const me = await kapi('/v2/user/me', token);
      const a = me.kakao_account || {};
      return toProfile(me.id, a.birthyear, a.birthday, a.gender, a.profile && a.profile.nickname);
    },
  };
}

function createIdentity(kind, opts = {}) {
  if (kind === 'portone') return portone(opts.portoneSecret);
  return mock;
}

/** 만 나이 (한국 시간 기준) */
function manAge(birth, now = Date.now()) {
  const kst = new Date(now + 9 * 3600e3);
  const y = kst.getUTCFullYear();
  const md = (kst.getUTCMonth() + 1) * 100 + kst.getUTCDate();
  const by = +birth.slice(0, 4);
  const bmd = +birth.slice(4, 8);
  return y - by - (md < bmd ? 1 : 0);
}

/** 관리자 화면용 이름 가리기: 김민수 → 김*수, 이준 → 이* */
function maskName(name) {
  const chars = [...name];
  if (chars.length <= 1) return '*';
  if (chars.length === 2) return chars[0] + '*';
  return chars[0] + '*'.repeat(chars.length - 2) + chars[chars.length - 1];
}

module.exports = { kakao, createIdentity, IdentityError, manAge, maskName, validDate };
