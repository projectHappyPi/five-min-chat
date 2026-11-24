import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// 대화방에서 고를 수 있는 언어. 코드는 서버(LANGS)와 ML Kit 언어 코드와 같다.
class Lang {
  const Lang(this.code, this.name, this.koName);
  final String code;
  final String name; // 그 언어로 쓴 이름
  final String koName; // 한국어 이름
  String get label => name == koName ? name : '$name · $koName';
}

const kLangs = <Lang>[
  Lang('ko', '한국어', '한국어'),
  Lang('en', 'English', '영어'),
  Lang('ja', '日本語', '일본어'),
  Lang('zh', '中文', '중국어'),
  Lang('vi', 'Tiếng Việt', '베트남어'),
  Lang('th', 'ไทย', '태국어'),
  Lang('id', 'Bahasa Indonesia', '인도네시아어'),
  Lang('es', 'Español', '스페인어'),
  Lang('fr', 'Français', '프랑스어'),
  Lang('de', 'Deutsch', '독일어'),
  Lang('ru', 'Русский', '러시아어'),
  Lang('pt', 'Português', '포르투갈어'),
];

Lang? langOf(String? code) {
  for (final l in kLangs) {
    if (l.code == code) return l;
  }
  return null;
}

/// 폰 기본 언어가 목록에 있으면 그걸, 아니면 한국어
String deviceLangCode() {
  final code = PlatformDispatcher.instance.locale.languageCode;
  return langOf(code)?.code ?? 'ko';
}

/// Google ML Kit 기기 내 번역.
/// 언어 팩(언어당 약 30MB)을 처음 한 번 받고 나면 인터넷 없이 폰 안에서 번역한다.
class Translator extends ChangeNotifier {
  Translator._();
  static final Translator instance = Translator._();

  final _manager = OnDeviceTranslatorModelManager();
  final Map<String, bool> _downloaded = {};
  final Set<String> downloading = {};
  final Map<String, OnDeviceTranslator> _engines = {};

  bool? isDownloadedCached(String code) => code == 'en' ? true : _downloaded[code];

  Future<bool> isDownloaded(String code) async {
    if (code == 'en') return true; // 영어는 ML Kit에 기본으로 들어 있다
    final cached = _downloaded[code];
    if (cached != null) return cached;
    final v = await _manager.isModelDownloaded(code);
    _downloaded[code] = v;
    notifyListeners();
    return v;
  }

  Future<void> refreshAll() async {
    for (final l in kLangs) {
      _downloaded.remove(l.code);
    }
    for (final l in kLangs) {
      await isDownloaded(l.code);
    }
  }

  /// 언어 팩 받기. wifiOnly 가 true 면 와이파이에서만 받는다
  Future<bool> download(String code, {bool wifiOnly = false}) async {
    if (code == 'en') return true;
    if (downloading.contains(code)) return false;
    downloading.add(code);
    notifyListeners();
    try {
      final ok = await _manager.downloadModel(code, isWifiRequired: wifiOnly);
      _downloaded[code] = ok || await _manager.isModelDownloaded(code);
      return _downloaded[code]!;
    } finally {
      downloading.remove(code);
      notifyListeners();
    }
  }

  Future<void> delete(String code) async {
    if (code == 'en') return;
    await _closeEnginesUsing(code);
    await _manager.deleteModel(code);
    _downloaded[code] = false;
    notifyListeners();
  }

  /// 두 언어 팩이 다 있는지 (없으면 번역 전에 받아야 한다)
  Future<List<String>> missing(String from, String to) async {
    final out = <String>[];
    for (final c in {from, to}) {
      if (!await isDownloaded(c)) out.add(c);
    }
    return out;
  }

  Future<String> translate(String text, {required String from, required String to}) async {
    if (from == to || text.trim().isEmpty) return text;
    final key = '$from>$to';
    final engine = _engines[key] ??= OnDeviceTranslator(
      sourceLanguage: TranslateLanguage.fromRawValue(from)!,
      targetLanguage: TranslateLanguage.fromRawValue(to)!,
    );
    final out = await engine.translateText(text);
    return out.trim();
  }

  Future<void> _closeEnginesUsing(String code) async {
    final keys = _engines.keys.where((k) => k.split('>').contains(code)).toList();
    for (final k in keys) {
      await _engines.remove(k)?.close();
    }
  }
}
