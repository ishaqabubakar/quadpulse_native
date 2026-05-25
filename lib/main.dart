import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

final WebUri quadPulseHomeUrl = WebUri('https://quadpulse.io/home');
final WebUri quadPulseCookieUrl = WebUri('https://quadpulse.io');
final WebUri mobileAuthCompleteUrl =
    WebUri('https://quadpulse.io/auth/mobile/complete');
final Uri quadPulseBaseUri = Uri.parse('https://quadpulse.io');
const String defaultMobileAuthReturnPath = '/dashboard';
const String androidUserAgentSuffix = 'QuadPulse-AndroidNative';
const String legacyWebNativeUserAgentSuffix = 'QuadPulse-WebNative';
const String pushDeviceIdKey = 'quadpulse.push.device_id';
const String pushAlertsChannelId = 'quadpulse_alerts';
const String pushAlertsChannelName = 'QuadPulse alerts';
const Set<String> inAppHosts = {'quadpulse.io', 'www.quadpulse.io'};
const Set<String> externalHosts = {
  'facebook.com',
  'www.facebook.com',
  'm.facebook.com',
  'instagram.com',
  'www.instagram.com',
  'linkedin.com',
  'www.linkedin.com',
  'maps.google.com',
  'www.google.com',
  'maps.app.goo.gl',
  'x.com',
  'www.x.com',
  'twitter.com',
  'www.twitter.com',
  'wa.me',
  'whatsapp.com',
  'www.whatsapp.com',
};

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();
bool firebaseMessagingAvailable = false;

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await _initializeFirebaseMessaging();
}

Future<void> _initializeFirebaseMessaging() async {
  if (firebaseMessagingAvailable) return;
  try {
    await Firebase.initializeApp();
    firebaseMessagingAvailable = true;
  } catch (error) {
    debugPrint('QuadPulse push: Firebase is not configured yet: $error');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: SystemUiOverlay.values,
  );
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(false);
  }

  await _initializeFirebaseMessaging();
  if (firebaseMessagingAvailable) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }

  runApp(const QuadPulseApp());
}

class QuadPulseApp extends StatelessWidget {
  const QuadPulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: QuadPulseWebShell(),
    );
  }
}

class QuadPulseWebShell extends StatefulWidget {
  const QuadPulseWebShell({super.key});

  @override
  State<QuadPulseWebShell> createState() => _QuadPulseWebShellState();
}

class _QuadPulseWebShellState extends State<QuadPulseWebShell> {
  final AppLinks _appLinks = AppLinks();
  final ChromeSafariBrowser _authBrowser = ChromeSafariBrowser();

  InAppWebViewController? _controller;
  StreamSubscription<Uri>? _linkSubscription;
  WebAuthenticationSession? _authSession;
  WebUri? _pendingDeepLink;
  WebUri? _pendingConsumeCookieCheckUrl;
  int? _popupWindowId;
  DateTime? _lastBackPressAt;
  StreamSubscription<String>? _pushTokenSubscription;
  StreamSubscription<RemoteMessage>? _foregroundPushSubscription;
  StreamSubscription<RemoteMessage>? _pushOpenSubscription;
  String? _lastRegisteredPushToken;
  bool _pushInitialized = false;
  bool _pushRegistrationInFlight = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
    _initPushNotifications();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _pushTokenSubscription?.cancel();
    _foregroundPushSubscription?.cancel();
    _pushOpenSubscription?.cancel();
    _authBrowser.dispose();
    _authSession?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        if (_popupWindowId != null) {
          setState(() => _popupWindowId = null);
          return;
        }

        final controller = _controller;
        if (controller != null && await controller.canGoBack()) {
          await controller.goBack();
          return;
        }

        final now = DateTime.now();
        final shouldExit = _lastBackPressAt != null &&
            now.difference(_lastBackPressAt!) < const Duration(seconds: 2);
        _lastBackPressAt = now;

