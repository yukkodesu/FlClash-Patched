import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart';

Future<void> seedBundledGeodata(String home) async {
  for (final name in ['Country.mmdb', 'GeoLite2-ASN.mmdb', 'geosite.dat']) {
    final target = File(join(home, name));
    if (await target.exists()) {
      continue;
    }
    final asset = await rootBundle.load('assets/data/$name');
    final staging = await Directory(home).createTemp('.geodata-');
    try {
      final source = File(join(staging.path, name));
      await source.writeAsBytes(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        flush: true,
      );
      if (!await target.exists()) {
        await source.rename(target.path);
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
