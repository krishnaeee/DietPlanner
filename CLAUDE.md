# AI Diet Planner — CLAUDE.md

An AI-powered diet planner pairing a **Flutter** mobile app with a **Node/Express** backend that proxies authenticated plan generation to a pluggable **LLM provider** — **Anthropic Claude** (`claude-opus-4-8`, default) or **Google Gemini** (`gemini-2.5-flash`), switched with one env var. Users sign up with email+password or Google, fill a body/goal form, and the model returns a structured multi-day meal plan that the app renders, saves per account, and turns into local reminders (a grocery alert at 7 PM the day before + meal-time alarms). The backend keeps the LLM API key off the device and stores accounts in SQLite; **plans live only on the device** (per-account `SharedPreferences`) and are not yet server-synced.

## Architecture

```
┌─────────────────────────────────────────────┐
│            Flutter app (mobile/lib)           │
│                                               │
│  AuthGate → Login/Signup/Google → InputScreen │
│                       │  → PlanScreen          │
│  ┌─────────────────────────────────────────┐ │
│  │ On-device SharedPreferences               │ │
│  │  • JWT + email   (auth_token / auth_email)│ │
│  │  • plans PER ACCOUNT                       │ │
│  │     saved_plans_v2::<email>   (LOCAL ONLY)│ │
│  │  • local notification reminders           │ │
│  └─────────────────────────────────────────┘ │
└───────────────┬───────────────────────────────┘
                │ HTTPS/HTTP + Bearer JWT
                ▼
┌─────────────────────────────────────────────┐
│        Backend proxy (Node/Express 5)         │
│                                               │
│   /api/auth  (signup·login·google·me)         │
│   /api/plan  (requireAuth) ──────────┐        │
│   /health                            │        │
│        │                             │        │
│        ▼                             ▼        │
│  ┌───────────────┐    ┌──────────────────┐   │
│  │ SQLite (users)│    │ LLM provider     │   │
│  │ node:sqlite   │    │ providers.js     │   │
│  │ id·email·hash·│    │  anthropic|gemini│   │
│  │ google_sub    │    │ JSON ≤ MAX_PLAN_DAYS│ │
│  └───────────────┘    └──────────────────┘   │
└─────────────────────────────────────────────┘
```

Accounts (and password hashes / Google links) persist server-side in SQLite. Generated plans never reach the server — they are persisted only in on-device `SharedPreferences`, namespaced per signed-in account.

## Repository layout

```
diet-planner-app/
├── backend/
│   ├── server.js          Express app: route mounting, CORS, JSON limit, /health, /api/plan + input validation, request timing logs
│   ├── auth.js            authRouter (signup/login/google/me) + requireAuth middleware; bcrypt, JWT, Google ID-token verify
│   ├── db.js              SQLite user store via node:sqlite (DatabaseSync); createUser/findUserByEmail/findUserById/linkGoogle + migration
│   ├── planService.js     generatePlan(): provider-agnostic orchestration — day cap, heartbeat logging, JSON parsing
│   ├── providers.js       Provider layer: getProvider()/describeProvider(); anthropic + gemini generate() impls, schema dialect conversion
│   ├── planSchema.js      PLAN_SCHEMA (strict JSON Schema) + buildPrompt() (system + user prompt)
│   ├── package.json       ES-module config, scripts (dev/start), deps
│   └── .env.example       Documents all env vars
│
└── mobile/lib/
    ├── main.dart                    Bootstrap: notif init, overlay style, MaterialApp(home: AuthGate), cold-start deep link
    ├── config.dart                  AppConfig: apiBaseUrl resolution, googleServerClientId (--dart-define)
    ├── models/
    │   └── diet_plan.dart           Ingredient/Meal/DayPlan/DietPlan models + fromResponse/toResponseJson round-trip
    ├── screens/
    │   ├── auth_gate.dart           AuthGate: splash → verify JWT → InputScreen | LoginScreen (reactive)
    │   ├── login_screen.dart        Email/password + Google login form
    │   ├── signup_screen.dart       Email/password (+confirm) + Google signup form
    │   ├── input_screen.dart        Home: body/goal form, saved-plans list, account menu, Generate
    │   └── plan_screen.dart         Plan generation/display, cooking loader, day/meal cards, reminder bar
    ├── services/
    │   ├── auth_service.dart        AuthService singleton: session, signup/login/google/verify/logout, authState notifier
    │   ├── api_service.dart         ApiService.generatePlan(): POST /api/plan with Bearer, 240s timeout
    │   ├── plan_storage.dart        StoredPlan model + PlanStorage: per-account SharedPreferences CRUD, slot allocation, migration
    │   ├── notification_service.dart NotificationService singleton: schedule/cancel reminders, ID/slot scheme, tz, permissions
    │   └── app_router.dart          appNavigatorKey + routeFromNotification() deep-link into PlanScreen
    ├── widgets/
    │   ├── auth_widgets.dart        validateEmail, AuthField, AuthBadge, OrDivider, GoogleSignInButton, AuthFooter
    │   └── common.dart              GradientHeader, SectionCard, FieldLabel
    └── theme/
        └── app_theme.dart          AppColors, AppRadius, softShadow, AppTheme.light() (Material 3, Plus Jakarta Sans)
```

