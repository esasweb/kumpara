import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/app_api.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:upgrader/upgrader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:app_settings/app_settings.dart';
import 'package:in_app_review/in_app_review.dart';



const String _kOneSignalIdStorageKey = 'onesignal_id';
const String _kUserIdStorageKey = 'user_id';
const String _kSyncDoneKey =
    'onesignal_sync_done'; // Aynı çift için tekrar alert göstermemek için

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
 // Status bar simgelerini BEYAZ yapar
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light, // Android için beyaz
    statusBarBrightness: Brightness.dark,      // iOS için beyaz
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  
  // Ekranın en altına kadar yayılmayı zorla
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); 

  await MobileAds.instance.initialize();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };

  OneSignal.initialize('c19bfcc0-96e5-43ae-b482-f38b2be22b76');

  OneSignal.User.addObserver((OSUserChangedState state) {
    final id = state.current.onesignalId;
    if (id != null && id.isNotEmpty) {
      _saveOneSignalIdAndNotify(id);
    }
  });

  runApp(const MyApp());
}



Future<void> requestNotificationPermission(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final String lastPromptKey = 'last_notification_prompt_date';
  final String today = DateTime.now().toIso8601String().split('T')[0];

  // 1. ADIM: Bugün zaten sorduk mu? (En başa aldık)
  final String? lastPromptDate = prefs.getString(lastPromptKey);
  if (lastPromptDate == today) {
    debugPrint("Bildirim izni bugün zaten soruldu.");
    return; 
  }

  // 2. ADIM: Mevcut izin durumunu kontrol et (Sormadan önce)
  bool hasPermission = OneSignal.Notifications.permission;
  if (hasPermission) return; // Zaten izin var, bir şey yapma.

  // 3. ADIM: Bugün sormadıysak ve izin yoksa, SİSTEM penceresini aç
  // Not: Kullanıcı daha önce "Asla" dediyse bu pencere açılmaz, direkt false döner.
  bool result = await OneSignal.Notifications.requestPermission(true);

  // 4. ADIM: Eğer sistem penceresinde reddettiyse veya daha önce reddetmişse
  if (!result) {
    if (context.mounted) {
      // Bugün sorduğumuzu kaydedelim (Diyaloğu göstersek de göstermesek de)
      await prefs.setString(lastPromptKey, today);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text("Bildirimler Kapalı!"),
          content: const Text(
            "Görev ve kanıt bildirimleri için bildirim izni vermeniz gerekir. Lütfen ayarlardan bildirimleri açın.",
          ),
          actions: [  
            TextButton(
              child: const Text("Kapat"),
              onPressed: () => Navigator.pop(context),
            ),
            ElevatedButton(
            child: const Text("Ayarlara Git"),
  onPressed: () {
    Navigator.pop(context);
    // Bu komut, kullanıcıyı hiiiç soru sormadan direkt 
    // telefonun Ayarlar > Kumpara sayfasına ışınlar.
    AppSettings.openAppSettings(type: AppSettingsType.notification);
  },
            ),
          ],
        ),
      );
    }
  }
}

 
void _saveOneSignalIdAndNotify(String id) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kOneSignalIdStorageKey, id);

  await _syncOneSignalIdToBackendIfReady();
}

