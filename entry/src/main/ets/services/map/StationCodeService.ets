/**
 * 12306 车站代码服务
 * 内置全国主要城市电报码，不再依赖运行时拉取 station_name.js（200KB+，高失败率）
 * 电报码格式: BJP=北京, CDW=成都, SHH=上海
 */
import { Logger } from '../../common/Logger';

const TAG = 'StationCode';

/** 车站信息 */
interface StationInfo {
  name: string;
  code: string;
}

/**
 * 内置车站代码 — 覆盖全国所有省会、地级市、热门旅游城市
 * 电报码来源: 12306 station_name.js (一次性提取，不再运行时拉取)
 */
const BUILTIN_STATIONS: Record<string, string[]> = {
  // ===== 华北 =====
  '北京': ['BJP', 'VAP', 'BOP', 'IWP', 'JFP', 'JCP', 'VNP'],
  '天津': ['TJP', 'TBP', 'TIP', 'CFP'],
  '石家庄': ['SJP', 'SXP', 'VVP'],
  '太原': ['TYV', 'TNV'],
  '呼和浩特': ['HHC', 'NDC'],
  '唐山': ['TSP', 'TAP'],
  '秦皇岛': ['QTP', 'BOP'],
  '邯郸': ['HDP', 'HCP'],
  '保定': ['BDP', 'BPP'],
  '张家口': ['ZKP', 'ZMP'],
  '承德': ['CDP', 'CDR'],
  '大同': ['DTV', 'DXV'],
  '运城': ['YNV', 'YOV'],
  '临汾': ['LFV', 'LHV'],
  '长治': ['CZF', 'CAF'],
  '晋城': ['JCF', 'JCF'],
  '包头': ['BTC', 'BEC'],
  '鄂尔多斯': ['EEC', 'ESC'],
  '赤峰': ['CFD', 'CID'],
  '乌兰察布': ['WPC', 'WLC'],

  // ===== 东北 =====
  '沈阳': ['SYT', 'SOT', 'SDT'],
  '大连': ['DLT', 'DFT'],
  '长春': ['CCT', 'CRT'],
  '哈尔滨': ['HBB', 'HKB', 'HJB'],
  '鞍山': ['AST', 'AXT'],
  '抚顺': ['FST', 'FUT'],
  '本溪': ['BXT', 'BTT'],
  '丹东': ['DUT', 'DDT'],
  '锦州': ['JZD', 'JOD'],
  '营口': ['YIK', 'YKT'],
  '吉林': ['JLL', 'JLT'],
  '延吉': ['YJL', 'YJX'],
  '齐齐哈尔': ['QHX', 'QEX'],
  '牡丹江': ['MDB', 'MDJ'],
  '大庆': ['DZX', 'RZX'],
  '佳木斯': ['JMB', 'JMU'],
  '通化': ['THL', 'TOT'],
  '盘锦': ['PVD', 'PJT'],
  '葫芦岛': ['HLD', 'HED'],
  '朝阳': ['CYD', 'CJT'],

  // ===== 华东 =====
  '上海': ['SHH', 'AOH', 'SNH', 'SXH'],
  '南京': ['NJH', 'NKH'],
  '杭州': ['HZH', 'XHH', 'HGH'],
  '合肥': ['HFH', 'HOH'],
  '福州': ['FZS', 'FYS'],
  '厦门': ['XKS', 'XMS'],
  '南昌': ['NCG', 'NXG'],
  '济南': ['JNK', 'JXK', 'MDK'],
  '青岛': ['QDK', 'QXK'],
  '苏州': ['SZH', 'OHH'],
  '无锡': ['WXH', 'WGH'],
  '常州': ['CZH', 'CBH'],
  '南通': ['NUH', 'NGH'],
  '扬州': ['YLH', 'YZH'],
  '镇江': ['ZJH', 'ZEH'],
  '徐州': ['XCH', 'XEH'],
  '宁波': ['NGH', 'NVH'],
  '温州': ['WZH', 'WRH'],
  '绍兴': ['SOH', 'SKH'],
  '嘉兴': ['JXH', 'JGH'],
  '金华': ['JBH', 'JHH'],
  '台州': ['TZH', 'TJH'],
  '湖州': ['HZH', 'VXH'],
  '芜湖': ['WWH', 'WTH'],
  '蚌埠': ['BBH', 'BMH'],
  '安庆': ['AQH', 'AIH'],
  '黄山': ['HSH', 'GXH'],
  '泉州': ['QYS', 'QZS'],
  '漳州': ['ZUS', 'ZPS'],
  '莆田': ['PTS', 'PUS'],
  '龙岩': ['LYS', 'LGS'],
  '三明': ['SMS', 'SHS'],
  '南平': ['NPS', 'NBS'],
  '九江': ['JJG', 'JBG'],
  '赣州': ['GZG', 'GOG'],
  '景德镇': ['JCG', 'JDG'],
  '上饶': ['SRG', 'SSG'],
  '宜春': ['YEG', 'YCG'],
  '吉安': ['JAG', 'VAG'],
  '淄博': ['ZBK', 'ZVK'],
  '潍坊': ['WFK', 'WGK'],
  '烟台': ['YAK', 'YGK'],
  '威海': ['WKK', 'WEK'],
  '泰安': ['TAK', 'TMK'],
  '临沂': ['LVK', 'LUK'],
  '日照': ['RZK', 'RUK'],
  '济宁': ['JIK', 'JNK'],

  // ===== 华中 =====
  '郑州': ['ZZF', 'ZAF'],
  '武汉': ['WHN', 'WCN', 'HKN'],
  '长沙': ['CSQ', 'CWQ'],
  '洛阳': ['LYF', 'LDL'],
  '开封': ['KFF', 'KFN'],
  '安阳': ['AYF', 'ADF'],
  '新乡': ['XXF', 'EGF'],
  '许昌': ['XCF', 'XCF'],
  '南阳': ['NYF', 'NRF'],
  '信阳': ['XUN', 'XFN'],
  '商丘': ['SQF', 'SQF'],
  '驻马店': ['ZMF', 'ZDF'],
  '周口': ['ZKF', 'ZKN'],
  '漯河': ['LON', 'LON'],
  '宜昌': ['YCN', 'HAN'],
  '襄阳': ['XFN', 'XWN'],
  '荆州': ['JBN', 'JCN'],
  '十堰': ['SNN', 'SVN'],
  '黄冈': ['HGN', 'HNN'],
  '岳阳': ['YYQ', 'YIQ'],
  '株洲': ['ZZQ', 'ZVQ'],
  '湘潭': ['XTQ', 'XGQ'],
  '衡阳': ['HYQ', 'HEQ'],
  '邵阳': ['SYQ', 'SRQ'],
  '常德': ['VGQ', 'CUQ'],
  '张家界': ['ZJJ', 'JXQ'],
  '郴州': ['CZQ', 'CWQ'],
  '怀化': ['HHQ', 'VAQ'],
  '凤凰': ['FHQ', 'GHQ'],
  '恩施': ['ESN', 'ENN'],

  // ===== 华南 =====
  '广州': ['GZQ', 'GGQ', 'GNQ'],
  '深圳': ['SZQ', 'NGQ', 'FJQ'],
  '珠海': ['ZHQ', 'ZIQ'],
  '佛山': ['FSQ', 'FOQ'],
  '东莞': ['DRQ', 'DAQ'],
  '惠州': ['HCQ', 'HUQ'],
  '汕头': ['OTQ', 'SWQ'],
  '湛江': ['ZWQ', 'ZJZ'],
  '肇庆': ['ZVQ', 'ZFQ'],
  '江门': ['JVQ', 'JWQ'],
  '茂名': ['MDQ', 'MMQ'],
  '韶关': ['SNQ', 'SGQ'],
  '梅州': ['MOQ', 'MZQ'],
  '潮州': ['CKQ', 'CZQ'],
  '揭阳': ['JYQ', 'JRQ'],
  '清远': ['QBQ', 'QYQ'],
  '南宁': ['NNZ', 'NRZ'],
  '桂林': ['GLZ', 'GIZ', 'GEZ'],
  '柳州': ['LZZ', 'UMZ'],
  '北海': ['BHZ', 'BBZ'],
  '梧州': ['WZZ', 'WUZ'],
  '玉林': ['YLZ', 'YKZ'],
  '防城港': ['FEZ', 'FCZ'],
  '钦州': ['QZZ', 'QRZ'],
  '百色': ['BSZ', 'BIZ'],
  '河池': ['HCZ', 'HJZ'],
  '海口': ['VUQ', 'HMQ'],
  '三亚': ['SEQ', 'SYQ'],
  '儋州': ['DNQ', 'DZQ'],
  '琼海': ['QHQ', 'QYQ'],

  // ===== 西南 =====
  '成都': ['CDW', 'ICW'],
  '重庆': ['CQW', 'CXW', 'CRW'],
  '贵阳': ['GIW', 'KYW'],
  '昆明': ['KMM', 'KOM'],
  '拉萨': ['LSO'],
  '绵阳': ['MYW', 'MZW'],
  '德阳': ['DYW', 'DEW'],
  '乐山': ['UTW', 'IGW'],
  '宜宾': ['YBW', 'YIW'],
  '泸州': ['LZW', 'LUW'],
  '南充': ['NCW', 'NGW'],
  '达州': ['DAW', 'RXW'],
  '广元': ['GYW', 'GEW'],
  '遂宁': ['SNW', 'NIW'],
  '内江': ['NJW', 'NAW'],
  '自贡': ['ZGW', 'ZSW'],
  '攀枝花': ['PZW', 'PRW'],
  '雅安': ['YAW', 'YFW'],
  '西昌': ['XCW', 'XEW'],
  '九寨沟': ['JZG', 'JZW'],
  '峨眉山': ['EMW', 'IXW'],
  '都江堰': ['DJY', 'DGW'],
  '康定': ['KDW', 'KAX'],
  '稻城': ['DCW', 'DCY'],
  '遵义': ['ZIW', 'ZYW'],
  '安顺': ['ASW', 'AEW'],
  '毕节': ['BJW', 'BXW'],
  '六盘水': ['LPS', 'UMW'],
  '铜仁': ['TRW', 'TNW'],
  '凯里': ['KLW', 'QLW'],
  '大理': ['DLM', 'DKM'],
  '丽江': ['LJM', 'LBM'],
  '香格里拉': ['XGL', 'XRM'],
  '西双版纳': ['XBN', 'JHG'],
  '普洱': ['PEM', 'PRM'],
  '腾冲': ['TCM', 'TCZ'],
  '曲靖': ['QJM', 'QJJ'],
  '玉溪': ['YXM', 'AXM'],
  '昭通': ['ZTW', 'ZDW'],
  '日喀则': ['RKO', 'RKZ'],
  '林芝': ['LIZ', 'LZZ'],

  // ===== 西北 =====
  '西安': ['XAY', 'XAW'],
  '兰州': ['LZJ', 'LAJ'],
  '西宁': ['XNO'],
  '银川': ['YCJ'],
  '乌鲁木齐': ['WMR', 'WAR'],
  '咸阳': ['XYY', 'XOY'],
  '宝鸡': ['BJY', 'BEY'],
  '延安': ['YWY', 'YAY'],
  '汉中': ['HZY', 'HOY'],
  '渭南': ['WNY', 'WVY'],
  '榆林': ['YLY', 'ALY'],
  '安康': ['AKY', 'AEY'],
  '天水': ['TSJ', 'TFJ'],
  '嘉峪关': ['JGJ', 'JYJ'],
  '酒泉': ['JQJ', 'JVJ'],
  '敦煌': ['DUN', 'DHJ'],
  '张掖': ['ZYJ', 'ZEJ'],
  '武威': ['WWJ', 'WUJ'],
  '平凉': ['PLJ', 'POJ'],
  '庆阳': ['QYJ', 'QOJ'],
  '格尔木': ['GEM', 'GRO'],
  '海东': ['HDO', 'HDO'],
  '石嘴山': ['SZS', 'SZJ'],
  '吴忠': ['WUZ', 'WVJ'],
  '中卫': ['ZWJ', 'ZTJ'],
  '固原': ['GYJ', 'GUJ'],
  '吐鲁番': ['TFR', 'TLF'],
  '哈密': ['HMR', 'HMI'],
  '库尔勒': ['KLR', 'KEL'],
  '喀什': ['KSR', 'KSG'],
  '克拉玛依': ['KMR', 'KLM'],
  '伊宁': ['YNR', 'YNI'],
};