## End-to-end flow

1. **Launch.** `main()` runs `WidgetsFlutterBinding.ensureInitialized()`, sets a transparent status bar, then `await NotificationService.instance.init()` (initializes the plugin + timezones; does **not** request permission yet). It wires `NotificationService.instance.onTap = routeFromNotification`, calls `runApp(const DietPlannerApp())`, then awaits `initialLaunchPayload()` — if a notification cold-started the app, it routes via a post-frame callback once the navigator exists.
2. **AuthGate.** `DietPlannerApp` builds `MaterialApp(home: AuthGate)`. `AuthGate._init()` calls `AuthService.instance.loadSession()` (hydrate saved JWT + email) then `verify()` (GET `/api/auth/me` with the Bearer token). A definitive `401` clears the session and logs out; any network error is swallowed (offline users stay logged in). While checking, a brand-gradient splash with a leaf icon shows.
3. **Login / Signup / Google.** A `ValueListenableBuilder` on `AuthService.instance.authState` renders `InputScreen` when logged in, else `LoginScreen`. Email/password flows call `signup`/`login`; Google flows call `googleLogin()` (google_sign_in 7.x: `initialize(serverClientId)`, `authenticate()`, extract `idToken`, POST `/api/auth/google`). On success `authState` flips and the gate swaps to home — no manual navigation.
4. **Home (InputScreen).** `initState → _initForUser()` runs `PlanStorage.loadAll()` then `NotificationService.instance.rescheduleAll(list)`, re-syncing reminders to the current account's plans (which clears the previous user's first). The screen shows the body/goal form and a `_SavedPlansSection` listing this account's `StoredPlan`s (open/rename/delete).
5. **Fill form + Generate.** The user enters weight/height/target weight, location, target period (weeks/days), optional age/sex/activity/diet preference, and a plan name ("Who is this for?"). A live goal banner shows lose/gain/maintain. `_submit()` validates, converts the period to `targetDays`, builds the request body, and pushes `PlanScreen(requestBody, location, planName)`.
6. **POST /api/plan.** `ApiService.generatePlan(body)` POSTs to `${apiBaseUrl}/api/plan` with `Content-Type: application/json` and `Authorization: Bearer <token>`, with a **240s** timeout. A `401` triggers `logout()` + "session expired".
7. **Backend validates + calls the LLM.** `requireAuth` verifies the JWT; `validate()` range-checks the body; `generatePlan()` resolves the active provider via `getProvider()` and calls its `generate()`. Anthropic streams `messages.stream({...})` + `finalMessage()` with `thinking: { type: 'adaptive' }` and `output_config.format` = the strict `PLAN_SCHEMA`; Gemini calls `models.generateContent({...})` with `responseMimeType: 'application/json'` + a converted schema. Either way the model returns one JSON object. Days are capped at `MAX_PLAN_DAYS` (`plannedDays = min(targetDays, cap)`); the response is `{ plan, meta }` where `meta.truncated` is true if the goal exceeded the cap and `meta.provider`/`meta.model` record what produced it.
8. **Plan rendered + auto-saved.** `PlanScreen` shows a `_CookingLoader` during generation, then `_PlanView` (summary, day selector, per-meal cards, truncation banner). On success it builds a `StoredPlan` (`id` = `microsecondsSinceEpoch`, `slot = PlanStorage.nextSlot(all)`, `startDate` = tomorrow, `remindersScheduled: false`) and `PlanStorage.upsert(sp)` — auto-saved under the account.
9. **Set daily reminders.** Tapping "Set daily reminders" opens a Today/Tomorrow picker, calls `requestPermissions()`, then upserts `remindersScheduled: true` and runs `_rescheduleAndRefresh()`. `NotificationService` schedules, per plan slot: a **grocery alert at 7 PM the day before** each day (deduped ingredient shopping list) plus **meal-time alarms** at each meal's parsed `HH:mm`. IDs are namespaced per plan slot so people never collide.
10. **Reminders persist; logout/login reconcile.** Scheduled counts are written back to each `StoredPlan`, and reminders survive reboot (boot receiver re-arms them). **Logout** (`_AccountMenu`) calls `NotificationService.instance.cancelAll()` before `AuthService.instance.logout()`; **login** re-syncs via the home's `_initForUser → rescheduleAll`.

