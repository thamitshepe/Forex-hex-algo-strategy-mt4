#!/usr/bin/env python3
"""
Static sanity checker for MQL4 Expert Advisors.

There is no MetaEditor compiler on macOS, so before shipping an .mq4 file this
script checks the things a compiler would catch and that are easy to get wrong
when code is written without one:

  * balanced braces / parens / brackets (outside comments and strings)
  * every called function is defined in the file or is a known MQL4 builtin
  * no duplicate function definitions
  * no leftover merge/append markers
  * every `extern` input name is unique
  * every referenced global is declared
  * the OnInit/OnTick lifecycle hooks exist

Usage:
    python3 Tools/lint_mql4.py MQL4/Experts/HEX-FVG-Breaker.mq4

Exit code 0 = clean, 1 = problems found.
"""
import re
import sys

BUILTIN = set("""
if for while switch return struct enum true false input extern
MathAbs MathMax MathMin MathFloor MathCeil MathSqrt MathPow MathLog MathMod MathRand MathSrand
NormalizeDouble DoubleToString IntegerToString TimeToStr StrToTime StringTrimLeft StringTrimRight
StringSubstr StringSplit StringReplace StringLen StringFind StringToUpper StringToLower
TimeCurrent TimeLocal TimeToStruct StructToTime GetTickCount
Symbol Period Digits Point Bid Ask Close Open High Low Time Volume Bars
iATR iMA iCustom iHigh iLow iOpen iClose iTickValue iBars iTime
OrdersTotal OrdersHistoryTotal OrderSelect OrderSend OrderClose OrderDelete OrderModify
OrderTicket OrderType OrderLots OrderOpenPrice OrderStopLoss OrderTakeProfit OrderProfit
OrderSwap OrderCommission OrderMagicNumber OrderSymbol OrderCloseTime OrderComment
OrderOpenTime OrderClosePrice OrderExpertMagicNumber
AccountEquity AccountBalance AccountFreeMargin AccountFreeMarginCheck AccountMargin
AccountCurrency AccountName AccountNumber AccountServer AccountInfoDouble
MarketInfo OrderCalcMargin
FolderExist FolderCreate FileOpen FileClose FileWriteString FileReadString FileSeek FileDelete
FileExists FileIsEnding FileFlush FileReadNumber FileWriteNumber FileSize FileGetInteger
ArraySize ArrayResize ArrayFree ArrayCopy ArrayMaximum ArrayMinimum ArraySort ArrayInitialize
ObjectCreate ObjectDelete ObjectsDeleteAll ObjectSetInteger ObjectSetString ObjectSetDouble
ObjectFind ObjectMove ObjectDescription ObjectGetValue
Comment Alert Print PrintFormat GetLastError IsTesting IsTradeAllowed
IsConnected IsTradeContextBusy TerminalInfoInteger TerminalPath ChartID
WebRequest StringToCharArray CharArrayToString StringGetCharacter StringSetCharacter
IsOptimization IsVisualMode IsTermination IsStopped
DoubleToStr StrToDouble StringFormat MathRound StrToInteger
AccountLogin RefreshRates GetPreviousPos PriceToStr
""".split())

SIG = r"(?:int|double|bool|void|string|color|datetime|long|ulong|uint|short|ushort|char|uchar|float|TradeRec|ZoneRec|MqlDateTime)"


def split_args(s):
    """Split an argument list on top-level commas; returns [] for '()'."""
    s = s.strip()
    if not s:
        return []
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return [p for p in parts if p.strip() != ""]


def parse_params(inner):
    """Parse a definition parameter list. Returns (required, has_defaults)."""
    params = split_args(inner)
    has_default = "=" in inner
    req = len(params)
    if has_default:
        # count leading params before the first one that carries a default
        req = 0
        for p in params:
            depth, seen = 0, False
            for ch in p:
                if ch in "([{":
                    depth += 1
                elif ch in ")]}":
                    depth -= 1
                elif ch == "=" and depth == 0:
                    seen = True
                    break
            if not seen:
                req += 1
    return req, has_default


def matching_paren(s, open_idx):
    """Index of the ')' closing the '(' at open_idx, or -1 if unbalanced."""
    depth = 0
    k = open_idx
    while k < len(s):
        if s[k] == "(":
            depth += 1
        elif s[k] == ")":
            depth -= 1
            if depth == 0:
                return k
        k += 1
    return -1


def next_nonspace(s, i):
    while i < len(s) and s[i].isspace():
        i += 1
    return s[i] if i < len(s) else ""


def preceding_token(s, start):
    """The identifier immediately before position `start`, or '' if none."""
    head = s[:start].rstrip()
    m = re.search(r"([A-Za-z_]\w*)$", head)
    return m.group(1) if m else ""


TYPE_WORDS = set(SIG.split("|")) | {"const", "TradeRec", "ZoneRec"}