/// Hem user_id hem onesignal_id storage'da varsa Laravel API'ye gönderir; sonucu syncResultToShowModal ile UI'da alert olarak gösterir
Future<void> _syncOneSignalIdToBackendIfReady() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_kUserIdStorageKey);
    final onesignalId = prefs.getString(_kOneSignalIdStorageKey);
    if (userId == null ||
        userId.isEmpty ||
        onesignalId == null ||
        onesignalId.isEmpty) {
      return;
    }

    // Aynı çift için tekrar istek atmayı önle (isteği yine at, sadece alert tekrarlanmasın istersen bu satırı kaldır)
    final syncKey = '$userId-$onesignalId';
    if (prefs.getString(_kSyncDoneKey) == syncKey) {
      return;
    }

    final uri = Uri.parse('${AppApi.baseUrl}/api/mobile/update-onesignal-id');
    final res = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'X-API-Key': AppApi.apiSecret,
          },
          body: jsonEncode({'user_id': userId, 'onesignal_id': onesignalId}),
        )
        .timeout(const Duration(seconds: 10));

    if (res.statusCode == 200) {
      await prefs.setString(_kSyncDoneKey, '$userId-$onesignalId');
     
      debugPrint('OneSignal ID backend ile eşlendi: user_id=$userId');
    } else {
   
      debugPrint('OneSignal sync API hatası: ${res.statusCode} ${res.body}');
    }
  } catch (e) {
   
    debugPrint('OneSignal sync istisna: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override // Sadece bir tane override olmalı
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kumpara',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('tr', 'TR'), 
        Locale('en', 'US'),
      ],
      locale: const Locale('tr', 'TR'), 
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const WebViewPage(),
    );
  }
}

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver{
  static const String _initialUrl = 'https://www.kumpara.com.tr/mobil/';
  late final WebViewController _controller;
  bool _isLoading = true;
StreamSubscription<Uri>? _sub;
InterstitialAd? _interstitialAd;
RewardedAd? _rewardedAd;

int _pageCount = 0;
int _adsShown = 0;

bool _adsEnabled = false;
int _interstitialEvery = 10;
int _maxAdsPerSession = 3;
int _minSecondsBetweenAds = 90;
bool _appOpenEnabled = false;
int _appOpenCooldown = 30;

// Eski banner değişkenlerini sil, bunları ekle:
final Map<String, BannerAd?> _bannerAds = {};
final Map<String, bool> _isAdLoaded = {};
final Map<String, bool> _showAd = {};
final Map<String, Offset> _adPositions = {};

// Boyut tanımları
// Mevcut _adSizes haritasını şu şekilde güncelle:
final Map<String, AdSize> _adSizes = {
  'bannerreklam1': AdSize.mediumRectangle,
  'bannerreklam2': AdSize.banner,
  'bannerreklam3': AdSize.largeBanner,
  'bannerreklam4': AdSize.banner,
  'bannerreklam5': AdSize.banner, // 50px yükseklik için standart banner
};
 
void _preloadAllBanners() {
    _adSizes.forEach((id, size) {
      _bannerAds[id] = BannerAd(
        adUnitId: Platform.isAndroid 
            ? 'ca-app-pub-6275851890605245/6372884572' 
            : 'ca-app-pub-6275851890605245/9377275683',
        size: size,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (ad) => setState(() => _isAdLoaded[id] = true),
          onAdFailedToLoad: (ad, error) {
            ad.dispose();
            debugPrint("$id yüklenemedi: ${error.message}");
          },
        ),
      )..load();
    });
  }

DateTime _lastAdTime = DateTime.now();

String get adUnitId {
  if (Platform.isAndroid) {
    return 'ca-app-pub-6275851890605245/7689194073';
  } else if (Platform.isIOS) {
    return 'ca-app-pub-6275851890605245/6248862156';
  } else {
    throw UnsupportedError("Unsupported platform");
  }
}


 
String get _storeUrl {
  if (Platform.isAndroid) {
    // Buraya kendi Google Play linkini yapıştır
    return 'https://play.google.com/store/apps/details?id=net.kumpara.app';
  } else if (Platform.isIOS) {
    // Buraya kendi App Store linkini yapıştır
    return 'https://apps.apple.com/tr/app/kumpara-g%C3%B6rev-yap-kazan/id6760625142?l=tr';
  }
  return 'https://kumpara.com.tr/indir';
}


// --- APP OPEN REKLAM DEĞİŞKENLERİ ---
AppOpenAd? _appOpenAd;
bool _isAppOpenAdLoading = false;
DateTime? _lastAppOpenAdShownTime;

