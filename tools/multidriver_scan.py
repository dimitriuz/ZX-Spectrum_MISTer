#!/usr/bin/env python3
"""Scan Verilog/SystemVerilog files for variables driven by multiple always blocks.

Heuristic but precise for this codebase's style: finds always/always_comb/
always_ff blocks per module, matches begin/end scopes, collects assignment
targets (<= and =), excludes block-local declarations. Reports names assigned
in 2+ distinct always blocks within one module (a synthesis multi-driver
error in Quartus). Known blind spot: relational comparisons like
(a <= b) inside expressions are indistinguishable from assignments at text
level, so hits should be eyeballed before acting.
"""
import re, sys
from collections import defaultdict

KEYWORDS = {'begin','end','if','else','case','casex','casez','default','for',
            'while','repeat','fork','join','initial','always','always_comb',
            'always_ff','always_latch','module','endmodule','function','endfunction',
            'task','endtask','generate','endgenerate','localparam','parameter',
            'reg','logic','wire','integer','genvar','assign','posedge','negedge'}

def strip_comments(src):
    src = re.sub(r'//.*', '', src)
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    return src

def tokenize(src):
    toks = []
    for m in re.finditer(r'[A-Za-z_][A-Za-z0-9_$]*|<=|==|!=|===|!==|=|\+|-|\*|/|&|\||\^|~|!|<|>|\(|\)|;|,|\.|:|@|\'[a-z]?[\x27]?[0-9a-fA-FxXzZ?_]*', src):
        toks.append((m.group(0), m.start()))
    return toks

def scan_file(path):
    src = strip_comments(open(path).read())
    toks = tokenize(src)
    n = len(toks)
    # module spans (multi-module files are common in sys/)
    mods = []
    for idx, (t, pos) in enumerate(toks):
        if t == 'module' and idx + 1 < n:
            name = toks[idx+1][0]
            endpos = len(src)
            for t2, p2 in toks[idx+1:]:
                if t2 == 'endmodule':
                    endpos = p2
                    break
            mods.append((name, pos, endpos))
    def mod_of(p):
        return next((nm for nm, s, e in mods if s <= p < e), '(top)')
    # locate always blocks
    drivers = defaultdict(list)  # var -> list of (line, block_id)
    block_id = 0
    for idx, (t, pos) in enumerate(toks):
        if t not in ('always', 'always_comb', 'always_ff'):
            continue
        # skip optional @(...) sensitivity list: find matching paren if next is @
        j = idx + 1
        if j < n and toks[j][0] == '@':
            j += 1
            if j < n and toks[j][0] == '(':
                depth = 0
                while j < n:
                    if toks[j][0] == '(': depth += 1
                    elif toks[j][0] == ')':
                        depth -= 1
                        if depth == 0: break
                    j += 1
            j += 1
        # now expect begin (or a single statement ending in ;)
        if j < n and toks[j][0] == 'begin':
            start = j + 1
            depth = 1
            k = start
            locals_ = set()
            body_start = start
            while k < n and depth > 0:
                w = toks[k][0]
                if w == 'begin': depth += 1
                elif w == 'end': depth -= 1
                k += 1
            bstart, bend = toks[start-1][1], toks[k-1][1]
            body = src[bstart + 5:bend]
            # local declarations inside body
            # local declarations inside body (multi-name lists)
            for dm in re.finditer(r'\b(?:reg|logic|integer|real|time|signed)\s*([^;]*);', body):
                decl = re.sub(r'\[[^\]]*\]', '', dm.group(1))
                for nm in re.findall(r'[A-Za-z_][A-Za-z0-9_$]*', decl):
                    if nm not in ('signed', 'reg', 'logic', 'integer', 'real', 'time'):
                        locals_.add(nm)
            for am in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_$]*)\s*(?:<=|=(?!=))', body):
                name = am.group(1)
                if name in KEYWORDS or name in locals_:
                    continue
                line = src[:bstart + 5 + am.start()].count('\n') + 1
                drivers[(mod_of(pos), name)].append((line, block_id))
            block_id += 1
    return drivers

def main():
    files = sys.argv[1:]
    problems = False
    for f in files:
        try:
            d = scan_file(f)
        except Exception as e:
            print(f"!! {f}: scan error: {e}")
            continue
        for (mod, name), sites in sorted(d.items()):
            blocks = set(b for _, b in sites)
            if len(blocks) >= 2:
                lines = ', '.join(str(l) for l, _ in sites)
                print(f"{f} [{mod}]: '{name}' driven by {len(blocks)} always blocks (lines {lines})")
                problems = True
    if not problems:
        print("OK: no multi-driver variables found")

if __name__ == '__main__':
    main()