## Backend reference

### Endpoints

| Method & path | Auth | Purpose |
|---|---|---|
| `GET /health` | No | Liveness; returns `{ ok: true, maxPlanDays }` |
| `POST /api/auth/signup` | No | Create account → `{ token, user }` (`400` invalid, `409` exists) |
| `POST /api/auth/login` | No | Authenticate → `{ token, user }` (`401` bad creds) |
| `POST /api/auth/google` | No | Verify Google ID token, find-or-create account → `{ token, user }` |
| `GET /api/auth/me` | Yes | Validate token; returns `{ user: { id, email } }` |
| `POST /api/plan` | Yes | Generate diet plan → `{ plan, meta }` |

Global middleware: `express.json({ limit: '1mb' })` and `cors()` (wide open). Auth routes are an Express `Router` (`authRouter`) mounted at `/api/auth`.

**`POST /api/plan` body** — required & range-checked by `validate()`: `weightKg` (0–500), `heightCm` (0–300), `targetWeightKg` (0–500), `targetDays` (1–365, rounded), `location` (non-empty). Optional: `age` (0–120), `sex` (`SEXES`: male/female/other), `activityLevel` (`ACTIVITY`: sedentary/light/moderate/active/very_active), `dietaryPreference` (string). Invalid optionals add to a `{ error: [...] }` 400 list.

**`POST /api/plan` success** —
```
{
  plan: { summary, dailyCalorieTarget,
          days: [ { day, totalCalories,
                    meals: [ { name, time, dish, description, calories,
                               ingredients: [ { name, quantity } ] } ] } ] },
  meta: { requestedDays, plannedDays, truncated, provider, model }
}
```
`truncated` is true when `targetDays > plannedDays` (goal exceeded `MAX_PLAN_DAYS`); `provider`/`model` name what generated the plan. Errors: `400` validation, `401` no/invalid token, `422` model refusal/safety block, `500` missing key or unknown provider, `502` empty/unparseable output.

### Auth internals (`auth.js` + `db.js`)

