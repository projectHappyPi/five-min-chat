'use strict';
// 관리자 비밀번호를 단방향 해시로 바꿔 출력한다. Render 환경변수 ADMIN_PASSWORD_HASH 에 넣으면
// 서버는 평문 비밀번호 없이 해시로만 확인한다.  사용: node src/hash-password.js '비밀번호'
const { hashPassword } = require('./server');
const pw = process.argv[2];
if (!pw || pw.length < 10) {
  console.error('10자 이상 비밀번호를 넣어 주세요: node src/hash-password.js \'비밀번호\'');
  process.exit(1);
}
console.log(hashPassword(pw));