        if (shouldExit) {
          await SystemNavigator.pop();
          return;
        }

        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              const SnackBar(
                content: Text('Press back again to exit'),
                duration: Duration(seconds: 2),
              ),
            );
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Positioned.fill(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: quadPulseHomeUrl),
                  initialSettings: _mainWebViewSettings(),
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    _loadPendingDeepLink();
                  },
                  onProgressChanged: (_, progress) {
                    if (mounted) {
                      setState(() => _progress = progress / 100);
                    }
                  },
                  onLoadStart: (controller, url) async {
                    if (url == null) return;

                    final canonicalUrl = _canonicalQuadPulseWebUrl(url);
                    if (_isLogoutUrl(canonicalUrl)) {
                      await _unregisterPushTokenWithWebSession();
                    }
                    if (canonicalUrl.toString() == url.toString()) return;

                    await controller.stopLoading();
                    await _loadInMainWebView(canonicalUrl);
                  },
                  onLoadStop: (controller, url) async {
                    if (mounted) setState(() => _progress = 1);
                    await _maybeLogAuthConsumeResult(controller, url);
                    await _registerPushTokenIfAuthenticated(url);
                  },
                  shouldOverrideUrlLoading:
                      (controller, navigationAction) async {
                    final requestedUrl = navigationAction.request.url;
                    if (requestedUrl == null) {
                      return NavigationActionPolicy.ALLOW;
                    }
                    final url = _canonicalQuadPulseWebUrl(requestedUrl);
                    if (url.toString() != requestedUrl.toString()) {
                      await controller.loadUrl(
                          urlRequest: URLRequest(url: url));
                      return NavigationActionPolicy.CANCEL;
                    }
                    if (_shouldOpenInSystemAuthSession(url)) {
                      await _openSystemAuthSession(url);
                      return NavigationActionPolicy.CANCEL;
                    }
                    if (!_shouldOpenExternally(url)) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    await launchUrl(url, mode: LaunchMode.externalApplication);
                    return NavigationActionPolicy.CANCEL;
                  },
                  onCreateWindow: (controller, createWindowAction) async {
                    final requestedUrl = createWindowAction.request.url;
                    final url = requestedUrl == null
                        ? null
                        : _canonicalQuadPulseWebUrl(requestedUrl);
                    if (requestedUrl != null &&
                        url != null &&
                        url.toString() != requestedUrl.toString()) {
                      await _loadInMainWebView(url);
                      return false;
                    }
                    if (url != null && _shouldOpenInSystemAuthSession(url)) {
                      await _openSystemAuthSession(url);
                      return false;
                    }
                    if (url != null && _shouldOpenExternally(url)) {
                      await launchUrl(url,
                          mode: LaunchMode.externalApplication);
                      return false;
                    }

                    if (url != null && _isQuadPulseUrl(url)) {
                      await controller.loadUrl(
                        urlRequest: createWindowAction.request,
                      );
                      return false;
                    }

                    setState(
                        () => _popupWindowId = createWindowAction.windowId);
                    return true;
                  },
                  onGeolocationPermissionsShowPrompt: (_, origin) async {
                    final status = await Permission.locationWhenInUse.request();
                    return GeolocationPermissionShowPromptResponse(
                      origin: origin,
                      allow: status.isGranted || status.isLimited,
                      retain: true,
                    );
                  },
                  onPermissionRequest: (_, permissionRequest) async {
                    final canGrant = await _requestNativePermissions(
                      permissionRequest.resources,
                    );
                    return PermissionResponse(
                      resources: canGrant ? permissionRequest.resources : [],
                      action: canGrant
                          ? PermissionResponseAction.GRANT
                          : PermissionResponseAction.DENY,
                    );
                  },
                ),
              ),
              if (_popupWindowId != null)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Stack(
                      children: [
                        InAppWebView(
                          windowId: _popupWindowId,
                          initialSettings: _popupWebViewSettings(),
                          onCloseWindow: (_) {
                            if (mounted) {
                              setState(() => _popupWindowId = null);
                            }
                          },
                          onLoadStart: (_, url) => _handlePopupReturn(url),
                          shouldOverrideUrlLoading:
                              (controller, navigationAction) async {
                            final requestedUrl = navigationAction.request.url;
                            if (requestedUrl == null) {
                              return NavigationActionPolicy.ALLOW;
                            }
                            final url = _canonicalQuadPulseWebUrl(requestedUrl);
                            if (url.toString() != requestedUrl.toString()) {
                              await _loadInMainWebView(url);
                              if (mounted) {
                                setState(() => _popupWindowId = null);
                              }
                              return NavigationActionPolicy.CANCEL;
                            }
                            if (_shouldOpenInSystemAuthSession(url)) {
                              await _openSystemAuthSession(url);
                              if (mounted) {
                                setState(() => _popupWindowId = null);
                              }
                              return NavigationActionPolicy.CANCEL;
                            }
                            if (_isQuadPulseUrl(url)) {
                              await _loadInMainWebView(url);
                              if (mounted) {
                                setState(() => _popupWindowId = null);
                              }
                              return NavigationActionPolicy.CANCEL;
                            }
                            if (_shouldOpenExternally(url)) {
                              await launchUrl(
                                url,
                                mode: LaunchMode.externalApplication,
                              );
                              return NavigationActionPolicy.CANCEL;
                            }
                            return NavigationActionPolicy.ALLOW;
                          },
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: IconButton.filled(
                            tooltip: 'Close',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black54,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              setState(() => _popupWindowId = null);
                            },
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_progress > 0 && _progress < 1)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 2,
                    color: const Color(0xFF8B5CF6),
                    backgroundColor: Colors.transparent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  InAppWebViewSettings _mainWebViewSettings() {
    return InAppWebViewSettings(
      allowsBackForwardNavigationGestures: true,
      allowsInlineMediaPlayback: true,
      applicationNameForUserAgent: _nativeUserAgentSuffix,
      domStorageEnabled: true,
      geolocationEnabled: true,
      incognito: false,
      javaScriptCanOpenWindowsAutomatically: true,
      javaScriptEnabled: true,
      mediaPlaybackRequiresUserGesture: false,
      sharedCookiesEnabled: true,
      supportMultipleWindows: true,
      thirdPartyCookiesEnabled: true,
      transparentBackground: false,
      useShouldOverrideUrlLoading: true,
    );
  }

  InAppWebViewSettings _popupWebViewSettings() {
    return InAppWebViewSettings(
      applicationNameForUserAgent: _nativeUserAgentSuffix,
      domStorageEnabled: true,
      incognito: false,
      javaScriptCanOpenWindowsAutomatically: true,
      javaScriptEnabled: true,
      mediaPlaybackRequiresUserGesture: false,
      sharedCookiesEnabled: true,
      supportMultipleWindows: true,
      thirdPartyCookiesEnabled: true,
      useShouldOverrideUrlLoading: true,
    );
  }

  String get _nativeUserAgentSuffix {
    return Platform.isAndroid
        ? androidUserAgentSuffix
        : legacyWebNativeUserAgentSuffix;
  }

  Future<void> _initDeepLinks() async {
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _openDeepLink,
      onError: (_) {},
    );

    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _openDeepLink(initialUri);
      }
    } catch (_) {
      // Deep links are best-effort; the WebView still opens the home URL.
    }
  }

  Future<void> _initPushNotifications() async {
    if (!firebaseMessagingAvailable) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        final uri = Uri.tryParse(payload);
        if (uri != null) _openPushHref(uri.toString());
      },
    );

    const androidChannel = AndroidNotificationChannel(
      pushAlertsChannelId,
      pushAlertsChannelName,
      description: 'Native QuadPulse trading and account alerts.',
      importance: Importance.high,
    );
    await localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    _foregroundPushSubscription = FirebaseMessaging.onMessage.listen(
      _showForegroundPushNotification,
    );
    _pushOpenSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => _openPushHref(message.data['href']?.toString()),
    );
    _pushTokenSubscription = FirebaseMessaging.instance.onTokenRefresh.listen(
      (token) => _registerPushTokenWithWebSession(token),
    );

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    final initialHref = initialMessage?.data['href']?.toString();
    if (initialHref != null && initialHref.isNotEmpty) {
      _openPushHref(initialHref);
    }

    _pushInitialized = true;
  }

  Future<void> _showForegroundPushNotification(RemoteMessage message) async {
    final notification = message.notification;
    final title = notification?.title ?? message.data['title']?.toString();
    final body = notification?.body ?? message.data['body']?.toString();
    final href =
        message.data['href']?.toString() ?? defaultMobileAuthReturnPath;
    if (title == null || title.trim().isEmpty) return;

    await localNotifications.show(
      message.hashCode,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          pushAlertsChannelId,
          pushAlertsChannelName,
          channelDescription: 'Native QuadPulse trading and account alerts.',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: href,
    );
  }

  Future<void> _registerPushTokenIfAuthenticated(WebUri? loadedUrl) async {
    if (!_pushInitialized || _pushRegistrationInFlight) return;
    final url = loadedUrl ?? await _controller?.getUrl();
    if (url == null || !_isAuthenticatedAppUrl(url)) return;

    _pushRegistrationInFlight = true;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (Platform.isAndroid) {
        await Permission.notification.request();
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await _registerPushTokenWithWebSession(
        token,
        permissionStatus:
            _authorizationStatusName(settings.authorizationStatus),
      );
    } finally {
      _pushRegistrationInFlight = false;
    }
  }

  Future<void> _registerPushTokenWithWebSession(
    String token, {
    String permissionStatus = 'unknown',
  }) async {
    final controller = _controller;
    if (controller == null || token.isEmpty) return;

    final deviceId = await _pushDeviceId();
    final appVersion = await _appVersion();
    final script = '''
      fetch('/api/mobile/push/register', {
        method: 'POST',
        credentials: 'include',
        headers: {'Content-Type': 'application/json'},
        body: ${jsonEncode(jsonEncode({
          'platform': Platform.isAndroid ? 'android' : 'ios',
          'deviceId': deviceId,
          'appVersion': appVersion,
          'token': token,
          'permissionStatus': permissionStatus,
        }))}
      }).then(function (res) {
        return res.ok;
      }).catch(function () {
        return false;
      });
    ''';
    final result = await controller.evaluateJavascript(source: script);
    if (result == true || result == 'true') {
      _lastRegisteredPushToken = token;
    }
  }

  Future<void> _unregisterPushTokenWithWebSession() async {
    final controller = _controller;
    if (controller == null) return;

    final token = _lastRegisteredPushToken ??
        (firebaseMessagingAvailable
            ? await FirebaseMessaging.instance
                .getToken()
                .catchError((_) => null)
            : null);
    final deviceId = await _pushDeviceId();
    final script = '''
      fetch('/api/mobile/push/unregister', {
        method: 'POST',
        credentials: 'include',
        headers: {'Content-Type': 'application/json'},
        body: ${jsonEncode(jsonEncode({
          'deviceId': deviceId,
          if (token != null && token.isNotEmpty) 'token': token,
        }))}
      }).catch(function () {
        return false;
      });
    ''';
    await controller.evaluateJavascript(source: script);
    _lastRegisteredPushToken = null;
  }

  Future<String> _pushDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(pushDeviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    final deviceId = base64UrlEncode(bytes).replaceAll('=', '');
    await prefs.setString(pushDeviceIdKey, deviceId);
    return deviceId;
  }

  Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  String _authorizationStatusName(AuthorizationStatus status) {
    switch (status) {
      case AuthorizationStatus.authorized:
        return 'authorized';
      case AuthorizationStatus.denied:
        return 'denied';
      case AuthorizationStatus.provisional:
        return 'provisional';
      case AuthorizationStatus.notDetermined:
        return 'notDetermined';
    }
  }

  void _openDeepLink(Uri uri) {
    final webUri = WebUri.uri(uri);
    if (_isMobileAuthCompleteUri(uri)) {
      final tokenLength = uri.queryParameters['token']?.length ?? 0;
      debugPrint(
        'QuadPulse auth handoff: deep link received '
        '(${uri.scheme}://${uri.host}${uri.path}, token length $tokenLength)',
      );
      _closeAuthSurfaces();
      _pendingDeepLink = _webUrlFromMobileAuthComplete(uri);
      _loadPendingDeepLink();
      return;
    }

    if (!_isQuadPulseUrl(webUri)) return;

    _closeAuthSurfaces();

    _pendingDeepLink = webUri;
    _loadPendingDeepLink();
  }

  Future<void> _loadPendingDeepLink() async {
    final url = _pendingDeepLink;
    final controller = _controller;
    if (url == null || controller == null) return;

    _pendingDeepLink = null;
    await _loadInMainWebView(url);
  }

  Future<void> _handlePopupReturn(WebUri? url) async {
    if (url == null) return;

    final canonicalUrl = _canonicalQuadPulseWebUrl(url);
    if (!_isQuadPulseUrl(canonicalUrl)) return;

    await _loadInMainWebView(canonicalUrl);
    if (mounted) {
      setState(() => _popupWindowId = null);
    }
  }

  Future<void> _loadInMainWebView(WebUri url) async {
    final canonicalUrl = _canonicalQuadPulseWebUrl(url);
    if (_isMobileAuthConsumeUrl(canonicalUrl)) {
      _pendingConsumeCookieCheckUrl = canonicalUrl;
      debugPrint(
        'QuadPulse auth handoff: loading consume URL in WebView '
        '${_redactedAuthUrl(canonicalUrl)}',
      );
    }
    await _controller?.loadUrl(urlRequest: URLRequest(url: canonicalUrl));
  }

  bool _isQuadPulseUrl(WebUri url) {
    final host = url.host.toLowerCase();
    return url.scheme == 'https' && inAppHosts.contains(host);
  }

  WebUri _canonicalQuadPulseWebUrl(WebUri url) {
    if (_isQuadPulseUrl(url)) return url;

    final uri = Uri.tryParse(url.toString());
    if (uri == null) return url;

    final scheme = uri.scheme.toLowerCase();
    if ((scheme == 'http' || scheme == 'https') && _isLocalhostUri(uri)) {
      return WebUri.uri(_quadPulseUrlFromPath(uri));
    }

    return url;
  }

  bool _shouldOpenExternally(WebUri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return true;
    }

    final host = url.host.toLowerCase();
    if (inAppHosts.contains(host)) {
      return false;
    }
    if (_looksLikeAuthFlow(url)) {
      return false;
    }

    return externalHosts.any((externalHost) {
      return host == externalHost || host.endsWith('.$externalHost');
    });
  }

  bool _isGoogleAuthUrl(WebUri url) {
    final host = url.host.toLowerCase();
    return url.scheme == 'https' &&
        (host == 'accounts.google.com' || host == 'accounts.youtube.com');
  }

  bool _isAuthEntryUrl(WebUri url) {
    if (!_isQuadPulseUrl(url)) return false;

    final path = url.path.toLowerCase();
    return path == '/auth/signin' ||
        path == '/api/auth/signin' ||
        path.startsWith('/api/auth/signin/');
  }

  bool _shouldOpenInSystemAuthSession(WebUri url) {
    return _isAuthEntryUrl(url) || _isGoogleAuthUrl(url);
  }

  bool _isMobileAuthCompleteUri(Uri uri) {
    return uri.scheme == 'quadpulse' &&
        (uri.host == 'auth' || uri.host == 'auth-complete') &&
        (uri.path == '/complete' || uri.path.isEmpty);
  }

  bool _isMobileAuthConsumeUrl(WebUri url) {
    return _isQuadPulseUrl(url) && url.path == '/auth/mobile/consume';
  }

  bool _isAuthenticatedAppUrl(WebUri url) {
    if (!_isQuadPulseUrl(url)) return false;
    final path = url.path.toLowerCase();
    return path == '/dashboard' || path.startsWith('/dashboard/');
  }

  bool _isLogoutUrl(WebUri url) {
    if (!_isQuadPulseUrl(url)) return false;
    final path = url.path.toLowerCase();
    return path == '/api/auth/logout' ||
        path == '/api/auth/signout' ||
        path == '/auth/logout' ||
        path == '/logout';
  }

  void _openPushHref(String? href) {
    final cleaned = href?.trim();
    if (cleaned == null || cleaned.isEmpty) return;

    final uri = _safeQuadPulseReturnUri(cleaned);
    if (uri == null) return;
    final destination = WebUri.uri(
      quadPulseBaseUri.replace(
        path: uri.path.isEmpty ? defaultMobileAuthReturnPath : uri.path,
        query: uri.hasQuery ? uri.query : null,
        fragment: uri.hasFragment ? uri.fragment : null,
      ),
    );

    _pendingDeepLink = destination;
    _loadPendingDeepLink();
  }

  WebUri _webUrlFromMobileAuthComplete(Uri uri) {
    final urlValue = uri.queryParameters['url'];
    if (urlValue != null) {
      final parsed = WebUri(urlValue);
      if (_isQuadPulseUrl(parsed)) return parsed;
    }

    final token = uri.queryParameters['token'];
    if (token != null && token.isNotEmpty) {
      debugPrint(
        'QuadPulse auth handoff: token received (${token.length} chars)',
      );
      return _mobileAuthConsumeUrl(token);
    }

    return quadPulseHomeUrl;
  }

  WebUri _mobileAuthConsumeUrl(String token) {
    return WebUri.uri(
      quadPulseBaseUri.replace(
        path: '/auth/mobile/consume',
        queryParameters: {
          'token': token,
          'qp_native': '1',
          'qp_native_platform': Platform.isAndroid ? 'android' : 'ios',
        },
      ),
    );
  }

  Future<void> _openSystemAuthSession(WebUri url) async {
    final authUrl = _systemAuthSessionUrl(url);
    debugPrint('QuadPulse auth handoff: opening external auth URL $authUrl');

    if (Platform.isIOS && await WebAuthenticationSession.isAvailable()) {
      await _openIosWebAuthenticationSession(authUrl);
      return;
    }

    if (_authBrowser.isOpened()) {
      await _authBrowser.close();
    }

    if (await ChromeSafariBrowser.isAvailable()) {
      await _authBrowser.open(
        url: authUrl,
        settings: ChromeSafariBrowserSettings(
          dismissButtonStyle: DismissButtonStyle.CLOSE,
          presentationStyle: ModalPresentationStyle.PAGE_SHEET,
          shareState: CustomTabsShareState.SHARE_STATE_OFF,
        ),
      );
      return;
    }

    await launchUrl(authUrl, mode: LaunchMode.externalApplication);
  }

  Future<void> _openIosWebAuthenticationSession(WebUri url) async {
    await _authSession?.cancel();
    await _authSession?.dispose();

    final session = await WebAuthenticationSession.create(
      url: url,
      callbackURLScheme: 'quadpulse',
      initialSettings: WebAuthenticationSessionSettings(
        prefersEphemeralWebBrowserSession: false,
      ),
      onComplete: (callbackUrl, error) async {
        final completedUri =
            callbackUrl == null ? null : Uri.tryParse(callbackUrl.toString());
        if (completedUri != null) {
          _openDeepLink(completedUri);
        }
        await _authSession?.dispose();
        _authSession = null;
      },
    );

    _authSession = session;

    if (!await session.canStart() || !await session.start()) {
      await session.dispose();
      _authSession = null;
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  void _closeAuthSurfaces() {
    _authBrowser.close();
    _authSession?.cancel();
    _authSession?.dispose();
    _authSession = null;
  }

  WebUri _systemAuthSessionUrl(WebUri url) {
    if (!_isAuthEntryUrl(url)) return url;

    final uri = Uri.tryParse(url.toString());
    if (uri == null) return url;

    final originalCallback = uri.queryParameters['callbackUrl'];
    final returnUrl = _safeQuadPulseDashboardReturnPath(originalCallback);
    final mobileCallback = Uri(path: mobileAuthCompleteUrl.path)
        .replace(queryParameters: {'returnUrl': returnUrl}).toString();

    final query = Map<String, String>.from(uri.queryParameters)
      ..remove('error')
      ..['qp_native'] = '1'
      ..['qp_native_platform'] = Platform.isIOS ? 'ios' : 'android'
      ..['callbackUrl'] = mobileCallback;

    return WebUri.uri(
      quadPulseBaseUri.replace(path: '/auth/signin', queryParameters: query),
    );
  }

  String _safeQuadPulseDashboardReturnPath(String? value) {
    final mobileReturnUrl = _returnUrlFromMobileAuthCallback(value);
    final uri = _safeQuadPulseReturnUri(mobileReturnUrl ?? value);
    if (uri == null) return defaultMobileAuthReturnPath;

    final path = uri.path.toLowerCase();
    if (path == defaultMobileAuthReturnPath ||
        path.startsWith('$defaultMobileAuthReturnPath/')) {
      return uri.toString();
    }

    return defaultMobileAuthReturnPath;
  }

  String? _returnUrlFromMobileAuthCallback(String? value) {
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty) return null;

    final uri = Uri.tryParse(cleaned);
    if (uri == null) return null;

    final isRelativeMobileCallback = cleaned.startsWith('/') &&
        !cleaned.startsWith('//') &&
        uri.path == mobileAuthCompleteUrl.path;
    final isAbsoluteMobileCallback = _isQuadPulseUrl(WebUri.uri(uri)) &&
        uri.path == mobileAuthCompleteUrl.path;
    if (!isRelativeMobileCallback && !isAbsoluteMobileCallback) return null;

    final returnUrl = uri.queryParameters['returnUrl']?.trim();
    return returnUrl == null || returnUrl.isEmpty ? null : returnUrl;
  }

  Uri? _safeQuadPulseReturnUri(String? value) {
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty) {
      return Uri.parse(defaultMobileAuthReturnPath);
    }

    final uri = Uri.tryParse(cleaned);
    if (uri == null) return Uri.parse(defaultMobileAuthReturnPath);

    if (cleaned.startsWith('/') && !cleaned.startsWith('//')) {
      return uri;
    }

    final parsed = WebUri.uri(uri);
    if (_isQuadPulseUrl(parsed)) {
      return Uri(
        path: uri.path.isEmpty ? '/' : uri.path,
        query: uri.hasQuery ? uri.query : null,
        fragment: uri.hasFragment ? uri.fragment : null,
      );
    }

    if (_isLocalhostUri(uri)) {
      return Uri(
        path: uri.path.isEmpty ? '/' : uri.path,
        query: uri.hasQuery ? uri.query : null,
        fragment: uri.hasFragment ? uri.fragment : null,
      );
    }

    return Uri.parse(defaultMobileAuthReturnPath);
  }

  Future<void> _maybeLogAuthConsumeResult(
    InAppWebViewController controller,
    WebUri? loadedUrl,
  ) async {
    final consumeUrl = _pendingConsumeCookieCheckUrl;
    if (consumeUrl == null) return;

    _pendingConsumeCookieCheckUrl = null;

    try {
      final cookies = await CookieManager.instance().getCookies(
        url: quadPulseCookieUrl,
        webViewController: controller,
      );
      final finalUrl = loadedUrl ?? await controller.getUrl();
      debugPrint(
        'QuadPulse auth handoff: consume completed; '
        'cookies for quadpulse.io=${cookies.length}; final URL=$finalUrl',
      );
    } catch (error) {
      debugPrint('QuadPulse auth handoff: cookie check failed: $error');
    }
  }

  String _redactedAuthUrl(WebUri url) {
    final uri = Uri.tryParse(url.toString());
    if (uri == null || !uri.queryParameters.containsKey('token')) {
      return url.toString();
    }

    final queryParameters = Map<String, String>.from(uri.queryParameters)
      ..['token'] = 'REDACTED';
    return uri.replace(queryParameters: queryParameters).toString();
  }

  bool _isLocalhostUri(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '0.0.0.0' ||
        host == '::1' ||
        host == '[::1]';
  }

  Uri _quadPulseUrlFromPath(Uri uri) {
    return quadPulseBaseUri.replace(
      path: uri.path.isEmpty ? '/' : uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    );
  }

  bool _looksLikeAuthFlow(WebUri url) {
    final host = url.host.toLowerCase();
    final path = url.path.toLowerCase();
    final query = url.query.toLowerCase();
    final authHosts = {
      'accounts.google.com',
      'appleid.apple.com',
      'login.microsoftonline.com',
      'github.com',
      'gitlab.com',
    };

    if (authHosts.contains(host) ||
        host.endsWith('.auth0.com') ||
        host.endsWith('.clerk.accounts.dev') ||
        host.endsWith('.firebaseapp.com') ||
        host.endsWith('.supabase.co')) {
      return true;
    }

    return path.contains('oauth') ||
        path.contains('auth') ||
        path.contains('callback') ||
        path.contains('signin') ||
        path.contains('sign-in') ||
        path.contains('login') ||
        query.contains('redirect_uri=') ||
        query.contains('client_id=') ||
        query.contains('response_type=');
  }

  Future<bool> _requestNativePermissions(
    List<PermissionResourceType> resources,
  ) async {
    final permissions = <Permission>{};

    for (final resource in resources) {
      if (resource == PermissionResourceType.CAMERA ||
          resource == PermissionResourceType.CAMERA_AND_MICROPHONE) {
        permissions.add(Permission.camera);
      }
      if (resource == PermissionResourceType.MICROPHONE ||
          resource == PermissionResourceType.CAMERA_AND_MICROPHONE) {
        permissions.add(Permission.microphone);
      }
      if (resource == PermissionResourceType.GEOLOCATION) {
        permissions.add(Permission.locationWhenInUse);
      }
      if (resource == PermissionResourceType.FILE_READ_WRITE) {
        permissions.add(Permission.photos);
      }
    }

    if (permissions.isEmpty) {
      return true;
    }

    final results = Map<Permission, PermissionStatus>.fromEntries(
      await Future.wait(
        permissions.map((permission) async {
          return MapEntry(permission, await permission.request());
        }),
      ),
    );
    return results.values.every(
      (status) => status.isGranted || status.isLimited,
    );
  }
}
