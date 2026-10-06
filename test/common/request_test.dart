import 'package:dio/dio.dart';
import 'package:fl_clash/common/exception.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/common/package.dart';
import 'package:fl_clash/state.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
    globalState.packageInfo = PackageInfo(
      appName: 'FlClash-Meow',
      packageName: 'com.yukko.flclashmeow',
      version: '0.9.2',
      buildNumber: '1',
    );
  });

  test('getTextResponseForUrl propagates the typed DioException', () async {
    // flutter_test's mocked HttpClient answers every request with HTTP 400,
    // which Dio surfaces as a badResponse DioException.
    await expectLater(
      request.getTextResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  test('getFileResponseForUrl propagates the typed DioException', () async {
    await expectLater(
      request.getFileResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  test('checkForUpdate includes HTTP status and response body', () async {
    final interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.reject(
          DioException(
            requestOptions: options,
            response: Response<String>(
              requestOptions: options,
              statusCode: 403,
              data: 'rate limited',
            ),
            type: DioExceptionType.badResponse,
          ),
        );
      },
    );
    request.dio.interceptors.add(interceptor);
    addTearDown(() {
      request.dio.interceptors.remove(interceptor);
    });

    await expectLater(
      request.checkForUpdate(),
      throwsA(
        isA<MessageException>()
            .having((e) => e.message, 'message', contains('[403]'))
            .having((e) => e.message, 'message', contains('rate limited')),
      ),
    );
  });
  Map<String, dynamic> release(
    String tag, {
    bool prerelease = false,
    bool draft = false,
    bool complete = true,
  }) => {
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': draft,
    'html_url':
        'https://github.com/yukkodesu/FlClash-Patched/releases/tag/$tag',
    'assets': [
      if (complete)
        for (final platform in ['windows', 'linux', 'macos'])
          for (final arch in ['x64', 'arm64'])
            {
              'name':
                  'FlClash-Meow-${tag.substring(1)}-$platform-$arch.${switch (platform) {
                    'macos' => 'dmg',
                    'linux' => 'tar.zst',
                    _ => 'zip',
                  }}',
              'size': 100,
              'browser_download_url': 'https://github.com/download/package',
            },
    ],
  };

  Request withReleases(List<Object?> releases, {bool pre = true}) {
    final client = Request(includePrereleases: pre);
    addTearDown(() => client.dio.close(force: true));
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.path, '/repos/yukkodesu/FlClash-Patched/releases');
          handler.resolve(Response(requestOptions: options, data: releases));
        },
      ),
    );
    return client;
  }

  test(
    'updater compares the installed fork revision and preserves its user agent',
    () async {
      final candidate = release('v0.9.2+2');
      final client = withReleases([candidate]);
      expect(await client.checkForUpdate(), candidate);
      expect(globalState.packageInfo.ua, startsWith('FlClash-Meow/v0.9.2+1 '));
      expect(
        await withReleases([release('v0.9.2+1')]).checkForUpdate(),
        isNull,
      );
    },
  );

  test(
    'pre channel selects the greatest release version rather than API order',
    () async {
      final candidate = release('v0.9.3+1', prerelease: true);
      final client = withReleases([
        release('v0.9.2+10'),
        candidate,
        release('v0.9.2+2', prerelease: true),
      ]);
      expect(await client.checkForUpdate(), candidate);
    },
  );

  test('stable channel ignores a newer prerelease', () async {
    final candidate = release('v0.9.2+2');
    final client = withReleases([
      release('v0.9.3+1', prerelease: true),
      candidate,
    ], pre: false);
    expect(await client.checkForUpdate(), candidate);
  });

  test(
    'draft, malformed and incomplete releases do not hide a valid update',
    () async {
      final candidate = release('v0.9.2+2');
      final partial = release('v0.9.2+5');
      (partial['assets'] as List).removeLast();
      final client = withReleases([
        release('v0.9.9+1', draft: true),
        release('v0.9.9+2', complete: false),
        partial,
        release('v0.9.2+0'),
        release('v0.9.2-pre.1'),
        release('broken'),
        null,
        candidate,
      ]);
      expect(await client.checkForUpdate(), candidate);
    },
  );
}