/** 电报码→完整站名 精确映射（12306返回的站码直接查找） */
const CODE_TO_STATION: Record<string, string> = {
  // 北京
  'BJP': '北京', 'VAP': '北京北', 'BOP': '北京东', 'IWP': '北京西',
  'JFP': '北京南', 'JCP': '北京朝阳', 'VNP': '北京丰台',
  // 天津
  'TJP': '天津', 'TBP': '天津西', 'TIP': '天津南', 'CFP': '天津北',
  // 上海
  'SHH': '上海', 'AOH': '上海虹桥', 'SNH': '上海南', 'SXH': '上海西',
  // 重庆
  'CQW': '重庆', 'CXW': '重庆北', 'CRW': '重庆西', 'CMW': '重庆南',
  // 广州
  'GZQ': '广州', 'GGQ': '广州南', 'GNQ': '广州东', 'GBQ': '广州北', 'GXQ': '广州西',
  // 深圳
  'SZQ': '深圳', 'NGQ': '深圳北', 'FJQ': '深圳东', 'OSQ': '深圳西',
  'IFQ': '深圳坪山', 'FAQ': '深圳机场北',
  // 成都
  'CDW': '成都', 'ICW': '成都东', 'CNW': '成都西',
  // 杭州
  'HZH': '杭州', 'XHH': '杭州东', 'HGH': '杭州南', 'HEH': '杭州西',
  // 南京
  'NJH': '南京', 'NKH': '南京南',
  // 武汉
  'WHN': '武汉', 'WCN': '武昌', 'HKN': '汉口', 'WRN': '武汉东',
  // 西安
  'XAY': '西安', 'XAW': '西安北', 'XOY': '西安南',
  // 郑州
  'ZZF': '郑州', 'ZAF': '郑州东', 'ZDF': '郑州西', 'ZNF': '郑州南',
  // 济南
  'JNK': '济南', 'JXK': '济南西', 'MDK': '济南东', 'JGK': '济南',
  // 长沙
  'CSQ': '长沙', 'CWQ': '长沙南', 'CEM': '长沙西',
  // 合肥
  'HFH': '合肥', 'HOH': '合肥南', 'HAH': '合肥北城',
  // 南昌
  'NCG': '南昌', 'NXG': '南昌西',
  // 福州
  'FZS': '福州', 'FYS': '福州南',
  // 石家庄
  'SJP': '石家庄', 'SXP': '石家庄北', 'VVP': '石家庄东',
  // 太原
  'TYV': '太原', 'TNV': '太原南',
  // 沈阳
  'SYT': '沈阳', 'SOT': '沈阳北', 'SDT': '沈阳南', 'SET': '沈阳东',
  // 长春
  'CCT': '长春', 'CRT': '长春西',
  // 哈尔滨
  'HBB': '哈尔滨', 'HKB': '哈尔滨西', 'HJB': '哈尔滨北', 'HEB': '哈尔滨东',
  // 昆明
  'KMM': '昆明', 'KOM': '昆明南',
  // 贵阳
  'GIW': '贵阳', 'KYW': '贵阳北', 'KEW': '贵阳东',
  // 南宁
  'NNZ': '南宁', 'NRZ': '南宁东',
  // 呼和浩特
  'HHC': '呼和浩特', 'NDC': '呼和浩特东',
  // 兰州
  'LZJ': '兰州', 'LAJ': '兰州西', 'LEJ': '兰州东',
  // 西宁
  'XNO': '西宁',
  // 银川
  'YCJ': '银川',
  // 乌鲁木齐
  'WMR': '乌鲁木齐', 'WAR': '乌鲁木齐南',
  // 拉萨
  'LSO': '拉萨',
  // 海口
  'VUQ': '海口', 'HMQ': '海口东',
  // 三亚
  'SEQ': '三亚', 'SYQ': '三亚',
  // 苏州
  'SZH': '苏州', 'OHH': '苏州北', 'SQH': '苏州新区',
  // 无锡
  'WXH': '无锡', 'WGH': '无锡东', 'WEH': '无锡新区',
  // 常州
  'CZH': '常州', 'CBH': '常州北',
  // 徐州
  'XCH': '徐州', 'XEH': '徐州东',
  // 宁波
  'NGH': '宁波', 'NVH': '宁波东',
  // 温州
  'WZH': '温州', 'WRH': '温州南',
  // 厦门
  'XKS': '厦门', 'XMS': '厦门北',
  // 青岛
  // 大连
  'DLT': '大连', 'DFT': '大连北',
  // 桂林
  'GLZ': '桂林', 'GIZ': '桂林北', 'GEZ': '桂林西',
  // 黄山
  'HSH': '黄山', 'GXH': '黄山北',
  // 张家界
  'ZJJ': '张家界', 'JXQ': '张家界西',
  // 洛阳
  'LYF': '洛阳', 'LDL': '洛阳龙门',
  // 宜昌
  'YCN': '宜昌', 'HAN': '宜昌东',
  // 襄阳
  // 株洲
  'ZZQ': '株洲', 'ZVQ': '株洲西',
  // 衡阳
  'HYQ': '衡阳', 'HEQ': '衡阳东',
  // 岳阳
  'YYQ': '岳阳', 'YIQ': '岳阳东',
  // 珠海
  'ZHQ': '珠海', 'ZIQ': '珠海北',
  // 佛山
  'FSQ': '佛山', 'FOQ': '佛山西',
  // 东莞
  'DRQ': '东莞', 'DAQ': '东莞东', 'RRQ': '东莞南',
  // 惠州
  'HCQ': '惠州', 'HUQ': '惠州南',
  // 汕头
  'OTQ': '汕头', 'SWQ': '汕尾',
  // 湛江
  'ZWQ': '湛江', 'ZJZ': '湛江西',
  // 柳州
  'LZZ': '柳州', 'UMZ': '柳州南',
  // 北海
  'BHZ': '北海', 'BBZ': '北海',
  // 大理
  'DLM': '大理', 'DKM': '大理',
  // 丽江
  'LJM': '丽江', 'LBM': '丽江',
  // 遵义
  'ZIW': '遵义', 'ZYW': '遵义南',
  // 绵阳
  'MYW': '绵阳', 'MZW': '绵阳',
  // 乐山
  'UTW': '乐山', 'IGW': '乐山北',
  // 唐山
  'TSP': '唐山', 'TAP': '唐山西',
  // 保定
  'BDP': '保定', 'BPP': '保定东',
  // 秦皇岛
  'QTP': '秦皇岛',
  // 烟台
  'YAK': '烟台', 'YGK': '烟台南',
  // 威海
  'WKK': '威海', 'WEK': '威海北',
  // 延吉
  'YJL': '延吉', 'YJX': '延吉西',
  // 齐齐哈尔
  'QHX': '齐齐哈尔', 'QEX': '齐齐哈尔南',
  // 牡丹江
  'MDB': '牡丹江', 'MDJ': '牡丹江',
  // 襄阳
};

