#!/usr/bin/env python3
"""Cross-session leaderboard from dcs.log files.

The mission logs one line per scored task:
    ... [CIVIL] SCORE|player|taskType|points|q=0.80|t=0.50
and final standings at mission end:
    ... [CIVIL] FINAL|player|points|tasks

This script aggregates the SCORE lines from any number of dcs.log files
(pass several to build a historical leaderboard across sessions) and
prints a ranking with a per-task-type breakdown. No dependencies.

Usage:
    python3 tools/leaderboard.py path/to/dcs.log [more.log ...]
    python3 tools/leaderboard.py --csv out.csv logs/*.log
"""

import argparse
import collections
import csv
import re
import sys

SCORE_RE = re.compile(r"SCORE\|([^|]+)\|([^|]+)\|(-?\d+)\|")


def parse(paths):
    players = collections.defaultdict(lambda: {
        "points": 0, "tasks": 0, "types": collections.Counter()})
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    match = SCORE_RE.search(line)
                    if not match:
                        continue
                    name, task_type, points = match.groups()
                    row = players[name]
                    row["points"] += int(points)
                    row["tasks"] += 1
                    row["types"][task_type] += int(points)
        except OSError as err:
            print(f"warning: cannot read {path}: {err}", file=sys.stderr)
    return players


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("logs", nargs="+", help="dcs.log files to aggregate")
    parser.add_argument("--csv", metavar="FILE", help="also write a CSV file")
    args = parser.parse_args()

    players = parse(args.logs)
    if not players:
        print("no SCORE lines found in the given logs")
        return 1

    ranking = sorted(players.items(), key=lambda kv: kv[1]["points"], reverse=True)

    name_width = max(len(name) for name, _ in ranking)
    print(f"{'#':>3} {'player':<{name_width}} {'points':>7} {'tasks':>6}  best types")
    for rank, (name, row) in enumerate(ranking, start=1):
        best = ", ".join(f"{t} {p}" for t, p in row["types"].most_common(3))
        print(f"{rank:>3} {name:<{name_width}} {row['points']:>7} {row['tasks']:>6}  {best}")

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(["rank", "player", "points", "tasks"])
            for rank, (name, row) in enumerate(ranking, start=1):
                writer.writerow([rank, name, row["points"], row["tasks"]])
        print(f"\nwrote {args.csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
