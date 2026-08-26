import 'package:flutter/material.dart';
import 'package:drift/drift.dart' as d;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';

import 'app_database.dart'; // 引入剛才自動生成成功的 Drift 資料庫
import 'price_service.dart';
import 'tw_price_service.dart';

// ⭐ 宣告全域唯一、方便跨頁面存取的 Drift SQLite 資料庫實例
late AppDatabase db;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  db = AppDatabase(); // 初始化 SQLite
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const AssetHomePage(),
    );
  }
}

// 畫面上顯示用的聚合結構模型
class AssetGroup {
  final String name;
  double totalQuantity;
  double totalCost;
  double currentPrice;

  AssetGroup({
    required this.name,
    this.totalQuantity = 0,
    this.totalCost = 0,
    this.currentPrice = 0,
  });

  double get averageCost => totalQuantity > 0 ? totalCost / totalQuantity : 0;
  double get currentMarketValue => totalQuantity * currentPrice;
}

class AssetHomePage extends StatefulWidget {
  const AssetHomePage({super.key});
  @override
  State<AssetHomePage> createState() => _AssetHomePageState();
}

// 核心資料源改為儲存由 Drift 讀出來的 InvestmentItem 列表
class _AssetHomePageState extends State<AssetHomePage> {
  List<InvestmentItem> _historyList = [];
  static final Map<String, double> _realPriceCache = {};
  bool _isLoadingPrices = false;

  // 🌟 背景定時器宣告
  Timer? _priceUpdateTimer;

  final List<Color> _chartColors = [
    Colors.blue.shade400,
    Colors.green.shade400,
    Colors.orange.shade400,
    Colors.purple.shade400,
    Colors.pink.shade400,
    Colors.teal.shade400,
  ];

  // 🎯 ⭐ 預設項目清單 (2026 最新前 20 大加密貨幣 + 美股)，用以確保「開 App 直接抓取所有預設項目」
  final List<String> _defaultSymbols = [
    'BTC',
    'ETH',
    'USDT',
    'BNB',
    'SOL',
    'XRP',
    'USDC',
    'ADA',
    'STETH',
    'DOGE',
    'WBC',
    'WETH',
    'SHIB',
    'TON',
    'DOT',
    'WBTC',
    'LINK',
    'TRX',
    'NEAR',
    'MATIC',
    'MSFT',
    'AAPL',
    'NVDA',
    'GOOGL',
    'AMZN',
    'META',
    'BRK.A',
    'LLY',
    'CLSK',
    'TSLA',
    'V',
    'JPM',
    'WMT',
    'UNH',
    'MA',
    'XOM',
    'NVO',
    'HD',
    'ASML',
    'AMD',
  ];

  final List<String> _defaultSymbolsTW = [
    // 市值前 1 - 20 名
    '2330',
    '2317',
    '0050',
    '2454',
    '2308',
    '3711',
    '2881',
    '2382',
    '2882',
    '2303',
    '2891',
    '2412',
    '0056',
    '00878',
    '2886',
    '1303',
    '2395',
    '2884',
    '3008',
    '2002',

    // // 市值前 21 - 40 名
    // '1301',
    // '2892',
    // '2912',
    // '2357',
    // '2885',
    // '00919',
    // '5880',
    // '1216',
    // '2603',
    // '3045',
    // '2327',
    // '00929',
    // '2880',
    // '2609',
    // '4904',
    // '2887',
    // '3037',
    // '2345',
    // '2207',
    // '2883',

    // // 市值前 41 - 60 名
    // '3231',
    // '2888',
    // '2379',
    // '2801',
    // '6669',
    // '3017',
    // '2408',
    // '1101',
    // '006208',
    // '2356',
    // '2615',
    // '5876',
    // '2409',
    // '2301',
    // '6515',
    // '2809',
    // '4938',
    // '2383',
    // '6488',
    // '5274',

    // // 市值前 61 - 80 名
    // '2324',
    // '1326',
    // '2105',
    // '9904',
    // '2610',
    // '2618',
    // '1402',
    // '5871',
    // '6239',
    // '1503',
    // '2377',
    // '2353',
    // '6415',
    // '1605',
    // '00940',
    // '2474',
    // '2812',
    // '3443',
    // '2059',
    // '1102',

    // // 市值前 81 - 100 名
    // '2347',
    // '2845',
    // '6770',
    // '8046',
    // '3702',
    // '2360',
    // '9945',
    // '2903',
    // '9910',
    // '2498',
    // '2302',
    // '2834',
    // '1504',
    // '2352',
    // '6213',
    // '2376',
    // '3034',
    // '1802',
    // '5434',
    // '2385',
  ];