String get appOpenAdUnitId {
  if (Platform.isAndroid) {
    return 'ca-app-pub-6275851890605245/4049081947'; // Görseldeki Android ID
  } else if (Platform.isIOS) {
    return 'ca-app-pub-6275851890605245/8084529874'; // Görseldeki iOS ID
  }
  return '';
}

// Reklamı yükle (Pre-load)
void _loadAppOpenAd() {
  if (_isAppOpenAdLoading) return;
  _isAppOpenAdLoading = true;

  AppOpenAd.load(
    adUnitId: appOpenAdUnitId,
    request: const AdRequest(),
    adLoadCallback: AppOpenAdLoadCallback(
      onAdLoaded: (ad) {
        _appOpenAd = ad;
        _isAppOpenAdLoading = false;
      },
      onAdFailedToLoad: (error) {
        _isAppOpenAdLoading = false;
        _appOpenAd = null;
      },
    ),
  );
}

// Reklamı göster (Ayarlara göre)
void _showAppOpenAdIfReady() {
  if (!_appOpenEnabled) return; // Sunucudan gelen kilit kapalıysa çık
  if (_appOpenAd == null) {
    _loadAppOpenAd();
    return;
  }

  // Cooldown (Soğuma) Kontrolü
  if (_lastAppOpenAdShownTime != null) {
    final diff = DateTime.now().difference(_lastAppOpenAdShownTime!).inMinutes;
    if (diff < _appOpenCooldown) {
      debugPrint("Açılış reklamı için soğuma süresi dolmadı: $diff/$_appOpenCooldown dk");
      return;
    }
  }

  _appOpenAd!.fullScreenContentCallback = FullScreenContentCallback(
    onAdDismissedFullScreenContent: (ad) {
      _appOpenAd = null;
      _loadAppOpenAd(); // Kapanınca yenisini yükle
    },
    onAdFailedToShowFullScreenContent: (ad, error) {
      _appOpenAd = null;
      _loadAppOpenAd();
    },
  );

  _appOpenAd!.show();
  _lastAppOpenAdShownTime = DateTime.now();
}

void _showUpdateDialog(bool forceUpdate, String url) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Dialog(
        // Modalın köşe keskinliği (İstediğin gibi 3px)
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Üst Kısım: İkon ve Başlık
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.deepPurple.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.system_update_rounded,
                  size: 40,
                  color: Colors.deepPurple,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                "Yeni Sürüm Hazır!",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2D3142),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                "Size daha iyi bir deneyim sunabilmek için uygulamamızı güncelledik. Devam etmek için lütfen güncelleyin.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF919191),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              
              // Buton: Border radius 3px ve tam genişlik
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(3), // İstediğin 3px radius
                    ),
                  ),
                  child: const Text(
                    "ŞİMDİ GÜNCELLE",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  onPressed: () async {
                    final uri = Uri.parse(url);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                ),
              ),
              
              // Eğer forceUpdate değilse kapat butonu eklenebilir
              if (!forceUpdate)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    "Daha Sonra",
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  ); 
} 
Future<void> _loadAdSettings() async { 
  try {
    final res = await http.get(
      Uri.parse('${AppApi.baseUrl}/api/mobile/ad-settings'),
    );
	

    if (res.statusCode == 200) {
  final data = jsonDecode(res.body);
  setState(() { // <--- BU ÇOK ÖNEMLİ
    _adsEnabled = data["ads_enabled"] ?? false;
    _interstitialEvery = data["interstitial_every"] ?? 10;
    _maxAdsPerSession = data["max_ads_per_session"] ?? 3;
    _minSecondsBetweenAds = data["min_seconds_between_ads"] ?? 90;
    _appOpenEnabled = data["app_open_enabled"] ?? false;
    _appOpenCooldown = data["app_open_cooldown_minutes"] ?? 30;
  });

  if (_appOpenEnabled) {
    _loadAppOpenAd();
  }
  // --- MANUEL VERSİYON KONTROLÜ ---
      final int latestBuildNumber = data["latest_build_number"] ?? 0;
      
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      int currentBuildNumber = int.parse(packageInfo.buildNumber);

      // Eğer API'deki build numarası, telefondakinden büyükse
      if (latestBuildNumber > currentBuildNumber) {
        if (mounted) {
          // forceUpdate: true olarak sabitliyoruz, kullanıcıyı zorluyoruz
          _showUpdateDialog(true, _storeUrl);
        }
      }
}

  } catch (e) {
    debugPrint("Ad settings error: $e");
  }
}

