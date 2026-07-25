import { computeTargets } from './tdee.js';

// JSON Schema for the structured diet-plan response Claude must return.
// Shaped so the (next-pass) mobile storage layer can persist each day's meals
// and ingredients directly. Structured-output rules: every object sets
// additionalProperties:false and lists all its properties in `required`.

// One meal — shared between the full plan schema and the single-meal swap
// schema so both stay in lockstep.
export const MEAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    name: {
      type: 'string',
      description: 'Meal slot, e.g. "Breakfast", "Lunch", "Snack", "Dinner".',
    },
    time: {
      type: 'string',
      description: 'Suggested 24h time to eat, e.g. "08:00".',
    },
    dish: {
      type: 'string',
      description: 'Name of the local/regional dish.',
    },
    description: {
      type: 'string',
      description: 'One-line description and any simple prep note.',
    },
    calories: { type: 'integer', description: 'Calories for this meal (kcal).' },
    protein: { type: 'integer', description: 'Protein for this meal, in grams.' },
    carbs: { type: 'integer', description: 'Carbohydrates for this meal, in grams.' },
    fat: { type: 'integer', description: 'Fat for this meal, in grams.' },
    ingredients: {
      type: 'array',
      description: 'Shopping-list ingredients for this meal.',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          name: { type: 'string', description: 'Ingredient name.' },
          quantity: {
            type: 'string',
            description: 'Amount with unit, e.g. "100 g", "1 cup", "2 pcs".',
          },
        },
        required: ['name', 'quantity'],
      },
    },
  },
  required: ['name', 'time', 'dish', 'description', 'calories', 'protein', 'carbs', 'fat', 'ingredients'],
};

export const PLAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    summary: {
      type: 'string',
      description:
        "2-4 sentence overview: the plan's approach, the daily calorie target, and the regional cuisine it draws on. For a weight-loss or weight-gain goal, mention the safe rate of change and, if the target is not safely achievable in the period, say so and explain the adjusted, safe target you planned instead. For an 'eat healthy'/maintenance plan, describe the balanced, weight-stable approach (do not talk about weight change or a target).",
    },
    dailyCalorieTarget: {
      type: 'integer',
      description: 'Approximate daily calorie target the plan is built around (kcal).',
    },
    dailyProteinTarget: { type: 'integer', description: 'Daily protein target, in grams.' },
    dailyCarbsTarget: { type: 'integer', description: 'Daily carbohydrate target, in grams.' },
    dailyFatTarget: { type: 'integer', description: 'Daily fat target, in grams.' },
    days: {
      type: 'array',
      description: 'One entry per planned day, in order.',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          day: { type: 'integer', description: 'Day number, starting at 1.' },
          totalCalories: {
            type: 'integer',
            description: 'Sum of the calories of all meals for this day (kcal).',
          },
          meals: {
            type: 'array',
            description: 'Meals for the day, in the order they should be eaten.',
            items: MEAL_SCHEMA,
          },
        },
        required: ['day', 'totalCalories', 'meals'],
      },
    },
  },
  required: [
    'summary',
    'dailyCalorieTarget',
    'dailyProteinTarget',
    'dailyCarbsTarget',
    'dailyFatTarget',
    'days',
  ],
};

