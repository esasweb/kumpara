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

/// Bildirim izni verildiğinde alınan OneSignal ID buraya yazılır; UI modal gösterir.
final ValueNotifier<String?> onesignalIdToShowModal = ValueNotifier<String?>(
  null,
);

/// Laravel'den giriş yapıldığında gelen user_id; UI popup gösterir.
final ValueNotifier<String?> loggedInUserIdToShowModal = ValueNotifier<String?>(
  null,
);

/// OneSignal ID API sync sonucu; ekranda alert gösterilir (başarılı / başarısız).
final ValueNotifier<SyncResult?> syncResultToShowModal =
    ValueNotifier<SyncResult?>(null);

class SyncResult {
  final bool success;
  final String message;
  SyncResult({required this.success, required this.message});
}

const String _kOneSignalIdStorageKey = 'onesignal_id';
const String _kUserIdStorageKey = 'user_id';
const String _kSyncDoneKey =
    'onesignal_sync_done'; // Aynı çift için tekrar alert göstermemek için

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // OneSignal 5.4.1: initialize senkron (void döner)
  OneSignal.initialize('c19bfcc0-96e5-43ae-b482-f38b2be22b76');

  // Panelde gördüğünüz cihaz ID'si = OneSignal User ID (Subscription ID değil)
  OneSignal.User.addObserver((OSUserChangedState state) {
    final id = state.current.onesignalId;
    if (id != null && id.isNotEmpty) {
      _saveOneSignalIdAndNotify(id);
    }
  });

  OneSignal.Notifications.requestPermission(true);

  runApp(const MyApp());
}

void _saveOneSignalIdAndNotify(String id) async {
  final prefs = await SharedPreferences.getInstance();
  final hadStoredId = prefs.getString(_kOneSignalIdStorageKey) != null;
  await prefs.setString(_kOneSignalIdStorageKey, id);

  if (!hadStoredId) {
    onesignalIdToShowModal.value = id;
  }
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
      syncResultToShowModal.value = SyncResult(
        success: true,
        message: 'İstek gönderildi, kaydedildi.',
      );
      debugPrint('OneSignal ID backend ile eşlendi: user_id=$userId');
    } else {
      syncResultToShowModal.value = SyncResult(
        success: false,
        message:
            'Gönderilemedi. (${res.statusCode}) ${res.body.isNotEmpty ? res.body : "Sunucu hatası"}',
      );
      debugPrint('OneSignal sync API hatası: ${res.statusCode} ${res.body}');
    }
  } catch (e) {
    syncResultToShowModal.value = SyncResult(
      success: false,
      message: 'Gönderilemedi. Hata: $e',
    );
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

  @override
  void initState() {
    super.initState();
    _controller = _createController();

    onesignalIdToShowModal.addListener(_onOneSignalIdToShow);
    loggedInUserIdToShowModal.addListener(_onLoggedInUserIdToShow);
    syncResultToShowModal.addListener(_onSyncResultToShow);

    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (String url) {
            setState(() => _isLoading = false);
            _tryParseUserIdFromUrl(url);
          },
          onWebResourceError: (error) {
            debugPrint('WebView hatası: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(_initialUrl));
  }

  /// Laravel login/register sonrası yönlendirmede gelen ?user_id= ile user_id'yi alır; storage'a yazar, popup gösterir, API sync dener
  void _tryParseUserIdFromUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      final uid = uri.queryParameters['user_id'];
      if (uid == null || uid.isEmpty) return;

      loggedInUserIdToShowModal.value = uid;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserIdStorageKey, uid);
      await _syncOneSignalIdToBackendIfReady();
    } catch (_) {
      debugPrint('user_id URL parse hatası: $url');
    }
  }

  @override
  void dispose() {
    onesignalIdToShowModal.removeListener(_onOneSignalIdToShow);
    loggedInUserIdToShowModal.removeListener(_onLoggedInUserIdToShow);
    syncResultToShowModal.removeListener(_onSyncResultToShow);
    super.dispose();
  }

  void _onSyncResultToShow() {
    final result = syncResultToShowModal.value;
    if (result == null || !mounted) return;
    syncResultToShowModal.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (context) => AlertDialog(
          title: Text(
            result.success
                ? 'OneSignal ID kaydedildi'
                : 'OneSignal ID gönderilemedi',
          ),
          content: SelectableText(result.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Tamam'),
            ),
          ],
        ),
      );
    });
  }

  void _onLoggedInUserIdToShow() {
    final userId = loggedInUserIdToShowModal.value;
    if (userId == null || !mounted) return;
    loggedInUserIdToShowModal.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (context) => AlertDialog(
          title: const Text('Giriş başarılı'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('User ID\'niz:'),
              const SizedBox(height: 8),
              SelectableText(
                userId,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Tamam'),
            ),
          ],
        ),
      );
    });
  }

  void _onOneSignalIdToShow() {
    final id = onesignalIdToShowModal.value;
    if (id == null || !mounted) return;
    onesignalIdToShowModal.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (context) => AlertDialog(
          title: const Text('OneSignal ID alındı'),
          content: SelectableText(id),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Tamam'),
            ),
          ],
        ),
      );
    });
  }

  WebViewController _createController() {
    final platformParams = const PlatformWebViewControllerCreationParams();

    if (Platform.isAndroid) {
      final androidParams =
          AndroidWebViewControllerCreationParams.fromPlatformWebViewControllerCreationParams(
            platformParams,
          );
      return WebViewController.fromPlatformCreationParams(androidParams);
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
