import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/diet_plan.dart';
import 'auth_service.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class ApiService {
  /// POSTs the user's metrics to the backend proxy and returns the parsed plan.
  /// Generation can take a while (the model streams a multi-day plan), so the
  /// timeout is generous.
  static Future<DietPlan> generatePlan(Map<String, dynamic> body) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/plan');

    final token = AuthService.instance.token;
    http.Response resp;
    try {
      resp = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 240));
    } catch (e) {
      throw ApiException(
        'Could not reach the server at ${AppConfig.apiBaseUrl}.\n'
        'Is the backend running? ($e)',
      );
    }

    if (resp.statusCode == 200) {
      return DietPlan.fromResponse(jsonDecode(resp.body) as Map<String, dynamic>);
    }

    // Token missing/expired — clear the session so the gate sends them to login.
    if (resp.statusCode == 401) {
      await AuthService.instance.logout();
      throw ApiException('Your session expired. Please log in again.');
    }

    // Surface the backend's error message(s) when present.
    String message;
    try {
      final err = jsonDecode(resp.body);
      final e = err is Map ? err['error'] : null;
      message = e is List ? e.join('\n') : (e?.toString() ?? 'Request failed');
    } catch (_) {
      message = 'Request failed (HTTP ${resp.statusCode}).';
    }
    throw ApiException(message);
  }
}