- **Password hashing:** `bcryptjs`, `bcrypt.hash(password, 10)`. Login uses `bcrypt.compare` and deliberately runs a compare even on a missing row to avoid leaking account existence via timing. Google accounts get an unusable random hash.
- **JWT:** `jsonwebtoken`. `signToken(user)` → `jwt.sign({ sub, email }, JWT_SECRET, { expiresIn: '30d' })`. `requireAuth` reads `Authorization: Bearer <jwt>`, verifies, sets `req.user = { id: payload.sub, email: payload.email }`; `401 "Authentication required."` (no token) or `401 "Session expired. Please log in again."` (verify throws).
- **`JWT_SECRET`** falls back to `'dev-insecure-secret-change-me'` with a startup warning if unset.
- **Email:** `EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/`; trimmed + lowercased in `readCredentials`.
- **Google (`google-auth-library`):** `new OAuth2Client().verifyIdToken({ idToken, audience: GOOGLE_WEB_CLIENT_ID })`; extracts `email`/`sub`, finds-or-creates by email, `linkGoogle(user.id, sub)`, issues the app's own JWT. `GOOGLE_WEB_CLIENT_ID` is the **Web** OAuth client ID (the audience the Android ID token is minted for); unset → `500`.
- **SQLite (`db.js`):** Node built-in `node:sqlite` (`DatabaseSync`) — no native build. DB at `DB_PATH` (default `./data/app.db`, dir auto-created). `users(id, email UNIQUE, password_hash, created_at)`; runtime migration adds `google_sub TEXT` via `PRAGMA table_info` if missing. Helpers: `createUser`, `findUserByEmail` (includes hash), `findUserById` (no hash), `linkGoogle`.

### Provider layer (`providers.js`)

- **Vendor switch:** `PROVIDER` (default `anthropic`; also `gemini`) selects the vendor; `MODEL` (optional) overrides that vendor's default model. Defaults: anthropic → `claude-opus-4-8`, gemini → `gemini-2.5-flash`.
- **`getProvider()`** returns `{ name, model, generate }`. It throws a clear `500` if `PROVIDER` is unknown or the vendor's key env (`ANTHROPIC_API_KEY` / `GEMINI_API_KEY`) is unset. `describeProvider()` is a non-throwing variant used for the startup banner (works with no key).
- **Uniform contract:** each provider's `generate({ system, user, maxTokens, effort })` returns `{ text, outTokens }`. `planService.js` stays vendor-agnostic — it builds the prompt, calls `generate()`, then parses the returned text.
- **Anthropic impl:** streams `messages.stream({...})` + `finalMessage()`; `thinking: { type: 'adaptive' }`; `output_config: { effort, format: { type: 'json_schema', schema: PLAN_SCHEMA } }`. Maps `stop_reason === 'refusal'` → `422`, missing text block → `502`.
- **Gemini impl** (`@google/genai`): `models.generateContent({...})` with `systemInstruction`, `maxOutputTokens`, `responseMimeType: 'application/json'`, and `responseSchema`. `EFFORT` is ignored (2.5-flash has built-in thinking). `finishReason === 'SAFETY'` → `422`, empty text → `502`.
- **Schema dialect:** `toGeminiSchema()` adapts the shared `PLAN_SCHEMA` for Gemini — strips `additionalProperties` and uppercases `type` (OBJECT/ARRAY/STRING/INTEGER) — so both vendors return the same JSON shape (converted once, memoised).
- **Lazy clients:** both `new Anthropic()` and `new GoogleGenAI({...})` are built on first use, so the server boots and `/health` responds without any key (generation then errors clearly with `500`).

### Plan-gen config (`planService.js` + `planSchema.js`)