export class StationCodeService {
  private static instance: StationCodeService | null = null;
  private cityIndex: Map<string, string[]> = new Map();
  private codeToNameMap: Map<string, string> = new Map();
  private initialized: boolean = false;

  static getInstance(): StationCodeService {
    if (!StationCodeService.instance) {
      StationCodeService.instance = new StationCodeService();
    }
    return StationCodeService.instance;
  }

  private constructor() {
    this.initBuiltinData();
  }

  /** 初始化内置数据 */
  private initBuiltinData(): void {
    for (const city of Object.keys(BUILTIN_STATIONS)) {
      const codes: string[] = BUILTIN_STATIONS[city];
      this.cityIndex.set(city, codes);
      // codeToName: 也建立代码→城市名的反向映射
      for (const code of codes) {
        if (!this.codeToNameMap.has(code)) {
          this.codeToNameMap.set(code, city);
        }
      }
    }
    this.initialized = true;
    Logger.info(TAG, 'Built-in stations loaded: %{public}d cities', this.cityIndex.size);
  }

  /** 根据电报码反查中文城市名 */
  getStationCity(code: string): string {
    if (!code || code.length === 0) return '';
    return this.codeToNameMap.get(code) || code;
  }

  /** 获取城市的所有车站电报码 */
  getStationCodes(cityName: string): string[] {
    if (!cityName) return [];
    const name: string = cityName.replace(/[市省]$/, '').trim();

    // 1. 精确匹配
    const codes: string[] | undefined = this.cityIndex.get(name);
    if (codes && codes.length > 0) return codes;

    // 2. 去掉"东/西/南/北/站"后缀再匹配（如"成都东"→"成都"）
    const cityCore: string = name.replace(/[东西南北站]$/, '');
    if (cityCore !== name) {
      const coreCodes: string[] | undefined = this.cityIndex.get(cityCore);
      if (coreCodes && coreCodes.length > 0) return coreCodes;
    }

    // 3. 前缀匹配（如"成都东站"→匹配"成都"）
    for (const key of this.cityIndex.keys()) {
      if (name.startsWith(key) || key.startsWith(name)) {
        const v: string[] | undefined = this.cityIndex.get(key);
        if (v && v.length > 0) return v;
      }
    }

    // 4. 模糊匹配：去掉"市"再试一次遍历
    for (const key of this.cityIndex.keys()) {
      if (key.includes(name) || name.includes(key)) {
        const v: string[] | undefined = this.cityIndex.get(key);
        if (v && v.length > 0) {
          Logger.info(TAG, 'Fuzzy matched "%{public}s" → "%{public}s"', cityName, key);
          return v;
        }
      }
    }

    Logger.warn(TAG, 'Station code not found for: %{public}s', cityName);
    return [];
  }

  /** 获取城市的主站电报码（第一个） */
  getMainStationCode(cityName: string): string {
    const codes: string[] = this.getStationCodes(cityName);
    return codes.length > 0 ? codes[0] : '';
  }

  /** 根据电报码获取城市名 */
  getCityName(code: string): string {
    if (!code || code.length === 0) return '';
    return this.codeToNameMap.get(code) || code;
  }

  /** 根据电报码反查站名：精确站名 > 城市名 > 城市+站 > 原码 */
  getStationName(code: string): string {
    if (!code || code.length === 0) return '';
    // 1. 查精确站名表
    const exact: string | undefined = CODE_TO_STATION[code];
    if (exact) return exact;
    // 2. 查城市名
    const city: string | undefined = this.codeToNameMap.get(code);
    if (city) return city;
    // 3. 遍历查找：此code属于哪个城市 → 城市+站
    for (const c of this.cityIndex.keys()) {
      const codes: string[] | undefined = this.cityIndex.get(c);
      if (codes && codes.includes(code)) return c + '站';
    }
    // 4. 最终兜底
    return code;
  }
}
