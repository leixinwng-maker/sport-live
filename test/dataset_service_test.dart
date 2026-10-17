import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_planner/services/dataset_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P6-D 数据集服务单测（全 mock：不触真实外网）
///
/// 覆盖三段：
/// - 数据集目录 API（HuggingFace 元数据）：解析、参数、错误分支（中文报错）
/// - 精选子集清单契约：许可已核实、registryId 对应登记表「已接入」条目
/// - 精选子集下载与记录：写盘、进度、重下覆盖、失败清理、删除与路径防护
///
/// 网络层用自定义 HttpClientAdapter 生成响应，绝不发起真实请求；
/// 下载进度由「流式二进制响应 + content-length 头」触发 dio 的 onReceiveProgress。

/// 自定义 mock 适配器：按 handler 生成响应，记录调用次数与最近一次请求
class _MockAdapter implements HttpClientAdapter {
  _MockAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  int callCount = 0;
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    lastOptions = options;
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// JSON 响应（贴真实 API 的 content-type）
ResponseBody _json(Object? json, {int code = 200}) =>
    ResponseBody.fromString(
      jsonEncode(json),
      code,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// 流式二进制响应：分块投递触发 dio 的 onReceiveProgress；
/// total 取自 content-length 头（dio 源码 ResponseBody.contentLength 语义）
ResponseBody _binaryChunks(List<List<int>> chunks) {
  final total = chunks.fold<int>(0, (sum, c) => sum + c.length);
  return ResponseBody(
    Stream.fromIterable(chunks.map(Uint8List.fromList)),
    200,
    headers: {
      Headers.contentLengthHeader: ['$total'],
      Headers.contentTypeHeader: ['application/octet-stream'],
    },
  );
}

/// 单测用精选子集定义（与真实清单同构，路径指向假域名，绝不触网）
const CuratedDataset _testSubset = CuratedDataset(
  id: 'test-subset',
  registryId: 'exmo',
  name: '测试子集',
  description: '单测用子集定义',
  url: 'https://example.com/data.bin',
  fileName: 'data.bin',
  license: 'CC0 1.0',
  sourceName: 'Test Source',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    // SharedPreferences 官方 mock：下载记录仅存内存，不落真实用户数据
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('wenDaoDatasetTest');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  DatasetService makeService(_MockAdapter adapter) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 1),
      receiveTimeout: const Duration(seconds: 1),
    ));
    dio.httpClientAdapter = adapter;
    return DatasetService(dio: dio, rootResolver: () async => root);
  }

  group('数据集目录 API（HuggingFace 元数据）', () {
    test('parseHuggingFaceSearch：解析字段并剔除非法条目', () {
      const body = '''
[
  {"id": "a/ds-one", "likes": 12, "downloads": 345,
   "lastModified": "2024-05-01T00:00:00Z", "tags": ["t1", "  "]},
  "junk",
  {},
  {"id": "   "},
  {"id": "ds-two", "downloads": "9"}
]
''';
      final out = DatasetService.parseHuggingFaceSearch(body);
      expect(out, hasLength(2));
      expect(out[0].id, 'a/ds-one');
      expect(out[0].likes, 12);
      expect(out[0].downloads, 345);
      expect(out[0].lastModified, contains('2024-05-01'));
      expect(out[0].tags, ['t1']); // 空白 tag 被剔除
      expect(out[1].id, 'ds-two');
      expect(out[1].downloads, 9); // 字符串数字安全转换
    });

    test('parseHuggingFaceSearch：limit 截断生效', () {
      const body = '[{"id": "a"}, {"id": "b"}, {"id": "c"}, {"id": "d"}]';
      expect(
        DatasetService.parseHuggingFaceSearch(body, limit: 2),
        hasLength(2),
      );
    });

    test('空关键词直接返回空，不发起任何请求', () async {
      final adapter = _MockAdapter((_) => _json(<Object>[]));
      final service = makeService(adapter);

      final hits = await service.searchHuggingFaceDatasets('   ');
      expect(hits, isEmpty);
      expect(adapter.callCount, 0);
    });

    test('检索命中 HuggingFace API 且请求参数正确', () async {
      final adapter = _MockAdapter(
        (_) => _json(<Object>[
          <String, Object>{'id': 'a/b', 'downloads': 5},
        ]),
      );
      final service = makeService(adapter);

      final hits = await service.searchHuggingFaceDatasets('fitness', limit: 3);
      expect(hits, hasLength(1));
      expect(hits.first.id, 'a/b');
      expect(adapter.callCount, 1);

      final opt = adapter.lastOptions!;
      expect(opt.uri.host, 'huggingface.co');
      expect(opt.uri.path, '/api/datasets');
      expect(opt.queryParameters['search'], 'fitness');
      expect(opt.queryParameters['limit'], 3);
      expect(opt.queryParameters['sort'], 'downloads');
      expect(opt.queryParameters['direction'], -1); // 按下载量降序
    });

    test('HTTP 500：报「服务返回异常」并带状态码', () async {
      final adapter = _MockAdapter((_) => _json({'error': 'oops'}, code: 500));
      final service = makeService(adapter);

      await expectLater(
        service.searchHuggingFaceDatasets('x'),
        throwsA(isA<DatasetException>()
            .having((e) => e.message, 'message', contains('HTTP 500'))
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('连接超时：报「请求超时」中文提示', () async {
      final adapter = _MockAdapter(
        (options) => throw DioException.connectionTimeout(
          requestOptions: options,
          timeout: const Duration(seconds: 1),
        ),
      );
      final service = makeService(adapter);

      await expectLater(
        service.searchHuggingFaceDatasets('x'),
        throwsA(isA<DatasetException>()
            .having((e) => e.message, 'message', contains('请求超时'))),
      );
    });

    test('非法 JSON：报「解析失败」中文提示', () async {
      final adapter =
          _MockAdapter((_) => ResponseBody.fromString('not-json{', 200));
      final service = makeService(adapter);

      await expectLater(
        service.searchHuggingFaceDatasets('x'),
        throwsA(isA<DatasetException>()
            .having((e) => e.message, 'message', contains('解析失败'))),
      );
    });

    test('详情 404：报「未找到」并带状态码', () async {
      final adapter = _MockAdapter((_) => _json({'error': 'nf'}, code: 404));
      final service = makeService(adapter);

      await expectLater(
        service.fetchHuggingFaceDatasetDetail('no/such'),
        throwsA(isA<DatasetException>()
            .having((e) => e.message, 'message', contains('未找到'))
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('详情空 ID：短路报错，不发起请求', () async {
      final adapter = _MockAdapter((_) => _json({'id': 'x'}));
      final service = makeService(adapter);

      await expectLater(
        service.fetchHuggingFaceDatasetDetail('  '),
        throwsA(isA<DatasetException>()),
      );
      expect(adapter.callCount, 0);
    });

    test('详情：解析 siblings 文件清单并剔除非法项', () async {
      final adapter = _MockAdapter((_) => _json(<String, Object>{
            'id': 'Ning311/my-data',
            'likes': 3,
            'downloads': 88,
            'lastModified': '2024-06-01T00:00:00.000Z',
            'siblings': [
              <String, String>{'rfilename': 'README.md'},
              <String, String>{'rfilename': 'data/train.jsonl'},
              'junk',
              <String, String>{},
            ],
          }));
      final service = makeService(adapter);

      final detail =
          await service.fetchHuggingFaceDatasetDetail('Ning311/my-data');
      expect(adapter.lastOptions!.uri.path, '/api/datasets/Ning311/my-data');
      expect(detail.author, 'Ning311'); // 取 id 中「/」前缀
      expect(detail.summary.downloads, 88);
      expect(detail.files, ['README.md', 'data/train.jsonl']);
    });

    test('parseHuggingFaceDetail：缺少必要字段（空 id）返回 null', () {
      expect(DatasetService.parseHuggingFaceDetail('{"likes": 1}'), isNull);
    });
  });

  group('精选子集清单契约', () {
    test('子集 id 唯一、https 直链、许可已核实、registryId 属于登记表', () {
      final ids = DatasetService.curatedSubsets.map((s) => s.id).toSet();
      expect(ids.length, DatasetService.curatedSubsets.length);

      // 登记表「已接入」条目（许可已核实），登记题录不允许出现在清单中
      const allowedRegistries = {'exmo', 'rehabo', 'longhaul-exercises'};
      for (final s in DatasetService.curatedSubsets) {
        expect(s.url, startsWith('https://'));
        expect(s.license, isNotEmpty);
        expect(s.license.contains('未确认'), isFalse);
        expect(allowedRegistries, contains(s.registryId));
        expect(s.fileName, isNotEmpty);
      }
    });

    test('formatBytes：B / KB / MB 分级展示', () {
      expect(DatasetService.formatBytes(512), '512 B');
      expect(DatasetService.formatBytes(2048), '2.0 KB');
      expect(DatasetService.formatBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('精选子集下载与记录', () {
    test('下载写盘、进度回调、生成下载记录', () async {
      final adapter = _MockAdapter((_) => _binaryChunks([
            [1, 2, 3],
            [4, 5],
          ]));
      final service = makeService(adapter);

      final progress = <int, int?>{}; // received → total
      final record = await service.downloadSubset(
        _testSubset,
        onProgress: (received, total) => progress[received] = total,
      );

      final file = File(record.filePath);
      expect(await file.exists(), isTrue);
      expect(file.readAsBytesSync(), [1, 2, 3, 4, 5]);
      expect(record.fileSizeBytes, 5);
      expect(
        record.filePath,
        endsWith(
          'datasets${Platform.pathSeparator}test-subset${Platform.pathSeparator}data.bin',
        ),
      );
      expect(record.subsetId, 'test-subset');
      expect(record.license, 'CC0 1.0');

      expect(progress, isNotEmpty); // 流式分块触发了进度回调
      expect(progress.keys.last, 5); // 已收字节累计到最后一次回调
      expect(progress.values.last, 5); // total 来自 content-length 头
      expect(await service.loadRecords(), hasLength(1));
    });

    test('重新下载：覆盖本地文件与同 id 记录', () async {
      var call = 0;
      final adapter = _MockAdapter((_) {
        call++;
        return _binaryChunks([
          call == 1 ? <int>[1, 2, 3, 4, 5] : <int>[9, 8, 7, 6, 5, 4, 3],
        ]);
      });
      final service = makeService(adapter);

      await service.downloadSubset(_testSubset);
      final second = await service.downloadSubset(_testSubset);

      expect(second.fileSizeBytes, 7);
      expect(File(second.filePath).readAsBytesSync(), [9, 8, 7, 6, 5, 4, 3]);
      final records = await service.loadRecords();
      expect(records, hasLength(1)); // 同 id 只保留一条
      expect(records.first.fileSizeBytes, 7);
    });

    test('下载失败：清理 .part 临时文件且不产生记录', () async {
      final adapter = _MockAdapter((_) => _json({'error': 'oops'}, code: 500));
      final service = makeService(adapter);

      // 预置一个残留 .part 文件，验证失败后被清理
      final partFile = File(
        '${root.path}${Platform.pathSeparator}datasets'
        '${Platform.pathSeparator}test-subset'
        '${Platform.pathSeparator}data.bin.part',
      );
      await partFile.parent.create(recursive: true);
      await partFile.writeAsString('partial');

      await expectLater(
        service.downloadSubset(_testSubset),
        throwsA(isA<DatasetException>()
            .having((e) => e.message, 'message', contains('HTTP 500'))),
      );
      expect(partFile.existsSync(), isFalse);
      expect(await service.loadRecords(), isEmpty);
    });

    test('deleteDownload：删除文件与记录，重复删除安全', () async {
      final adapter = _MockAdapter((_) => _binaryChunks([
            [1, 2, 3],
          ]));
      final service = makeService(adapter);
      final record = await service.downloadSubset(_testSubset);

      await service.deleteDownload('test-subset');
      expect(await File(record.filePath).exists(), isFalse);
      expect(await service.loadRecords(), isEmpty);

      // 重复删除：记录不存在时静默返回，不抛异常
      await service.deleteDownload('test-subset');
    });

    test('路径防护：记录指向下载根目录之外时不删文件，仅移除记录', () async {
      final service = makeService(_MockAdapter((_) => _binaryChunks([[1]])));

      final outside = File(
        '${root.parent.path}${Platform.pathSeparator}outside-guard.bin',
      );
      await outside.writeAsString('keep');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync();
      });

      // 模拟一条被篡改 / 历史遗留的越界记录
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'dataset_download_records_v1',
        jsonEncode(<Object>[
          <String, Object>{
            'subsetId': 'test-subset',
            'name': '越界记录',
            'fileName': 'outside-guard.bin',
            'filePath': outside.path,
            'url': 'https://example.com/x',
            'license': 'CC0 1.0',
            'fileSizeBytes': 4,
            'downloadedAt': '2026-01-01T00:00:00.000Z',
          },
        ]),
      );

      await service.deleteDownload('test-subset');
      expect(outside.existsSync(), isTrue); // 越界文件不被删除
      expect(await service.loadRecords(), isEmpty); // 但记录被移除
    });

    test('loadRecords：记录损坏时安全返回空', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('dataset_download_records_v1', 'not-json{');
      final service = makeService(_MockAdapter((_) => _json(<Object>[])));

      expect(await service.loadRecords(), isEmpty);
    });
  });
}