- **Params:** `EFFORT` (default `medium`; low|medium|high|max — Anthropic only), `MAX_TOKENS` (default `32000`). Model/vendor live in the provider layer above.
- **Day cap:** `MAX_PLAN_DAYS` (default `7`, exported); `plannedDays = min(targetDays, cap)`. Lowered to 7 because a full 14-day Opus plan can exceed the client timeout.
- **Generation:** `generatePlan()` resolves `getProvider()`, calls `provider.generate(...)`, then `parsePlanJson(result.text)`. Returns `{ plan, meta }` with `meta.provider`/`meta.model`.
- **Observability:** `setInterval` heartbeat every 10s (`…still generating (Ns)`); logs `provider:model`, response time, and out-tokens; `server.js` adds `[plan] ←`/`[plan] →` request timing.
- **Errors:** provider-specific refusal/empty-output mapping lives in `providers.js` (see above); JSON parse failure logs the first 300 chars and rethrows. `parsePlanJson` tries clean `JSON.parse`, else strips ```` ```json ````/```` ``` ```` fences and grabs the outermost `{...}`.
- **Prompt (`buildPrompt`):** system prompt = registered dietitian enforcing safe weight-change rates (~0.25–1 kg/week) and minimum-intake floors (~1200 kcal/day women, ~1500 men), local/seasonal ingredients, structured output only. User prompt injects body/goal/location + optional fields + computed `direction` (lose/gain/maintain) and requires exactly `plannedDays` days, 4 meals/day (Breakfast/Lunch/Dinner/Snack), local varied dishes, per-meal ingredients with quantities. Both vendors share this prompt + `PLAN_SCHEMA`.

### Env vars

| Var | Used in | Default / purpose |
|---|---|---|
| `PROVIDER` | `providers.js` | `anthropic` (or `gemini`) — selects the LLM vendor |
| `ANTHROPIC_API_KEY` | `providers.js` (SDK) | Required when `PROVIDER=anthropic`; startup banner shows `…=set\|MISSING` |
| `GEMINI_API_KEY` | `providers.js` (SDK) | Required when `PROVIDER=gemini` |
| `MODEL` | `providers.js` | Overrides the active vendor's default (`claude-opus-4-8` / `gemini-2.5-flash`) |
| `PORT` | `server.js` | `3000` |
| `EFFORT` | `planService.js` | `medium` (Anthropic only; Gemini ignores it) |
| `MAX_TOKENS` | `planService.js` | `32000` |
| `MAX_PLAN_DAYS` | `planService.js` | `7` (`.env.example` shows `14`, but code default is `7`) |
| `JWT_SECRET` | `auth.js` | Falls back to insecure dev secret + warning |
| `GOOGLE_WEB_CLIENT_ID` | `auth.js` | Web OAuth client ID = Google ID-token audience |
| `DB_PATH` | `db.js` | `./data/app.db` |

### Run

- **Dev:** `npm run dev` → `node --watch server.js` (auto-restart on source change).
- **Prod:** `npm start` → `node server.js`.
- Listens on `http://localhost:${PORT}` (default `3000`); boot log: `provider=… · model=… · effort=… · maxPlanDays=… · <KEY_ENV>=set|MISSING`. Requires Node `>=18` with `node:sqlite`; prints an experimental-feature warning at startup. SQLite file created at `data/app.db`.

## Frontend reference

### Screens (`mobile/lib/screens/`)

