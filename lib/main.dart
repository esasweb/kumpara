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
import 'package:uni_links/uni_links.dart';
import 'dart:async';







const String _kOneSignalIdStorageKey = 'onesignal_id';
const String _kUserIdStorageKey = 'user_id';
const String _kSyncDoneKey =
    'onesignal_sync_done'; // Aynı çift için tekrar alert göstermemek için

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

await MobileAds.instance.initialize();
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

  bool permission = await OneSignal.Notifications.requestPermission(true);

  if (!permission) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Bildirim İzni"),
        content: const Text(
          "Görev ve Kanıt Bildirimleri için bildirim izni vermeniz gerekir.",
        ),
        actions: [
          TextButton(
            child: const Text("Kapat"),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kumpara',
      debugShowCheckedModeBanner: false,
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

class _WebViewPageState extends State<WebViewPage> {
  static const String _initialUrl = 'https://www.kumpara.com.tr/mobil/';
  late final WebViewController _controller;
  bool _isLoading = true;
StreamSubscription? _sub;
InterstitialAd? _interstitialAd;
RewardedAd? _rewardedAd;

int _pageCount = 0;
int _adsShown = 0;

bool _adsEnabled = false;
int _interstitialEvery = 10;
int _maxAdsPerSession = 3;
int _minSecondsBetweenAds = 90;

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

Future<void> _loadAdSettings() async {
  try {
    final res = await http.get(
      Uri.parse('${AppApi.baseUrl}/api/mobile/ad-settings'),
    );

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);

      _adsEnabled = data["ads_enabled"] ?? false;
      _interstitialEvery = data["interstitial_every"] ?? 10;
      _maxAdsPerSession = data["max_ads_per_session"] ?? 3;
      _minSecondsBetweenAds = data["min_seconds_between_ads"] ?? 90;
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
      },
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

Future<void> _initDeepLinks() async {

  // App kapalıyken gelen link
  final initialUri = await getInitialUri();

  if (initialUri != null) {
    _controller.loadRequest(initialUri);
  }

  // App açıkken gelen link
  _sub = uriLinkStream.listen((Uri? uri) {
    if (uri != null) {
      _controller.loadRequest(uri);
    }
  });
}

  @override
void initState() {
_loadAdSettings().then((_) {
  _loadAd();
});
_loadRewardedAd();
  super.initState();
  _controller = _createController();
  
if (_controller.platform is AndroidWebViewController) {
  AndroidWebViewController androidController =
      _controller.platform as AndroidWebViewController; 

  androidController.setMediaPlaybackRequiresUserGesture(false);
}




  Future.delayed(const Duration(seconds: 2), () {
    if (mounted) {
      requestNotificationPermission(context);
    }
  });

  // App açıkken bildirime basma
  OneSignal.Notifications.addClickListener((event) {
    final data = event.notification.additionalData;

    if (data != null && data["url"] != null) {
      final url = data["url"];
      _controller.loadRequest(Uri.parse(url));
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
    ..setNavigationDelegate(
    NavigationDelegate(
onNavigationRequest: (NavigationRequest request) async {

  final uri = Uri.parse(request.url);

  if (uri.scheme == 'http' || uri.scheme == 'https') {
    return NavigationDecision.navigate;
  }

  if (await canLaunchUrl(uri)) {  
    await launchUrl(uri);
    return NavigationDecision.prevent;
  }

  return NavigationDecision.navigate;
},

  onPageStarted: (_) => setState(() => _isLoading = true),

  onPageFinished: (String url) {
  setState(() => _isLoading = false);

 _pageCount++;
_tryParseUserIdFromUrl(url);
_maybeShowAd();
},
),
    )
    ..loadRequest(Uri.parse(_initialUrl));
	_initDeepLinks();
}

  /// Laravel login/register sonrası yönlendirmede gelen ?user_id= ile user_id'yi alır; storage'a yazar, popup gösterir, API sync dener
  void _tryParseUserIdFromUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      final uid = uri.queryParameters['user_id'];
      if (uid == null || uid.isEmpty) return;

      

      final prefs = await SharedPreferences.getInstance();
	    OneSignal.login(uid);
      await prefs.setString(_kUserIdStorageKey, uid);
      await _syncOneSignalIdToBackendIfReady();
    } catch (_) {
      debugPrint('user_id URL parse hatası: $url');
    }
  }

@override
void dispose() {
  _sub?.cancel();
  _interstitialAd?.dispose();
  _rewardedAd?.dispose();
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

  AndroidWebViewController.enableDebugging(true);

  return controller;
}

    if (Platform.isIOS) {
      final wkParams =
          WebKitWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
            platformParams,
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
          );
      return WebViewController.fromPlatformCreationParams(wkParams);
    }

    return WebViewController.fromPlatformCreationParams(platformParams);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_isLoading) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
