import 'package:flutter_test/flutter_test.dart';
import 'package:five_min_chat/state.dart';

void main() {
  test('남은 시간 표시', () {
    expect(clockText(192000), '3:12');
    expect(clockText(-5), '0:00');
    expect(clockText(59001), '1:00');
  });

  test('메모 앞 7글자', () {
    expect(memoShort(''), '메모 추가');
    expect(memoShort('카페 단골'), '카페 단골');
    expect(memoShort('고양이 키우는 카페 단골'), '고양이 키우는…');
  });

  test('서버 주소 정리', () {
    expect(AppState.normalize('192.168.0.10:3000/'), 'http://192.168.0.10:3000');
    expect(AppState.normalize(' http://10.0.0.2:3000/j/abc '), 'http://10.0.0.2:3000');
  });
}
