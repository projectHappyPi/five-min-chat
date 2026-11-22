# 5분 채팅

지나가다 만난 사람과 1회용 QR 한 번으로 텍스트 대화방을 열고, 5분이 지나면 연장을 요청하는 앱입니다.

| 폴더 | 내용 |
| --- | --- |
| `server/` | Node.js 서버 (Express + Socket.io), 테스트 웹페이지, 관리자 페이지 |
| `app/` | 안드로이드 앱 (Flutter) |
| `render.yaml` | Render 무료 서버 배포 설정 |
| `config/server_url.txt` | 앱에 넣을 서버 주소 (APK 빌드 때 사용) |
| `.github/workflows/` | APK 자동 빌드·배포, 서버 자동 테스트, 서버 깨우기 |

## 무료 인프라 구성

| 역할 | 서비스 | 무료 조건 |
| --- | --- | --- |
| 서버 | Render 무료 웹 서비스 (싱가포르) | 15분 동안 요청이 없으면 잠들고, 깨울 때 30초~1분. keepalive 워크플로가 14분마다 깨움 |
| 데이터베이스 | Supabase PostgreSQL (서울 리전) | 0.5GB. 7일 동안 사용이 없으면 일시정지되는데, keepalive 가 서버를 깨울 때 DB도 함께 건드려 막는다 |
| 소스·APK 빌드·배포 | GitHub Actions, Releases | 공개 저장소 무료 |

## 처음 배포하기

1. **Supabase**: supabase.com 에서 GitHub 계정으로 가입 → New project (Region: Northeast Asia (Seoul)) → DB 비밀번호 정하기
   → 위쪽 **Connect** → **Session pooler** 연결 주소 복사 (`postgresql://postgres.xxxx:[비밀번호]@aws-...pooler.supabase.com:5432/postgres`), `[YOUR-PASSWORD]` 자리에 DB 비밀번호 넣기
   (Direct connection 주소는 IPv6 전용이라 Render 무료 서버에서 연결되지 않는다)
2. **Render**: render.com 에서 GitHub 계정으로 가입 → **New → Blueprint** → 이 저장소 선택
   - `DATABASE_URL` 입력칸에 1번에서 만든 주소를 붙여넣고 **Apply**
   - 몇 분 뒤 서비스 주소가 나온다 (예: `https://five-min-chat.onrender.com`)
   - 관리자 비밀번호: Render 의 서비스 화면 → **Environment** → `ADMIN_PASSWORD` 값
3. 서비스 주소가 `https://five-min-chat-a5re.onrender.com` 이 아니면 `config/server_url.txt` 를 그 주소로 고친다
4. GitHub 의 **Actions** 탭에서 `Android APK` 가 끝나면 **Releases → 테스트용 안드로이드 APK** 에 `app-release.apk` 가 올라온다

## 테스트 방법 (PC 웹 + 안드로이드 폰)

1. **PC 브라우저**로 서버 주소를 연다 → 테스트 간편인증 → 가입 → 내 QR 이 보인다 (상대 역할)
2. **폰**에서 Releases 페이지를 열어 APK 설치 (출처를 알 수 없는 앱 설치 허용 필요)
3. 앱 실행 → 기기 인증(자동) → 간편인증 → 나이·성별 자동 입력 확인 → 가입 → 내 QR 화면
4. 앱의 **스캔** 탭으로 PC 화면의 QR 을 찍으면 양쪽에 대화방이 열린다
5. 다음 실행부터는 자동로그인. 앱을 지웠다 다시 깔면 간편인증만 다시 하면 같은 계정으로 로그인된다

테스트 간편인증은 이름·생년월일·성별·휴대폰 번호를 직접 넣는다. 같은 정보로 인증하면 같은 사람으로 취급한다.
PC 웹에서 쓴 정보와 다른 정보로 앱에서 인증해야 두 사람이 된다.

기다리기 길면 관리자 페이지 → 설정에서 무료 대화 시간 30초, 재도전 대기 30초처럼 줄인다.

## 관리자 페이지 (`서버주소/admin`, 아이디 `admin`)

- **회원**: 닉네임, 가린 이름, 성별, 나이, 기기, 신고 수, 차단 상태. 재화 지급, 차단
- **대화 조회**: 모든 대화방의 메시지 열람. 열 때마다 접근 기록에 남는다
- **신고**: 앱에서 들어온 신고, 대화 보기, 차단, 처리 완료
- **블랙리스트**: 차단하면 즉시 로그아웃되고, 같은 사람(CI)은 다른 기기로도 가입·로그인 불가. 연장·해제(사유 필수), 기간이 지나면 CI 자동 폐기
- **설정·거절 사유**, **접근 기록**

## 가입 흐름

```
앱 첫 실행 → 기기 인증 (기기 전용 토큰을 키스토어에 저장)
          → 간편인증 (CI, 생년월일, 성별)
          → 블랙리스트·만 19세 확인
          → 처음이면 가입 확인 화면 (나이·성별 자동 입력, 약관 동의) / 이미 가입했으면 바로 로그인
          → 로그인 토큰을 키스토어에 저장 → 다음부터 자동로그인
```

- 1계정 1기기: 다른 기기에서 인증하면 예전 기기는 로그아웃된다
- 서버는 CI 를 비밀키로 해시해서 저장하고, 이름은 가려서(김*수) 저장한다

### 실제 간편인증으로 바꾸려면

사업자등록 후 포트원(PortOne) 같은 본인확인 대행사와 본인인증 채널을 계약해야 한다 (건당 비용 발생).
서버는 `IDENTITY_PROVIDER=portone`, `PORTONE_API_SECRET` 만 넣으면 포트원 결과를 확인하도록 준비돼 있고,
앱의 테스트 인증 화면 자리에 포트원 Flutter SDK 인증창을 붙이면 된다.

## 개발

```bash
# 서버 (DATABASE_URL 이 없으면 server/data.json 에 저장)
cd server && npm install && npm start
npm test                                            # 파일 저장소로 19개 흐름 검사
TEST_DATABASE_URL=postgresql://... npm test         # PostgreSQL 로 검사

# 앱 (Flutter 설치 필요)
cd app
flutter create --platforms=android --org com.happypi --project-name five_min_chat .
flutter run --dart-define=SERVER_URL=http://192.168.0.10:3000
```

PC 에서만 서버를 띄워 테스트할 때는 `server\start-server.bat` 을 실행하고, 앱은 SERVER_URL 없이 빌드하면 처음 화면에서 서버 주소를 입력할 수 있다.

## 아직 안 된 것

- 실제 간편인증(PASS·카카오), 인앱결제 (가입 시 재화 100 지급으로 대신)
- 사용자끼리 차단, 문의함, 푸시 알림
- iOS 빌드 (Mac 또는 클라우드 빌드 필요)
- 서버는 한 대 기준 (데이터를 메모리에 올려 쓰는 구조). 사용자가 많아지면 구조 변경 필요

## 왜 Vercel 이 아니라 Render 인가

이 서버는 Socket.io 로 앱과 연결을 계속 유지하고, 1초마다 대화 타이머를 확인한다.
Vercel 은 요청이 올 때만 잠깐 실행되는 서버리스 방식이라 이런 상시 연결 서버를 올릴 수 없다.
Vercel 로 가려면 실시간 채팅을 Supabase Realtime 으로, 타이머·연장 로직을 DB 함수와 예약 작업으로 옮기는 재설계가 필요하다.