// Builds the system + user prompts for a given validated request.
export function buildPrompt(input, plannedDays) {
  const {
    weightKg,
    heightCm,
    location,
    targetWeightKg,
    targetDays,
    age,
    sex,
    activityLevel,
    dietaryPreference,
    goal,
    startDay = 1,
    avoidDishes = [],
    allergies = [],
    cookingStyle,
  } = input;

  const endDay = startDay + plannedDays - 1;
  const isContinuation = startDay > 1;

  // Deterministic energy target (Mifflin-St Jeor → TDEE → goal-adjusted, safety
  // clamped). generatePlan passes it in precomputed; compute here if called
  // standalone. This is the authoritative number — the model builds meals to
  // hit it rather than guessing its own.
  const targets = input.targets || computeTargets(input);

  const system =
    'You are a registered dietitian and meal planner. You design realistic, ' +
    'nutritionally balanced diet plans that respect safe rates of weight change ' +
    '(roughly 0.25-1 kg per week) and never prescribe dangerously low intake ' +
    '(generally not below ~1200 kcal/day for women or ~1500 kcal/day for men ' +
    'without medical supervision). You specialise in cooking with locally available, ' +
    'regional, in-season ingredients. You treat a stated food allergy as an absolute ' +
    'medical constraint and never include an allergen in any form. ' +
    'You return ONLY the structured plan requested.';

  const optional = [
    age ? `Age: ${age}` : null,
    sex ? `Sex: ${sex}` : null,
    activityLevel ? `Activity level: ${activityLevel}` : null,
    dietaryPreference ? `Dietary preference: ${dietaryPreference}` : null,
  ]
    .filter(Boolean)
    .join('\n');

  // Prefer the explicit goal; fall back to inferring from the weights.
  const resolvedGoal =
    goal || (targetWeightKg < weightKg ? 'lose' : targetWeightKg > weightKg ? 'gain' : 'maintain');
  const isMaintain = resolvedGoal === 'maintain';

  const continuationContext = isContinuation
    ? `\nThis is a CONTINUATION of an ongoing ${targetDays}-day plan. You are filling days ${startDay} to ${endDay}. Keep the same daily calorie target and style as the rest of the plan.`
    : '';

  const avoidLine = avoidDishes.length
    ? `\n- Do NOT reuse any of these dishes already planned earlier — pick different meals: ${avoidDishes.join(', ')}.`
    : '';

  // The goal line + calorie instruction differ for "eat healthy" (maintain) vs
  // a weight-change goal.
  const goalLine = isMaintain
    ? `Goal: eat healthy and MAINTAIN a stable weight (currently ${weightKg} kg).`
    : `Current weight: ${weightKg} kg\nTarget weight: ${targetWeightKg} kg (goal: ${resolvedGoal} weight)`;

  const calorieLine = isMaintain
    ? `- Build every day around EXACTLY ${targets.calorieTarget} kcal/day — the user's maintenance TDEE. Do NOT create a deficit or surplus. Focus on balanced, nutritious, wholesome meals.`
    : `- Build every day around EXACTLY ${targets.calorieTarget} kcal/day. This is the pre-computed, safety-checked target for this goal and period — do NOT choose a different number.`;

  const macroLine =
    `- Use these daily macro targets and distribute them across the day's meals: ` +
    `protein ${targets.macros.protein} g, carbs ${targets.macros.carbs} g, fat ${targets.macros.fat} g. ` +
    `Return these exact numbers as dailyProteinTarget / dailyCarbsTarget / dailyFatTarget and ${targets.calorieTarget} as dailyCalorieTarget.`;

  const summaryNote = targets.warnings.length
    ? `\n- Tell the user this in the summary: ${targets.warnings.join(' ')}`
    : '';

  // Allergies are a MEDICAL constraint, not a taste preference. Stated twice —
  // as its own prominent block and again as the first requirement — so it can't
  // be glossed over in favour of authenticity or variety.
  const allergyList = allergies.join(', ');
  const allergyBlock = allergies.length
    ? `\nALLERGIES — HARD SAFETY CONSTRAINT\nThe user is ALLERGIC to: ${allergyList}.\n` +
      `NEVER include these, or ANY dish or ingredient containing or derived from them — ` +
      `including hidden sources such as sauces, pastes, stocks, oils, marinades, garnishes and coatings. ` +
      `If a traditional local dish would normally contain one, omit that dish or substitute a safe alternative. ` +
      `Do not compromise on this for authenticity or variety.\n`
    : '';
  const allergyRule = allergies.length
    ? `\n- SAFETY FIRST: every meal and every ingredient must be completely free of: ${allergyList}.`
    : '';

  // Cooking style shapes HOW every dish is prepared. 'everyday' is the default
  // and adds nothing.
  const cookingStyleRule = {
    less_oil:
      '\n- COOKING STYLE — LIGHT: use minimal oil throughout. Prefer sautéing, grilling, roasting, stir-frying with little oil, steaming or boiling; avoid deep-frying and heavy tempering. Keep dishes light on added fats.',
    steamed:
      '\n- COOKING STYLE — STEAMED/BOILED: favour steamed, boiled, poached or lightly stir-fried dishes with very little oil. Avoid fried and deep-fried items entirely.',
    mixed:
      '\n- COOKING STYLE — HEALTHY MIX: mostly light, low-oil, steamed or grilled dishes, with the occasional normally-cooked comfort dish for variety.',
  }[cookingStyle] || '';

  const user = `Create a personalised diet plan with these details:

${goalLine}
Height: ${heightCm} cm
Target time period: ${targetDays} days
Location: ${location}
${optional ? optional + '\n' : ''}${continuationContext}${allergyBlock}
Requirements:${allergyRule}
- Plan exactly ${plannedDays} day(s), numbered ${startDay} to ${endDay}.
- Each day must include Breakfast, Lunch, Dinner, and one Snack (4 meals).
- Use dishes and ingredients that are local, regional, and commonly available in ${location}.
- Vary the dishes across days so the plan does not get repetitive.${avoidLine}
- For every meal, list its ingredients with realistic shopping quantities.
- For every meal, give realistic calories and macros (protein, carbs, fat in grams). Each day's meal calories should add up close to the daily calorie target.
${calorieLine}
${macroLine}${cookingStyleRule}${summaryNote}`;

  return { system, user };
}

