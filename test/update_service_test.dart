import 'package:flutter_test/flutter_test.dart';
import 'package:zy_player/utils/version.dart';

/// 版本更新的纯逻辑：版本比较与清单解析。
///
/// 只依赖 `utils/version.dart`（不含 Flutter / http / path_provider），
/// 所以这组用例在纯 Dart 环境也能验证。
void main() {
  group('VersionRules.compareNames', () {
    test('逐段按数字比较', () {
      expect(VersionRules.compareNames('1.18.0', '1.17.9'), 1);
      expect(VersionRules.compareNames('1.17.9', '1.18.0'), -1);
      expect(VersionRules.compareNames('1.17.0', '1.17.0'), 0);
      expect(VersionRules.compareNames('2.0', '1.99'), 1);
      // 字符串比较会判错（'1.10' < '1.9'），必须按数字比
      expect(VersionRules.compareNames('1.10.0', '1.9.0'), 1);
      expect(VersionRules.compareNames('1.17', '1.17.0'), 0);
    });
  });

  group('UpdateInfo.fromJson', () {
    test('标准字段', () {
      final info = UpdateInfo.fromJson({
        'versionName': '1.18.0',
        'versionCode': 192,
        'apkUrl': 'https://example.com/a.apk',
        'notes': '第一行\n第二行',
        'force': false,
      });
      expect(info.versionName, '1.18.0');
      expect(info.versionCode, 192);
      expect(info.notes, '第一行\n第二行');
      expect(info.force, false);
    });

    test('兼容 version=1.18.0+192 / apk_url / mandatory', () {
      final info = UpdateInfo.fromJson({
        'version': '1.18.0+192',
        'apk_url': 'https://example.com/a.apk',
        'changelog': '说明',
        'mandatory': true,
      });
      expect(info.versionName, '1.18.0');
      expect(info.versionCode, 192);
      expect(info.notes, '说明');
      expect(info.force, true);
    });

    test('缺地址 / 缺版本号抛可读异常', () {
      expect(
        () => UpdateInfo.fromJson({'versionName': '1.0.0'}),
        throwsA(isA<UpdateException>()),
      );
      expect(
        () => UpdateInfo.fromJson({'apkUrl': 'https://example.com/a.apk'}),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  group('VersionRules.isNewer', () {
    const info = UpdateInfo(
      versionName: '1.18.0',
      versionCode: 192,
      apkUrl: 'https://example.com/a.apk',
    );

    test('有 versionCode 时按 versionCode 判断', () {
      expect(
        VersionRules.isNewer(info, localCode: 191, localName: '1.17.0'),
        true,
      );
      expect(
        VersionRules.isNewer(info, localCode: 192, localName: '1.18.0'),
        false,
      );
      expect(
        VersionRules.isNewer(info, localCode: 193, localName: '1.19.0'),
        false,
      );
    });

    test('拿不到 versionCode 时退化为版本名比较', () {
      expect(
        VersionRules.isNewer(info, localCode: 0, localName: '1.17.0'),
        true,
      );
      expect(
        VersionRules.isNewer(info, localCode: 0, localName: '1.18.0'),
        false,
      );
    });
  });
}
