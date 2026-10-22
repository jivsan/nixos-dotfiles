#!/usr/bin/env python3
# homarr sqlite -> postgres, row by row (written 2026-10-22 for homarr v2.7.0)
#
# homarr has no converter of its own. so: let homarr build its empty postgres tables first
# (its migrate.cjs), then this turns every row of the old db.sqlite into one psql script
# that empties those tables and fills them with COPY, all in one transaction.
#
#   homarr-sqlite-to-pg.py <db.sqlite> <columns.tsv> > load.sql
#
# columns.tsv is the target's column list, from:
#   psql -AtF$'\t' -c "select table_name, column_name, data_type, coalesce(character_maximum_length,0)
#     from information_schema.columns where table_schema='public' order by table_name, ordinal_position"
#
# load.sql needs a superuser (it turns foreign keys off while loading, user <-> board point at
# each other), so I load it into a throwaway postgres and move the result on with
# pg_dump + pg_restore: the restore adds the foreign keys back and checks every row.
#
# load.sql holds the secrets from the db (encrypted integration secrets, password hash):
# keep it 0600 and delete it after. this script only prints counts, never values.
import sqlite3, sys
from datetime import datetime, timezone

src, cols_file = sys.argv[1], sys.argv[2]
db = sqlite3.connect(f"file:{src}?mode=ro", uri=True)

# target columns per table, in order
pg = {}
for line in open(cols_file):
    t, c, typ, maxlen = line.rstrip("\n").split("\t")
    pg.setdefault(t, []).append((c, typ, int(maxlen)))

skip = {"__drizzle_migrations", "sqlite_sequence"}   # postgres keeps its own migration list
lite = [r[0] for r in db.execute("select name from sqlite_master where type='table' order by name") if r[0] not in skip]
if set(lite) != set(pg):
    sys.exit(f"tables differ: only in sqlite {sorted(set(lite) - set(pg))}, only in postgres {sorted(set(pg) - set(lite))}")
for t in lite:
    lc = {r[1] for r in db.execute(f'pragma table_info("{t}")')}
    pc = {c for c, _, _ in pg[t]}
    if lc != pc:
        sys.exit(f"{t}: columns differ: only in sqlite {sorted(lc - pc)}, only in postgres {sorted(pc - lc)}")

def esc(s):
    if "\x00" in s:
        raise ValueError("NUL byte")
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")

def conv(v, typ, maxlen):
    if v is None:
        return "\\N"
    if typ == "boolean":
        if v not in (0, 1):
            raise ValueError(f"not 0/1: {type(v).__name__}")
        return "t" if v else "f"
    if typ.startswith("timestamp"):
        # drizzle's sqlite side keeps seconds (mode timestamp) or milliseconds (timestamp_ms);
        # its postgres side keeps utc wall time in "timestamp without time zone"
        if not isinstance(v, int):
            raise ValueError(f"time is {type(v).__name__}")
        sec = v / 1000 if v > 100_000_000_000 else v
        d = datetime.fromtimestamp(sec, tz=timezone.utc)
        if not 2000 <= d.year <= 2100:
            raise ValueError(f"time out of range ({d.year})")
        return d.strftime("%Y-%m-%d %H:%M:%S.%f")
    if typ in ("integer", "smallint", "bigint"):
        if not isinstance(v, int):
            raise ValueError(f"integer is {type(v).__name__}")
        return str(v)
    if typ == "bytea":
        return "\\\\x" + bytes(v).hex()
    if typ in ("text", "character varying"):
        if not isinstance(v, str):
            raise ValueError(f"text is {type(v).__name__}")
        if maxlen and len(v) > maxlen:
            raise ValueError(f"longer than {maxlen}")
        return esc(v)
    raise ValueError(f"no rule for type {typ}")

out = sys.stdout
out.write("\\set ON_ERROR_STOP on\nBEGIN;\nSET session_replication_role = replica;\n")
out.write("TRUNCATE " + ", ".join(f'public."{t}"' for t in sorted(pg)) + ";\n")
total = 0
for t in lite:
    names = [c for c, _, _ in pg[t]]
    types = {c: (typ, m) for c, typ, m in pg[t]}
    out.write(f'COPY public."{t}" (' + ", ".join(f'"{c}"' for c in names) + ") FROM stdin;\n")
    n = 0
    sel = ", ".join(f'"{c}"' for c in names)
    for row in db.execute(f'select {sel} from "{t}"'):
        fields = []
        for c, v in zip(names, row):
            try:
                fields.append(conv(v, *types[c]))
            except ValueError as e:
                sys.exit(f"{t} row {n + 1}, column {c}: {e}")
        out.write("\t".join(fields) + "\n")
        n += 1
    out.write("\\.\n")
    print(f"{t}\t{n}", file=sys.stderr)
    total += n
out.write("SET session_replication_role = DEFAULT;\nCOMMIT;\n")
print(f"TOTAL\t{total}", file=sys.stderr)
