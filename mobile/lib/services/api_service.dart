import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/billing.dart';
import '../models/diet_plan.dart';
import 'auth_service.dart';
import 'billing_service.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// Thrown when the backend rejects a generation for lack of credits/subscription
/// (HTTP 402). Carries the latest balance so the UI can show the paywall.
class PaymentRequiredException implements Exception {
  final String message;
  final Entitlements entitlements;
  PaymentRequiredException(this.message, this.entitlements);
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
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      // The backend returns the post-charge balance — keep the UI in sync.
      if (body['account'] is Map) {
        BillingService.instance
            .applyEntitlements(Entitlements.fromJson(body['account'] as Map<String, dynamic>));
      }
      return DietPlan.fromResponse(body);
    }

    // Token missing/expired — clear the session so the gate sends them to login.
    if (resp.statusCode == 401) {
      await AuthService.instance.logout();
      throw ApiException('Your session expired. Please log in again.');
    }

    // Out of credits / no subscription — surface a typed error for the paywall.
    if (resp.statusCode == 402) {
      Entitlements ent = const Entitlements();
      String message = "You're out of credits.";
      try {
        final err = jsonDecode(resp.body) as Map<String, dynamic>;
        message = err['error']?.toString() ?? message;
        if (err['entitlements'] is Map) {
          ent = Entitlements.fromJson(err['entitlements'] as Map<String, dynamic>);
        }
      } catch (_) {}
      BillingService.instance.applyEntitlements(ent);
      throw PaymentRequiredException(message, ent);
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

  /// Regenerates a single meal (a "swap"). Free on the backend (auth only), so
  /// no paywall path here. Returns the replacement meal.
  static Future<Meal> swapMeal(Map<String, dynamic> body) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/plan/meal');
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
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      throw ApiException('Could not reach the server. ($e)');
    }

    if (resp.statusCode == 200) {
      final b = jsonDecode(resp.body) as Map<String, dynamic>;
      final meal = b['meal'];
      if (meal is Map<String, dynamic>) return Meal.fromJson(meal);
      throw ApiException('The server returned no meal.');
    }
    if (resp.statusCode == 401) {
      await AuthService.instance.logout();
      throw ApiException('Your session expired. Please log in again.');
    }
    String message;
    try {
      final err = jsonDecode(resp.body);
      final e = err is Map ? err['error'] : null;
      message = e?.toString() ?? 'Could not swap the meal.';
    } catch (_) {
      message = 'Could not swap the meal (HTTP ${resp.statusCode}).';
    }
    throw ApiException(message);
  }
}
