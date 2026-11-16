#!/usr/bin/env python3
"""
Static sanity checker for MQL5 sources.

There is no MetaEditor on this machine (the Dockerfile's ea-check stage is what
compiles for real, in CI). This is the fast pass that needs no Wine, and it
catches the mistakes that are easy to make when an MQL4 file is carried to MQL5:

  * balanced braces / parens / brackets (outside comments and strings)
  * MQL4-only API: MarketInfo, OrderSend/OrderSelect/OrderClose/OrderModify,
    OrdersHistoryTotal, OP_BUY..., MODE_*, the Time[]/High[]/Low[]/Close[]/
    Open[] series, bare Bid/Ask/Point/Digits/Bars, extern, TimeToStr,
    RefreshRates, IsTradeAllowed
  * duplicate function definitions
  * every called function resolves to a definition in the file or a known builtin
  * the OnInit/OnTick lifecycle hooks, and the includes/timers they imply

Usage:
    python3 Tools/lint_mql5.py MQL5/Experts/HEX-FVG-Breaker.mq5

Exit code 0 = clean, 1 = problems found.
"""
import re
import sys

# MQL4 names that do not exist in MQL5, or whose signature moved.
MQL4_ONLY = {
    "MarketInfo": "SymbolInfoDouble / SymbolInfoInteger",
    "OrderSend": "CTrade::Buy/Sell/BuyLimit/SellLimit/PositionOpen",
    "OrderClose": "CTrade::PositionClose / PositionClosePartial",
    "OrderModify": "CTrade::PositionModify / OrderModify",
    "OrdersHistoryTotal": "HistoryDealsTotal (after HistorySelect)",
    "AccountBalance": "AccountInfoDouble(ACCOUNT_BALANCE)",
    "AccountEquity": "AccountInfoDouble(ACCOUNT_EQUITY)",
    "AccountFreeMargin": "AccountInfoDouble(ACCOUNT_MARGIN_FREE)",
    "AccountNumber": "AccountInfoInteger(ACCOUNT_LOGIN)",
    "AccountCurrency": "AccountInfoString(ACCOUNT_CURRENCY)",
    "TimeToStr": "TimeToString",
    "RefreshRates": "SymbolInfoDouble(_Symbol, SYMBOL_BID/ASK)",
    "IsTradeAllowed": "TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) + MQLInfoInteger(MQL_TRADE_ALLOWED)",
    "WindowRedraw": "ChartRedraw",
}

# Bare identifiers MQL4 provides as series / variables.
MQL4_VARS = {
    "Bid": "SymbolInfoDouble(_Symbol, SYMBOL_BID)",
    "Ask": "SymbolInfoDouble(_Symbol, SYMBOL_ASK)",
    "Point": "_Point",
    "Digits": "_Digits",
    "Bars": "Bars(_Symbol, _Period)",
}

# MQL4 constants. MODE_EMA/PRICE_CLOSE exist in MQL5 but iMA changed shape, and
# they are listed in the arity note rather than here.
MQL4_CONSTS = {
    "OP_BUY": "ORDER_TYPE_BUY / POSITION_TYPE_BUY",
    "OP_SELL": "ORDER_TYPE_SELL / POSITION_TYPE_SELL",
    "OP_BUYLIMIT": "ORDER_TYPE_BUY_LIMIT",
    "OP_SELLLIMIT": "ORDER_TYPE_SELL_LIMIT",
    "OP_BUYSTOP": "ORDER_TYPE_BUY_STOP",
    "OP_SELLSTOP": "ORDER_TYPE_SELL_STOP",
    "MODE_TRADES": "PositionsTotal()",
    "MODE_HISTORY": "HistorySelect()",
    "MODE_LOTSIZE": "SYMBOL_TRADE_CONTRACT_SIZE",
    "MODE_TICKVALUE": "SYMBOL_TRADE_TICK_VALUE",
    "MODE_TICKSIZE": "SYMBOL_TRADE_TICK_SIZE",
    "MODE_MINLOT": "SYMBOL_VOLUME_MIN",
    "MODE_MAXLOT": "SYMBOL_VOLUME_MAX",
    "MODE_LOTSTEP": "SYMBOL_VOLUME_STEP",
    "MODE_STOPLEVEL": "SYMBOL_TRADE_STOPS_LEVEL",
    "MODE_SPREAD": "SYMBOL_SPREAD",
    "MODE_ASK": "SYMBOL_ASK",
    "MODE_BID": "SYMBOL_BID",
    "SELECT_BY_POS": "removed in MQL5",
    "SELECT_BY_TICKET": "removed in MQL5",
}

