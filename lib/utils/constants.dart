/// 全局常量
class AppConstants {
  static const String appName = 'ZY Player';

  /// 青少年模式开启时命中的敏感词（与 uni-app 版 film.vue 中的列表一致）
  static const List<String> r18KeyWords = [
    '伦理',
    '论理',
    '倫理',
    '福利',
    '激情',
    '理论',
    '写真',
    '情色',
    '美女',
    '街拍',
    '赤足',
    '性感',
    '里番',
  ];

  /// 首页分类下拉中屏蔽的主分类
  static const List<String> hiddenClasses = [
    '电影',
    '电影片',
    '电视剧',
    '连续剧',
    '综艺',
    '动漫',
  ];

  static const String defaultSiteAsset = 'assets/data/init_site.json';
  static const String defaultSettingAsset = 'assets/data/init_setting.json';
}