void _loadAd() {
  InterstitialAd.load(
    adUnitId: adUnitId,
  request: const AdRequest(),
    adLoadCallback: InterstitialAdLoadCallback(
      onAdLoaded: (ad) { 

        _interstitialAd = ad;

        ad.fullScreenContentCallback = FullScreenContentCallback(
          onAdDismissedFullScreenContent: (ad) {
            ad.dispose();
            _loadAd();
          },
          onAdFailedToShowFullScreenContent: (ad, error) {
            ad.dispose();
            _loadAd();
          },
        );

      },
     onAdFailedToLoad: (error) {
  _interstitialAd = null;

  Future.delayed(
    const Duration(seconds: 10),
    _loadAd,
  );
}
    ),
  );
}

void _loadRewardedAd() {
  RewardedAd.load(
    adUnitId: Platform.isAndroid
        ? 'ca-app-pub-6275851890605245/4744208793'
        : 'ca-app-pub-6275851890605245/9430231719',
    request: const AdRequest(),
    rewardedAdLoadCallback: RewardedAdLoadCallback(
      onAdLoaded: (ad) {
        _rewardedAd = ad;
      },
     onAdFailedToLoad: (error) {
  _rewardedAd = null;

  Future.delayed(
    const Duration(seconds: 15),
    _loadRewardedAd,
  );
},
    ),
  );
}

void _showRewardedAd() {

  if (_rewardedAd == null) {

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Reklam yükleniyor, lütfen tekrar deneyin"),
      ),
    );

    _loadRewardedAd();
    return;
  }

  _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
    onAdDismissedFullScreenContent: (ad) {
      ad.dispose();
      _loadRewardedAd();
    },
    onAdFailedToShowFullScreenContent: (ad, error) {
      ad.dispose();
      _loadRewardedAd();
    },
  );

  _rewardedAd!.show(
    onUserEarnedReward: (AdWithoutView ad, RewardItem reward) {

      _controller.runJavaScript("""
        window.dispatchEvent(new Event('rewardCompleted'));
      """);

    },
  );

  _rewardedAd = null;
}

void _maybeShowAd() async {

  final prefs = await SharedPreferences.getInstance();
  final userId = prefs.getString(_kUserIdStorageKey);

  if (userId == null || userId.isEmpty) return; // 🔴 user yoksa reklam yok

  if (!_adsEnabled) return;

  if (_pageCount < _interstitialEvery) return;

  if (_adsShown >= _maxAdsPerSession) return;

  if (_pageCount % _interstitialEvery != 0) return;

  final diff = DateTime.now().difference(_lastAdTime).inSeconds;

  if (diff < _minSecondsBetweenAds) return;

  if (_interstitialAd == null) return;

  final ad = _interstitialAd;
  _interstitialAd = null;

  ad!.show();

  _adsShown++;
  _lastAdTime = DateTime.now();

  _loadAd();
}


// _WebViewPageState sınıfının içinde bir yere ekle:
final InAppReview _inAppReview = InAppReview.instance;

Future<void> _maybeShowReviewDialog() async {
  final prefs = await SharedPreferences.getInstance();
  
  // Daha önce sorduysak bir daha sorma
  bool alreadyReviewed = prefs.getBool('already_reviewed') ?? false;
  if (alreadyReviewed) return;

  // 25 sayfa gezildiyse tetikle
  if (_pageCount >= 35) {
    if (await _inAppReview.isAvailable()) {
      await _inAppReview.requestReview();
      // Başarıyla tetiklendiyse kaydet ki her 25 sayfada bir çıkmasın
      await prefs.setBool('already_reviewed', true);
    }
  }
}


