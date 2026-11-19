'use strict';

// 형용사 + 명사 조합 (한글 4~5자, 말로 불러주기 쉬운 단어만)
const ADJ = ['푸른', '졸린', '느린', '맑은', '작은', '조용한', '빠른', '붉은', '흐린', '밝은', '따뜻한', '시원한', '하얀', '노란', '깊은', '포근한', '수줍은', '용감한', '반짝', '새벽'];
const NOUN = ['고래', '여우', '바람', '구름', '별', '사과', '숲', '달', '파도', '바위', '곰', '토끼', '고양이', '나무', '호수', '노을', '참새', '강', '섬', '등대'];

// 월요일 기준 주차 키 (예: 2026-W41). 매주 월요일 0시에 닉네임이 바뀐다
function weekKey(d = new Date()) {
  const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((t - yearStart) / 86400000 + 1) / 7);
  return `${t.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function generate(taken) {
  for (let i = 0; i < 200; i++) {
    const n = pick(ADJ) + pick(NOUN);
    if (!taken.has(n)) return n;
  }
  // 조합이 부족하면 숫자 한 자리를 붙인다
  for (let i = 0; i < 1000; i++) {
    const n = pick(ADJ) + pick(NOUN) + Math.floor(Math.random() * 10);
    if (!taken.has(n)) return n;
  }
  return pick(ADJ) + pick(NOUN) + Date.now() % 1000;
}

module.exports = { weekKey, generate };