def check_arity(name, clean, problems):
    """Warn when a user-defined function is called with an impossible number of
    arguments. This is the bug a real compiler catches instantly and this linter
    otherwise cannot: matching names, mismatched arity."""
    if name in TYPE_WORDS:
        return
    defs, calls = [], []
    for m in re.finditer(rf"\b{re.escape(name)}\s*\(", clean):
        oi = m.end() - 1
        ci = matching_paren(clean, oi)
        if ci < 0:
            return                       # unbalanced: the paren check reports it
        inner = clean[oi + 1:ci]
        nxt = next_nonspace(clean, ci + 1)
        prev = preceding_token(clean, m.start())
        if nxt == "{":                   # body follows: definition
            defs.append(parse_params(inner))
        elif nxt == ";" and prev in TYPE_WORDS:
            pass                         # forward declaration, not a call
        else:
            calls.append((oi, len(split_args(inner))))
    uniq = list(dict.fromkeys(defs))
    if len(uniq) != 1:
        return                           # overloaded or unparseable: not our business
    req, has_def = uniq[0]
    for oi, n in calls:
        if n < req or (n > req and not has_def):
            ln = clean[:oi].count("\n") + 1
            problems.append(
                f"{name}() called with {n} arg(s) at line {ln}; defined with "
                f"{req}{'+defaults' if has_def else ''}")


def strip_noise(src):
    """Remove // and /* */ comments and string literals, preserving line count."""
    out = []
    i, n = 0, len(src)
    in_block = False
    while i < n:
        ch = src[i]
        if in_block:
            if src.startswith("*/", i):
                in_block = False
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
            continue
        if src.startswith("/*", i):
            in_block = True
            out.append("  ")
            i += 2
            continue
        if ch == '"':
            out.append('"')
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    out.append(" ")
                    i += 1
                    if i >= n:
                        break
                out.append(" ")
                i += 1
            if i < n:
                out.append('"')
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    clean = strip_noise(raw)
    problems = []

    for a, b in (("{", "}"), ("(", ")"), ("[", "]")):
        ca, cb = clean.count(a), clean.count(b)
        if ca != cb:
            problems.append(f"unbalanced {a}{b}: {ca} vs {cb}")

    for marker in ("@@APPEND@@", "@@INPUTS@@", "<<<<<<<"):
        if marker in clean:
            line = next(i for i, l in enumerate(clean.splitlines(), 1) if marker in l)
            problems.append(f"leftover marker {marker!r} at line {line}")

    # function definitions, tracked by line so true duplicates are detectable
    sig_lines = [(m.start(), m.group(1))
                 for m in re.finditer(rf"^{SIG}\s+([A-Za-z_]\w*)\s*\([^;]*$", clean, re.M)]
    one_line = [(m.start(), m.group(1))
                for m in re.finditer(rf"^{SIG}\s+([A-Za-z_]\w*)\s*\([^)]*\)\s*\{{", clean, re.M)]
    seen = {}
    for pos, name in sig_lines + one_line:
        seen.setdefault(name, set()).add(pos)
    defs = [n for _, n in sig_lines + one_line]
    dupes = sorted({n for n, ps in seen.items() if len(ps) > 1})
    if dupes:
        problems.append(f"duplicate function definitions: {dupes}")

    called = set(re.findall(r"\b([A-Za-z_]\w*)\s*\(", clean))
    declared = set(defs)
    unknown = sorted(
        c for c in called - declared - BUILTIN
        if not c.startswith(("OBJ", "OP_", "MODE_", "FILE_", "STYLE_", "CLR", "ANCHOR", "PRICE_", "SELECT_", "TIME_", "INIT_", "DRAW_"))
    )
    if unknown:
        problems.append(f"possibly undefined functions: {unknown}")

    # argument-count mismatches on functions defined in this file. Catches the
    # "added an argument to the call site but not the signature" bug that a real
    # compiler would reject and this linter previously waved through.
    for name in sorted(set(defs) - set(BUILTIN)):
        check_arity(name, clean, problems)

    ext = re.findall(r"^\s*extern\s+\w+\s+([A-Za-z_]\w*)", clean, re.M)
    dup_ext = sorted({e for e in ext if ext.count(e) > 1})
    if dup_ext:
        problems.append(f"duplicate extern inputs: {dup_ext}")

    gdecl = set(re.findall(r"^\s*(?:extern\s+)?[A-Za-z_]\w*\s+(\w+)\s*(?:\[[^\]]*\])?\s*[=;]", clean, re.M))
    grefs = set(re.findall(r"\b(g_\w+)\b", clean))
    missing_g = sorted(grefs - gdecl)
    if missing_g:
        problems.append(f"undeclared globals: {missing_g}")

    for hook in ("OnInit", "OnTick"):
        if hook not in defs:
            problems.append(f"missing lifecycle function {hook}()")

    # every OrderSend must be followed by error handling
    if "OrderSend(" in clean and "GetLastError()" not in clean:
        problems.append("OrderSend used without GetLastError() reporting")

    print(f":: {path}")
    print(f"   lines={len(raw.splitlines())} externs={len(ext)} functions={len(set(defs))}")
    if problems:
        for p in problems:
            print("   FAIL " + p)
        return 1
    print("   PASS structure, identifiers, markers, externs, globals, order-error handling")
    return 0


if __name__ == "__main__":
    targets = sys.argv[1:] or ["MQL4/Experts/HEX-FVG-Breaker.mq4"]
    sys.exit(max(check(t) for t in targets))