// Structured recipe — step-by-step home preparation for a single dish.
export const RECIPE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    dish: { type: 'string', description: 'The dish name.' },
    servings: { type: 'integer', description: 'How many servings these steps make.' },
    prepMinutes: { type: 'integer', description: 'Rough total time in minutes.' },
    steps: {
      type: 'array',
      description: 'Ordered preparation steps, each a short imperative sentence.',
      items: { type: 'string' },
    },
    tips: {
      type: 'array',
      description: '0-3 short, genuinely useful tips (may be empty).',
      items: { type: 'string' },
    },
  },
  required: ['dish', 'servings', 'prepMinutes', 'steps', 'tips'],
};

// Structured activity suggestions — for one day or a week. Detailed enough to
// actually DO: each session carries ordered how-to steps, one key form cue,
// equipment, and why it helps; the plan carries a shared warm-up, a progression
// rule, and concrete safety guardrails.
export const ACTIVITY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    headline: {
      type: 'string',
      description:
        'One encouraging, specific sentence framing the day or week (for a week, it may name the structure/theme).',
    },
    warmup: {
      type: 'string',
      description:
        'ONE shared warm-up AND cool-down routine every session uses, stated once here (so per-session steps never repeat it). Include both the "before" warm-up and the "after" cool-down.',
    },
    activities: {
      type: 'array',
      description: 'The suggested sessions, in order.',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          day: {
            type: 'string',
            description: 'Weekday label for a week plan (e.g. "Mon"); empty string for a single-day request.',
          },
          name: {
            type: 'string',
            description:
              'The concrete session name, e.g. "Full-body dumbbell circuit", "Zone-2 brisk walk", "Active recovery + mobility". A real name, not a category word.',
          },
          focus: {
            type: 'string',
            description:
              'One short line naming what the session trains AND why it serves the goal, e.g. "Glutes, quads, core — builds calorie-burning muscle". Must not restate the name.',
          },
          minutes: {
            type: 'integer',
            description: 'Total session duration in minutes, warm-up and cool-down included.',
          },
          intensity: {
            type: 'string',
            enum: ['light', 'moderate', 'vigorous'],
            description: "Overall effort; must match the person's fitness level and agree with calories/minutes.",
          },
          calories: { type: 'integer', description: 'Approx calories burned for this session (kcal).' },
          equipment: {
            type: 'string',
            description:
              'Concrete kit needed before starting, one line; use the explicit "None — bodyweight only" when there is none. Never blank or vague.',
          },
          howTo: {
            type: 'array',
            description:
              'THE "how to do it": 3-6 ordered, imperative steps, each carrying a concrete parameter (sets x reps, interval, distance, pace, or tempo). The last step is a short cool-down. Do NOT repeat the shared warm-up. On a rest day, give 2-3 gentle recovery lines.',
            items: { type: 'string' },
          },
          formCue: {
            type: 'string',
            description:
              'The single most important technique/safety cue for this session (<=15 words). Empty string allowed on a pure rest day. Must differ from the name and from every howTo step.',
          },
        },
        required: ['day', 'name', 'focus', 'minutes', 'intensity', 'calories', 'equipment', 'howTo', 'formCue'],
      },
    },
    progression: {
      type: 'string',
      description: 'The concrete "when and how to make it harder" rule. Forward guidance, not a recap.',
    },
    safety: {
      type: 'string',
      description:
        'Plan-wide stop-signs (e.g. chest pain, dizziness, sharp joint pain) plus a recovery/rest rule, stated once.',
    },
    tip: {
      type: 'string',
      description:
        'One practical adherence/scheduling nudge — how to fit this into a real week. Distinct from safety and progression.',
    },
  },
  required: ['headline', 'warmup', 'activities', 'progression', 'safety', 'tip'],
};

