// Provider abstraction so the plan generator can target different LLM vendors
// with a single env var. Switch vendor with PROVIDER (anthropic | gemini) and
// optionally override the model with MODEL. Each provider exposes the same
// generate({ system, user, maxTokens, effort }) -> { text, outTokens } shape;
// planService.js stays vendor-agnostic and just parses the returned text.

import Anthropic from '@anthropic-ai/sdk';
import { GoogleGenAI } from '@google/genai';
import { PLAN_SCHEMA } from './planSchema.js';

// Gemini's responseSchema is an OpenAPI subset: it rejects `additionalProperties`
// and wants the `type` keyword uppercased (OBJECT/ARRAY/STRING/INTEGER). Convert
// the strict Anthropic schema into that dialect once, recursively.
function toGeminiSchema(node) {
  if (Array.isArray(node)) return node.map(toGeminiSchema);
  if (node && typeof node === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(node)) {
      if (k === 'additionalProperties') continue;
      if (k === 'type' && typeof v === 'string') {
        out[k] = v.toUpperCase();
        continue;
      }
      out[k] = toGeminiSchema(v);
    }
    return out;
  }
  return node;
}

// Lazy clients so the server still boots (and /health responds) without a key —
// the key is only required the first time the selected provider actually runs.
let _anthropic;
let _gemini;
let _geminiSchema;

const PROVIDERS = {
  anthropic: {
    keyEnv: 'ANTHROPIC_API_KEY',
    defaultModel: 'claude-opus-4-8',
    async generate({ model, system, user, maxTokens, effort, schema = PLAN_SCHEMA }) {
      if (!_anthropic) _anthropic = new Anthropic(); // reads ANTHROPIC_API_KEY
      // Stream so large multi-day plans don't hit the SDK's non-streaming timeout.
      const stream = _anthropic.messages.stream({
        model,
        max_tokens: maxTokens,
        thinking: { type: 'adaptive' },
        output_config: {
          effort,
          format: { type: 'json_schema', schema },
        },
        system,
        messages: [{ role: 'user', content: user }],
      });
      const message = await stream.finalMessage();

      if (message.stop_reason === 'refusal') {
        const err = new Error('The model declined to generate this plan.');
        err.status = 422;
        throw err;
      }
      const block = message.content.find((b) => b.type === 'text');
      if (!block) {
        console.error('[gen] no text block. blocks:', message.content.map((b) => b.type));
        const err = new Error('The model returned no plan text.');
        err.status = 502;
        throw err;
      }
      return { text: block.text, outTokens: message.usage?.output_tokens };
    },
  },

  gemini: {
    keyEnv: 'GEMINI_API_KEY',
    defaultModel: 'gemini-2.5-flash',
    async generate({ model, system, user, maxTokens, schema = PLAN_SCHEMA }) {
      if (!_gemini) {
        _gemini = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
      }
      // Convert + cache the default plan schema; convert others on demand
      // (meal-swap calls are infrequent).
      let responseSchema;
      if (schema === PLAN_SCHEMA) {
        if (!_geminiSchema) _geminiSchema = toGeminiSchema(PLAN_SCHEMA);
        responseSchema = _geminiSchema;
      } else {
        responseSchema = toGeminiSchema(schema);
      }

      const res = await _gemini.models.generateContent({
        model,
        contents: user,
        config: {
          systemInstruction: system,
          maxOutputTokens: maxTokens,
          // Force a single JSON object that matches the schema — no fences,
          // no prose — so the same tolerant parser handles both providers.
          responseMimeType: 'application/json',
          responseSchema,
        },
      });

      const text = res.text;
      if (!text) {
        const reason = res.candidates?.[0]?.finishReason;
        console.error('[gen] gemini returned no text. finishReason:', reason);
        const err = new Error('The model returned no plan text.');
        err.status = reason === 'SAFETY' ? 422 : 502;
        throw err;
      }
      return { text, outTokens: res.usageMetadata?.candidatesTokenCount };
    },
  },
};

// Resolve the active provider from the environment. PROVIDER picks the vendor;
// MODEL (if set) overrides that vendor's default model. Throws a 500 with a
// clear message if the vendor is unknown or its API key is missing.
export function getProvider() {
  const name = (process.env.PROVIDER || 'anthropic').toLowerCase();
  const provider = PROVIDERS[name];
  if (!provider) {
    const err = new Error(
      `Unknown PROVIDER "${name}". Supported: ${Object.keys(PROVIDERS).join(', ')}.`,
    );
    err.status = 500;
    throw err;
  }
  if (!process.env[provider.keyEnv]) {
    const err = new Error(
      `${provider.keyEnv} is not set for PROVIDER="${name}". Add it to .env.`,
    );
    err.status = 500;
    throw err;
  }
  const model = process.env.MODEL || provider.defaultModel;
  return {
    name,
    model,
    generate: (opts) => provider.generate({ ...opts, model }),
  };
}

// Non-throwing summary for the startup banner (works even with no key set).
export function describeProvider() {
  const name = (process.env.PROVIDER || 'anthropic').toLowerCase();
  const provider = PROVIDERS[name];
  if (!provider) return { name, model: '?', keyEnv: '?', keySet: false };
  return {
    name,
    model: process.env.MODEL || provider.defaultModel,
    keyEnv: provider.keyEnv,
    keySet: Boolean(process.env[provider.keyEnv]),
  };
}
