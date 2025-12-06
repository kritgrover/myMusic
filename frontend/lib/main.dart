import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

// Neon blue color for highlights
const Color neonBlue = Color(0xFF00D9FF);

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'myMusic',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: neonBlue,
          onPrimary: Colors.black,
          secondary: neonBlue,
          onSecondary: Colors.black,
          surface: Colors.black,
          onSurface: neonBlue,
          background: Colors.black,
          onBackground: neonBlue,
          error: Colors.red,
          onError: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: neonBlue,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: neonBlue,
            foregroundColor: Colors.black,
            elevation: 0,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: neonBlue,
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: neonBlue,
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: neonBlue,
          foregroundColor: Colors.black,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: neonBlue),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: neonBlue),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: neonBlue, width: 2),
          ),
          hintStyle: TextStyle(color: Colors.grey[600]),
          labelStyle: const TextStyle(color: neonBlue),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(color: neonBlue),
          displayMedium: TextStyle(color: neonBlue),
          displaySmall: TextStyle(color: neonBlue),
          headlineLarge: TextStyle(color: neonBlue),
          headlineMedium: TextStyle(color: neonBlue),
          headlineSmall: TextStyle(color: neonBlue),
          titleLarge: TextStyle(color: neonBlue),
          titleMedium: TextStyle(color: neonBlue),
          titleSmall: TextStyle(color: neonBlue),
          bodyLarge: TextStyle(color: neonBlue),
          bodyMedium: TextStyle(color: neonBlue),
          bodySmall: TextStyle(color: Colors.grey),
        ),
        cardTheme: CardThemeData(
          color: Colors.grey[900],
          elevation: 0,
        ),
        listTileTheme: const ListTileThemeData(
          textColor: neonBlue,
          iconColor: neonBlue,
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: Colors.black,
          selectedIconTheme: const IconThemeData(color: neonBlue),
          selectedLabelTextStyle: const TextStyle(color: neonBlue),
          unselectedIconTheme: const IconThemeData(color: Colors.grey),
          unselectedLabelTextStyle: const TextStyle(color: Colors.grey),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: neonBlue,
          inactiveTrackColor: Colors.grey[800],
          thumbColor: neonBlue,
          overlayColor: neonBlue.withOpacity(0.2),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: MaterialStateProperty.resolveWith<Color?>(
            (Set<MaterialState> states) {
              if (states.contains(MaterialState.selected)) {
                return neonBlue;
              }
              return null;
            },
          ),
          checkColor: MaterialStateProperty.all(Colors.black),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: neonBlue,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}


