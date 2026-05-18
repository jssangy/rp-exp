#!/usr/bin/env python3
"""Summarize and plot Experiment 1 network/drop results.

Outputs:
  results/exp1/analysis/exp1_runs.csv
  results/exp1/analysis/exp1_summary.csv
  results/exp1/analysis/figures/*.png
"""

from __future__ import annotations

import argparse
import csv
import math
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean, stdev

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


SCENARIOS = ["S1", "S2", "S3a", "S3b", "S3c", "S4a", "S4b", "S5a", "S5b"]
CONDITIONS = ["baseline", "rp_hz", "topic_hz", "rp_bag", "rosbag2"]
DELTA_CONDITIONS = ["rp_hz", "topic_hz", "rp_bag", "rosbag2"]
CONDITION_LABELS = {
    "baseline": "Baseline",
    "rp_hz": "rp topic hz",
    "topic_hz": "ros2 topic hz",
    "rp_bag": "rp bag",
    "rosbag2": "ros2 bag",
}

# Payload sizes used only to compute traffic-weighted drop for composite S5 runs.
# They match the workload descriptions in experiment1.md.
S5_PAYLOAD_BYTES = {
    "S5a": {
        "s1_sub": 72,
        "s2_sub": 320,
        "s3a_sub": 4_300,
        "s4a_sub": 150 * 1024,
    },
    "S5b": {
        "s1_sub": 72,
        "s2_sub": 320,
        "s3_points_sub-3": 2_720_000,
        "s3_points_sub-4": 644_000,
        "s4a_sub-5": 150 * 1024,
        "s4a_sub-6": 150 * 1024,
        "s4a_sub-7": 150 * 1024,
        "s4a_sub-8": 150 * 1024,
        "s4_image_sub": 600 * 1024,
    },
}
COLORS = {
    "baseline": "#6b7280",
    "rp_hz": "#1f77b4",
    "topic_hz": "#ff7f0e",
    "rp_bag": "#17becf",
    "rosbag2": "#d62728",
}


FINAL_RE = re.compile(r"FINAL \[60s\]: recv (\d+) / expected (\d+) -> drop ([0-9.]+)%")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def parse_netdev(path: Path) -> tuple[int, float | None, float | None, int | None]:
    samples: list[tuple[int, int]] = []
    if not path.exists():
        return 0, None, None, None
    for line in path.read_text(errors="ignore").splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            samples.append((int(parts[0]), int(parts[1])))
        except ValueError:
            continue
    if len(samples) < 2:
        return len(samples), None, None, None
    duration_s = (samples[-1][0] - samples[0][0]) / 1000.0
    delta_bytes = samples[-1][1] - samples[0][1]
    if duration_s <= 0 or delta_bytes < 0:
        return len(samples), None, duration_s, delta_bytes
    return len(samples), delta_bytes * 8.0 / duration_s / 1e6, duration_s, delta_bytes


def final_label(line: str) -> str:
    prefix = line.split("FINAL", 1)[0].strip()
    prefix = ANSI_RE.sub("", prefix)
    prefix = prefix.strip("[] ")
    return prefix or "single"


def payload_for_final(scenario: str, label: str) -> int | None:
    payloads = S5_PAYLOAD_BYTES.get(scenario)
    if not payloads:
        return None
    for prefix, payload_bytes in payloads.items():
        if label.startswith(prefix):
            return payload_bytes
    return None


def weighted_drop_pct(scenario: str, finals: list[dict[str, object]]) -> float | None:
    if scenario not in S5_PAYLOAD_BYTES:
        return None
    lost_weighted = 0.0
    total_weighted = 0.0
    for final in finals:
        payload = payload_for_final(scenario, str(final["label"]))
        if payload is None:
            continue
        expected = int(final["expected"])
        recv = int(final["recv"])
        lost_weighted += max(expected - recv, 0) * payload
        total_weighted += expected * payload
    if total_weighted <= 0:
        return None
    return lost_weighted / total_weighted * 100.0


