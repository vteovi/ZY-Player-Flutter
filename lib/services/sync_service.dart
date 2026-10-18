import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 局域网设备同步：零依赖，全部基于 dart:io 标准库。
///
/// 发现：组播 239.255.100.100:19528（TTL=1，仅本地子网）。共享端周期性广播，
///       同步端监听组播收集设备；同时支持手动输入对方 IP:端口 作为兜底。
/// 传输：共享端在 9527 端口起 HttpServer，GET /sync 返回 JSON 形式的原始数据。
///
/// 为什么不用 mDNS / NSD：Android 12+ 的 NsdManager 需要申请「附近设备」权限，
/// 而原生 UDP 组播不需要任何额外权限，跨平台更省事。
class LanDevice {
  final String ip;
  final int httpPort;
  final String name;

  LanDevice({required this.ip, required this.httpPort, required this.name});

  @override
  bool operator ==(Object other) =>
      other is LanDevice && other.ip == ip && other.httpPort == httpPort;

  @override
  int get hashCode => ip.hashCode ^ httpPort.hashCode;

  @override
  String toString() => '$name ($ip:$httpPort)';
}

class LanDiscovery {
  static const String _magic = 'ZYPLAYER-SYNC';
  static const String multicastGroup = '239.255.100.100';
  static const int discoveryPort = 19528;
  static const Duration _interval = Duration(seconds: 2);

  /// 获取本机第一个私有 IPv4 地址（用于显示 / 忽略自身广播）。
  static Future<String?> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (_isPrivateIp(ip)) return ip;
        }
      }
    } catch (_) {
      // ignore：拿不到就返回 null，由调用方兜底
    }
    return null;
  }

  static bool _isPrivateIp(String ip) {
    if (ip.startsWith('192.168.')) return true;
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('172.')) {
      final part = int.tryParse(ip.split('.')[1]);
      if (part != null && part >= 16 && part <= 31) return true;
    }
    return false;
  }

  /// 作为共享端：周期性向组播组广播自身存在。返回停止函数。
  static Future<Future<void> Function()> startAnnouncing(
    int httpPort,
    String name,
  ) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final payload = utf8.encode('$_magic|$httpPort|$name');
    final group = InternetAddress(multicastGroup);
    var stopped = false;
    void sendOnce() {
      if (stopped) return;
      try {
        socket.send(payload, group, discoveryPort);
      } catch (_) {
        // 网络切换 / 网卡不可用时忽略
      }
    }

    sendOnce();
    final timer = Timer.periodic(_interval, (_) => sendOnce());
    return () async {
      if (stopped) return;
      stopped = true;
      timer.cancel();
      socket.close();
    };
  }

  /// 作为同步端：监听组播，发现局域网内正在共享的设备。返回停止函数。
  static Future<Future<void> Function()> startListening(
    void Function(LanDevice) onDevice,
  ) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    try {
      socket.joinMulticast(InternetAddress(multicastGroup));
    } catch (_) {
      // 部分 rom / 网络不支持组播，忽略：用户仍可手动输入 IP 连接
    }
    final localIp = await getLocalIp();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      final fromIp = dg.address.address;
      if (fromIp == localIp) return; // 忽略自身
      final text = utf8.decode(dg.data, allowMalformed: true);
      if (!text.startsWith(_magic)) return;
      final parts = text.split('|');
      if (parts.length < 3) return;
      final port = int.tryParse(parts[1]);
      if (port == null) return;
      onDevice(LanDevice(ip: fromIp, httpPort: port, name: parts[2]));
    });
    return () async {
      try {
        socket.leaveMulticast(InternetAddress(multicastGroup));
      } catch (_) {}
      socket.close();
    };
  }
}

/// 共享端 HTTP 服务：在固定端口暴露选定库的原始数据。
class SyncServer {
  final HttpServer _server;

  SyncServer._(this._server);

  /// 启动服务。端口被占用时返回 null（调用方提示用户）。
  static Future<SyncServer?> start(
    Map<String, List<Map<String, dynamic>>> payload, {
    int port = 9527,
  }) async {
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      final instance = SyncServer._(server);
      server.listen((request) async {
        if (request.method == 'GET' && request.uri.path == '/sync') {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(<String, dynamic>{'ok': true, 'data': payload}));
          await request.response.close();
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      });
      return instance;
    } catch (_) {
      return null;
    }
  }

  int get port => _server.port;

  Future<void> stop() async {
    await _server.close();
  }
}

/// 同步端 HTTP 客户端：拉取对方共享的数据。
class SyncClient {
  static Future<Map<String, List<Map<String, dynamic>>>> fetch(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = timeout;
      final uri = Uri.http('$host:$port', '/sync');
      final request = await client.getUrl(uri);
      final response = await responseToBody(request, timeout);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final body = await _readBody(response, timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw Exception('响应格式错误');
      final data = decoded['data'];
      if (data is! Map) throw Exception('响应缺少 data 字段');
      final result = <String, List<Map<String, dynamic>>>{};
      data.forEach((key, value) {
        if (value is List) {
          result[key.toString()] = value
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      });
      return result;
    } finally {
      client.close(force: true);
    }
  }

  static Future<HttpClientResponse> responseToBody(
    HttpClientRequest request,
    Duration timeout,
  ) =>
      request.close().timeout(timeout);

  static Future<String> _readBody(
    HttpClientResponse response,
    Duration timeout,
  ) =>
      response.transform(utf8.decoder).join().timeout(timeout);
}