  @override
  void initState() {
    super.initState();
    _initAppTimeline();
  }

  // ⭐ 離線優先高規格時序管理
  void _initAppTimeline() async {
    await _loadDataAndLocalPrices(); // 🛠️ 1. 先讀取 SQLite (開屏秒開，畫面不卡頓)
    _loadDataAndRefreshPrices(); // 🌐 2. 隨後開機直衝網路：全自動去 GitHub 撈取「所有預設項目」的最新單價
    _start1HourTimer(); // ⏱️ 3. 啟動 1 小時背景定時循環更新
  }

  // 🌟 啟動 1 小時自動循環計時器
  void _start1HourTimer() {
    _priceUpdateTimer?.cancel();
    _priceUpdateTimer = Timer.periodic(const Duration(hours: 1), (timer) {
      if (kDebugMode) {
        print('⏱️ [定時器] 1 小時已到，啟動背景全預設項目行情自動更新程序...');
      }
      _loadDataAndRefreshPrices();
    });
  }

  @override
  void dispose() {
    _priceUpdateTimer?.cancel(); // 🛠️ 記憶體防洩漏釋放
    super.dispose();
  }

  // A. 純讀取本地 SQLite（包含流水帳與先前快取的市價）
  Future<void> _loadDataAndLocalPrices() async {
    final items = await db.getAllInvestmentItems();
    final cachedPrices = await db.select(db.marketPriceCaches).get();

    setState(() {
      _historyList = items.reversed.toList();
      for (var cache in cachedPrices) {
        _realPriceCache[cache.symbol] = cache.price; // 還原記憶體快取
      }
    });
    if (kDebugMode) {
      print('💾 [離線讀取] 順利引渡本地硬碟快取的歷史市價，畫面載入完成。');
    }
  }

  // B. 純本地重整（從子網頁返回首頁時呼叫，完全阻斷網路網路請求）
  Future<void> _loadLocalDataOnly() async {
    final items = await db.getAllInvestmentItems();
    setState(() {
      _historyList = items.reversed.toList();
    });
    if (kDebugMode) {
      print('🏠 [回到首頁] 僅刷新本地交易記錄明細，拒絕戳網路 API。');
    }
  }

  // C. 🌐 核心網路更新：遍歷所有預設的 40 大金融項目進行全面撈取與持久化備份
  Future<void> _loadDataAndRefreshPrices() async {
    final items = await db.getAllInvestmentItems();
    setState(() {
      _historyList = items.reversed.toList();
    });

    setState(() => _isLoadingPrices = true);
    final List<MarketPriceCache> dbCacheList = [];
    if (kDebugMode) {
      print('🌐 [網路同步] 開始非同步撈取 40 大預設資產項目的最新 GitHub JSON 行情...');
    }
    // ⭐ 機械式遍歷所有 40 大預設代號，不論使用者買過與否，通通抓回來
    for (var name in _defaultSymbols) {
      double price = await PriceService.getRealMarketPrice(name);
      if (price > 0) {
        _realPriceCache[name] = price; // 更新記憶體，隨時供圓餅圖渲染

        dbCacheList.add(
          MarketPriceCache(
            symbol: name,
            price: price,
            updatedAt: DateTime.now(),
          ),
        );
      }
    }

    // ⭐ 機械式遍歷所有 40 大預設代號，不論使用者買過與否，通通抓回來
    for (var name in _defaultSymbolsTW) {
      double price = await PriceServiceTW.getRealMarketPrice(name);
      price = price / 31;
      // if (kDebugMode) {
      //   print('dbCacheList之前,除31後 $name , $price');
      // }
      if (price > 0) {
        _realPriceCache[name] = price; // 更新記憶體，隨時供圓餅圖渲染

        dbCacheList.add(
          MarketPriceCache(
            symbol: name,
            price: price,
            updatedAt: DateTime.now(),
          ),
        );
      }
    }

    // 將最新抓到的 40 大預設項目市價批次壓入手機 SQLite 存檔
    if (dbCacheList.isNotEmpty) {
      await db.saveMarketPrices(dbCacheList);
      if (kDebugMode) {
        print('🚀 [SQLite 備份成功] 全數預設項目的最新市價已穩健寫入手機硬碟。');
      }
    }

    if (mounted) {
      setState(() => _isLoadingPrices = false);
    }
  }