def parse_sub_log(path: Path, scenario: str) -> dict[str, object]:
    finals: list[dict[str, object]] = []
    if path.exists():
        for raw_line in path.read_text(errors="ignore").splitlines():
            line = ANSI_RE.sub("", raw_line)
            match = FINAL_RE.search(line)
            if not match:
                continue
            finals.append(
                {
                    "label": final_label(line),
                    "recv": int(match.group(1)),
                    "expected": int(match.group(2)),
                    "drop_pct": float(match.group(3)),
                }
            )
    if not finals:
        return {
            "recv": None,
            "expected": None,
            "drop_pct": None,
            "plot_drop_pct": None,
            "weighted_drop_pct": None,
            "drop_label": "",
            "final_count": 0,
            "max_drop_pct": None,
        }

    selected = finals[0]
    if scenario == "S5a":
        selected = next((f for f in finals if str(f["label"]).startswith("s4a_sub")), finals[-1])
    elif scenario == "S5b":
        selected = next((f for f in finals if str(f["label"]).startswith("s3_points_sub-3")), finals[0])

    return {
        "recv": selected["recv"],
        "expected": selected["expected"],
        "drop_pct": selected["drop_pct"],
        "plot_drop_pct": weighted_drop_pct(scenario, finals) if scenario in S5_PAYLOAD_BYTES else selected["drop_pct"],
        "weighted_drop_pct": weighted_drop_pct(scenario, finals),
        "drop_label": selected["label"],
        "final_count": len(finals),
        "max_drop_pct": max(float(f["drop_pct"]) for f in finals),
    }


def parse_cpu_mem(path: Path) -> dict[str, float | int | None]:
    cpu: list[float] = []
    mem: list[int] = []
    if path.exists():
        for line in path.read_text(errors="ignore").splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            try:
                cpu.append(float(parts[1]))
                mem.append(int(parts[2]))
            except ValueError:
                continue
    if not cpu:
        return {
            "cpu_mem_samples": 0,
            "cpu_avg": None,
            "cpu_max": None,
            "mem_avg_kb": None,
            "mem_max_kb": None,
        }
    return {
        "cpu_mem_samples": len(cpu),
        "cpu_avg": mean(cpu),
        "cpu_max": max(cpu),
        "mem_avg_kb": mean(mem),
        "mem_max_kb": max(mem),
    }


def classify(row: dict[str, object]) -> str:
    if row["drop_pct"] is None:
        return "invalid_missing_final"
    if int(row["netdev_samples"]) < 50 or row["rx_mbps"] is None:
        return "invalid_missing_netdev"
    return "valid"


def collect_runs(results_dir: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for scenario in SCENARIOS:
        scenario_dir = results_dir / scenario
        if not scenario_dir.exists():
            continue
        for condition in CONDITIONS:
            condition_dir = scenario_dir / condition
            if not condition_dir.exists():
                continue
            for run_dir in sorted(condition_dir.glob("run*")):
                if not run_dir.is_dir():
                    continue
                netdev_samples, rx_mbps, netdev_duration_s, rx_delta_bytes = parse_netdev(
                    run_dir / "netdev.log"
                )
                sub = parse_sub_log(run_dir / "sub.log", scenario)
                cpu_mem = parse_cpu_mem(run_dir / "cpu_mem.log")
                row: dict[str, object] = {
                    "scenario": scenario,
                    "condition": condition,
                    "run": run_dir.name,
                    "path": str(run_dir),
                    "recv": sub["recv"],
                    "expected": sub["expected"],
                    "drop_pct": sub["drop_pct"],
                    "plot_drop_pct": sub["plot_drop_pct"],
                    "weighted_drop_pct": sub["weighted_drop_pct"],
                    "drop_label": sub["drop_label"],
                    "final_count": sub["final_count"],
                    "max_drop_pct": sub["max_drop_pct"],
                    "netdev_samples": netdev_samples,
                    "netdev_duration_s": netdev_duration_s,
                    "rx_delta_bytes": rx_delta_bytes,
                    "rx_mbps": rx_mbps,
                    **cpu_mem,
                }
                row["validity"] = classify(row)
                rows.append(row)
    add_delta_rx(rows)
    return rows


def add_delta_rx(rows: list[dict[str, object]]) -> None:
    baseline: dict[tuple[str, str], float] = {}
    by_scenario_run: dict[tuple[str, str], list[float]] = defaultdict(list)
    for row in rows:
        if row["condition"] == "baseline" and row["rx_mbps"] is not None:
            by_scenario_run[(str(row["scenario"]), str(row["run"]))].append(float(row["rx_mbps"]))
    for key, values in by_scenario_run.items():
        baseline[key] = mean(values)

    baseline_mean: dict[str, float] = {}
    for scenario in SCENARIOS:
        values = [
            float(row["rx_mbps"])
            for row in rows
            if row["scenario"] == scenario and row["condition"] == "baseline" and row["rx_mbps"] is not None
        ]
        if values:
            baseline_mean[scenario] = mean(values)

    for row in rows:
        rx = row["rx_mbps"]
        if rx is None:
            row["delta_rx_mbps"] = None
            continue
        same_run = baseline.get((str(row["scenario"]), str(row["run"])))
        base = same_run if same_run is not None else baseline_mean.get(str(row["scenario"]))
        row["delta_rx_mbps"] = float(rx) - base if base is not None else None


def csv_value(value: object) -> object:
    if value is None:
        return ""
    if isinstance(value, float):
        return f"{value:.6f}"
    return value


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(rows[0].keys())
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: csv_value(row.get(key)) for key in fieldnames})


