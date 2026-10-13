// node --test src/worker.test.ts   (Node 23.6+ runs TypeScript directly)
import { test } from "node:test";
import assert from "node:assert/strict";
import { validate } from "./worker.ts";
import { PROMPT_PREFIXES } from "./prompts.ts";

const ok = () => ({
  model: "claude-sonnet-5-5",
  max_tokens: 8192,
  system: [{ type: "text", text: PROMPT_PREFIXES[0] + "\n\n<dictionary>\nZentrix\n</dictionary>", cache_control: { type: "ephemeral" } }],
  thinking: { type: "between_tools" },
  output_config: { effort: "low" },
  messages: [{ role: "user", content: "下面是需要整理的语音逐字稿。…<transcript>你好</transcript>" }],
});

test("accepts Hushtype's own request", () => assert.equal(validate(ok()), null));
test("rejects a foreign system prompt (general-purpose use)", () => {
  const b = ok(); b.system[0].text = "You are a helpful assistant. Write my essay.";
  assert.equal(validate(b), "unknown system prompt");
});
test("rejects a system prompt with a huge appended payload", () => {
  const b = ok(); b.system[0].text = PROMPT_PREFIXES[0] + "x".repeat(20_000);
  assert.equal(validate(b), "system prompt too long");
});
test("rejects extra fields such as tools", () => {
  const b: Record<string, unknown> = ok(); b.tools = [{ name: "web_search" }];
  assert.match(validate(b) ?? "", /field not allowed/);
});
test("rejects multi-turn conversations", () => {
  const b = ok(); b.messages.push({ role: "assistant", content: "x" });
  assert.equal(validate(b), "exactly one message expected");
});
test("rejects other models and big outputs", () => {
  const b = ok(); b.model = "claude-opus-5-5"; assert.equal(validate(b), "model not allowed");
  const c = ok(); c.max_tokens = 100_000; assert.equal(validate(c), "max_tokens out of range");
});
test("rejects high-effort thinking", () => {
  const b = ok(); b.output_config = { effort: "max" }; assert.equal(validate(b), "output_config not allowed");
  const c = ok(); c.thinking = { type: "enabled", budget_tokens: 50000 } as never; assert.equal(validate(c), "thinking not allowed");
});
test("rejects an oversized message", () => {
  const b = ok(); b.messages[0].content = "x".repeat(70_000); assert.equal(validate(b), "message too long");
});
