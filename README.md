# AI Diet Planner

A mobile app that turns your body metrics into an AI-generated, **location-aware** diet
plan — a day-by-day menu built from food local to you, with per-meal ingredient lists.

This is **pass 1** of the build: app scaffold, the input form, and plan
generation + display. Local storage and reminders are the next pass (see
[Roadmap](#roadmap)).

```
diet-planner-app/
├── backend/   Node + Express proxy that calls Claude (keeps the API key off the device)
└── mobile/    Flutter app (iOS / Android / web)
```

## How it works

```
Flutter app ──POST /api/plan──▶ Node backend ──▶ Claude (claude-opus-4-8)
   (metrics)                     (holds API key)   (structured JSON plan)
        ◀───────────── day-by-day plan with ingredients ──────────────────
```

The API key lives **only** on the backend — the app never sees it. Claude is asked
for a structured JSON plan (one entry per day, each with meals → ingredients), so the
mobile storage layer can persist it directly in pass 2.

---

## 1. Backend

Requires Node 18+ and an Anthropic API key.

```bash
cd backend
npm install
cp .env.example .env        # then edit .env and paste your ANTHROPIC_API_KEY
npm run dev                  # starts on http://localhost:3000 (auto-reload)
```

Check it's up:

```bash
curl http://localhost:3000/health      # → {"ok":true,"maxPlanDays":14}
```

Generate a plan directly (sanity check, needs a valid key):

```bash
curl -s http://localhost:3000/api/plan \
  -H 'Content-Type: application/json' \
  -d '{"weightKg":82,"heightCm":178,"location":"Chennai, India","targetWeightKg":75,"targetDays":28,"sex":"male","activityLevel":"light","dietaryPreference":"vegetarian"}'
```

**Config** (all optional, via `.env`): `PORT`, `MODEL` (default `claude-opus-4-8`;
set `claude-sonnet-4-6`/`claude-haiku-4-5` for cheaper/faster), `EFFORT`,
`MAX_TOKENS`, `MAX_PLAN_DAYS` (default 14 — the most days detailed per call).

### API contract

`POST /api/plan`

```jsonc
// request
{
  "weightKg": 82, "heightCm": 178, "targetWeightKg": 75,
  "targetDays": 28, "location": "Chennai, India",
  "age": 34, "sex": "male",                 // optional
  "activityLevel": "light",                 // optional: sedentary|light|moderate|active|very_active
  "dietaryPreference": "vegetarian"         // optional, free text
}
// response
{
  "plan": {
    "summary": "…", "dailyCalorieTarget": 1800,
    "days": [ { "day": 1, "totalCalories": 1790,
      "meals": [ { "name": "Breakfast", "time": "08:00", "dish": "…",
        "description": "…", "calories": 420,
        "ingredients": [ { "name": "Idli batter", "quantity": "2 cups" } ] } ] } ]
  },
  "meta": { "requestedDays": 28, "plannedDays": 14, "truncated": true, "model": "claude-opus-4-8" }
}
```

---

## 2. Mobile app

Requires Flutter 3.x.

```bash
cd mobile
flutter pub get
flutter run
```

**Point the app at your backend.** The default base URL adapts automatically:

| Target              | Reaches backend at | Notes                                  |
| ------------------- | ------------------ | -------------------------------------- |
| Android emulator    | `10.0.2.2:3000`    | automatic                              |
| iOS simulator / web | `localhost:3000`   | automatic                              |
| Physical device     | your machine's LAN IP | pass it explicitly (below)          |

For a physical device, run the backend on your machine and start the app with:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.50:3000   # your LAN IP
```

Verify the app builds/lints and the smoke test passes:

```bash
flutter analyze
flutter test
```

---

## Pass 2 — storage & reminders (done)

- **Local storage** — the generated plan is auto-saved on the device (`shared_preferences`). The form shows an **"Open saved plan"** card so it persists across restarts and opens without re-calling the API.
- **Grocery reminder** — a local notification at **7:00 PM the day before** each day, listing that next day's ingredients (`flutter_local_notifications`).
- **Meal alarms** — a notification at each meal's time, every day.
- Tap **"Set daily reminders"** on the plan screen → choose Today/Tomorrow as Day 1 → grant the notification (and exact-alarm) permission → reminders are scheduled and survive app close/reboot.

**Android — for reliable firing on aggressive OEMs (MIUI/Redmi, etc.):** allow Notifications, allow exact alarms, set the app's battery to **"No restrictions"**, and enable **Autostart**. Otherwise the OS may delay or kill scheduled alarms.

> Native changes were added (manifest permissions/receivers + Gradle core-library desugaring), so after pulling these changes do a full **`flutter run`** rebuild — hot reload won't pick them up.

## Roadmap (later)

- Full-period plans beyond `MAX_PLAN_DAYS` (currently 14 detailed days).
- Optional GPS auto-fill for location; editable meal times; multiple saved plans.