def summarize(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    grouped: dict[tuple[str, str], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        grouped[(str(row["scenario"]), str(row["condition"]))].append(row)

    metrics = ["rx_mbps", "delta_rx_mbps", "drop_pct", "plot_drop_pct", "weighted_drop_pct", "max_drop_pct"]
    out_rows: list[dict[str, object]] = []
    for scenario, condition in sorted(grouped):
        group = grouped[(scenario, condition)]
        out: dict[str, object] = {
            "scenario": scenario,
            "condition": condition,
            "n_runs": len(group),
            "validity_values": ";".join(sorted({str(row["validity"]) for row in group})),
        }
        for metric in metrics:
            values = [float(row[metric]) for row in group if row.get(metric) is not None]
            out[f"{metric}_mean"] = mean(values) if values else None
            out[f"{metric}_std"] = stdev(values) if len(values) > 1 else 0.0 if values else None
            out[f"{metric}_min"] = min(values) if values else None
            out[f"{metric}_max"] = max(values) if values else None
        out_rows.append(out)
    return out_rows


def metric_values(rows: list[dict[str, object]], scenario: str, condition: str, metric: str) -> list[float]:
    return [
        float(row[metric])
        for row in rows
        if row["scenario"] == scenario and row["condition"] == condition and row.get(metric) is not None
    ]


def plot_scenario(
    rows: list[dict[str, object]],
    figures_dir: Path,
    filename: str,
    title: str,
    ylabel: str,
    metric: str,
    scenario: str,
    conditions: list[str],
    zero_line: bool = False,
) -> None:
    fig, ax = plt.subplots(figsize=(7.2, 4.2))
    x_positions = list(range(len(conditions)))
    means: list[float] = []
    errors: list[float] = []
    colors: list[str] = []

    for condition in conditions:
        values = metric_values(rows, scenario, condition, metric)
        means.append(mean(values) if values else math.nan)
        errors.append(stdev(values) if len(values) > 1 else 0.0)
        colors.append(COLORS[condition])

    ax.bar(
        x_positions,
        means,
        width=0.64,
        yerr=errors,
        capsize=3,
        color=colors,
        edgecolor="#111827",
        linewidth=0.5,
        alpha=0.92,
    )

    if zero_line:
        ax.axhline(0, color="#111827", linewidth=1.1)
    ax.set_xticks(x_positions)
    ax.set_xticklabels([CONDITION_LABELS[c] for c in conditions], rotation=20, ha="right")
    ax.set_ylabel(ylabel)
    ax.grid(axis="y", color="#d1d5db", linewidth=0.8, alpha=0.8)
    ax.set_axisbelow(True)
    fig.suptitle(title, y=0.98, fontsize=13)
    fig.subplots_adjust(left=0.12, right=0.98, bottom=0.23, top=0.86)
    figures_dir.mkdir(parents=True, exist_ok=True)
    fig.savefig(figures_dir / f"{filename}.png", dpi=220, bbox_inches="tight")
    plt.close(fig)


def make_figures(rows: list[dict[str, object]], figures_dir: Path) -> None:
    for scenario in SCENARIOS:
        plot_scenario(
            rows,
            figures_dir,
            f"rx_mbps_{scenario}",
            f"Experiment 1 RX Mbps ({scenario})",
            "RX Mbps",
            "rx_mbps",
            scenario,
            CONDITIONS,
        )
        plot_scenario(
            rows,
            figures_dir,
            f"drop_rate_{scenario}",
            f"Experiment 1 Drop Rate ({scenario})",
            "Drop rate (%)",
            "plot_drop_pct",
            scenario,
            CONDITIONS,
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", default="results/exp1", type=Path)
    parser.add_argument("--out-dir", default=None, type=Path)
    args = parser.parse_args()

    out_dir = args.out_dir or args.results_dir / "analysis"
    rows = collect_runs(args.results_dir)
    if not rows:
        raise SystemExit(f"No Experiment 1 runs found under {args.results_dir}")
    write_csv(out_dir / "exp1_runs.csv", rows)
    write_csv(out_dir / "exp1_summary.csv", summarize(rows))
    make_figures(rows, out_dir / "figures")
    print(f"Wrote {len(rows)} run rows to {out_dir / 'exp1_runs.csv'}")
    print(f"Wrote summary to {out_dir / 'exp1_summary.csv'}")
    print(f"Wrote figures to {out_dir / 'figures'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