late final AppLinks _appLinks;

Future<void> _initDeepLinks() async {
  _appLinks = AppLinks();

  // İlk açılış linkini yakala
  final uri = await _appLinks.getInitialLink();
  if (uri != null) {
    // WebView'ın tamamen hazır olduğundan emin olmak için kısa bir bekleme
    WidgetsBinding.instance.addPostFrameCallback((_) {
       _controller.loadRequest(uri);
    });
  }

  // Uygulama arkadayken gelen linkleri dinle
  _sub = _appLinks.uriLinkStream.listen((uri) {
    if (mounted) {
      debugPrint("🔗 Gelen Deep Link: $uri");
      _controller.loadRequest(uri);
    }
  });
}

  @override
void initState() {
  super.initState();

  WidgetsBinding.instance.addObserver(this);
_loadAdSettings().then((_) {
      _loadAd();
      _preloadAllBanners(); // Bunu ekledik, 4 reklamı arkada yükler.
      _loadAppOpenAd();
    });
_loadRewardedAd();

  _controller = _createController();
   
  
if (_controller.platform is AndroidWebViewController) {
  AndroidWebViewController androidController =
      _controller.platform as AndroidWebViewController; 

  androidController.setMediaPlaybackRequiresUserGesture(false);
  
  
  // --- BURASI DOSYA SEÇMEYİ SAĞLAYAN KRİTİK KISIM ---
  androidController.setOnShowFileSelector((params) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any, // Sadece resim istersen FileType.image yapabilirsin
      allowMultiple: params.mode == FileSelectorMode.openMultiple,
    );

    if (result != null && result.files.isNotEmpty) {
      // Seçilen dosyaların yollarını WebView'a geri gönderiyoruz
      return result.files
          .where((file) => file.path != null)
          .map((file) => Uri.file(file.path!).toString())
          .toList();
    }
    return []; // Kullanıcı iptal ederse boş liste dön
  });
  // ------------------------------------------------
}




  

// OneSignal Dinleyicisi
  OneSignal.Notifications.addClickListener((event) {
    final data = event.notification.additionalData;
    if (data != null && data["url"] != null) {
      String targetUrl = data["url"].toString();
      if (!targetUrl.startsWith('http')) {
         targetUrl = 'https://www.kumpara.com.tr' + (targetUrl.startsWith('/') ? '' : '/') + targetUrl;
      }
      _controller.loadRequest(Uri.parse(targetUrl));
    }
  });

  

  _controller
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
	..addJavaScriptChannel(
  'RewardAd',
  onMessageReceived: (message) {
    _showRewardedAd();
  },
  
  
)



  
// initState içindeki BannerControl kanalı yerine şunları kullandığından emin ol:
..addJavaScriptChannel(
    'BannerPosition',
    onMessageReceived: (message) {
      final data = jsonDecode(message.message);
      final String id = data['id'];
      if (mounted) {
        setState(() { 
          _adPositions[id] = Offset(data['x'].toDouble(), data['y'].toDouble());
          _showAd[id] = data['present'] as bool;
        });
      }
    },
)
  
    ..setNavigationDelegate(
    NavigationDelegate(
onNavigationRequest: (NavigationRequest request) async {
  final String url = request.url;
  final String lowUrl = url.toLowerCase();

  debugPrint("🔍 Kontrol edilen URL: $url");

  // HTTP olmayanlar
  if (!lowUrl.startsWith('http')) {
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication);
      }
    } catch (e) {
      debugPrint("Şema açma hatası: $e");
    }
    return NavigationDecision.prevent;
  }

  Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return NavigationDecision.prevent;
  }

  // kendi siten
  if (uri.host.endsWith('kumpara.com.tr')) {
    return NavigationDecision.navigate;
  }

  // login servisleri
  if (lowUrl.contains('accounts.google.com') ||
      lowUrl.contains('googleusercontent.com') ||
      lowUrl.contains('gstatic.com') ||
      lowUrl.contains('appleid.apple.com')) {
    return NavigationDecision.navigate;
  }

  // dış siteler
  if (request.isMainFrame) {
    debugPrint("🚀 DIŞ TARAYICIYA GÖNDERİLİYOR: $url");

   if (await canLaunchUrl(uri)) {
  await launchUrl(
    uri,
    mode: LaunchMode.externalApplication, 
  );
}

    return NavigationDecision.prevent;
  }

  return NavigationDecision.navigate;
},

  // WebViewPage içindeki NavigationDelegate bölümünde:
