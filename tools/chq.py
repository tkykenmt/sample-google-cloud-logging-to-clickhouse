#!/usr/bin/env python3
"""Run a .sql file (or -q SQL) against a ClickHouse Cloud service, one statement at a time,
through `clickhousectl cloud service query`. Statements are split on lines ending with ';'
(optionally followed by a -- comment).

Usage: chq.py --service <id> file.sql [file2.sql ...]   |   chq.py --service <id> -q "SELECT 1"
Variables: --var NAME=VALUE replaces {{NAME}} in the SQL text.
"""
import argparse, os, re, subprocess, sys

END = re.compile(r";\s*(--.*)?$")  # ';' at the end of a line, before an optional trailing comment

def statements(text):
    buf = []
    for line in text.splitlines():
        m = END.search(line)
        if m:
            line = line[:m.start() + 1]
        buf.append(line)
        if m:
            lines = list(buf)
            while lines and (not lines[0].strip() or lines[0].strip().startswith("--")):
                lines.pop(0)  # leading comments would be parsed as CLI flags
            stmt = "\n".join(lines).strip().rstrip(";").strip()
            buf = []
            if stmt:
                yield stmt
    rest = "\n".join(buf).strip()
    if rest and not all(l.strip().startswith("--") for l in rest.splitlines()):
        yield rest

def run(service, sql, fmt):
    has_format = re.search(r"\bFORMAT\s+\w+\s*$", sql, re.IGNORECASE)
    q = sql if (has_format or not sql.lstrip().upper().startswith(("SELECT", "WITH", "SHOW", "EXPLAIN", "DESCRIBE"))) else f"{sql}\nFORMAT {fmt}"
    # Runs in the current directory: clickhousectl prefers ./.clickhouse/credentials.json over the
    # CLICKHOUSE_CLOUD_API_KEY/SECRET environment variables, so run from a directory without other credentials.
    r = subprocess.run(["clickhousectl", "cloud", "service", "query", "--id", service, "-q", q],
                       capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    return r.returncode, out

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--service", default=os.environ.get("CH_SERVICE_ID"))
    p.add_argument("-q")
    p.add_argument("--format", default="TSVWithNames")
    p.add_argument("--var", action="append", default=[])
    p.add_argument("--keep-going", action="store_true")
    p.add_argument("files", nargs="*")
    a = p.parse_args()
    if not a.service:
        sys.exit("--service or CH_SERVICE_ID is required")
    texts = [a.q] if a.q else [open(f).read() for f in a.files]
    vars_ = dict(v.split("=", 1) for v in a.var)
    for text in texts:
        for k, v in vars_.items():
            text = text.replace("{{" + k + "}}", v)
        for stmt in statements(text):
            head = " ".join(stmt.split())[:90]
            code, out = run(a.service, stmt, a.format)
            print(f"-- {head}" + ("" if code == 0 else "  [ERROR]"))
            if out:
                print(out)
            if code != 0 and not a.keep_going:
                sys.exit(code)

if __name__ == "__main__":
    main()
