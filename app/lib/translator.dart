import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 폰 안에서 돌리는 통역 모델 후보.
/// 파일 목록은 앱이 Hugging Face 에서 직접 받아온다 (모델 저장소에 올라온 파일이 바뀌어도 앱을 고칠 필요가 없게).
class ModelRepo {
  const ModelRepo(this.repoId, this.title, this.note, {this.recommended = false, this.mayFail = false});
  final String repoId;
  final String title;
  final String note;
  final bool recommended;
  final bool mayFail; // 텐센트 전용 실행 코드(STQ)가 필요해 일반 llama.cpp 에서 안 열릴 수 있음
}

const kModelRepos = <ModelRepo>[
  ModelRepo('tencent/Hy-MT2-1.8B-GGUF', 'Hy-MT2 1.8B', '텐센트 번역 전용 모델. 33개 언어, 상업 이용 가능(Apache 2.0)', recommended: true),
  ModelRepo('tencent/Hy-MT2-1.8B-2bit-GGUF', 'Hy-MT2 1.8B (2비트)', '더 작지만 전용 실행 코드가 필요해 열리지 않을 수 있어요', mayFail: true),
  ModelRepo('tencent/Hy-MT2-1.8B-1.25bit-GGUF', 'Hy-MT2 1.8B (1.25비트, 약 440MB)', '가장 작지만 전용 실행 코드가 필요해 열리지 않을 수 있어요', mayFail: true),
  ModelRepo('tencent/HY-MT1.5-1.8B-GGUF', 'HY-MT1.5 1.8B', '이전 버전. 비교용'),
  ModelRepo('unsloth/Qwen3.5-0.8B-GGUF', 'Qwen3.5 0.8B', '번역 전용이 아닌 가벼운 일반 모델. 크기·속도 비교용'),
];

class ModelFile {
  ModelFile(this.repo, this.path, this.bytes);
  final ModelRepo repo;
  final String path;
  final int bytes;
  String get sizeLabel => bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(2)}GB' : '${(bytes / 1e6).round()}MB';
  String get key => '${repo.repoId}/$path';
}

/// 번역 결과와 걸린 시간
class TranslateResult {
  TranslateResult(this.text, this.millis);
  final String text;
  final int millis;
}

/// 통역 모델 다운로드·로딩·번역을 맡는다. 앱 전체에서 하나만 쓴다.
class Translator extends ChangeNotifier {
  Translator._();
  static final Translator instance = Translator._();

  LlamaEngine? _engine;
  String? loadedKey; // 지금 메모리에 올라간 모델
  String? busyKey; // 내려받거나 여는 중인 모델
  double? progress; // 0~1, 모르면 null
  int receivedBytes = 0;
  String? error;
  ModelDownloadCancelToken? _cancel;
  bool _translating = false;
  Future<void> _queue = Future.value();

  bool get ready => _engine != null;

  /// 저장소의 .gguf 파일 목록 (용량 포함)
  static Future<List<ModelFile>> listFiles(ModelRepo repo) async {
    final res = await http.get(Uri.parse('https://huggingface.co/api/models/${repo.repoId}/tree/main')).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('모델 목록을 가져오지 못했어요 (${res.statusCode})');
    final list = jsonDecode(res.body) as List;
    final files = <ModelFile>[];
    for (final e in list) {
      final m = Map<String, dynamic>.from(e as Map);
      final path = m['path'] as String? ?? '';
      if (!path.toLowerCase().endsWith('.gguf')) continue;
      // LFS 파일은 lfs.size 에 실제 용량이 있다
      final lfs = m['lfs'] is Map ? Map<String, dynamic>.from(m['lfs'] as Map) : null;
      final size = ((lfs?['size'] ?? m['size']) as num?)?.toInt() ?? 0;
      files.add(ModelFile(repo, path, size));
    }
    files.sort((a, b) => a.bytes.compareTo(b.bytes));
    return files;
  }

  /// 처음이면 내려받고(와이파이 권장), 이미 받았으면 캐시에서 바로 연다.
  Future<void> load(ModelFile file) async {
    if (busyKey != null) return;
    busyKey = file.key;
    progress = null;
    receivedBytes = 0;
    error = null;
    notifyListeners();
    final token = _cancel = ModelDownloadCancelToken();
    try {
      await _engine?.dispose();
      _engine = null;
      loadedKey = null;
      final engine = await LlamaEngine.load(
        LlamaModel(ModelSource.huggingFace(repoId: file.repo.repoId, filePath: file.path)),
        // 문장 단위 번역이라 문맥은 짧게 잡아 메모리를 아낀다
        params: const ModelParams(contextSize: 2048),
        download: ModelLoadOptions(cancelToken: token, resume: true, maxRetries: 3),
        onProgress: (p) {
          receivedBytes = p.receivedBytes;
          progress = p.fraction;
          notifyListeners();
        },
      );
      _engine = engine;
      loadedKey = file.key;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('translator.model', jsonEncode({'repo': file.repo.repoId, 'path': file.path, 'bytes': file.bytes}));
    } catch (e) {
      error = token.isCancelled ? '다운로드를 취소했어요' : '모델을 열지 못했어요: $e';
    } finally {
      busyKey = null;
      _cancel = null;
      notifyListeners();
    }
  }

  void cancel() => _cancel?.cancel();

  /// 예전에 받아 둔 모델이 있으면 그 정보 (다시 열 때 다운로드 없이 캐시 사용)
  static Future<ModelFile?> lastUsed() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('translator.model');
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final repo = kModelRepos.firstWhere((r) => r.repoId == m['repo'], orElse: () => ModelRepo(m['repo'] as String, m['repo'] as String, ''));
    return ModelFile(repo, m['path'] as String, (m['bytes'] as num?)?.toInt() ?? 0);
  }

  /// 원문에 한글이 있으면 영어로, 없으면 한국어로 번역
  static String autoTarget(String text) => RegExp(r'[가-힣]').hasMatch(text) ? 'English' : 'Korean';

  Future<TranslateResult> translate(String text, {String? target}) {
    // 모델은 한 번에 하나의 요청만 처리하므로 순서대로 처리한다
    final c = Completer<TranslateResult>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await _translateNow(text, target ?? autoTarget(text)));
      } catch (e) {
        c.completeError(e);
      }
    });
    return c.future;
  }

  Future<TranslateResult> _translateNow(String text, String target) async {
    final engine = _engine;
    if (engine == null) throw Exception('통역 모델을 먼저 내려받아 주세요');
    _translating = true;
    final sw = Stopwatch()..start();
    try {
      // Hy-MT2 기본 번역 지시문 (시스템 프롬프트 없음)
      final prompt = 'Translate the following text into $target. '
          'Note that you should only output the translated result without any additional explanation:\n\n$text';
      final out = await engine
          .create(
            [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt)],
            params: const GenerationParams(maxTokens: 512, temp: 0.7, topK: 20, topP: 0.6, penalty: 1.05),
          )
          .text();
      // 일반 모델이 생각 과정을 붙이는 경우 지운다
      final cleaned = out.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
      return TranslateResult(cleaned, sw.elapsedMilliseconds);
    } finally {
      _translating = false;
    }
  }

  bool get translating => _translating;

  Future<void> unload() async {
    await _engine?.dispose();
    _engine = null;
    loadedKey = null;
    notifyListeners();
  }
}