onPageStarted: (String url) {
  setState(() {
    _isLoading = true;
    // Sayfa değiştiği an tüm bannerları ve pozisyonları temizle
    _showAd.clear(); 
    _adPositions.clear();
  });
},

  onPageFinished: (String url) {
  

_controller.runJavaScript('''
    var lastSentPositions = {};

    function trackBanners() {
       // onPageFinished içindeki ids listesini şu şekilde güncelle:
const ids = ['bannerreklam1', 'bannerreklam2', 'bannerreklam3', 'bannerreklam4', 'bannerreklam5'];
        ids.forEach(id => {
            const el = document.getElementById(id);
            if (el && el.offsetParent !== null) {
                const rect = el.getBoundingClientRect();
                const currentX = rect.left;
                const currentY = rect.top;

                if (!lastSentPositions[id] || 
                    Math.abs(lastSentPositions[id].x - currentX) > 0.5 || 
                    Math.abs(lastSentPositions[id].y - currentY) > 0.5 || 
                    lastSentPositions[id].present !== true) {
                    
                    lastSentPositions[id] = { x: currentX, y: currentY, present: true };
                    window.BannerPosition.postMessage(JSON.stringify({
                        id: id,
                        present: true,
                        x: currentX,
                        y: currentY
                    }));
                }
            } else {
                if (!lastSentPositions[id] || lastSentPositions[id].present !== false) {
                    lastSentPositions[id] = { present: false };
                    window.BannerPosition.postMessage(JSON.stringify({ id: id, present: false }));
                }
            }
        });
    }

    // Olayları dinle
    window.addEventListener('scroll', trackBanners);
    window.addEventListener('resize', trackBanners);
    
    // Sayfa içindeki her türlü yer değişimini (resim yüklenmesi vb.) izler
    if (window.ResizeObserver) {
        const observer = new ResizeObserver(trackBanners);
        document.body.childNodes.forEach(node => {
            if(node.nodeType === 1) observer.observe(node);
        });
    }

    // Periyodik kontrolü hızlandır (Görünürlük ve ani değişimler için)
    setInterval(trackBanners, 100); 
    trackBanners();
''');


  
  // Mevcut JS kodlarının içine veya altına ekle:
  _controller.runJavaScript('''
    // Sayfanın en üstüne ve en altına telefonun boşluğu kadar padding ekler
    document.body.style.paddingTop = 'env(safe-area-inset-top)';
    document.body.style.paddingBottom = 'env(safe-area-inset-bottom)';
    
    // Eğer sitende sabit (fixed) bir header varsa onun için de şunu ekleyebilirsin:
    var header = document.querySelector('header'); 
    if(header) {
      header.style.paddingTop = 'env(safe-area-inset-top)';
    }
  ''');
  
  // BURAYI EKLE
  if (url.contains('/dashboard')) {
    requestNotificationPermission(context);
  }
  setState(() => _isLoading = false);

 _pageCount++;
_tryParseUserIdFromUrl(url); 
_maybeShowAd();
// BURAYA EKLE:
  _maybeShowReviewDialog();

// --- YATAY KAYDIRMAYI ENGELLEME VE GİZLEME KODU ---
  _controller.runJavaScript('''
    var style = document.createElement('style');
    style.type = 'text/css';
    style.innerHTML = `
      html, body {
        overflow-x: hidden !important; /* Yatay kaydırmayı tamamen kapat */
        width: 100% !important;
        position: relative !important;
      }
      ::-webkit-scrollbar {
        display: none !important; /* Kaydırma çubuklarını tamamen gizle (isteğe bağlı) */
      }
    `;
    document.getElementsByTagName('head')[0].appendChild(style);
  ''');
  // ------------------------------------------------
  
},
onWebResourceError: (error) {
  debugPrint("WebView error: ${error.description}");
},
),
    ) 
    ..loadRequest(Uri.parse(_initialUrl));
	
	// Delegate (zırh) artık hazır olduğu için bu link fırlatılamayacak!
  _initDeepLinks();
	
}

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  // Uygulama tekrar ön plana (ekrana) geldiğinde
  if (state == AppLifecycleState.resumed) {
    _showAppOpenAdIfReady();
  }
}
  /// Laravel login/register sonrası yönlendirmede gelen ?user_id= ile user_id'yi alır; storage'a yazar, popup gösterir, API sync dener
  void _tryParseUserIdFromUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      final uid = uri.queryParameters['user_id'];
      if (uid == null || uid.isEmpty) return;

      

      final prefs = await SharedPreferences.getInstance();
	   OneSignal.login(uid);
