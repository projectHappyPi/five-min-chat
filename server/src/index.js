'use strict';
// 서버 실행 진입점. 설정은 환경변수로 받는다 (README 참고).
const { start } = require('./server');

start()
  .then((s) => {
    console.log('');
    console.log('  5분 채팅 서버가 켜졌어요');
    console.log(`  저장소          : ${s.store.kind === 'postgres' ? 'PostgreSQL' : 'data.json 파일'}`);
    console.log(`  간편인증        : ${s.identity === 'mock' ? '테스트 인증' : s.identity}`);
    console.log(`  테스트 웹페이지 : ${s.publicUrl}`);
    console.log(`  관리자 페이지   : ${s.publicUrl}/admin  (아이디 admin${s.adminDefault ? ' / 비밀번호 admin1234' : ''})`);
    console.log('');
    const stop = () => s.close().then(() => process.exit(0));
    process.on('SIGTERM', stop);
    process.on('SIGINT', stop);
  })
  .catch((e) => {
    console.error('서버를 시작하지 못했어요:', e.message);
    process.exit(1);
  });