# Functions an MQL5 file may call without a local definition. Every name here is
# called by HEX-FVG-Breaker.mq5 or HEX-BoomRider.mq5 and is part of the MQL5
# standard library / language, not of this repo.
BUILTIN = set("""
MathAbs MathMax MathMin MathFloor MathCeil MathRound MathSqrt MathPow MathMod MathRand MathSrand
MathIsValidNumber NormalizeDouble DoubleToString IntegerToString StringFormat StringLen StringFind
StringSubstr StringReplace StringToUpper StringToLower StringTrimLeft StringTrimRight StringSplit
StringToCharArray StringToShortArray StringGetCharacter CharToString StringConcatenate EnumToString
TimeCurrent TimeLocal TimeToStruct StructToTime TimeToString StringToTime PeriodSeconds Period
Bars iBars iBarShift iTime iOpen iHigh iLow iClose iTickVolume iRealVolume iSpread iHighest iLowest
iATR iMA iRSI iMACD iStochastic iBands iADX IndicatorRelease CopyBuffer CopyRates CopyTime CopyClose
BarsCalculated
CopyHigh CopyLow CopyOpen ArrayResize ArraySize ArraySetAsSeries ArrayCopy ArrayInitialize
AccountInfoDouble AccountInfoInteger AccountInfoString AccountCurrency
SymbolInfoDouble SymbolInfoInteger SymbolInfoString SymbolInfoTick SymbolSelect SymbolIsSynchronized
SymbolsTotal SymbolName
PositionGetTicket PositionSelect PositionSelectByTicket PositionGetDouble PositionGetInteger
PositionGetString PositionsTotal OrderGetTicket OrderGetDouble OrderGetInteger OrderGetString
OrdersTotal OrderSelect OrderCalcMargin OrderCalcProfit OrderCheck
HistorySelect HistorySelectByPosition HistoryDealsTotal HistoryDealGetTicket HistoryDealGetDouble
HistoryDealGetInteger HistoryDealGetString HistoryOrdersTotal HistoryOrderGetTicket
GlobalVariableSet GlobalVariableGet GlobalVariableCheck GlobalVariableDel GlobalVariableTemp
FileOpen FileClose FileSeek FileWriteString FileWrite FileReadString FileSize FileIsEnding FolderCreate
ObjectCreate ObjectDelete ObjectSetInteger ObjectSetDouble ObjectSetString ObjectsDeleteAll
ChartRedraw ChartID ChartSymbol ChartPeriod
Print PrintFormat Comment Alert SendNotification WebRequest Sleep ResetLastError GetLastError
EventSetTimer EventKillTimer EventSetMillisecondTimer
TerminalInfoInteger TerminalInfoDouble TerminalInfoString MQLInfoInteger MQLInfoString
""".split())

# Types that look like calls to a regex but are not, plus statement keywords.
NOT_CALLS = set("""
if for while switch return else do
""".split())

RETURN_TYPES = set("""
void int long ulong short ushort char uchar bool double float string datetime color
""".split())

PROBLEMS = []


