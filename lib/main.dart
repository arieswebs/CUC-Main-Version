import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'theme.dart';
import 'package:flutter/foundation.dart';

import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_storage_s3/amplify_storage_s3.dart';
import 'amplify_outputs.dart';
import 'models/ModelProvider.dart';
import 'package:window_manager/window_manager.dart';

import 'services/notification_service.dart';
import 'services/auth_service.dart';
import 'screens/dashboard_screen.dart';
import 'screens/admin_dashboard_screen.dart';
import 'screens/manager_dashboard_screen.dart';
import 'screens/delivery_dashboard_screen.dart';
import 'screens/client_portal/client_portal_dashboard_screen.dart';
import 'services/time_tracking_service.dart';
import 'services/meta_service.dart';

final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
String? _amplifyStartupError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Catch global errors to prevent the framework from crashing (especially useful for 
  // web plugins throwing async errors like google_sign_in_web COOP errors)
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Global Uncaught Error: $error');
    return true; 
  };
  
  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || 
                  defaultTargetPlatform == TargetPlatform.linux || 
                  defaultTargetPlatform == TargetPlatform.macOS)) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);

    WindowOptions windowOptions = const WindowOptions(
      size: Size(1366, 768),
      minimumSize: Size(1200, 800),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.maximize();
    });
  }

  try {
    final apiPlugin = AmplifyAPI(options: APIPluginOptions(modelProvider: ModelProvider.instance));
    final authPlugin = AmplifyAuthCognito();
    
    final plugins = <AmplifyPluginInterface>[apiPlugin, authPlugin];
    if (amplifyConfig.contains('"storage"')) {
      plugins.add(AmplifyStorageS3());
    }
    
    await Amplify.addPlugins(plugins);
    await Amplify.configure(amplifyConfig);
    debugPrint('✅ Amplify configured successfully');
  } on AmplifyAlreadyConfiguredException {
    debugPrint('⚠️ Amplify already configured (hot restart) - continuing');
  } catch (e, stacktrace) {
    final errMsg = 'AMPLIFY CONFIG ERROR:\n$e\n\n$stacktrace';
    debugPrint(errMsg);
    _amplifyStartupError = errMsg;
  }

  // Initialize local notifications for mobile
  await NotificationService().initLocalNotifications();

  // Wire up desktop notification toast support
  NotificationService.scaffoldMessengerKey = _scaffoldMessengerKey;

  // Start embedded Meta Webhook Server for inbound WhatsApp & Lead automation
  try {
    MetaWebhookServer().startServer(port: 8088);
  } catch (e) {
    debugPrint('Meta Webhook Server startup note: $e');
  }

  // Force login on every startup to track time accurately
  // This also gracefully logs out any session that was previously killed unexpectedly
  await AuthService().logout();

  runApp(MyApp(startupError: _amplifyStartupError));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, this.startupError});
  final String? startupError;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WindowListener, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || 
                    defaultTargetPlatform == TargetPlatform.linux || 
                    defaultTargetPlatform == TargetPlatform.macOS)) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // App is being swiped away / killed
      // Location tracking features have been removed
    }
  }

  @override
  void onWindowClose() async {
    // Flush time tracker and logout before exiting
    TimeTrackingService.instance.stopTracking();
    await AuthService().logout();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => TimeTrackingService.instance.registerActivity(),
      onPointerSignal: (_) => TimeTrackingService.instance.registerActivity(),
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Cochin United',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _scaffoldMessengerKey,
        theme: AppTheme.lightTheme(),
        home: widget.startupError != null
            ? Scaffold(
                backgroundColor: Colors.red.shade900,
                body: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: SelectableText(
                      '⚠️ AMPLIFY STARTUP ERROR\n\n${widget.startupError}',
                      style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              )
            : const AuthWrapper(),
      ),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService();
    return FutureBuilder<bool>(
      future: auth.isLoggedIn(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: AppTheme.primaryColor),
            ),
          );
        }
        
        if (snapshot.data == true) {
          return FutureBuilder<String?>(
            future: auth.getUserRole(),
            builder: (context, roleSnapshot) {
              if (roleSnapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  body: Center(
                    child: CircularProgressIndicator(color: AppTheme.primaryColor),
                  ),
                );
              }
              
              final role = roleSnapshot.data;
              if (role == 'admin') return const AdminDashboardScreen();
              if (role == 'manager') return const ManagerDashboardScreen();
              if (role == 'delivery') return const DeliveryDashboardScreen();
              if (role == 'client') return const ClientPortalDashboardScreen();
              // Default to DashboardScreen for accountant and others
              return const DashboardScreen();
            },
          );
        }
        
        return const LoginScreen();
      },
    );
  }
}