// Prompts for activity suggestions. Advice only — these are NOT fed back into
// the calorie/TDEE math (which already uses the onboarding activity level).
export function buildActivityPrompt(input) {
  const { scope, goal, sex, age, activityLevel, weightKg } = input;
  const forWeek = scope === 'week';

  const system =
    'You are a supportive, safety-conscious strength & conditioning coach. You design ' +
    'realistic, achievable sessions tailored to the person\'s goal and current fitness ' +
    'level — always beginner-friendly unless they are clearly advanced — and you never ' +
    'push unsafe intensity. Every session must be executable: a beginner can read it and ' +
    'actually DO it. You return ONLY the structured suggestions requested.';

  const who = [
    goal ? `Goal: ${goal} weight.` : null,
    weightKg ? `Weight: ${weightKg} kg.` : null,
    age ? `Age: ${age}.` : null,
    sex ? `Sex: ${sex}.` : null,
    activityLevel ? `Current fitness/activity level: ${activityLevel}.` : null,
  ]
    .filter(Boolean)
    .join(' ');

  const rules = `Rules:
- "focus": name what the session trains (muscles / energy system) AND why it serves the goal, in one line. Never restate the name.
- "howTo": 3 to 6 ordered, imperative steps. EVERY step carries a concrete parameter — sets x reps, interval structure, distance, pace, or tempo (e.g. "Squats: 3 x 12, rest 60s"). Ban vague steps like "do some cardio" or "stretch a bit". The last step is a short cool-down. Do NOT repeat the shared warm-up.
- "formCue": the single most important technique/safety correction for that session, <=15 words. Must differ from the name and from every howTo step.
- "equipment": concrete kit, or the explicit "None — bodyweight only". Never blank.
- Intensity must match their fitness level (beginner-friendly unless clearly advanced) and agree with calories/minutes.
- Write the shared warm-up AND cool-down ONCE in the top-level "warmup".
- "progression": how and when to make it harder. "safety": concrete stop-signs plus a recovery rule. "tip": one scheduling/adherence nudge (distinct from safety and progression).`;

  const user = forWeek
    ? `Design a balanced, detailed 7-day activity plan.
${who}
- Exactly 7 entries, one per weekday, each labelled in "day" (Mon..Sun).
- Include 1-2 real but light rest / active-recovery days (2-3 gentle recovery lines in howTo, empty formCue).
${rules}`
    : `Design 2 to 4 detailed activities for ONE day.
${who}
- Leave "day" empty for each (this is a single day).
${rules}`;

  return { system, user };
}

