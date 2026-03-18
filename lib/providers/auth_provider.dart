import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class AuthState {
  final String? username;
  final String? token;
  final String? role;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.username,
    this.token,
    this.role,
    this.isLoading = false,
    this.error,
  });

  bool get isLoggedIn => token != null && token!.isNotEmpty;
  bool get isAdmin => role == 'admin';
}

class AuthNotifier extends StateNotifier<AuthState> {
  final Box _box;
  static const _tokenKey = 'auth_token';
  static const _usernameKey = 'auth_username';
  static const _roleKey = 'auth_role';

  AuthNotifier(this._box) : super(const AuthState()) {
    final token = _box.get(_tokenKey) as String?;
    final username = _box.get(_usernameKey) as String?;
    final role = _box.get(_roleKey) as String?;
    if (token != null && username != null) {
      state = AuthState(token: token, username: username, role: role);
    }
  }

  Future<void> login(String serverUrl, String username, String password) async {
    state = const AuthState(isLoading: true);
    try {
      final res = await http
          .post(
            Uri.parse('${serverUrl.replaceAll(RegExp(r'/$'), '')}/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200) {
        final token = data['token'] as String;
        final role = data['role'] as String? ?? 'user';
        await _box.put(_tokenKey, token);
        await _box.put(_usernameKey, username);
        await _box.put(_roleKey, role);
        state = AuthState(token: token, username: username, role: role);
      } else {
        state = AuthState(error: data['error'] as String? ?? '로그인 실패');
      }
    } catch (e) {
      state = AuthState(error: '서버 연결 실패: $e');
    }
  }

  Future<void> logout(String serverUrl) async {
    final token = state.token;
    if (token != null) {
      try {
        await http
            .post(
              Uri.parse(
                '${serverUrl.replaceAll(RegExp(r'/$'), '')}/auth/logout',
              ),
              headers: {'Authorization': 'Bearer $token'},
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _box.delete(_tokenKey);
    await _box.delete(_usernameKey);
    await _box.delete(_roleKey);
    state = const AuthState();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(Hive.box('settings'));
});
