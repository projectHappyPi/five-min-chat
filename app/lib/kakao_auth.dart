import 'package:flutter/services.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';

/// 카카오 디벨로퍼스 > 앱 > 플랫폼 키의 "네이티브 앱 키". 빌드할 때 config/kakao_native_app_key.txt 에서 넣는다.
/// 비어 있으면 카카오 가입은 테스트 모드(카카오 계정 정보를 직접 입력)로 동작한다.
const kKakaoNativeKey = String.fromEnvironment('KAKAO_NATIVE_APP_KEY');
bool get kakaoReady => kKakaoNativeKey.isNotEmpty;

Future<void> initKakao() async {
  if (kakaoReady) await KakaoSdk.init(nativeAppKey: kKakaoNativeKey);
}

/// 카카오톡이 있으면 카카오톡으로, 없거나 실패하면 카카오 계정(웹)으로 로그인한다.
/// 사용자가 취소하면 null.
Future<String?> kakaoLogin() async {
  try {
    OAuthToken token;
    if (await isKakaoTalkInstalled()) {
      try {
        token = await UserApi.instance.loginWithKakaoTalk();
      } on PlatformException catch (e) {
        if (e.code == 'CANCELED') return null;
        token = await UserApi.instance.loginWithKakaoAccount();
      }
    } else {
      token = await UserApi.instance.loginWithKakaoAccount();
    }
    return token.accessToken;
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED') return null;
    rethrow;
  }
}

/// 처음 로그인 때 성별·출생연도·생일 제공에 동의하지 않았으면 그 항목만 다시 동의받는다
Future<String?> kakaoAskBirthGender() async {
  try {
    final token = await UserApi.instance.loginWithNewScopes(['gender', 'birthyear', 'birthday']);
    return token.accessToken;
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED') return null;
    rethrow;
  }
}