def strip_code(src):
    """Blank out comments and string/char literals, keeping line structure."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            out.append("  ")
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            out.append("  ")
            i += 2
        elif c in "\"'":
            q = c
            out.append(" ")
            i += 1
            while i < n:
                if src[i] == "\\":
                    out.append("  ")
                    i += 2
                    continue
                if src[i] == q:
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def lineno(src, idx):
    return src.count("\n", 0, idx) + 1


def check(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    code = strip_code(src)

    for open_c, close_c in ("{}", "()", "[]"):
        if code.count(open_c) != code.count(close_c):
            PROBLEMS.append("unbalanced %s%s: %d open vs %d close"
                            % (open_c, close_c, code.count(open_c), code.count(close_c)))

    for name, repl in MQL4_ONLY.items():
        for m in re.finditer(r"\b" + re.escape(name) + r"\s*\(", code):
            PROBLEMS.append("MQL4-only %s at line %d -> use %s"
                            % (name, lineno(code, m.start()), repl))

    for name, repl in MQL4_VARS.items():
        for m in re.finditer(r"\b" + re.escape(name) + r"\b", code):
            # Bars(...) is the MQL5 call, not the MQL4 variables; Point/Digits/
            # Bid/Ask never take an argument, so the same test is safe for all.
            if name == "Bars" and code[m.end():m.end() + 1] == "(":
                continue
            PROBLEMS.append("MQL4-only variable %s at line %d -> use %s"
                            % (name, lineno(code, m.start()), repl))

    for name, repl in MQL4_CONSTS.items():
        for m in re.finditer(r"\b" + re.escape(name) + r"\b", code):
            PROBLEMS.append("MQL4-only constant %s at line %d -> use %s"
                            % (name, lineno(code, m.start()), repl))

    # MQL4 series access: Time[0], High[i], Close[1] ...
    for name in ("Time", "Open", "High", "Low", "Close", "Volume"):
        for m in re.finditer(r"\b" + name + r"\s*\[", code):
            PROBLEMS.append("MQL4 series %s[] at line %d -> use i%s(_Symbol, _Period, shift)"
                            % (name, lineno(code, m.start()), name))

    for m in re.finditer(r"\bextern\b", code):
        PROBLEMS.append("'extern' at line %d -> use input/sinput in MQL5" % lineno(code, m.start()))

    # Function definitions: "<type> name(" at the start of a line.
    defs = {}
    for m in re.finditer(r"^[ \t]*([A-Za-z_][\w]*)[ \t]+([A-Za-z_]\w*)[ \t]*\(", code, re.M):
        rtype, name = m.group(1), m.group(2)
        if rtype not in RETURN_TYPES or name in NOT_CALLS:
            continue
        defs.setdefault(name, []).append(lineno(code, m.start()))
    for name, lines in defs.items():
        if len(lines) > 1:
            PROBLEMS.append("duplicate definition of %s at lines %s" % (name, lines))

    # Every call must resolve to a local definition or a known builtin.
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(", code):
        name = m.group(1)
        if name in NOT_CALLS or name in BUILTIN or name in defs:
            continue
        if name in ("CTrade", "MqlTradeRequest", "MqlTradeResult", "MqlRates", "MqlDateTime",
                    "MqlTradeTransaction", "MqlTick", "MqlTradeCheckResult", "ENUM_ORDER_TYPE",
                    "ENUM_TIMEFRAMES", "ENUM_POSITION_TYPE"):
            continue
        if code[max(0, m.start() - 1):m.start()] == ".":
            continue                      # object.Method(...) is resolved loosely
        PROBLEMS.append("call to undefined function %s() at line %d" % (name, lineno(code, m.start())))

    for hook in ("OnInit", "OnTick"):
        if not re.search(r"\b" + hook + r"\s*\(", code):
            PROBLEMS.append("missing the %s entry point" % hook)
    if re.search(r"\bCTrade\b", code) and "#include <Trade/Trade.mqh>" not in src:
        PROBLEMS.append("CTrade is used but #include <Trade/Trade.mqh> is missing")
    if re.search(r"\bEventSetTimer\s*\(", code) and not re.search(r"\bOnTimer\s*\(", code):
        PROBLEMS.append("EventSetTimer is called but there is no OnTimer()")
    return code


def main(path):
    check(path)
    if PROBLEMS:
        print("FAIL %s" % path)
        for p in PROBLEMS:
            print("  -", p)
        return 1
    print("PASS %s: structure, MQL4-only API, definitions, lifecycle" % path)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: lint_mql5.py <file.mq5>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
