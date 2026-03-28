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









const String _kOneSignalIdStorageKey = 'onesignal_id';
const String _kUserIdStorageKey = 'user_id';
const String _kSyncDoneKey =
    'onesignal_sync_done'; // Aynı çift için tekrar alert göstermemek için

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  @override
void initState() {
  super.initState();
  _controller = _createController();

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
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) => setState(() => _isLoading = true),
        onPageFinished: (String url) {
          setState(() => _isLoading = false);
          _tryParseUserIdFromUrl(url);
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

      

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserIdStorageKey, uid);
      await _syncOneSignalIdToBackendIfReady();
    } catch (_) {
      debugPrint('user_id URL parse hatası: $url');
    }
  }

  @override
  void dispose() {
   
    super.dispose();
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