// Structured progress review — a detailed written assessment of how the user is
// doing: a status, a narrative summary, a block of concrete metric read-outs
// derived from their own figures, what's going well, what to fix, a concrete
// action plan, and a hedged outlook.
export const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    headline: {
      type: 'string',
      description: 'One warm, specific sentence summarising how it is going.',
    },
    status: {
      type: 'string',
      enum: ['early', 'on_track', 'ahead', 'behind', 'too_fast'],
      description: 'Overall assessment vs the goal.',
    },
    summary: {
      type: 'string',
      description:
        "2-4 sentences that interpret the person's ACTUAL weight change and adherence into a story. Do not just re-list the raw numbers already shown in metrics; state no number that was not supplied.",
    },
    metrics: {
      type: 'array',
      description: '3-5 concrete read-outs, each derived ONLY from the supplied/pre-computed figures.',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          label: {
            type: 'string',
            description: 'Metric name, e.g. "Pace", "Goal progress", "Projected finish", "Meal adherence", "Off-plan extras".',
          },
          value: {
            type: 'string',
            description:
              'The figure, drawn ONLY from supplied/pre-computed inputs — e.g. "0.6 kg/week", "40% (2.0 of 5.0 kg)", "82% (46/56 meals)". Use the literal "Not enough data yet" when it cannot be computed.',
          },
          read: {
            type: 'string',
            description:
              'One-line interpretation that ADDS meaning (a band or comparison), e.g. "inside the safe 0.5-1 kg/week zone". Must not echo the value.',
          },
          trend: {
            type: 'string',
            enum: ['good', 'watch', 'off'],
            description: 'Colors the row: good=on track, watch=keep an eye, off=needs attention.',
          },
        },
        required: ['label', 'value', 'read', 'trend'],
      },
    },
    doingWell: {
      type: 'array',
      description: '0-3 specific strengths grounded in the real data. May be empty if genuinely too early.',
      items: { type: 'string' },
    },
    improve: {
      type: 'array',
      description: '0-3 short diagnoses — what is off and why (an observation, not a fix).',
      items: { type: 'string' },
    },
    actionPlan: {
      type: 'array',
      description:
        '2-4 concrete, time-boxed next actions (imperative, with a specific target). Must not restate an improve item.',
      items: { type: 'string' },
    },
    outlook: {
      type: 'string',
      description:
        "A hedged forward trajectory, explicitly an estimate with its assumption stated. If fewer than two weigh-ins or very early, say it is too soon to project and focus on habits. For status too_fast, carry a health-caution line, not a rosy projection.",
    },
  },
  required: ['headline', 'status', 'summary', 'metrics', 'doingWell', 'improve', 'actionPlan', 'outlook'],
};

