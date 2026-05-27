#!/usr/bin/env python3
"""Render an XLS IR function as a Graphviz computation graph.

XLS doesn't ship a graph exporter in the `xls-bin/bin/` release (the IR
visualizers under external/xls/xls/visualization/ are source-only and would
need a Bazel build). But the textual IR *is* the dataflow graph — every node
lists its operands — so this turns any `.ir`/`.opt.ir` into Graphviz DOT and,
unless you ask for `--format dot`, renders it with `dot`.

Parsing and DOT emission are stdlib-only. Rendering shells out to the `dot`
binary; `graphviz` is in environment.yml so the env provides it (run via
`mamba run -n ppa-study ...`). With `--format dot` the tool needs nothing but
Python and prints/writes the DOT text, so it works from a bare nix-shell.

Nodes are coloured by operation class (comparator / arithmetic / mux / array /
bit-op / literal / param / output) and edges run operand -> consumer, so a
single-stage "parallel" binner reads top-down as: global_index fanning out to
N comparators, whose results a popcount collapses into bin_index. The tool also
prints a fanout (out-degree) report, which is the quick way to spot the
high-fanout broadcast nets (e.g. global_index, lower_bin_boundaries).

Usage:
    flows/ir_to_dot.py INPUT.ir [-o OUT] [--format svg|png|pdf|dot]
                       [--fn NAME] [--rankdir TB|LR]

Default output is INPUT with the extension swapped for the chosen format
(e.g. runs/.../binner.opt.ir -> runs/.../binner.opt.svg).
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

# A function header: optional "top", the name, "(params)", "-> ret", "{".
FN_RE = re.compile(r"^\s*(top\s+)?fn\s+([^\s(]+)\s*\((.*)\)\s*->\s*(.+?)\s*\{\s*$")
# A body node:  [ret] name : type = op(args)
NODE_RE = re.compile(r"^\s*(ret\s+)?([A-Za-z_][\w.]*)\s*:\s*(.+?)\s*=\s*([a-z_]+)\((.*)\)\s*$")
# A param inside the header:  name: type id=N
PARAM_RE = re.compile(r"([A-Za-z_]\w*)\s*:\s*(.+?)\s+id=\d+")
# Any identifier token (node/param names; literals/keywords filtered by membership).
TOKEN_RE = re.compile(r"[A-Za-z_][\w.]*")

# Operation -> (category, fillcolor). Categories drive the colour legend.
OP_CATEGORY = {
    "uge": "cmp", "ugt": "cmp", "ule": "cmp", "ult": "cmp",
    "sge": "cmp", "sgt": "cmp", "sle": "cmp", "slt": "cmp",
    "eq": "cmp", "ne": "cmp",
    "add": "arith", "sub": "arith", "umul": "arith", "smul": "arith",
    "udiv": "arith", "sdiv": "arith", "umod": "arith", "smod": "arith",
    "neg": "arith", "shll": "arith", "shrl": "arith", "shra": "arith",
    "sel": "mux", "priority_sel": "mux", "one_hot_sel": "mux", "one_hot": "mux",
    "array_index": "array", "array_update": "array", "array": "array",
    "array_slice": "array", "tuple_index": "array",
    "concat": "bit", "bit_slice": "bit", "bit_slice_update": "bit",
    "zero_ext": "bit", "sign_ext": "bit", "reverse": "bit", "decode": "bit",
    "encode": "bit", "and": "bit", "or": "bit", "xor": "bit", "not": "bit",
    "and_reduce": "bit", "or_reduce": "bit", "xor_reduce": "bit",
    "literal": "literal",
    "tuple": "output",
}
CATEGORY_COLOR = {
    "param":   "#bfdbfe",  # inputs
    "literal": "#e5e7eb",  # constants
    "cmp":     "#fca5a5",  # comparators
    "arith":   "#fde68a",  # adders/subtractors/shifts
    "mux":     "#bbf7d0",  # selects
    "array":   "#a5f3fc",  # array reads/writes
    "bit":     "#ffffff",  # concat / slices / bitwise
    "output":  "#e9d5ff",  # tuple / result
}


def split_top_level(s, sep=","):
    """Split on `sep`, ignoring separators inside (), [], <>, {}."""
    parts, depth, cur = [], 0, []
    pairs = {")": "(", "]": "[", ">": "<", "}": "{"}
    openers = set(pairs.values())
    for ch in s:
        if ch in openers:
            depth += 1
        elif ch in pairs and depth:
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


def parse_functions(text):
    """Return {fn_name: dict(params, nodes, edges, ret, is_top)} from IR text."""
    fns, cur = {}, None
    for line in text.splitlines():
        m = FN_RE.match(line)
        if m:
            is_top, name, params, _ret = m.groups()
            nodes = {}  # name -> dict(op, type, kind, ret)
            for p in split_top_level(params):
                pm = PARAM_RE.match(p)
                if pm:
                    nodes[pm.group(1)] = {"op": "param", "type": pm.group(2),
                                          "kind": "param", "ret": False}
            cur = {"params": list(nodes), "nodes": nodes, "edges": set(),
                   "ret": None, "is_top": bool(is_top)}
            fns[name] = cur
            continue
        if cur is None:
            continue
        if line.strip() == "}":
            cur = None
            continue
        nm = NODE_RE.match(line)
        if nm:
            is_ret, name, typ, op, _args = nm.groups()
            cur["nodes"][name] = {"op": op, "type": typ,
                                  "kind": OP_CATEGORY.get(op, "bit"),
                                  "ret": bool(is_ret)}
            if is_ret:
                cur["ret"] = name

    # Second pass: edges (operand -> consumer) for every body node's args.
    for fn in fns.values():
        known = set(fn["nodes"])
        for line in text.splitlines():
            nm = NODE_RE.match(line)
            if not nm:
                continue
            name = nm.group(2)
            if name not in fn["nodes"]:
                continue
            args = nm.group(5)
            for tok in TOKEN_RE.findall(args):
                if tok in known and tok != name:
                    fn["edges"].add((tok, name))
    return fns


def pick_function(fns, requested):
    if requested:
        if requested not in fns:
            sys.exit(f"ir_to_dot: no function named {requested!r}; have: "
                     f"{', '.join(fns) or '(none)'}")
        return requested, fns[requested]
    tops = [n for n, f in fns.items() if f["is_top"]]
    if tops:
        return tops[0], fns[tops[0]]
    if len(fns) == 1:
        n = next(iter(fns))
        return n, fns[n]
    sys.exit(f"ir_to_dot: multiple functions and no `top`; pick one with --fn "
             f"(have: {', '.join(fns)})")


def dot_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def build_dot(fn_name, fn, src, rankdir):
    lines = [f'digraph "{dot_escape(fn_name)}" {{',
             f"  rankdir={rankdir};",
             f'  labelloc="t"; label="{dot_escape(src)}  —  fn {dot_escape(fn_name)}";',
             '  node [style="filled", shape=box, fontname="monospace", fontsize=10];',
             '  edge [color="#6b7280", arrowsize=0.7];']
    for name, info in fn["nodes"].items():
        kind = info["kind"]
        color = CATEGORY_COLOR.get(kind, "#ffffff")
        if kind == "param":
            label = f"{name}\\n{info['type']}"
            shape = "invhouse"
        elif info["op"] == "param":
            label, shape = name, "box"
        else:
            # name already encodes op for "uge.81"-style names; show op·type once.
            label = f"{name}\\n{info['op']} · {info['type']}"
            shape = "house" if kind == "output" else "box"
        extra = ' peripheries=2' if info.get("ret") else ""
        lines.append(f'  "{dot_escape(name)}" '
                     f'[label="{label}", shape={shape}, fillcolor="{color}"{extra}];')
    for src_n, dst_n in sorted(fn["edges"]):
        lines.append(f'  "{dot_escape(src_n)}" -> "{dot_escape(dst_n)}";')
    lines.append("}")
    return "\n".join(lines) + "\n"


def fanout_report(fn, top_n=6):
    out_deg = {}
    for src_n, _dst in fn["edges"]:
        out_deg[src_n] = out_deg.get(src_n, 0) + 1
    ranked = sorted(out_deg.items(), key=lambda kv: (-kv[1], kv[0]))
    inputs = {n for n in fn["params"]}
    lines = [f"  nodes={len(fn['nodes'])}  edges={len(fn['edges'])}",
             "  highest-fanout nets (out-degree):"]
    for name, deg in ranked[:top_n]:
        tag = " [input]" if name in inputs else ""
        lines.append(f"    {deg:>3}  {name}{tag}")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Render an XLS IR function as a Graphviz graph.")
    ap.add_argument("input", help="XLS IR file (.ir / .opt.ir)")
    ap.add_argument("-o", "--out", help="output path (default: input with format extension)")
    ap.add_argument("--format", default="svg", choices=["svg", "png", "pdf", "dot"],
                    help="output format (default: svg; 'dot' writes the DOT text, no render)")
    ap.add_argument("--fn", help="function to render (default: the `top` fn)")
    ap.add_argument("--rankdir", default="TB", choices=["TB", "LR"],
                    help="graph direction (default: TB, inputs at top)")
    args = ap.parse_args(argv)

    src = Path(args.input)
    if not src.exists():
        sys.exit(f"ir_to_dot: no such file: {src}")
    fns = parse_functions(src.read_text())
    if not fns:
        sys.exit(f"ir_to_dot: no functions parsed from {src} — is it XLS IR?")
    fn_name, fn = pick_function(fns, args.fn)
    dot_text = build_dot(fn_name, fn, src.name, args.rankdir)

    out = Path(args.out) if args.out else src.with_suffix(f".{args.format}")
    if args.format == "dot":
        out.write_text(dot_text)
        print(f"[dot] {out}")
    else:
        dot_bin = shutil.which("dot")
        if not dot_bin:
            sys.exit("ir_to_dot: `dot` not found — run via the env that provides it,\n"
                     "  e.g. `mamba run -n ppa-study flows/ir_to_dot.py ...`,\n"
                     "  or use --format dot to emit DOT text without rendering.")
        subprocess.run([dot_bin, f"-T{args.format}", "-o", str(out)],
                       input=dot_text.encode(), check=True)
        print(f"[{args.format}] {out}  (via {dot_bin})")

    print(fanout_report(fn))
    return 0


if __name__ == "__main__":
    sys.exit(main())