- **`auth_gate.dart`** — `AuthGate`/`_AuthGateState` (`_checking`); splash while verifying, then reactive `ValueListenableBuilder` on `authState` → `InputScreen` (home) or `LoginScreen`.
- **`login_screen.dart`** — email/password form (`validateEmail`, obscure toggle), `_submit()` → `login`, `_google()` → `googleLogin`; footer pushes `SignupScreen`. No navigation on success — the gate swaps.
- **`signup_screen.dart`** — adds `_confirm`; password validator "At least 6 characters", confirm "Passwords do not match"; on success `navigator.pop()`s to reveal home; `showBack: true`.
- **`input_screen.dart`** — home form (`_weight`/`_targetWeight`/`_height`/`_location`/`_period`+`_periodUnit`/`_age`/`_sex`/`_activity`/`_dietPref`/`_planName`), live `_GoalBanner`, `_SavedPlansSection` (open/rename/delete via `_PlanCard`), sticky "Generate my diet plan" button, `_AccountMenu` (Log out → `cancelAll()` then `logout()`). `_submit()` builds the body and pushes `PlanScreen`.
- **`plan_screen.dart`** — takes `requestBody`+`planName` (generate) or `stored` (open). `_CookingLoader` during gen, `_ErrorView` on failure, `_PlanView` (`_SummaryCard`, `_InfoBanner` if truncated, `_DaySelector`, `_DayDetail`, `_MealCard`). Reminder bar: "Set daily reminders" (off) / count + "Turn off" (on); `_setupReminders`, `_turnOff`, shared `_rescheduleAndRefresh()`. Deep-link `initialDay`/`highlightMeal` scroll+highlight a meal.

### Services (`mobile/lib/services/`)

- **`AuthService`** (singleton) — keys `_tokenKey='auth_token'`, `_emailKey='auth_email'`; `ValueNotifier<bool> authState`. Methods: `loadSession`, `signup`/`login` (→ `_authPost`, 20s), `googleLogin` (google_sign_in 7.x; returns `false` on cancel), `verify` (GET `/api/auth/me`, 15s; `401` → `logout`; network error → stays logged in), `logout`, `_persist`. `AuthException.toString()` returns the message.
- **`ApiService`** — `generatePlan(body)` POSTs `/api/plan` with `Bearer` (240s); `200` → `DietPlan.fromResponse`; `401` → `logout()` + "session expired"; else extracts backend `error`. `ApiException.toString()` returns the message.
- **`PlanStorage`** (static) — per-account CRUD over `SharedPreferences`; `loadAll`/`upsert`/`rename`/`delete`/`nextSlot`; one-time migration of pre-auth/legacy plans.
- **`NotificationService`** (singleton) — wraps `FlutterLocalNotificationsPlugin`; channel `diet_reminders`/"Diet reminders" (high). `init` (idempotent, `kIsWeb` no-op, tz setup), `requestPermissions`, `rescheduleAll` (single source of truth: `cancelAll` then `_scheduleOne` per enabled plan, returns `{planId: count}`), `cancelAll`, `onTap`. `init`/`requestPermissions`/`rescheduleAll`/`cancelAll` are all `kIsWeb`-guarded.
- **`app_router.dart`** — global `appNavigatorKey` (handed to `MaterialApp.navigatorKey`); `routeFromNotification(payload)` decodes `{planId, day, meal}`, loads the `StoredPlan` by id, pushes `PlanScreen(stored, location, initialDay: day, highlightMeal: meal>=0 ? meal : null)`. Serves both live taps and cold-start.

### Models (`mobile/lib/models/diet_plan.dart`)

`Ingredient{name,quantity}` · `Meal{name,time,dish,description,calories,ingredients[]}` · `DayPlan{day,totalCalories,meals[]}` · `DietPlan{summary,dailyCalorieTarget,days[],requestedDays,plannedDays,truncated,model}`. `DietPlan.fromResponse(body)` reads `body['plan']` + `body['meta']`; `toResponseJson()` round-trips the same `{plan, meta}` shape for lossless local storage. `_toInt` coerces int/num/string → int.

### Per-user storage key

`PlanStorage._base = 'saved_plans_v2'`, legacy `_legacySingle = 'saved_plan_v1'`. Active key (`_key`): when `AuthService.instance.email` is non-empty →
```
saved_plans_v2::<email>
```
else the bare `_base` (logged-out). On first load for an account, pre-auth device-wide plans under bare `_base` migrate into the user key once (then `_base` is removed — only the first account to log in inherits them); failing that, the older single-plan `saved_plan_v1` migrates into a one-element list (name "My plan", `slot: 0`). `_parse` sorts newest-first by `savedAt`.