// Prompts for a progress review. The caller passes already-computed figures
// (weigh-in series, adherence, days elapsed); the model interprets them — it
// must not invent numbers.
export function buildReviewPrompt(input) {
  const {
    goal,
    startWeightKg,
    targetWeightKg,
    currentWeightKg,
    targetDays,
    daysElapsed,
    calorieTarget,
    weighIns = [],
    mealsDone = 0,
    mealsTotal = 0,
    extrasCount = 0,
    extrasCalories = 0,
  } = input;

  const system =
    'You are a supportive but honest registered dietitian reviewing a client\'s ' +
    'progress so far. You are encouraging and never discouraging, but you are ' +
    'truthful: you reference the ACTUAL data given, never invent numbers, and give ' +
    'specific, practical guidance. If it is very early or there is little data, you ' +
    'say so kindly and focus on habits rather than the scale. You return ONLY the ' +
    'structured review requested.';

  const goalLine =
    goal === 'maintain'
      ? 'Goal: eat healthy / maintain a stable weight'
      : `Goal: ${goal} weight, from ${startWeightKg} kg toward ${targetWeightKg} kg`;

  const trend = weighIns.length >= 2
    ? `Weigh-ins so far: ${weighIns.map((w) => `${w.date} ${w.kg}kg`).join('; ')}.`
    : weighIns.length === 1
      ? `Only one weigh-in so far: ${weighIns[0].kg} kg (no trend yet).`
      : 'No weigh-ins logged yet.';

  const adherence = mealsTotal > 0
    ? `Meal adherence: ${mealsDone} of ${mealsTotal} planned meals checked off over ${daysElapsed} day(s) — about ${Math.round((100 * mealsDone) / mealsTotal)}%.`
    : 'No planned meals checked off yet.';

  const extras = extrasCount > 0
    ? `Also logged ${extrasCount} off-plan item(s) totalling ~${extrasCalories} kcal.`
    : 'No off-plan extras logged.';

  // Pre-compute the risky derived figures here so the model only PHRASES them
  // and never does error-prone math (or invents numbers). Same defensive pattern
  // already used for the adherence % above.
  const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
  const round1 = (v) => Math.round(v * 10) / 10;
  const weeksElapsed = daysElapsed > 0 ? daysElapsed / 7 : 0;
  const enoughForPace = weighIns.length >= 2 && daysElapsed >= 5;

  const computed = [];
  let changeKg = null; // + = weight down
  if (isNum(startWeightKg) && isNum(currentWeightKg)) {
    changeKg = round1(startWeightKg - currentWeightKg);
    const dir = changeKg > 0 ? 'down' : changeKg < 0 ? 'up' : 'unchanged';
    computed.push(`Weight change: ${Math.abs(changeKg)} kg ${dir} (from ${startWeightKg} to ${currentWeightKg} kg).`);
  }
  let paceKgWk = null;
  if (enoughForPace && changeKg !== null && weeksElapsed > 0) {
    paceKgWk = round1(Math.abs(changeKg) / weeksElapsed);
    computed.push(
      `Observed pace: about ${paceKgWk} kg/week ${changeKg >= 0 ? 'lost' : 'gained'} over ${daysElapsed} days.`,
    );
  } else {
    computed.push('Observed pace: Not enough data yet (need two weigh-ins a few days apart).');
  }
  if (
    goal !== 'maintain' &&
    isNum(startWeightKg) &&
    isNum(targetWeightKg) &&
    isNum(currentWeightKg) &&
    startWeightKg !== targetWeightKg
  ) {
    const toGo = startWeightKg - targetWeightKg; // signed toward goal
    const done = startWeightKg - currentWeightKg;
    const pct = Math.round((done / toGo) * 100);
    computed.push(
      `Goal progress: ${pct}% of the way (${round1(Math.abs(done))} of ${round1(Math.abs(toGo))} kg toward ${targetWeightKg} kg).`,
    );
    if (paceKgWk && paceKgWk > 0 && Math.sign(done) === Math.sign(toGo)) {
      const remaining = Math.abs(currentWeightKg - targetWeightKg);
      const weeksLeft = remaining / paceKgWk;
      const projDay = Math.round(daysElapsed + weeksLeft * 7);
      computed.push(
        `Projected finish (ESTIMATE, only if pace holds): about ${Math.round(weeksLeft)} more week(s), around day ${projDay} of ${targetDays}.`,
      );
    }
  }
  if (extrasCount > 0 && daysElapsed > 0) {
    computed.push(
      `Off-plan extras: ~${Math.round(extrasCalories / daysElapsed)} kcal/day on average (${extrasCount} item(s), ~${extrasCalories} kcal total).`,
    );
  }

  const computedBlock = `Pre-computed figures — use THESE, do not recompute or invent others:\n- ${computed.join('\n- ')}`;

  const user = `Review this person's progress toward their goal, in detail.
${goalLine}, over ${targetDays} days.
Daily calorie target: ${calorieTarget || 'unknown'} kcal.
This is day ${daysElapsed} of ${targetDays}.${currentWeightKg ? `\nCurrent weight: ${currentWeightKg} kg.` : ''}
${trend}
${adherence}
${extras}

${computedBlock}

Write a detailed review:
- a warm one-line headline and the overall status;
- a 2-4 sentence summary that interprets the real weight change and adherence (don't just re-list the numbers);
- 3-5 "metrics", each { label, value, read, trend }. "value" comes ONLY from the figures above (or "Not enough data yet"); "read" adds meaning (a safe-range band or comparison), never a repeat of value; "trend" is good/watch/off. Good candidates: Pace, Goal progress, Projected finish, Meal adherence, Off-plan extras.
- 1-3 "doingWell" (grounded positives) and 1-3 "improve" (what's off and why — a diagnosis, not a fix);
- 2-4 "actionPlan" items: concrete, time-boxed next actions (imperative, specific target) — must not restate an improve item;
- an "outlook": the hedged forward trajectory, explicitly an estimate. Any projected date/weight must carry "est." / "if pace holds". If there are fewer than two weigh-ins or it's very early, say it's too soon to project and focus on habits. If status is too_fast, give a health-caution line instead of a rosy projection.

Never invent a number, weigh-in, %, rate, or date. Present-state read-outs (adherence, % done, observed pace) are stated plainly; every extrapolation (projected finish, extras to kg) must be hedged.`;

  return { system, user };
}

