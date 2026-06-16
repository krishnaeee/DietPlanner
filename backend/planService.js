import Anthropic from '@anthropic-ai/sdk';
import { PLAN_SCHEMA, buildPrompt } from './planSchema.js';

// Default to the most capable model. Override with MODEL=claude-haiku-4-5 (etc.)
// in the environment to trade quality for cost/latency.
const MODEL = process.env.MODEL || 'claude-opus-4-8';
const EFFORT = process.env.EFFORT || 'medium'; // low | medium | high | max
const MAX_TOKENS = Number(process.env.MAX_TOKENS || 32000);

// Cap how many days we ask the model to detail in one call, to keep the
// response within token limits AND generation time under the app's timeout.
// Longer goals still plan up to this many days; the summary notes the cap.
// (Lowered to 7 — a full 14-day Opus plan can run past the client timeout.)
export const MAX_PLAN_DAYS = Number(process.env.MAX_PLAN_DAYS || 7);

// Lazy singleton: construct on first use so the server still boots (and /health
// responds) when ANTHROPIC_API_KEY is not yet set — with a clear error on use.
let _client;
function getClient() {
  if (!_client) {
    if (!process.env.ANTHROPIC_API_KEY) {
      const err = new Error(
        'ANTHROPIC_API_KEY is not set. Copy .env.example to .env and add your key.',
      );
      err.status = 500;
      throw err;
    }
    _client = new Anthropic(); // reads ANTHROPIC_API_KEY from the environment
  }
  return _client;
}

// Tolerant JSON extraction: prefer clean parse, otherwise strip markdown
// fences and grab the outermost {...}. Guards against the model wrapping JSON.
function parsePlanJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    const cleaned = text.replace(/```json\s*/gi, '').replace(/```/g, '').trim();
    const start = cleaned.indexOf('{');
    const end = cleaned.lastIndexOf('}');
    if (start !== -1 && end !== -1 && end > start) {
      return JSON.parse(cleaned.slice(start, end + 1));
    }
    throw new Error('Model response was not valid JSON.');
  }
}

export async function generatePlan(input) {
  const plannedDays = Math.min(input.targetDays, MAX_PLAN_DAYS);
  const { system, user } = buildPrompt(input, plannedDays);

  console.log(
    `[gen] calling ${MODEL} (effort=${EFFORT}, maxTokens=${MAX_TOKENS}) for ${plannedDays} day(s)…`,
  );
  const t0 = Date.now();
  // Heartbeat so you can see it's still working (vs. hung) in the console.
  const heartbeat = setInterval(() => {
    console.log(`[gen]   …still generating (${((Date.now() - t0) / 1000).toFixed(0)}s)`);
  }, 10000);

  let message;
  try {
    // Stream so large multi-day plans don't hit the SDK's non-streaming timeout.
    const stream = getClient().messages.stream({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      thinking: { type: 'adaptive' },
      output_config: {
        effort: EFFORT,
        format: { type: 'json_schema', schema: PLAN_SCHEMA },
      },
      system,
      messages: [{ role: 'user', content: user }],
    });
    message = await stream.finalMessage();
  } catch (err) {
    clearInterval(heartbeat);
    console.error(`[gen] ✗ Anthropic call failed after ${((Date.now() - t0) / 1000).toFixed(1)}s:`, err?.message);
    throw err;
  }
  clearInterval(heartbeat);

  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  const usage = message.usage || {};
  console.log(
    `[gen] model responded in ${secs}s — stop_reason=${message.stop_reason}, out_tokens=${usage.output_tokens ?? '?'}`,
  );

  if (message.stop_reason === 'refusal') {
    const err = new Error('The model declined to generate this plan.');
    err.status = 422;
    throw err;
  }

  const textBlock = message.content.find((b) => b.type === 'text');
  if (!textBlock) {
    console.error('[gen] no text block. blocks:', message.content.map((b) => b.type));
    const err = new Error('The model returned no plan text.');
    err.status = 502;
    throw err;
  }

  let plan;
  try {
    plan = parsePlanJson(textBlock.text);
  } catch (e) {
    console.error('[gen] JSON parse failed. First 300 chars of output:\n', textBlock.text.slice(0, 300));
    throw e;
  }
  console.log(`[gen] parsed ${plan?.days?.length ?? 0} day(s) OK`);

  return {
    plan,
    meta: {
      requestedDays: input.targetDays,
      plannedDays,
      truncated: input.targetDays > plannedDays,
      model: MODEL,
    },
  };
}