OneSignal.User.addTagWithKey("user_id", uid);
      await prefs.setString(_kUserIdStorageKey, uid);
      await _syncOneSignalIdToBackendIfReady();
    } catch (_) {
      debugPrint('user_id URL parse hatası: $url');
    }
  }

@override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _interstitialAd?.dispose();
    _rewardedAd?.dispose();
    _appOpenAd?.dispose();
    // Bannerları temizle
    _bannerAds.values.forEach((ad) => ad?.dispose());
    super.dispose();
  }
 
 



WebViewController _createController() {
  final platformParams = const PlatformWebViewControllerCreationParams();

  if (Platform.isAndroid) {
    final androidParams =
        AndroidWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
          platformParams,
        );

    final controller =
        WebViewController.fromPlatformCreationParams(androidParams);

    controller.setUserAgent("KumparaApp-Android/1.0");

    if (!kReleaseMode) {
      AndroidWebViewController.enableDebugging(true);
    }

    return controller;
  }

  if (Platform.isIOS) {
    final wkParams =
        WebKitWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
          platformParams,
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        );

    final controller =
        WebViewController.fromPlatformCreationParams(wkParams);

    controller.setUserAgent("KumparaApp-iOS/1.0");

    return controller;
  }

  return WebViewController.fromPlatformCreationParams(platformParams);
}
 
@override
Widget build(BuildContext context) {
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
    child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            // 1. KATMAN: WebView
            WebViewWidget(controller: _controller),

            // 2. KATMAN: Akıllı Takipçi Reklam
            // Sitede div varsa, koordinatlar geldiyse ve reklam yüklüyse göster
        // build metodu içindeki Stack katmanı:
..._adSizes.keys.map((id) {
  final position = _adPositions[id];
  
  if (_showAd[id] == true &&  
      _isAdLoaded[id] == true && 
      _bannerAds[id] != null && 
      position != null) {

    // bannerreklam5 için Full-Width kuralı
    if (id == 'bannerreklam5') {
      return Positioned(
        top: position.dy,
        left: 0,
        right: 0,
        height: 50,
        child: Container( 
          color: Colors.white,
          alignment: Alignment.center,
          child: AdWidget(ad: _bannerAds[id]!),
        ),
      );
    }

    // Diğer reklamlar için standart kurallar
    return Positioned(
      top: position.dy,
      left: position.dx,
      width: _adSizes[id]!.width.toDouble(),
      height: _adSizes[id]!.height.toDouble(),
      child: Container(
        color: Colors.white,
        child: AdWidget(ad: _bannerAds[id]!),
      ),
    );
  }
  return const SizedBox.shrink();
}).toList(),

            // 3. KATMAN: Loading
            if (_isLoading)
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    ),
  );
}
}
