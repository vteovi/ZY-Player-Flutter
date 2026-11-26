/// 全局常量
class AppConstants {
  static const String appName = 'ZY Player';

  // 首页分类栏曾有一张硬编码屏蔽名单（电影 / 电影片 / 电视剧 / 连续剧 /
  // 综艺 / 动漫），1.44.2 起已删除：采集站的分类本来就该原样显示，藏掉
  // 主流分类会让首页缺一大块（实测 ys.cxkjg.cn 接口给 9 个只剩 6 栏）。

  static const String defaultSiteAsset = 'assets/data/init_site.json';
  static const String defaultSettingAsset = 'assets/data/init_setting.json';
}
