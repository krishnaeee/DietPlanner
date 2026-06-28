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
        "2-4 sentence overview: the safe rate of weight change, the daily calorie target, and the regional cuisine the plan draws on. If the user's target is not safely achievable in the period, say so here and explain the adjusted, safe target you planned for instead.",
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
    startDay = 1,
    avoidDishes = [],
  } = input;

  const endDay = startDay + plannedDays - 1;
  const isContinuation = startDay > 1;

  const system =
    'You are a registered dietitian and meal planner. You design realistic, ' +
    'nutritionally balanced diet plans that respect safe rates of weight change ' +
    '(roughly 0.25-1 kg per week) and never prescribe dangerously low intake ' +
    '(generally not below ~1200 kcal/day for women or ~1500 kcal/day for men ' +
    'without medical supervision). You specialise in cooking with locally available, ' +
    'regional, in-season ingredients. You return ONLY the structured plan requested.';

  const optional = [
    age ? `Age: ${age}` : null,
    sex ? `Sex: ${sex}` : null,
    activityLevel ? `Activity level: ${activityLevel}` : null,
    dietaryPreference ? `Dietary preference: ${dietaryPreference}` : null,
  ]
    .filter(Boolean)
    .join('\n');

  const direction = targetWeightKg < weightKg ? 'lose' : targetWeightKg > weightKg ? 'gain' : 'maintain';

  const continuationContext = isContinuation
    ? `\nThis is a CONTINUATION of an ongoing ${targetDays}-day plan. You are filling days ${startDay} to ${endDay}. Keep the same daily calorie target and style as the rest of the plan.`
    : '';

  const avoidLine = avoidDishes.length
    ? `\n- Do NOT reuse any of these dishes already planned earlier — pick different meals: ${avoidDishes.join(', ')}.`
    : '';

  const user = `Create a personalised diet plan with these details:

Current weight: ${weightKg} kg
Height: ${heightCm} cm
Target weight: ${targetWeightKg} kg (goal: ${direction} weight)
Target time period: ${targetDays} days
Location: ${location}
${optional ? optional + '\n' : ''}${continuationContext}
Requirements:
- Plan exactly ${plannedDays} day(s), numbered ${startDay} to ${endDay}.
- Each day must include Breakfast, Lunch, Dinner, and one Snack (4 meals).
- Use dishes and ingredients that are local, regional, and commonly available in ${location}.
- Vary the dishes across days so the plan does not get repetitive.${avoidLine}
- For every meal, list its ingredients with realistic shopping quantities.
- For every meal, give realistic calories and macros (protein, carbs, fat in grams). Each day's meal calories should add up close to the daily calorie target.
- Also provide daily protein/carbs/fat targets that are consistent with the calorie target (protein and carbs ≈ 4 kcal/g, fat ≈ 9 kcal/g) and include enough protein to support the user's goal.
- Choose a daily calorie target that moves the user safely toward the target weight over the full ${targetDays}-day period. If the target is not safely achievable in that time, plan for the safe maximum instead and explain this in the summary.`;

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
  } = input;

  const system =
    'You are a registered dietitian and meal planner. You suggest a single ' +
    'realistic, nutritionally sensible meal using locally available, regional, ' +
    'in-season ingredients. You return ONLY the structured meal requested.';

  const budget = targetCalories
    ? `around ${targetCalories} kcal`
    : 'an appropriate calorie amount for this meal slot';

  const user = `Suggest ONE replacement ${mealName || 'meal'} for someone in ${location}.

Requirements:
- A different dish from "${avoidDish || ''}" — do not repeat it.
- Local, regional, commonly available ingredients in ${location}.
- Target ${budget}; keep it balanced.
${dietaryPreference ? `- Respect this dietary preference: ${dietaryPreference}.\n` : ''}- Suggested time to eat: ${time || 'the usual time for this meal'}.
- Include realistic calories and macros (protein, carbs, fat in grams) and a shopping-quantity ingredient list.`;

  return { system, user };
}
