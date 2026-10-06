import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main() async {
  await ensureGeoData(rootDir: Directory.current.path);
}

const geoDataSources = {
  'Country.mmdb':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb',
  'GeoLite2-ASN.mmdb':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb',
  'geosite.dat':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
};

Future<void> ensureGeoData({
  required String rootDir,
  Map<String, String> sources = geoDataSources,
}) async {
  final dataDir = Directory(p.join(rootDir, 'assets', 'data'));
  if (!dataDir.existsSync()) {
    dataDir.createSync(recursive: true);
  }

  for (final entry in sources.entries) {
    final file = File(p.join(dataDir.path, entry.key));
    if (file.existsSync()) {
      if (file.lastModifiedSync().isBefore(
        DateTime.now().subtract(const Duration(days: 1)),
      )) {
        stdout.writeln('GeoData is outdated: ${entry.key}');
      } else {
        continue;
      }
    }
    await _downloadGeoData(url: entry.value, file: file);
  }
}

Future<void> _downloadGeoData({required String url, required File file}) async {
  final tempFile = File('${file.path}.download');
  stdout.writeln('Downloading GeoData: ${p.basename(file.path)}');

  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Failed to download $url: HTTP ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }

    await response.pipe(tempFile.openWrite());
    if (file.existsSync()) {
      file.deleteSync();
    }
    tempFile.renameSync(file.path);
  } catch (_) {
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
    rethrow;
  } finally {
    client.close(force: true);
  }
}
