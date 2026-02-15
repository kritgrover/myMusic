import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_http_client.dart';
import 'services/auth_service.dart';

// Modern color palette for dedicated music listeners
const Color primaryAccent = Color(0xFF6366F1); // Indigo
const Color secondaryAccent = Color(0xFF8B5CF6); // Purple
const Color surfaceDark = Color(0xFF0F0F0F);
const Color surfaceElevated = Color(0xFF1A1A1A);
const Color surfaceHover = Color(0xFF252525);
const Color textPrimary = Color(0xFFF5F5F5);
const Color textSecondary = Color(0xFFA3A3A3);
const Color textTertiary = Color(0xFF737373);
const Color dividerColor = Color(0xFF262626);

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final AuthService _authService = AuthService();

  @override
  void initState() {
    super.initState();
    AuthHttpClient.shared.configure(
      tokenProvider: () => _authService.token,
      onUnauthorized: _authService.handleUnauthorized,
    );
    _authService.initialize();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'myMusic',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: primaryAccent,
          onPrimary: Colors.white,
          secondary: secondaryAccent,
          onSecondary: Colors.white,
          surface: surfaceElevated,
          onSurface: textPrimary,
          background: surfaceDark,
          onBackground: textPrimary,
          error: const Color(0xFFEF4444),
          onError: Colors.white,
          surfaceVariant: surfaceHover,
        ),
        scaffoldBackgroundColor: surfaceDark,
        appBarTheme: AppBarTheme(
          backgroundColor: surfaceDark,
          foregroundColor: textPrimary,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: const TextStyle(
            color: textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryAccent,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: primaryAccent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: textPrimary,
            side: const BorderSide(color: dividerColor, width: 1),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: textSecondary,
            hoverColor: surfaceHover,
            padding: const EdgeInsets.all(8),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: primaryAccent,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surfaceElevated,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: primaryAccent, width: 2),
          ),
          hintStyle: const TextStyle(color: textTertiary),
          labelStyle: const TextStyle(color: textSecondary),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(color: textPrimary, fontSize: 57, fontWeight: FontWeight.w400, letterSpacing: -0.25),
          displayMedium: TextStyle(color: textPrimary, fontSize: 45, fontWeight: FontWeight.w400, letterSpacing: 0),
          displaySmall: TextStyle(color: textPrimary, fontSize: 36, fontWeight: FontWeight.w400, letterSpacing: 0),
          headlineLarge: TextStyle(color: textPrimary, fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 0),
          headlineMedium: TextStyle(color: textPrimary, fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: 0),
          headlineSmall: TextStyle(color: textPrimary, fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: 0),
          titleLarge: TextStyle(color: textPrimary, fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: 0),
          titleMedium: TextStyle(color: textPrimary, fontSize: 16, fontWeight: FontWeight.w500, letterSpacing: 0.15),
          titleSmall: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.1),
          bodyLarge: TextStyle(color: textPrimary, fontSize: 16, fontWeight: FontWeight.w400, letterSpacing: 0.5),
          bodyMedium: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w400, letterSpacing: 0.25),
          bodySmall: TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w400, letterSpacing: 0.4),
          labelLarge: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.1),
          labelMedium: TextStyle(color: textSecondary, fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.5),
          labelSmall: TextStyle(color: textTertiary, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.5),
        ),
        cardTheme: CardThemeData(
          color: surfaceElevated,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: EdgeInsets.zero,
        ),
        listTileTheme: ListTileThemeData(
          textColor: textPrimary,
          iconColor: textSecondary,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: surfaceDark,
          selectedIconTheme: const IconThemeData(color: primaryAccent, size: 24),
          selectedLabelTextStyle: const TextStyle(
            color: primaryAccent,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          unselectedIconTheme: const IconThemeData(color: textTertiary, size: 24),
          unselectedLabelTextStyle: const TextStyle(
            color: textTertiary,
            fontSize: 12,
            fontWeight: FontWeight.w400,
          ),
          indicatorColor: surfaceElevated,
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: primaryAccent,
          inactiveTrackColor: dividerColor,
          thumbColor: primaryAccent,
          overlayColor: primaryAccent.withOpacity(0.1),
          trackHeight: 4,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: MaterialStateProperty.resolveWith<Color?>(
            (Set<MaterialState> states) {
              if (states.contains(MaterialState.selected)) {
                return primaryAccent;
              }
              return null;
            },
          ),
          checkColor: MaterialStateProperty.all(Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: primaryAccent,
        ),
        dividerTheme: const DividerThemeData(
          color: dividerColor,
          thickness: 1,
          space: 1,
        ),
      ),
      home: ListenableBuilder(
        listenable: _authService,
        builder: (context, _) {
          if (!_authService.isInitialized || _authService.isLoading) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          }
          if (_authService.isAuthenticated) {
            return HomeScreen(authService: _authService);
          }
          return LoginScreen(authService: _authService);
        },
      ),
    );
  }
}