// Prompts for on-demand preparation steps for one dish. Kept allergy-aware even
// though the dish came from an allergy-safe plan, as a defence in depth.
export function buildRecipePrompt(input) {
  const { dish, location, dietaryPreference, allergies = [] } = input;

  const system =
    'You are a home cook. You give clear, concise, beginner-friendly step-by-step ' +
    'preparation instructions for a single dish using common home-kitchen methods. ' +
    'You treat a stated allergy as an absolute constraint. You return ONLY the ' +
    'structured recipe requested.';

  const allergyLine = allergies.length
    ? `\n- ALLERGY SAFETY (hard constraint): the cook is allergic to ${allergies.join(', ')}. ` +
      `Use none of these or anything containing them; substitute safely.`
    : '';

  const user = `Give home preparation steps for: ${dish}.
${location ? `Regional context: ${location}.\n` : ''}Requirements:
- 5 to 12 short, ordered steps, each a single clear action.
- Assume a normal home kitchen; include prep (chopping, soaking, marinating) as steps.
- Keep it practical and beginner-friendly.${dietaryPreference ? `\n- Respect this dietary preference: ${dietaryPreference}.` : ''}${allergyLine}
- Give realistic servings and a rough total time in minutes.
- Add 0 to 3 short tips only if genuinely useful.`;

  return { system, user };
}

// Builds the prompts to regenerate ONE meal (a "swap"), keeping the same slot,
// rough calorie/macro budget, and locale — but a different dish.
export function buildMealPrompt(input) {
  const {
    location,
    mealName,
    time,
    targetCalories,
    avoidDish,
    dietaryPreference,
    allergies = [],
  } = input;

  const system =
    'You are a registered dietitian and meal planner. You suggest a single ' +
    'realistic, nutritionally sensible meal using locally available, regional, ' +
    'in-season ingredients. You treat a stated food allergy as an absolute ' +
    'medical constraint and never include an allergen in any form. ' +
    'You return ONLY the structured meal requested.';

  const budget = targetCalories
    ? `around ${targetCalories} kcal`
    : 'an appropriate calorie amount for this meal slot';

  const user = `Suggest ONE replacement ${mealName || 'meal'} for someone in ${location}.
${
    allergies.length
      ? `\nALLERGIES — HARD SAFETY CONSTRAINT: the user is ALLERGIC to ${allergies.join(', ')}. ` +
        `The suggested meal and every ingredient must be completely free of these, including hidden ` +
        `sources (sauces, pastes, stocks, oils, marinades, garnishes, coatings).\n`
      : ''
  }
Requirements:${allergies.length ? `\n- SAFETY FIRST: contains none of: ${allergies.join(', ')}.` : ''}
- A different dish from "${avoidDish || ''}" — do not repeat it.
- Local, regional, commonly available ingredients in ${location}.
- Target ${budget}; keep it balanced.
${dietaryPreference ? `- Respect this dietary preference: ${dietaryPreference}.\n` : ''}- Suggested time to eat: ${time || 'the usual time for this meal'}.
- Include realistic calories and macros (protein, carbs, fat in grams) and a shopping-quantity ingredient list.`;

  return { system, user };
}
