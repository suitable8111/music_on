import 'package:flutter/material.dart';
import 'core/constants/app_colors.dart';
import 'ui/screens/home_screen.dart';

class MusicOnApp extends StatelessWidget {
  const MusicOnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music On',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          surface: AppColors.surface,
        ),
        scaffoldBackgroundColor: AppColors.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          iconTheme: IconThemeData(color: AppColors.textPrimary),
        ),
        tabBarTheme: const TabBarThemeData(
          indicatorColor: AppColors.primary,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: AppColors.card,
          contentTextStyle: TextStyle(color: AppColors.textPrimary),
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
