import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';

class Request {
  late final Dio dio;
  late final Dio _clashDio;
  String? userAgent;

  ProviderReader? _read;
  final bool _includePrereleases;

  void attach(ProviderReader read) {
    _read = read;
  }

  Request({
    bool includePrereleases =
        const String.fromEnvironment('APP_ENV', defaultValue: 'pre') == 'pre',
  }) : _includePrereleases = includePrereleases {
    dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _clashDio = Dio();
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          final read = _read;
          if (read == null) {
            return 'DIRECT';
          }
          return FlClashHttpOverrides.findProxyForReader(read, uri);
        };
        return client;
      },
    );
  }

  Future<Response<Uint8List>> getFileResponseForUrl(String url) async {
    try {
      return await _clashDio
          .get<Uint8List>(
            url,
            options: Options(responseType: ResponseType.bytes),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      commonPrint.log(
        'getFileResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  Future<Response<String>> getTextResponseForUrl(String url) async {
    try {
      return await _clashDio
          .get<String>(url, options: Options(responseType: ResponseType.plain))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      commonPrint.log(
        'getTextResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final response = await dio
          .get<List<dynamic>>(
            'https://api.github.com/repos/$repository/releases',
            queryParameters: {'per_page': 100},
            options: Options(responseType: ResponseType.json),
          )
          .timeout(const Duration(seconds: 10));
      Map<String, dynamic>? newest;
      var newestVersion = globalState.packageInfo.releaseVersion;
      for (final entry in response.data ?? const []) {
        if (entry is! Map<String, dynamic> ||
            entry['draft'] != false ||
            (!_includePrereleases && entry['prerelease'] != false)) {
          continue;
        }
        final tag = entry['tag_name'];
        if (tag is! String ||
            !RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$').hasMatch(tag)) {
          continue;
        }
        final version = tag.substring(1);
        if (version
                .replaceAll('+', '.')
                .split('.')
                .any((part) => int.tryParse(part) == null) ||
            !_hasDesktopPackages(entry, version)) {
          continue;
        }
        if (compareVersions(version, newestVersion) > 0) {
          newest = entry;
          newestVersion = version;
        }
      }
      return newest;
    } catch (e) {
      commonPrint.log(
        'checkForUpdate failed: ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      throw _requestException(e);
    }
  }

  bool _hasDesktopPackages(Map<String, dynamic> release, String version) {
    final assets = release['assets'];
    final htmlUrl = release['html_url'];
    final url = htmlUrl is String ? Uri.tryParse(htmlUrl) : null;
    if (assets is! List ||
        url?.scheme != 'https' ||
        url?.host != 'github.com') {
      return false;
    }
    final targets = <String>{};
    final namePattern = RegExp(
      '^FlClash-Meow-${RegExp.escape(version)}-(windows|linux|macos)-(x64|arm64)(?:-setup)?\\.(.+)\$',
    );
    for (final asset in assets) {
      if (asset is! Map ||
          asset['name'] is! String ||
          asset['size'] is! num ||
          (asset['size'] as num) <= 0 ||
          asset['browser_download_url'] is! String ||
          (asset['browser_download_url'] as String).isEmpty) {
        continue;
      }
      final match = namePattern.firstMatch(asset['name'] as String);
      if (match == null) continue;
      final platform = match[1]!;
      final extension = match[3]!;
      final supported = switch (platform) {
        'windows' => const {'exe', 'zip'},
        'macos' => const {'dmg'},
        _ => const {'deb', 'zip', 'AppImage', 'tar.zst'},
      };
      if (supported.contains(extension)) targets.add('$platform-${match[2]}');
    }
    return targets.length == 6;
  }

  MessageException _requestException(Object error) {
    if (error is MessageException) {
      return error;
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.badResponse) {
        final response = error.response;
        final statusCode = response?.statusCode ?? 0;
        final body = _responseBody(response);
        final detail = body.isEmpty ? '[$statusCode]' : '[$statusCode]\n$body';
        return MessageException(
          '${currentAppLocalizations.networkException} $detail',
        );
      }
      final detail = error.error?.toString().trim();
      if (detail != null && detail.isNotEmpty) {
        return MessageException(
          '${currentAppLocalizations.unknownNetworkError}\n$detail',
        );
      }
    }
    return MessageException(
      '${currentAppLocalizations.unknownNetworkError}\n$error',
    );
  }

  String _responseBody(Response<dynamic>? response) {
    final data = response?.data;
    if (data == null) {
      return '';
    }
    if (data is Uint8List) {
      try {
        return utf8.decode(data).trim();
      } catch (_) {
        return '';
      }
    }
    if (data is Map || data is List) {
      return jsonEncode(data).trim();
    }
    return data.toString().trim();
  }

  final Map<String, IpInfo Function(Map<String, dynamic>)> _ipInfoSources = {
    'https://ipwho.is': IpInfo.fromIpWhoIsJson,
    'https://api.myip.com': IpInfo.fromMyIpJson,
    'https://ipapi.co/json': IpInfo.fromIpApiCoJson,
    'https://ident.me/json': IpInfo.fromIdentMeJson,
    'http://ip-api.com/json': IpInfo.fromIpAPIJson,
    'https://api.ip.sb/geoip': IpInfo.fromIpSbJson,
    'https://ipinfo.io/json': IpInfo.fromIpInfoIoJson,
  };

  Future<Result<IpInfo?>> checkIp({CancelToken? cancelToken}) async {
    var failureCount = 0;
    final token = cancelToken ?? CancelToken();
    final futures = _ipInfoSources.entries.map((source) async {
      final Completer<Result<IpInfo?>> completer = Completer();
      void handleFailRes() {
        if (!completer.isCompleted && failureCount == _ipInfoSources.length) {
          completer.complete(Result.success(null));
        }
      }

      final future = dio
          .get<Map<String, dynamic>>(
            source.key,
            cancelToken: token,
            options: Options(responseType: ResponseType.json),
          )
          .timeout(const Duration(seconds: 10));
      unawaited(
        future
            .then((res) {
              if (res.statusCode == HttpStatus.ok && res.data != null) {
                completer.complete(Result.success(source.value(res.data!)));
                return;
              }
              commonPrint.log('checkIp data empty', logLevel: LogLevel.info);
              failureCount++;
              handleFailRes();
            })
            .catchError((e) {
              failureCount++;
              if (e is DioException && e.type == DioExceptionType.cancel) {
                completer.complete(Result.error('cancelled'));
                return;
              }
              commonPrint.log('checkIp error $e', logLevel: LogLevel.warning);
              handleFailRes();
            }),
      );
      return completer.future;
    });
    final res = await Future.any(futures);
    token.cancel();
    return res;
  }
}

final request = Request();

String? getFileNameForDisposition(String? disposition) {
  if (disposition == null) return null;
  final parseValue = HeaderValue.parse(disposition);
  final parameters = parseValue.parameters;
  final fileNamePointKey = parameters.keys.firstWhere(
    (key) => key == 'filename*',
    orElse: () => '',
  );
  if (fileNamePointKey.isNotEmpty) {
    final res = parameters[fileNamePointKey]?.split("''") ?? [];
    if (res.length >= 2) {
      return Uri.decodeComponent(res[1]);
    }
  }
  final fileNameKey = parameters.keys.firstWhere(
    (key) => key == 'filename',
    orElse: () => '',
  );
  if (fileNameKey.isEmpty) return null;
  return parameters[fileNameKey];
}

String? getFileNameFromUrl(String? url) {
  final realUrl = url?.trim();
  if (realUrl == null || realUrl.isEmpty) return null;
  final uri = Uri.tryParse(realUrl);
  if (uri == null || uri.pathSegments.isEmpty) return null;
  final fileName = uri.pathSegments
      .lastWhere((segment) => segment.trim().isNotEmpty, orElse: () => '')
      .trim();
  if (fileName.isEmpty || fileName.contains('/') || fileName.contains(r'\')) {
    return null;
  }
  final dotIndex = fileName.lastIndexOf('.');
  if (dotIndex <= 0 || dotIndex == fileName.length - 1) {
    return null;
  }
  return fileName;
}