  double _getCurrentPrice(String name, double averageCost) {
    final key = name.trim().toUpperCase();
    return _realPriceCache[key] ?? averageCost;
  }

  List<AssetGroup> _getAggregatedAssets() {
    final Map<String, AssetGroup> groups = {};
    for (var item in _historyList) {
      final key = item.name.trim().toUpperCase();
      if (key.isEmpty) continue;
      if (!groups.containsKey(key)) groups[key] = AssetGroup(name: key);
      groups[key]!.totalQuantity += item.quantity;
      groups[key]!.totalCost += item.totalAmount;
    }
    groups.forEach((key, group) {
      group.currentPrice = _getCurrentPrice(group.name, group.averageCost);
    });
    final List<AssetGroup> sortedList = groups.values.toList();
    sortedList.sort(
      (a, b) => b.currentMarketValue.compareTo(a.currentMarketValue),
    );
    return sortedList;
  }

  Future<bool> _showDeleteConfirmDialog(
    BuildContext context,
    InvestmentItem item,
  ) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning, color: Colors.red),
                SizedBox(width: 8),
                Text('確認刪除'),
              ],
            ),
            content: Text('您確定要刪除此筆【${item.name.toUpperCase()}】的購入紀錄嗎？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('確定刪除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  List<PieChartSectionData> _getChartSections(
    List<AssetGroup> assets,
    double globalTotalValue,
  ) {
    if (globalTotalValue == 0) return [];
    return List.generate(assets.length, (i) {
      final asset = assets[i];
      final percentage = (asset.currentMarketValue / globalTotalValue) * 100;
      return PieChartSectionData(
        color: _chartColors[i % _chartColors.length],
        value: asset.currentMarketValue,
        title: '${asset.name}\n${percentage.toStringAsFixed(1)}%',
        radius: 55,
        titleStyle: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final aggregatedAssets = _getAggregatedAssets();
    double globalTotalCost = 0;
    double globalCurrentValue = 0;
    for (var group in aggregatedAssets) {
      globalTotalCost += group.totalCost;
      globalCurrentValue += group.currentMarketValue;
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('投資資產管理'),
              const SizedBox(width: 8),
              _isLoadingPrices
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: _loadDataAndRefreshPrices,
                    ),
            ],
          ),
          centerTitle: true,
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.pie_chart), text: '資產分類統計'),
              Tab(icon: Icon(Icons.history), text: '歷史購入明細'),
              Tab(icon: Icon(Icons.analytics), text: '圖表走勢分析'),
            ],
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                color: Colors.indigo,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildGlobalInfo(
                        '總投入成本',
                        '\$${globalTotalCost.toStringAsFixed(0)}',
                      ),
                      _buildGlobalInfo(
                        '目前總價值',
                        '\$${globalCurrentValue.toStringAsFixed(0)}',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TabBarView(
                  children: [
                    // --- 分頁 1：資產分類統計 ---
                    Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const EditAssetPage(),
                                ),
                              );
                              _loadLocalDataOnly();
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('增加購入資產'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: aggregatedAssets.isEmpty
                              ? const Center(child: Text('暫無資產，請點選上方按鈕新增'))
                              : ListView.builder(
                                  itemCount: aggregatedAssets.length,
                                  itemBuilder: (context, index) {
                                    final group = aggregatedAssets[index];
                                    double roi = group.totalCost > 0
                                        ? ((group.currentMarketValue -
                                                      group.totalCost) /
                                                  group.totalCost) *
                                              100
                                        : 0;
                                    final indicatorColor =
                                        _chartColors[index %
                                            _chartColors.length];

                                    return Card(
                                      margin: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(12),
                                        onTap: () async {
                                          await Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  AssetDetailPage(
                                                    assetGroupName: group.name,
                                                    initialCurrentPrice:
                                                        group.currentPrice,
                                                  ),
                                            ),
                                          );
                                          _loadLocalDataOnly();
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.all(12.0),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Row(
                                                    children: [
                                                      Container(
                                                        width: 12,
                                                        height: 12,
                                                        decoration:
                                                            BoxDecoration(
                                                              color:
                                                                  indicatorColor,
                                                              shape: BoxShape
                                                                  .circle,
                                                            ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Text(
                                                        group.name,
                                                        style: const TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: Colors.indigo,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  Row(
                                                    children: [
                                                      Text(
                                                        '報酬率: ${roi >= 0 ? "+" : ""}${roi.toStringAsFixed(2)}%',
                                                        style: TextStyle(
                                                          color: roi >= 0
                                                              ? Colors.green
                                                              : Colors.red,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          fontSize: 13,
                                                        ),
                                                      ),
                                                      const Icon(
                                                        Icons.chevron_right,
                                                        color: Colors.grey,
                                                        size: 20,
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  left: 20.0,
                                                ),
                                                child: Text(
                                                  '目前市價: \$${group.currentPrice.toStringAsFixed(group.currentPrice < 2 ? 4 : 2)}',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey.shade700,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                              const Divider(height: 12),
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  _buildAssetDetailItem(
                                                    '目前數量',
                                                    group.totalQuantity
                                                        .toStringAsFixed(2),
                                                  ),
                                                  _buildAssetDetailItem(
                                                    '平均成本',
                                                    '\$${group.averageCost.toStringAsFixed(2)}',
                                                  ),
                                                  _buildAssetDetailItem(
                                                    '剩餘價值',
                                                    '\$${group.currentMarketValue.toStringAsFixed(0)}',
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),

                    // --- 分頁 2：歷史購買明細 ---
                    Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const EditAssetPage(),
                                ),
                              );
                              _loadLocalDataOnly();
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('增加購入資產'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: _historyList.isEmpty
                              ? const Center(child: Text('暫無購入明細'))
                              : ListView.builder(
                                  itemCount: _historyList.length,
                                  itemBuilder: (context, index) {
                                    final item = _historyList[index];
                                    return Card(
                                      margin: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      child: ListTile(
                                        title: Text(
                                          item.name.toUpperCase(),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        subtitle: Text(
                                          '${item.date.year}-${item.date.month}-${item.date.day}',
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  '總額: \$${item.totalAmount.toStringAsFixed(0)}',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                Text(
                                                  '價格: \$${item.price} | 數量: ${item.quantity}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.edit,
                                                color: Colors.blue,
                                                size: 20,
                                              ),
                                              onPressed: () async {
                                                await Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (context) =>
                                                        EditAssetPage(
                                                          itemIdToEdit: item.id,
                                                        ),
                                                  ),
                                                );
                                                _loadLocalDataOnly();
                                              },
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete,
                                                color: Colors.red,
                                                size: 20,
                                              ),
                                              onPressed: () async {
                                                bool confirm =
                                                    await _showDeleteConfirmDialog(
                                                      context,
                                                      item,
                                                    );
                                                if (confirm) {
                                                  await db.deleteInvestmentItem(
                                                    item.id,
                                                  );
                                                  _loadLocalDataOnly();
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),

                    // --- 分頁 3：圖表比例分析 ---
                    aggregatedAssets.isEmpty
                        ? const Center(child: Text('暫無資料可生成圖表，請先新增資產'))
                        : SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 16),
                                const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 8.0,
                                  ),
                                  child: Text(
                                    '📊 當前資產比例分佈',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Container(
                                  height: 220,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  child: PieChart(
                                    PieChartData(
                                      sectionsSpace: 2,
                                      centerSpaceRadius: 40,
                                      sections: _getChartSections(
                                        aggregatedAssets,
                                        globalCurrentValue,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGlobalInfo(String title, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildAssetDetailItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
} // 👈 結束 AssetHomePage 的 State 類別

// =========================================================================
// 4. 單一資產詳情頁面 (Drift SQLite 版)
// =========================================================================
class AssetDetailPage extends StatefulWidget {
  final String assetGroupName;
  final double initialCurrentPrice;
  const AssetDetailPage({
    super.key,
    required this.assetGroupName,
    required this.initialCurrentPrice,
  });

  @override
  State<AssetDetailPage> createState() => _AssetDetailPageState();
}

class _AssetDetailPageState extends State<AssetDetailPage> {
  List<InvestmentItem> _localHistory = [];

  @override
  void initState() {
    super.initState();
    _loadLocalGroupData();
  }

  // 改用 Drift + SQL 條件篩選，撈出特定項目的流水帳
  Future<void> _loadLocalGroupData() async {
    final items =
        await (db.select(db.investmentItems)..where(
              (t) => t.name.upper().equals(widget.assetGroupName.toUpperCase()),
            ))
            .get();
    setState(() {
      _localHistory = items.reversed.toList();
    });
  }

  // 計算該單一資產的加總統計數據
  AssetGroup _calculateLocalGroup() {
    AssetGroup group = AssetGroup(name: widget.assetGroupName);
    for (var item in _localHistory) {
      group.totalQuantity += item.quantity;
      group.totalCost += item.totalAmount;
    }
    group.currentPrice = widget.initialCurrentPrice;
    return group;
  }

  @override
  Widget build(BuildContext context) {
    final assetGroup = _calculateLocalGroup();
    return Scaffold(
      appBar: AppBar(title: Text('${assetGroup.name} 資產詳情'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 單一項目專屬數據看板
            Card(
              color: Colors.indigo.shade800,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildDetailHeader(
                          '資產總價值',
                          '\$${assetGroup.currentMarketValue.toStringAsFixed(0)}',
                        ),
                        _buildDetailHeader(
                          '投入總成本',
                          '\$${assetGroup.totalCost.toStringAsFixed(0)}',
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white24, height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildDetailHeader(
                          '持有總數量',
                          assetGroup.totalQuantity.toStringAsFixed(4),
                          isSmall: true,
                        ),
                        _buildDetailHeader(
                          '平均購入成本',
                          '\$${assetGroup.averageCost.toStringAsFixed(2)}',
                          isSmall: true,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '該項目歷史投入明細',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _localHistory.isEmpty
                  ? const Center(child: Text('此資產項目已無明細'))
                  : ListView.builder(
                      itemCount: _localHistory.length,
                      itemBuilder: (context, index) {
                        final item = _localHistory[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            leading: const Icon(
                              Icons.arrow_downward,
                              color: Colors.green,
                            ),
                            title: Text('買入價格: \$${item.price}'),
                            subtitle: Text(
                              '數量: ${item.quantity}\n日期: ${item.date.year}-${item.date.month}-${item.date.day}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '\$${item.totalAmount.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit,
                                    color: Colors.blue,
                                    size: 20,
                                  ),
                                  onPressed: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => EditAssetPage(
                                          itemIdToEdit: item.id,
                                        ),
                                      ),
                                    );
                                    _loadLocalGroupData();
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                    size: 20,
                                  ),
                                  onPressed: () async {
                                    bool confirm =
                                        await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('確認刪除'),
                                            content: const Text(
                                              '確定要刪除這筆購入紀錄嗎？',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, false),
                                                child: const Text('取消'),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, true),
                                                style: TextButton.styleFrom(
                                                  foregroundColor: Colors.red,
                                                ),
                                                child: const Text('刪除'),
                                              ),
                                            ],
                                          ),
                                        ) ??
                                        false;
                                    if (confirm) {
                                      await db.deleteInvestmentItem(item.id);
                                      _loadLocalGroupData();
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey.shade200,
                  foregroundColor: Colors.black87,
                ),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.home),
                label: const Text(
                  '回到首頁看板',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailHeader(
    String title,
    String value, {
    bool isSmall = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: Colors.white70, fontSize: isSmall ? 12 : 14),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

// =========================================================================
// 5. 編輯與新增通用頁面 (Drift SQLite 版)
// =========================================================================
class EditAssetPage extends StatefulWidget {
  final int? itemIdToEdit; // SQLite 主鍵為標準的 int 型態
  const EditAssetPage({super.key, this.itemIdToEdit});

  @override
  State<EditAssetPage> createState() => _EditAssetPageState();
}

class _EditAssetPageState extends State<EditAssetPage> {
  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  final _quantityController = TextEditingController();
  final _amountController = TextEditingController();
  final SearchController _searchController = SearchController();
  bool _isCalculating = false;
  InvestmentItem? _loadedItem;

  final List<String> _cryptoTop20 = [
    'BTC',
    'ETH',
    'USDT',
    'BNB',
    'SOL',
    'XRP',
    'USDC',
    'ADA',
    'STETH',
    'DOGE',
    'WBC',
    'WETH',
    'SHIB',
    'TON',
    'DOT',
    'WBTC',
    'LINK',
    'TRX',
    'NEAR',
    'MATIC',
  ];
  final List<String> _stockTop20 = [
    'MSFT',
    'AAPL',
    'NVDA',
    'GOOGL',
    'AMZN',
    'META',
    'BRK.A',
    'LLY',
    'CLSK',
    'TSLA',
    'V',
    'JPM',
    'WMT',
    'UNH',
    'MA',
    'XOM',
    'NVO',
    'HD',
    'ASML',
    'AMD',
  ];
  final List<String> _stockTWTop100 = [
    // 市值前 1 - 20 名
    '2330',
    // '2317',
    '0050',
    '2454',
    // '2308',
    // '3711',
    // '2881',
    // '2382',
    // '2882',
    // '2303',
    // '2891',
    // '2412',
    '0056',
    // '00878',
    // '2886',
    // '1303',
    // '2395',
    // '2884',
    // '3008',
    // '2002',

    // // 市值前 21 - 40 名
    // '1301',
    // '2892',
    // '2912',
    // '2357',
    // '2885',
    // '00919',
    // '5880',
    // '1216',
    // '2603',
    // '3045',
    // '2327',
    // '00929',
    // '2880',
    // '2609',
    // '4904',
    // '2887',
    // '3037',
    // '2345',
    // '2207',
    // '2883',

    // // 市值前 41 - 60 名
    // '3231',
    // '2888',
    // '2379',
    // '2801',
    // '6669',
    // '3017',
    // '2408',
    // '1101',
    // '006208',
    // '2356',
    // '2615',
    // '5876',
    // '2409',
    // '2301',
    // '6515',
    // '2809',
    // '4938',
    // '2383',
    // '6488',
    // '5274',

    // // 市值前 61 - 80 名
    // '2324',
    // '1326',
    // '2105',
    // '9904',
    // '2610',
    // '2618',
    // '1402',
    // '5871',
    // '6239',
    // '1503',
    // '2377',
    // '2353',
    // '6415',
    // '1605',
    // '00940',
    // '2474',
    // '2812',
    // '3443',
    // '2059',
    // '1102',

    // // 市值前 81 - 100 名
    // '2347',
    // '2845',
    // '6770',
    // '8046',
    // '3702',
    // '2360',
    // '9945',
    // '2903',
    // '9910',
    // '2498',
    // '2302',
    // '2834',
    // '1504',
    // '2352',
    // '6213',
    // '2376',
    // '3034',
    // '1802',
    // '5434',
    // '2385',
  ];

  String? _selectedSymbol;
  bool get isEditMode => widget.itemIdToEdit != null;
  ///////////////
  // 🌟 新增：智慧判定價格獲取器（優先讀取記憶體快取，查無則提示）
  String _getCurrentMarketPriceForForm(String symbolKey) {
    final key = symbolKey.trim().toUpperCase();

    // 🎯 智慧判定：檢查首頁全域的靜態記憶體快取中是否存在此代號的價格
    if (_AssetHomePageState._realPriceCache.containsKey(key)) {
      final double cachedPrice = _AssetHomePageState._realPriceCache[key]!;
      if (cachedPrice > 0) {
        // 根據價格大小自動決定小數點位數
        return '\$${cachedPrice.toStringAsFixed(cachedPrice < 2 ? 4 : 2)}';
      }
    }

    // 🎯 找不到最近一次價格時的安全閥回傳文字
    return '尚未取得最近一次價格';
  }

  ////////////////
  ///
  // 🌟 修改：直接存放對應的價格與整份 JSON 最上層的 last_updated 時間字串
  double? _fetchedPrice;
  String? _lastUpdatedTimeStr;
  bool _isFetchingLocalPrice = false;

  // 🌟 核心非同步反查：當使用者一選定項目，立刻去 SQLite 挖出上一次的價格與更新時間
  Future<void> _loadSelectedMarketPriceInfo(String symbolKey) async {
    if (_isFetchingLocalPrice) return;

    setState(() {
      _isFetchingLocalPrice = true;
      _fetchedPrice = null;
      _lastUpdatedTimeStr = null;
    });

    final key = symbolKey.trim().toUpperCase();

    // 🎯 透過 Drift 從 SQLite 快取表中精準捕捉該標的的價格與更新時間
    final record = await (db.select(
      db.marketPriceCaches,
    )..where((t) => t.symbol.equals(key))).getSingleOrNull();

    if (mounted) {
      setState(() {
        if (record != null) {
          _fetchedPrice = record.price;

          // 🎯 將資料庫儲存的 updatedAt 轉化為格式化字串
          final time = record.updatedAt;
          final String formattedMonth = time.month.toString().padLeft(2, '0');
          final String formattedDay = time.day.toString().padLeft(2, '0');
          //final String formattedHour = time.hour.toString().padLeft(2, '0');
          //final String formattedMinute = time.minute.toString().padLeft(2, '0');

          _lastUpdatedTimeStr = '$formattedMonth/$formattedDay';
          //'$formattedMonth/$formattedDay $formattedHour:$formattedMinute';
        }
        _isFetchingLocalPrice = false;
      });
    }
  }

  ///
  @override
  void initState() {
    super.initState();
    _initFields();
    _priceController.addListener(_calculateTotalAmount);
    _quantityController.addListener(_calculateTotalAmount);
    _amountController.addListener(_calculateQuantity);
  }

  // 改用 Drift 從 SQLite 抓出舊物件資料
  void _initFields() async {
    if (isEditMode) {
      final item = await (db.select(
        db.investmentItems,
      )..where((t) => t.id.equals(widget.itemIdToEdit!))).getSingleOrNull();
      if (item != null) {
        setState(() {
          _loadedItem = item;
          _nameController.text = item.name;
          _selectedSymbol = item.name.trim().toUpperCase();
          _searchController.text = _selectedSymbol!;
          _priceController.text = item.price.toString();
          _quantityController.text = item.quantity.toString();
          _amountController.text = item.totalAmount.toString();
        });
      }
    }
  }

  void _calculateTotalAmount() {
    if (_isCalculating) return;
    _isCalculating = true;
    double price = double.tryParse(_priceController.text) ?? 0;
    double quantity = double.tryParse(_quantityController.text) ?? 0;
    if (price > 0 && quantity > 0) {
      _amountController.text = (price * quantity).toStringAsFixed(2);
    }
    _isCalculating = false;
  }

  // 模式 B：當輸入總投資額與買入價格，自動反推購買數量
  void _calculateQuantity() {
    if (_isCalculating) return;
    _isCalculating = true;
    double price = double.tryParse(_priceController.text) ?? 0;
    double amount = double.tryParse(_amountController.text) ?? 0;
    if (price > 0 && amount > 0) {
      _quantityController.text = (amount / price).toStringAsFixed(4);
    }
    _isCalculating = false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
    _quantityController.dispose();
    _amountController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> allAllowedSymbols = [
      ..._cryptoTop20,
      ..._stockTop20,
      ..._stockTWTop100,
    ].toSet().toList();
    allAllowedSymbols.sort();

    return Scaffold(
      appBar: AppBar(title: Text(isEditMode ? '修改購入明細' : '新增購入資產')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '投資標的項目 (點擊可輸入關鍵字搜尋)',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.indigo,
              ),
            ),
            const SizedBox(height: 8),
            SearchAnchor(
              searchController: _searchController,
              builder: (BuildContext context, SearchController controller) {
                return SearchBar(
                  controller: controller,
                  hintText: '請輸入關鍵字搜尋 (如 BTC, TSLA)',
                  padding: const WidgetStatePropertyAll<EdgeInsets>(
                    EdgeInsets.symmetric(horizontal: 16.0),
                  ),
                  enabled: !isEditMode,
                  onTap: () => controller.openView(),
                  leading: const Icon(Icons.search, color: Colors.indigo),
                  trailing: _selectedSymbol != null && !isEditMode
                      ? [
                          IconButton(
                            icon: const Icon(Icons.clear, color: Colors.grey),
                            onPressed: () {
                              controller.clear();
                              setState(() => _selectedSymbol = null);
                            },
                          ),
                        ]
                      : null,
                );
              },
              suggestionsBuilder:
                  (BuildContext context, SearchController controller) {
                    final String inputKeyword = controller.text
                        .trim()
                        .toUpperCase();
                    final List<String> filteredList = allAllowedSymbols
                        .where((String symbol) => symbol.contains(inputKeyword))
                        .toList();
                    if (filteredList.isEmpty) {
                      return [const ListTile(title: Text('查無符合標的'))];
                    }
                    return filteredList.map((String symbol) {
                      final isCrypto = _cryptoTop20.contains(symbol);
                      return ListTile(
                        leading: Icon(
                          isCrypto ? Icons.currency_bitcoin : Icons.trending_up,
                          color: isCrypto ? Colors.orange : Colors.green,
                        ),
                        title: Text(
                          symbol,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: () {
                          setState(() {
                            _selectedSymbol = symbol;
                            _nameController.text = symbol;
                            controller.closeView(symbol);
                          });
                          // 🎯 ⭐ 修正點：選定項目後，立刻發動非同步 SQLite 硬碟反查，撈取時間與單價
                          _loadSelectedMarketPriceInfo(symbol);
                        },
                      );
                    }).toList();
                  },
            ),
            const SizedBox(height: 20),

            // 🎯 ⭐ 智慧型雙欄位（價格 ＋ 統一 last_updated 時間）動態渲染看板
            if (_selectedSymbol != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0, left: 4.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.monetization_on,
                      color: Colors.orange,
                      size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '目前市場參考價：',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    _isFetchingLocalPrice
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : Builder(
                            builder: (context) {
                              // 💡 智慧型判定：如果快取內有價格且大於 0，就漂亮展現數字與最後更新時間
                              if (_fetchedPrice != null &&
                                  _fetchedPrice! > 0 &&
                                  _lastUpdatedTimeStr != null) {
                                return Row(
                                  children: [
                                    Text(
                                      '\$${_fetchedPrice!.toStringAsFixed(_fetchedPrice! < 2 ? 4 : 2)} ',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Colors.indigo,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    // 🎯 緊跟在價格後面的精美小字時間戳印
                                    Text(
                                      '($_lastUpdatedTimeStr 同步市場價格)',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500,
                                        fontWeight: FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                );
                              }

                              // 💡 找不到價格時，誠實地顯示灰色斜體文字
                              return Text(
                                '尚未取得最近一次價格',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade600,
                                  fontStyle: FontStyle.italic,
                                ),
                              );
                            },
                          ),
                  ],
                ),
              ),

            TextField(
              controller: _priceController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '買入價格(USD)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _quantityController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '數量(股)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '總投資額(USD)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () async {
                  if (_selectedSymbol == null ||
                      _priceController.text.isEmpty ||
                      _quantityController.text.isEmpty) {
                    return;
                  }

                  if (isEditMode && _loadedItem != null) {
                    // 使用 Drift 執行 SQLite 舊資料覆寫更新 (Replace)
                    await db.updateInvestmentItem(
                      _loadedItem!.copyWith(
                        price: double.parse(_priceController.text),
                        quantity: double.parse(_quantityController.text),
                        totalAmount: double.parse(_amountController.text),
                      ),
                    );
                  } else {
                    // 使用 Drift 執行 SQLite 全新插入 (Insert)
                    await db.insertInvestmentItem(
                      InvestmentItemsCompanion.insert(
                        name: _selectedSymbol!,
                        price: double.parse(_priceController.text),
                        quantity: double.parse(_quantityController.text),
                        totalAmount: double.parse(_amountController.text),
                        date: DateTime.now(),
                      ),
                    );
                  }
                  if (mounted) Navigator.pop(context);
                },
                child: Text(isEditMode ? '儲存修改' : '確認送出'),
              ),
            ),
          ],
        ),
      ),
    );
  }
} // 👈 整份 main.dart 專案檔案在這裡畫下完美句點
