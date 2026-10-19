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

  /// 获取本机用于局域网互通的 IPv4 地址（用于显示 / 忽略自身广播）。
  ///
  /// 直接取「第一个私有地址」会拿到蜂窝数据、VPN、虚拟机/厂商虚拟网卡等地址
  /// （如 10.16.x.x、192.168.51.x），与真实路由器网段不符。这里优先挑选看起来像
  /// 物理网卡（Wi-Fi/以太网）的接口，避开 rmnet/tun/vEthernet/VMware 等虚拟网卡；
  /// 若挑不到再退回「首个私有地址」，避免回归。
  static Future<String?> getLocalIp() async {
    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
    } catch (_) {
      return null;
    }
    String? fallback;
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (!_isPrivateIp(ip)) continue;
        fallback ??= ip;
        if (_looksLikePhysicalLan(iface)) return ip;
      }
    }
    return fallback;
  }

  /// 该网卡名是否像物理 LAN 网卡（Wi-Fi/以太网），而非蜂窝 / VPN / 虚拟交换机。
  static bool _looksLikePhysicalLan(NetworkInterface iface) {
    final n = iface.name.toLowerCase();
    const excluded = [
      'lo', 'loopback',
      'rmnet', 'ccmni', 'ppp', 'tun', 'tap', // 蜂窝数据 / VPN
      'vmnet', 'vmware', 'vbox', 'virtualbox', // 虚拟机
      'vethernet', 'hyper-v', 'hyperv', 'docker', 'br-', // 虚拟交换机 / 容器
      'bluetooth', 'bt', 'pan', // 蓝牙网络共享
      'zerotier', 'tailscale', 'wireguard', 'openvpn', // VPN 隧道
    ];
    for (final e in excluded) {
      if (n.contains(e)) return false;
    }
    return true;
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

  /// 作为共享端：周期性向组播组广播自身存在，同时监听探测包并即时单播回应。
  /// 返回停止函数。
  static Future<Future<void> Function()> startAnnouncing(
    int httpPort,
    String name,
  ) async {
    final sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final payload = utf8.encode('$_magic|$httpPort|$name');
    final group = InternetAddress(multicastGroup);
    final recvSocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    try {
      recvSocket.joinMulticast(InternetAddress(multicastGroup));
    } catch (_) {
      // 部分 rom / 网络不支持组播，忽略：对方仍可手动输入 IP 连接
    }
    var stopped = false;
    void sendOnce({InternetAddress? to, int? toPort}) {
      if (stopped) return;
      try {
        if (to != null && toPort != null) {
          sendSocket.send(payload, to, toPort); // 探测回应：单播给请求方
        } else {
          sendSocket.send(payload, group, discoveryPort); // 周期广播
        }
      } catch (_) {
        // 网络切换 / 网卡不可用时忽略
      }
    }

    sendOnce();
    final timer = Timer.periodic(_interval, (_) => sendOnce());
    // 监听探测包，收到后单播立即回应（手动刷新可秒级发现）
    recvSocket.listen((event) {
      if (event != RawSocketEvent.read || stopped) return;
      final dg = recvSocket.receive();
      if (dg == null) return;
      final text = utf8.decode(dg.data, allowMalformed: true);
      if (text == '$_magic|PROBE') {
        sendOnce(to: dg.address, toPort: dg.port);
      }
    });
    return () async {
      if (stopped) return;
      stopped = true;
      timer.cancel();
      try {
        recvSocket.leaveMulticast(InternetAddress(multicastGroup));
      } catch (_) {}
      recvSocket.close();
      sendSocket.close();
    };
  }

  /// 同步端探测包载荷（共享端收到后单播立即回应）。
  static const String _probePayload = '$_magic|PROBE';

  /// 作为同步端：监听组播，发现局域网内正在共享的设备。返回 [LanListener]。
  static Future<LanListener> startListening(
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
    void handle(Datagram? dg) {
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
    }

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      handle(socket.receive());
    });
    return LanListener._(socket, () {
      try {
        socket.leaveMulticast(InternetAddress(multicastGroup));
      } catch (_) {}
      socket.close();
    });
  }
}

/// 同步端监听句柄。持有组播监听 socket，支持被动发现与主动探测刷新。
class LanListener {
  final RawDatagramSocket _socket;
  final void Function() _dispose;

  LanListener._(this._socket, this._dispose);

  /// 向局域网发送一次主动探测，促使共享端立即单播回应（手动刷新用）。
  void probe() {
    try {
      _socket.send(
        utf8.encode(LanDiscovery._probePayload),
        InternetAddress(LanDiscovery.multicastGroup),
        LanDiscovery.discoveryPort,
      );
    } catch (_) {
      // 网络不可用时忽略
    }
  }

  Future<void> stop() async => _dispose();
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