### Notification ID / slot scheme

Each `StoredPlan` has a small stable `slot` (allocated by `nextSlot` = smallest unused non-negative int) that namespaces its IDs. In `_scheduleOne`, `base = sp.slot * 100000`. For 0-based day `i` and meal `m`:

- **Grocery alert** — ID `base + 90000 + i`, fired **19:00 (7 PM) the day before** `dayDate` (only if in the future and the deduped ingredient list is non-empty). `BigTextStyleInformation` shopping list; payload `{planId, day:i, meal:-1, type:'grocery'}`.
- **Meal alarm** — ID `base + i * 10 + m`, fired at the meal's parsed `HH:mm` on `dayDate` (only if in the future and the time parses). Payload `{planId, day:i, meal:m, type:'meal'}`.

`tag` = ` · {plan name}` appended to titles (empty if blank). `dayDate` uses date-component arithmetic (`startDate.day + i`) for DST safety. The `*100000` per-plan namespace + `90000` grocery offset means each plan supports ~9000 day×meal slots before colliding with its grocery range, and plans (people) never collide. `_scheduleAt` first tries `AndroidScheduleMode.exactAllowWhileIdle`, falling back to `inexactAllowWhileIdle` if exact-alarm permission is missing. Helpers: `_parseTime` (regex `(\d{1,2}):(\d{2})`, validates h≤23/m≤59), `_ingredientsFor` (deduped case-insensitive comma-joined list).

## Build, run & setup

### Toolchain prerequisites

- **Flutter/Dart SDK** `^3.11.0`.
- **JDK 17** — `brew install openjdk@17`, then `flutter config --jdk-dir <path>`.
- **Android SDK** — install cmdline-tools and accept licenses (`flutter doctor --android-licenses`).
- **Backend needs no native build** — `node:sqlite` is built in and `bcryptjs` is pure JS (no `node-gyp`).

### Key dependencies (`mobile/pubspec.yaml`)

Package `diet_planner` `1.0.0+1`. Runtime: `http ^1.6.0`, `google_fonts ^6.2.1`, `shared_preferences ^2.5.5`, `flutter_local_notifications ^22.0.0`, `timezone ^0.11.0`, `flutter_timezone ^5.1.0`, `google_sign_in ^7.2.0`, `cupertino_icons ^1.0.8`. Dev: `flutter_test`, `flutter_lints ^6.0.0`.

### Android native config

- `applicationId`/`namespace` = `com.dietplanner.diet_planner`; `compileSdk` 36 (via Flutter); Java/Kotlin toolchain **17**.
- **Core-library desugaring enabled** (`desugar_jdk_libs:2.1.4`) — required by `flutter_local_notifications`.
- Release currently signed with the **debug** config (placeholder — replace before shipping).
- **Permissions:** `INTERNET`, `POST_NOTIFICATIONS`, `SCHEDULE_EXACT_ALARM`, `USE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`, `VIBRATE`.
- **Receivers:** flutter_local_notifications `ActionBroadcastReceiver`, `ScheduledNotificationReceiver`, `ScheduledNotificationBootReceiver` (intent-filter for `BOOT_COMPLETED`/`MY_PACKAGE_REPLACED`/`QUICKBOOT_POWERON`) so reminders survive reboot/app-replace.
- **Debug-only cleartext:** `mobile/android/app/src/debug/AndroidManifest.xml` sets `usesCleartextTraffic="true"` for plain-HTTP to the local backend (debug builds only; release stays HTTPS-only).

### Run commands

```bash
# from mobile/
flutter pub get
flutter analyze && flutter test     # sanity

# Web / Chrome — auto-uses localhost:3000
flutter run -d chrome

# Android emulator — auto-uses 10.0.2.2:3000

# Physical device — forward port + point at host explicitly
adb reverse tcp:3000 tcp:3000
flutter run \
  --dart-define=API_BASE_URL=http://localhost:3000 \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>
# or target the LAN IP:
flutter run --dart-define=API_BASE_URL=http://192.168.1.50:3000
```

