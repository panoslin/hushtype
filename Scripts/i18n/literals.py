"""Finds single-line Swift string literals containing CJK text, with nesting-aware parsing.
usage: literals.py report|wrap <files...>
wrap: surrounds each eligible literal with String(localized: ...)."""
import re, sys
CJK = re.compile(r'[一-鿿]')

def literals(src):
    """Yields (start, end, depth, multiline) of string literals; depth = nesting inside interpolation."""
    i, n, out = 0, len(src), []
    def scan_string(i, depth):
        multi = src.startswith('"""', i)
        q = '"""' if multi else '"'
        start = i; i += len(q)
        while i < n:
            if src.startswith('\\(', i):
                i += 2; par = 1
                while i < n and par:
                    if src[i] == '"':
                        i = scan_string(i, depth + 1); continue
                    if src[i] == '(': par += 1
                    elif src[i] == ')': par -= 1
                    i += 1
                continue
            if src[i] == '\\': i += 2; continue
            if src.startswith(q, i):
                i += len(q); out.append((start, i, depth, multi)); return i
            if not multi and src[i] == '\n': return i
            i += 1
        return i
    while i < n:
        if src.startswith('//', i): i = src.find('\n', i); i = n if i < 0 else i; continue
        if src.startswith('/*', i): j = src.find('*/', i); i = n if j < 0 else j + 2; continue
        if src.startswith('#"', i):  # raw strings: regexes etc, skip
            j = src.find('"#', i + 2); i = n if j < 0 else j + 2; continue
        if src[i] == '"': i = scan_string(i, 0); continue
        i += 1
    return out

def eligible(src, s, e, multi):
    if multi or not CJK.search(src[s:e]): return False
    line_start = src.rfind('\n', 0, s) + 1
    before = src[line_start:s]
    if 'Log.info(' in before or 'String(localized:' in src[max(0, s - 18):s]: return False
    # Not UI: prompt text, page-content matching, import headers, redaction marker.
    for skip in ('"phrase", ', 'text.contains(', 'withTemplate:', 'user: "预热"', 'err.contains(', 'err.hasPrefix('):
        if skip in before: return False
    return True

if __name__ == "__main__":
    mode, files = sys.argv[1], sys.argv[2:]
    for f in files:
        src = open(f, encoding='utf-8').read()
        lits = [l for l in literals(src) if eligible(src, l[0], l[1], l[3])]
        if mode == 'report':
            for s, e, d, _ in lits:
                ls = src.rfind('\n', 0, s) + 1
                print(f"{f}:{src.count(chr(10), 0, s)+1}: …{src[max(ls, s-45):s]}⟦{src[s:e]}⟧")
        else:
            # Wrap innermost-last so offsets stay valid: process from the end.
            for s, e, d, _ in sorted(lits, key=lambda x: -x[0]):
                src = src[:s] + 'String(localized: ' + src[s:e] + ')' + src[e:]
            open(f, 'w', encoding='utf-8').write(src)
            print(f, len(lits))
