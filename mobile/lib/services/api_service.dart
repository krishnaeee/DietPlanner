import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/billing.dart';
import '../models/activity.dart';
import '../models/diet_plan.dart';
import '../models/recipe.dart';
import '../models/review.dart';
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

  /// Fetches step-by-step preparation for a dish. A server-side cache HIT is
  /// free; a MISS costs one credit (or is free on an active subscription) and is
  /// then cached for everyone. Throws [PaymentRequiredException] on 402.
  static Future<Recipe> getRecipe(Map<String, dynamic> body) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/recipe');
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
          .timeout(const Duration(seconds: 90));
    } catch (e) {
      throw ApiException('Could not reach the server. ($e)');
    }

    if (resp.statusCode == 200) {
      final b = jsonDecode(resp.body) as Map<String, dynamic>;
      // A cache-miss response carries the post-charge balance — keep it in sync.
      if (b['account'] is Map) {
        BillingService.instance
            .applyEntitlements(Entitlements.fromJson(b['account'] as Map<String, dynamic>));
      }
      final r = b['recipe'];
      if (r is Map<String, dynamic>) return Recipe.fromJson(r);
      throw ApiException('The server returned no recipe.');
    }
    if (resp.statusCode == 401) {
      await AuthService.instance.logout();
      throw ApiException('Your session expired. Please log in again.');
    }
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
    String message;
    try {
      final err = jsonDecode(resp.body);
      final e = err is Map ? err['error'] : null;
      message = e?.toString() ?? 'Could not get preparation steps.';
    } catch (_) {
      message = 'Could not get preparation steps (HTTP ${resp.statusCode}).';
    }
    throw ApiException(message);
  }

  /// Asks the model to review progress from the user's own recorded figures.
  /// Free (auth only). [body] carries the already-computed summary numbers.
  static Future<Review> getReview(Map<String, dynamic> body) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/review');
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
          .timeout(const Duration(seconds: 90));
    } catch (e) {
      throw ApiException('Could not reach the server. ($e)');
    }

    if (resp.statusCode == 200) {
      final b = jsonDecode(resp.body) as Map<String, dynamic>;
      final r = b['review'];
      if (r is Map<String, dynamic>) return Review.fromJson(r);
      throw ApiException('The server returned no review.');
    }
    if (resp.statusCode == 401) {
      await AuthService.instance.logout();
      throw ApiException('Your session expired. Please log in again.');
    }
    String message;
    try {
      final err = jsonDecode(resp.body);
      final e = err is Map ? err['error'] : null;
      message = e?.toString() ?? 'Could not review your progress.';
    } catch (_) {
      message = 'Could not review your progress (HTTP ${resp.statusCode}).';
    }
    throw ApiException(message);
  }

  /// Suggests activities for a day or a week. Free (auth only).
  static Future<ActivityPlan> getActivity(Map<String, dynamic> body) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/activity');
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
          .timeout(const Duration(seconds: 90));
    } catch (e) {
      throw ApiException('Could not reach the server. ($e)');
    }

    if (resp.statusCode == 200) {
      final b = jsonDecode(resp.body) as Map<String, dynamic>;
      final a = b['activity'];
      if (a is Map<String, dynamic>) return ActivityPlan.fromJson(a);
      throw ApiException('The server returned no suggestions.');
    }
    if (resp.statusCode == 401) {
      await AuthService.instance.logout();
      throw ApiException('Your session expired. Please log in again.');
    }
    String message;
    try {
      final err = jsonDecode(resp.body);
      final e = err is Map ? err['error'] : null;
      message = e?.toString() ?? 'Could not suggest activities.';
    } catch (_) {
      message = 'Could not suggest activities (HTTP ${resp.statusCode}).';
    }
    throw ApiException(message);
  }

  /// Reads the last stored review for a plan (no generation) with the time it
  /// was generated. `review` is null when none exists yet. Free (auth only).
  static Future<({Review? review, DateTime? updatedAt})> getStoredReview(
      String planId) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/review?planId=$planId');
    final token = AuthService.instance.token;
    http.Response resp;
    try {
      resp = await http.get(
        uri,
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ApiException('Could not reach the server. ($e)');
    }
    if (resp.statusCode == 200) {
      final b = jsonDecode(resp.body) as Map<String, dynamic>;
      final r = b['review'];
      return (
        review: r is Map<String, dynamic> ? Review.fromJson(r) : null,
        updatedAt: DateTime.tryParse('${b['updatedAt'] ?? ''}'),
      );
    }
    if (resp.statusCode == 401) {
      await AuthService.instance.logout();
      throw ApiException('Your session expired. Please log in again.');
    }
    throw ApiException('Could not load your review (HTTP ${resp.statusCode}).');
  }

  /// Reads the last stored activity for a plan + scope (no generation) with the
  /// time it was generated. `activity` is null when none exists. Free (auth).
  static Future<({ActivityPlan? activity, DateTime? updatedAt})> getStoredActivity(
      String planId, String scope) async {
    final uri = Uri.parse(
        '${AppConfig.apiBaseUrl}/api/activity?planId=$planId&scope=$scope');
    final token = AuthService.instance.token;
    http.Response resp;
    try {
      resp = await http.get(
        uri,
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ApiException('Could not reach the server. ($e)');
    }
    if (resp.statusCode == 200) {
      final b = jsonDecode(resp.body) as Map<String, dynamic>;
      final a = b['activity'];
      return (
        activity: a is Map<String, dynamic> ? ActivityPlan.fromJson(a) : null,
        updatedAt: DateTime.tryParse('${b['updatedAt'] ?? ''}'),
      );
    }
    if (resp.statusCode == 401) {
      await AuthService.instance.logout();
      throw ApiException('Your session expired. Please log in again.');
    }
    throw ApiException('Could not load your activity (HTTP ${resp.statusCode}).');
  }
}