`AppConfig.apiBaseUrl` resolution: explicit `--dart-define=API_BASE_URL` wins; else Android (non-web) → `http://10.0.2.2:3000`; else (iOS sim/web/desktop) → `http://localhost:3000`.

### Google OAuth two-client setup

Two OAuth clients in **one** Google Cloud project:

1. **Android client** — registered with package `com.dietplanner.diet_planner` + the **debug SHA-1** (so sign-in works in debug builds).
2. **Web client** — its ID is used in **two** places and must be **identical** on both: the app's `--dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>` (as `AppConfig.googleServerClientId` / google_sign_in `serverClientId`) **and** the backend's `GOOGLE_WEB_CLIENT_ID` (the audience for ID-token verification).

## Conventions & gotchas

- **`node --watch` ignores `.env`** — it only reloads source files. Changing backend env vars requires a manual restart.
- **`MAX_PLAN_DAYS = 7`** keeps generation under the app's **240s** `ApiService` timeout; a full 14-day Opus plan can exceed it. `.env.example` shows `14` but the code default is `7`. The cap surfaces as `meta.truncated` + a `_InfoBanner` in the UI.
- **The Google client ID on the device is the *Web* client ID, not the Android one** — it's the `serverClientId` (`GOOGLE_SERVER_CLIENT_ID`) and must equal the backend's `GOOGLE_WEB_CLIENT_ID` (the ID-token audience). The Android client (package + SHA-1) only enables sign-in itself.
- **Reminders are local & phone-only** — every notification path (`init`/`requestPermissions`/`rescheduleAll`/`cancelAll`) is `kIsWeb`-no-op'd; reminders do nothing on web.
- **Plans are local-only & per-account** — stored in `SharedPreferences` under `saved_plans_v2::<email>`, never synced to the server. A device shared by multiple users keeps plans isolated (per-email key) and reminders isolated (login `rescheduleAll` after `cancelAll`; logout `cancelAll`).
- **Per-plan slot isolation** — `slot * 100000` namespacing means different people's reminders (and their grocery vs meal ID ranges) never collide.
- **Reconcile through one path** — enable, disable, delete, and login all funnel through `NotificationService.rescheduleAll` (which does `cancelAll` first) + writing back each plan's `scheduledCount`, keeping stored counts in sync with the OS.
- **Wireless adb drops** — wireless `adb` connections tend to disconnect; use USB + `adb reverse tcp:3000 tcp:3000` for stable physical-device runs.
- **Debug-only cleartext HTTP** — plain-HTTP to the dev backend is allowed only in debug builds; release builds stay HTTPS-only.
- **Native changes need a full rebuild** — manifest permissions/receivers and Gradle desugaring are not picked up by hot reload; re-run `flutter run` after pulling.
- **Switch LLM vendor with one env var** — `PROVIDER=anthropic|gemini` (+ `MODEL` to override the model). Only the selected vendor's key (`ANTHROPIC_API_KEY` / `GEMINI_API_KEY`) is needed. Because `node --watch` ignores `.env`, **restart the backend** after changing `PROVIDER`/`MODEL`/keys.
- **Lazy LLM clients** — the server boots and `/health` responds without any provider key; only `/api/plan` errors (`500`) when the active provider's key is missing.
- **Gemini shares Claude's schema/prompt** — `toGeminiSchema()` strips `additionalProperties` and uppercases `type` so the one strict `PLAN_SCHEMA` drives both vendors; the mobile `{ plan, meta }` shape is identical regardless of provider.
- **Login does not leak account existence** — `bcrypt.compare` runs even for unknown emails to equalize timing.
- **JWT default secret is insecure** — set `JWT_SECRET` in any real deployment; the fallback logs a warning.
