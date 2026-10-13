/**
 * Hushtype Cloud rewrite proxy (Cloudflare Worker).
 *
 * The Mac app talks to this exactly like the Anthropic Messages API (POST /v1/messages) but sends
 * `Authorization: Bearer <user token>` instead of an API key. The Worker checks the token, accepts
 * only requests shaped like Hushtype's own (a Hushtype system prompt, one user message, small output),
 * enforces per-user rate and token quotas, and forwards with the server's key. The Anthropic key
 * never reaches the client, and the proxy can't be used as a general-purpose Claude endpoint.
 *
 * Bindings (see wrangler.toml.example):
 *   ANTHROPIC_API_KEY  secret
 *   TOKENS             KV: "token:<token>" -> {"user": "...", "dailyTokens": 2000000}
 *   USAGE              KV: usage counters (approximate, eventually consistent)
 */
import { PROMPT_PREFIXES } from "./prompts.ts";

export interface Env {
  ANTHROPIC_API_KEY: string;
  TOKENS: KVNamespace;
  USAGE: KVNamespace;
}

interface TokenRecord {
  user: string;
  /** Input + output tokens per UTC day. */
  dailyTokens?: number;
  /** Requests per minute. */
  perMinute?: number;
  disabled?: boolean;
}

const ALLOWED_MODELS = new Set(["claude-sonnet-5-5", "claude-haiku-5-5"]);
const ALLOWED_FIELDS = new Set(["model", "max_tokens", "system", "thinking", "output_config", "messages"]);
const ALLOWED_THINKING = new Set(["between_tools", "disabled"]);
const ALLOWED_EFFORT = new Set(["low", "medium"]);
const MAX_BODY_BYTES = 256 * 1024;
const MAX_OUTPUT_TOKENS = 16_000;
const MAX_USER_CHARS = 60_000;
/** Dictionary, learned corrections, etc. appended after the fixed prompt. */
const MAX_SYSTEM_EXTRA_CHARS = 16_000;
const DEFAULT_DAILY_TOKENS = 2_000_000;
const DEFAULT_PER_MINUTE = 30;

function json(status: number, type: string, message: string): Response {
  return new Response(JSON.stringify({ type: "error", error: { type, message } }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Validates the request body. Returns an error string, or null when the request is acceptable. */
export function validate(body: Record<string, unknown>): string | null {
  for (const k of Object.keys(body)) {
    if (!ALLOWED_FIELDS.has(k)) return `field not allowed: ${k}`;
  }
  if (typeof body.model !== "string" || !ALLOWED_MODELS.has(body.model)) return "model not allowed";
  const max = body.max_tokens;
  if (typeof max !== "number" || !Number.isInteger(max) || max < 0 || max > MAX_OUTPUT_TOKENS) return "max_tokens out of range";

  // System prompt: exactly one text block that starts with one of Hushtype's own prompts.
  const sys = body.system;
  if (!Array.isArray(sys) || sys.length !== 1) return "system must be one block";
  const block = sys[0] as { type?: unknown; text?: unknown; cache_control?: unknown };
  if (block.type !== "text" || typeof block.text !== "string") return "system block must be text";
  for (const k of Object.keys(block)) if (!["type", "text", "cache_control"].includes(k)) return `system field not allowed: ${k}`;
  const prefix = PROMPT_PREFIXES.find((p) => (block.text as string).startsWith(p));
  if (!prefix) return "unknown system prompt";
  if ((block.text as string).length - prefix.length > MAX_SYSTEM_EXTRA_CHARS) return "system prompt too long";

  const messages = body.messages;
  if (!Array.isArray(messages) || messages.length !== 1) return "exactly one message expected";
  const m = messages[0] as { role?: unknown; content?: unknown };
  if (m.role !== "user" || typeof m.content !== "string") return "message must be a single user string";
  if (m.content.length > MAX_USER_CHARS) return "message too long";

  if (body.thinking !== undefined) {
    const t = body.thinking as { type?: unknown };
    if (typeof t !== "object" || t === null || !ALLOWED_THINKING.has(t.type as string) || Object.keys(t).length !== 1) return "thinking not allowed";
  }
  if (body.output_config !== undefined) {
    const o = body.output_config as { effort?: unknown };
    if (typeof o !== "object" || o === null || !ALLOWED_EFFORT.has(o.effort as string) || Object.keys(o).length !== 1) return "output_config not allowed";
  }
  return null;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/health") return new Response("ok");
    if (req.method !== "POST" || url.pathname !== "/v1/messages") return json(404, "not_found_error", "not found");

    const auth = req.headers.get("authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
    if (!token || token.length > 200) return json(401, "authentication_error", "missing token");
    const rec = await env.TOKENS.get<TokenRecord>(`token:${token}`, "json");
    if (!rec || rec.disabled) return json(401, "authentication_error", "invalid token");

    const len = Number(req.headers.get("content-length") ?? "0");
    if (len > MAX_BODY_BYTES) return json(413, "request_too_large", "request too large");
    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) return json(413, "request_too_large", "request too large");
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(raw);
    } catch {
      return json(400, "invalid_request_error", "invalid json");
    }
    const problem = validate(body);
    if (problem) return json(400, "invalid_request_error", problem);

    // Rate limit (per minute) and daily token quota. Cache warmups (max_tokens 0) skip the rate limit.
    const now = new Date();
    const day = now.toISOString().slice(0, 10);
    const minute = now.toISOString().slice(0, 16);
    const tokensKey = `tokens:${rec.user}:${day}`;
    const usedTokens = Number((await env.USAGE.get(tokensKey)) ?? "0");
    if (usedTokens >= (rec.dailyTokens ?? DEFAULT_DAILY_TOKENS)) return json(429, "rate_limit_error", "daily limit reached");
    if (body.max_tokens !== 0) {
      const rateKey = `rate:${rec.user}:${minute}`;
      const n = Number((await env.USAGE.get(rateKey)) ?? "0");
      if (n >= (rec.perMinute ?? DEFAULT_PER_MINUTE)) return json(429, "rate_limit_error", "too many requests");
      await env.USAGE.put(rateKey, String(n + 1), { expirationTtl: 120 });
    }

    const upstream = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    const text = await upstream.text();
    try {
      const usage = JSON.parse(text).usage ?? {};
      const spent = (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0);
      if (spent > 0) await env.USAGE.put(tokensKey, String(usedTokens + spent), { expirationTtl: 3 * 86400 });
    } catch {
      /* non-JSON upstream error: pass through */
    }
    return new Response(text, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  },
};
