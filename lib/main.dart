import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

final WebUri quadPulseHomeUrl = WebUri('https://quadpulse.io/home');
final WebUri mobileAuthCompleteUrl =
    WebUri('https://quadpulse.io/auth/mobile/complete');
final Uri quadPulseBaseUri = Uri.parse('https://quadpulse.io');
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
  int? _popupWindowId;
  DateTime? _lastBackPressAt;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
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
                  initialSettings: InAppWebViewSettings(
                    allowsBackForwardNavigationGestures: true,
                    allowsInlineMediaPlayback: true,
                    applicationNameForUserAgent: 'QuadPulse-WebNative',
                    geolocationEnabled: true,
                    javaScriptCanOpenWindowsAutomatically: true,
                    javaScriptEnabled: true,
                    mediaPlaybackRequiresUserGesture: false,
                    supportMultipleWindows: true,
                    transparentBackground: false,
                    useShouldOverrideUrlLoading: true,
                  ),
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
                    if (canonicalUrl.toString() == url.toString()) return;

                    await controller.stopLoading();
                    await _loadInMainWebView(canonicalUrl);
                  },
                  onLoadStop: (_, __) {
                    if (mounted) setState(() => _progress = 1);
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
                          initialSettings: InAppWebViewSettings(
                            applicationNameForUserAgent: 'QuadPulse-WebNative',
                            javaScriptCanOpenWindowsAutomatically: true,
                            javaScriptEnabled: true,
                            mediaPlaybackRequiresUserGesture: false,
                            supportMultipleWindows: true,
                            useShouldOverrideUrlLoading: true,
                          ),
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

  void _openDeepLink(Uri uri) {
    final webUri = WebUri.uri(uri);
    if (_isMobileAuthCompleteUri(uri)) {
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

  WebUri _webUrlFromMobileAuthComplete(Uri uri) {
    final urlValue = uri.queryParameters['url'];
    if (urlValue != null) {
      final parsed = WebUri(urlValue);
      if (_isQuadPulseUrl(parsed)) return parsed;
    }

    final token = uri.queryParameters['token'];
    if (token != null && token.isNotEmpty) {
      return WebUri(
        'https://quadpulse.io/auth/mobile/consume?token=${Uri.encodeQueryComponent(token)}',
      );
    }

    return quadPulseHomeUrl;
  }

  Future<void> _openSystemAuthSession(WebUri url) async {
    final authUrl = _systemAuthSessionUrl(url);

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
    final returnUrl = _safeQuadPulseDashboardReturnUrl(originalCallback);
    final mobileCallback = Uri.parse(mobileAuthCompleteUrl.toString())
        .replace(queryParameters: {'returnUrl': returnUrl}).toString();

    final query = Map<String, String>.from(uri.queryParameters)
      ..remove('error')
      ..['qp_native'] = '1'
      ..['qp_native_platform'] = Platform.isIOS ? 'ios' : 'android'
      ..['callbackUrl'] = mobileCallback;

    return WebUri.uri(uri.replace(queryParameters: query));
  }

  String _safeQuadPulseDashboardReturnUrl(String? value) {
    final mobileReturnUrl = _returnUrlFromMobileAuthCallback(value);
    final url = _safeQuadPulseReturnUrl(mobileReturnUrl ?? value);
    final uri = Uri.tryParse(url);
    if (uri == null) return quadPulseHomeUrl.toString();

    final path = uri.path.toLowerCase();
    if (path.startsWith('/auth/') || path.startsWith('/api/auth/')) {
      return quadPulseHomeUrl.toString();
    }

    return url;
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

  String _safeQuadPulseReturnUrl(String? value) {
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty) {
      return quadPulseHomeUrl.toString();
    }

    final uri = Uri.tryParse(cleaned);
    if (uri == null) return quadPulseHomeUrl.toString();

    if (cleaned.startsWith('/') && !cleaned.startsWith('//')) {
      return _quadPulseUrlFromPath(uri).toString();
    }

    final parsed = WebUri.uri(uri);
    if (_isQuadPulseUrl(parsed)) {
      return uri.toString();
    }

    if (_isLocalhostUri(uri)) {
      return _quadPulseUrlFromPath(uri).toString();
    }

    return quadPulseHomeUrl.toString();
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
