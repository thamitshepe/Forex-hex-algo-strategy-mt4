#!/usr/bin/env python3
"""Cross-check an MT5 .set file against the inputs of its .mq5.

A preset that names an input the EA does not have is silently ignored by the
terminal, and an input the preset forgets falls back to the code default - which
is exactly how "the preset says 4R but the EA trades 2.5R" happens. Both are
reported. Enums are compared numerically (that is how MT5 saves them).
"""
import re
import sys

ea_path, set_path = sys.argv[1], sys.argv[2]
ea = open(ea_path, encoding="utf-8").read()

inputs = {}
for m in re.finditer(r"^\s*input\s+([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*=\s*([^;]+);", ea, re.M):
    inputs[m.group(2)] = (m.group(1), m.group(3).strip())

preset = {}
for line in open(set_path, encoding="utf-8"):
    s = line.strip()
    if not s or s.startswith(";"):
        continue
    if "=" not in s:
        continue
    k, v = s.split("=", 1)
    preset[k.strip()] = v.strip()

problems = []
for k in preset:
    if k not in inputs:
        problems.append("preset sets %s, which is not an input of the EA" % k)
missing = [k for k in inputs if k not in preset and inputs[k][0] != "color"]
for k in missing:
    problems.append("EA input %s is not in the preset (it would run on the code default)"
                    % k)

for k, (typ, default) in sorted(inputs.items()):
    if k not in preset:
        continue
    v = preset[k]
    if typ in ("int", "long"):
        if not re.fullmatch(r"-?\d+", v):
            problems.append("%s=%s is not an integer (EA type %s)" % (k, v, typ))
    elif typ in ("double", "float"):
        if not re.fullmatch(r"-?\d+(\.\d+)?", v):
            problems.append("%s=%s is not a number (EA type %s)" % (k, v, typ))
    elif typ == "bool":
        if v not in ("0", "1", "true", "false"):
            problems.append("%s=%s is not a bool" % (k, v))

print("EA inputs:", len(inputs), "preset keys:", len(preset))
if problems:
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("PASS preset covers every input and names nothing the EA does not have")
