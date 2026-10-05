import 'method.dart';

class CoreInfo {
  static const supportedProtocolVersion = 1;

  final String name;
  final String version;
  final String hostVersion;
  final String commit;
  final int protocolVersion;
  final Set<String> capabilities;
  final String statisticsScope;
  final String connectionsScope;
  final List<String> tunModes;

  CoreInfo.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String,
      version = json['version'] as String,
      hostVersion = json['hostVersion'] as String,
      commit = json['commit'] as String,
      protocolVersion = json['protocolVersion'] as int,
      capabilities = Set.unmodifiable(
        List<String>.from(json['capabilities'] as List),
      ),
      statisticsScope = json['statisticsScope'] as String,
      connectionsScope = json['connectionsScope'] as String,
      tunModes = List.unmodifiable(
        List<String>.from(json['tunModes'] as List),
      ) {
    if (name != 'meow-rs' || protocolVersion != supportedProtocolVersion) {
      throw CoreMethodException(
        code: 'incompatible_protocol',
        message: 'Unsupported core $name with protocol $protocolVersion.',
      );
    }
    if (version.isEmpty || hostVersion.isEmpty || commit.isEmpty) {
      throw const CoreMethodException(
        code: 'invalid_response',
        message: 'Core identity is incomplete.',
      );
    }
  }
}

class CoreRuntimeState {
  final bool initialized;
  final bool configured;
  final bool running;
  final bool tunActive;
  final int generation;
  final NativeRecovery recovery;
  final List<CoreListener> listeners;
  final String? dnsListen;
  final String? externalController;

  CoreRuntimeState.fromJson(Map<String, dynamic> json)
    : initialized = json['initialized'] as bool,
      configured = json['configured'] as bool,
      running = json['running'] as bool,
      tunActive = json['tunActive'] as bool,
      generation = json['generation'] as int,
      recovery = NativeRecovery.fromJson(
        json['recovery'] as Map<String, dynamic>? ??
            const {'state': 'clean', 'details': <String>[]},
      ),
      listeners = List.unmodifiable(
        (json['listeners'] as List? ?? const []).map(
          (item) =>
              CoreListener.fromJson(Map<String, dynamic>.from(item as Map)),
        ),
      ),
      dnsListen = json['dnsListen'] as String?,
      externalController = json['externalController'] as String?;
}

class CoreListener {
  final String name;
  final String type;
  final String address;

  CoreListener.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String,
      type = json['type'] as String,
      address = json['address'] as String;
}

class NativeRecovery {
  final String state;
  final List<String> details;

  NativeRecovery.fromJson(Map<String, dynamic> json)
    : state = json['state'] as String,
      details = List.unmodifiable(List<String>.from(json['details'] as List)) {
    if (!const {
      'clean',
      'recovered',
      'needsPrivilege',
      'failed',
    }.contains(state)) {
      throw const CoreMethodException(
        code: 'invalid_response',
        message: 'Unknown native recovery state.',
      );
    }
  }

  bool get requiresAttention => state == 'needsPrivilege' || state == 'failed';
}

class ConfigDiagnostic {
  final String severity;
  final String path;
  final String reason;
  final String suggestion;

  ConfigDiagnostic.fromJson(Map<String, dynamic> json)
    : severity = json['severity'] as String,
      path = json['path'] as String,
      reason = json['reason'] as String,
      suggestion = json['suggestion'] as String {
    if (!const {'error', 'warning'}.contains(severity)) {
      throw const CoreMethodException(
        code: 'invalid_response',
        message: 'Unknown configuration diagnostic severity.',
      );
    }
  }
}

class ConfigCheck {
  final bool valid;
  final List<ConfigDiagnostic> diagnostics;

  ConfigCheck.fromJson(Map<String, dynamic> json)
    : valid = json['valid'] as bool,
      diagnostics = List.unmodifiable(
        (json['diagnostics'] as List).map(
          (item) =>
              ConfigDiagnostic.fromJson(Map<String, dynamic>.from(item as Map)),
        ),
      ) {
    if (valid && diagnostics.any((item) => item.severity == 'error')) {
      throw const CoreMethodException(
        code: 'invalid_response',
        message: 'Core accepted a configuration with blocking diagnostics.',
      );
    }
  }
}
