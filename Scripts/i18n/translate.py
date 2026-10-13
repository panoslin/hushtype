"""Translates Scripts/i18n/keys.json (zh-Hans source strings) into en and zh-Hant .strings files.
usage: HUSHTYPE_KEY_FILE=... translate.py"""
import json, os, re, sys, urllib.request
keys = json.load(open("Scripts/i18n/keys.json"))
api_key = open(os.environ["HUSHTYPE_KEY_FILE"]).read().strip()
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|lf|f|\.\d+f)")

def ask(target, items):
    system = f"""You localize the UI of Hushtype, a macOS voice-dictation app (press fn, speak, cleaned-up text is typed at the cursor; menu bar app; dictionary of custom terms; "整理" = the AI cleanup/rewrite step; "听写" = dictation; "浮窗" = the floating recording pill).
Translate each Simplified Chinese UI string into {target}. Keep it concise and natural for a native Mac app (Apple's style). Keep every format specifier (%@, %lld, %lf…) exactly, same count; you may reorder them only with positional forms like %1$@. Keep key symbols (fn, ⌘, ⌥, ⌃, ⇧, esc), brand names (Hushtype, Claude, Typeless, Whisper, SenseVoice, Sonnet, Haiku, Anthropic, Google, Notion), and file formats unchanged. Corner brackets 「」 become curly quotes “” in English.
Return only a JSON object mapping each input string to its translation."""
    body = {"model": "claude-sonnet-5-5", "max_tokens": 16000, "system": system,
            "messages": [{"role": "user", "content": json.dumps(items, ensure_ascii=False)}]}
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(),
          headers={"x-api-key": api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    text = json.load(urllib.request.urlopen(req, timeout=600))["content"][-1]["text"]
    return json.loads(text[text.find("{"): text.rfind("}") + 1])

def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def existing(lang):
    p = f"Resources/Localization/{lang}.lproj/Localizable.strings"
    if not os.path.exists(p): return {}
    pat = re.compile(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$')
    un = lambda s: s.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")
    return {un(m.group(1)): un(m.group(2)) for m in (pat.match(l) for l in open(p, encoding="utf-8")) if m}

src = [k for k in keys]
for target, lang in (("English", "en"), ("Traditional Chinese as used in Taiwan (繁體中文)", "zh-Hant")):
    out = {k: v for k, v in existing(lang).items() if k in keys}
    todo = [k for k in src if k not in out]
    for i in range(0, len(todo), 90):
        out.update(ask(target, todo[i:i + 90]))
    bad = [k for k in src if k not in out or sorted(SPEC.findall(re.sub(r"%\d+\$", "%", k))) != sorted(SPEC.findall(re.sub(r"%\d+\$", "%", out[k])))]
    for k in bad: out[k] = k if lang == "zh-Hant" else out.get(k, k)
    os.makedirs(f"Resources/Localization/{lang}.lproj", exist_ok=True)
    with open(f"Resources/Localization/{lang}.lproj/Localizable.strings", "w", encoding="utf-8") as f:
        for k in src:
            f.write(f'"{esc(k)}" = "{esc(out.get(k, k))}";\n')
    print(lang, len(out), "bad specifiers:", bad)
