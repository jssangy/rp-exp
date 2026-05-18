#!/usr/bin/env python3
"""Summarize and plot Experiment 3 results.

Outputs:
  results/exp3/analysis/exp3_runs.csv
  results/exp3/analysis/exp3_summary.csv
  results/exp3/analysis/figures/*.png
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


SCENARIOS = ["ST100", "ST500", "ST1000"]
CONDITIONS = ["baseline", "rp_hz", "topic_hz"]
OBSERVER_CONDITIONS = ["rp_hz", "topic_hz"]
PLATFORM_ORDER = ["pc", "rpi", "jetson"]
CONDITION_LABELS = {
    "baseline": "Baseline",
    "rp_hz": "rp topic hz",
    "topic_hz": "ros2 topic hz",
}
COLORS = {
    "baseline": "#6b7280",
    "rp_hz": "#1f77b4",
    "topic_hz": "#d62728",
}


def parse_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(errors="ignore").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def parse_sub_log(path: Path) -> tuple[int | None, int | None, float | None]:
    if not path.exists():
        return None, None, None
    text = path.read_text(errors="ignore")
    match = re.search(
        r"FINAL \[60s\]: recv (\d+) / expected (\d+) -> drop ([0-9.]+)%",
        text,
    )
    if not match:
        return None, None, None
    return int(match.group(1)), int(match.group(2)), float(match.group(3))


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
    rx_mbps = delta_bytes * 8.0 / duration_s / 1e6
    return len(samples), rx_mbps, duration_s, delta_bytes


def parse_observer_log(path: Path) -> dict[str, float | int | None]:
    cpu: list[float] = []
    mem: list[int] = []
    if path.exists():
        for line in path.read_text(errors="ignore").splitlines():
            if line.startswith("#"):
                continue
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
            "observer_samples": 0,
            "observer_cpu_avg": None,
            "observer_cpu_max": None,
            "observer_mem_avg_kb": None,
            "observer_mem_max_kb": None,
        }
    return {
        "observer_samples": len(cpu),
        "observer_cpu_avg": mean(cpu),
        "observer_cpu_max": max(cpu),
        "observer_mem_avg_kb": mean(mem),
        "observer_mem_max_kb": max(mem),
    }


def classify_validity(
    platform: str,
    scenario: str,
    condition: str,
    drop_pct: float | None,
    netdev_samples: int,
    rx_mbps: float | None,
) -> str:
    if drop_pct is None:
        return "invalid_missing_final"
    if netdev_samples < 50 or rx_mbps is None:
        return "invalid_missing_netdev"
    if scenario == "ST1000" and condition == "topic_hz" and drop_pct > 1.0:
        return "expected_overload"
    if platform == "rpi" and scenario == "ST1000" and condition == "rp_hz" and drop_pct > 1.0:
        return "startup_transient"
    if drop_pct > 1.0:
        return "suspect_drop"
    return "valid"


def collect_runs(results_dir: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for platform_dir in sorted(p for p in results_dir.iterdir() if p.is_dir()):
        if platform_dir.name == "analysis":
            continue
        platform = platform_dir.name
        for scenario in SCENARIOS:
            for condition in CONDITIONS:
                condition_dir = platform_dir / scenario / condition
                if not condition_dir.exists():
                    continue
                for run_dir in sorted(condition_dir.glob("run*")):
                    if not run_dir.is_dir():
                        continue
                    platform_values = parse_key_values(run_dir / "platform.log")
                    recv, expected, drop_pct = parse_sub_log(run_dir / "sub.log")
                    netdev_samples, rx_mbps, netdev_duration_s, rx_delta_bytes = parse_netdev(
                        run_dir / "netdev.log"
                    )
                    observer = parse_observer_log(run_dir / "observer_cpu.log")
                    logical_cores = int(platform_values.get("logical_cores", "0") or 0)
                    cpu_avg = observer["observer_cpu_avg"]
                    cpu_max = observer["observer_cpu_max"]
                    row: dict[str, object] = {
                        "platform": platform,
                        "scenario": scenario,
                        "condition": condition,
                        "run": run_dir.name,
                        "path": str(run_dir),
                        "date": platform_values.get("date", ""),
                        "hz": int(platform_values.get("hz", "0") or 0),
                        "payload_bytes": int(platform_values.get("payload_bytes", "0") or 0),
                        "logical_cores": logical_cores,
                        "nic": platform_values.get("nic", ""),
                        "cpu0_governor": platform_values.get("cpu0_governor", ""),
                        "recv": recv,
                        "expected": expected,
                        "drop_pct": drop_pct,
                        "netdev_samples": netdev_samples,
                        "netdev_duration_s": netdev_duration_s,
                        "rx_delta_bytes": rx_delta_bytes,
                        "rx_mbps": rx_mbps,
                        **observer,
                        "observer_cpu_norm_avg": (
                            cpu_avg / logical_cores if cpu_avg is not None and logical_cores else None
                        ),
                        "observer_cpu_norm_max": (
                            cpu_max / logical_cores if cpu_max is not None and logical_cores else None
                        ),
                    }
                    row["validity"] = classify_validity(
                        platform, scenario, condition, drop_pct, netdev_samples, rx_mbps
                    )
                    rows.append(row)
    return rows


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
    grouped: dict[tuple[str, str, str], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        grouped[(str(row["platform"]), str(row["scenario"]), str(row["condition"]))].append(row)

    summary_rows: list[dict[str, object]] = []
    metrics = [
        "rx_mbps",
        "drop_pct",
        "observer_cpu_avg",
        "observer_cpu_max",
        "observer_cpu_norm_avg",
        "observer_mem_avg_kb",
        "observer_mem_max_kb",
    ]
    for key in sorted(grouped):
        platform, scenario, condition = key
        group = grouped[key]
        out: dict[str, object] = {
            "platform": platform,
            "scenario": scenario,
            "condition": condition,
            "n_runs": len(group),
            "validity_values": ";".join(sorted({str(row["validity"]) for row in group})),
        }
        for metric in metrics:
            values = [float(row[metric]) for row in group if row.get(metric) is not None]
            if values:
                out[f"{metric}_mean"] = mean(values)
                out[f"{metric}_std"] = stdev(values) if len(values) > 1 else 0.0
                out[f"{metric}_min"] = min(values)
                out[f"{metric}_max"] = max(values)
            else:
                out[f"{metric}_mean"] = None
                out[f"{metric}_std"] = None
                out[f"{metric}_min"] = None
                out[f"{metric}_max"] = None
        summary_rows.append(out)
    return summary_rows


def metric_values(
    rows: list[dict[str, object]], platform: str, scenario: str, condition: str, metric: str
) -> list[float]:
    values: list[float] = []
    for row in rows:
        if (
            row["platform"] == platform
            and row["scenario"] == scenario
            and row["condition"] == condition
            and row.get(metric) is not None
        ):
            values.append(float(row[metric]))
    return values


def plot_metric(
    rows: list[dict[str, object]],
    figures_dir: Path,
    filename: str,
    title: str,
    ylabel: str,
    metric: str,
    conditions: list[str],
) -> None:
    platforms = [p for p in PLATFORM_ORDER if any(row["platform"] == p for row in rows)]
    for platform in platforms:
        fig, ax = plt.subplots(figsize=(7.2, 4.2))
        x_positions = list(range(len(SCENARIOS)))
        width = 0.22 if len(conditions) == 3 else 0.28
        offsets = [width * (i - (len(conditions) - 1) / 2) for i in range(len(conditions))]

        for offset, condition in zip(offsets, conditions):
            means: list[float] = []
            errors: list[float] = []
            for scenario in SCENARIOS:
                values = metric_values(rows, platform, scenario, condition, metric)
                means.append(mean(values) if values else math.nan)
                errors.append(stdev(values) if len(values) > 1 else 0.0)
            xpos = [x + offset for x in x_positions]
            bars = ax.bar(
                xpos,
                means,
                width=width,
                yerr=errors,
                capsize=3,
                label=CONDITION_LABELS[condition],
                color=COLORS[condition],
                edgecolor="#111827",
                linewidth=0.5,
                alpha=0.92,
            )
            if condition == "topic_hz":
                for scenario, bar in zip(SCENARIOS, bars):
                    if scenario == "ST1000":
                        bar.set_hatch("//")
        ax.set_xticks(x_positions)
        ax.set_xticklabels(SCENARIOS)
        ax.set_ylabel(ylabel)
        ax.grid(axis="y", color="#d1d5db", linewidth=0.8, alpha=0.8)
        ax.set_axisbelow(True)
        handles, labels = ax.get_legend_handles_labels()
        fig.suptitle(f"{title} ({platform.upper()})", y=0.98, fontsize=13)
        fig.legend(
            handles,
            labels,
            loc="upper center",
            bbox_to_anchor=(0.5, 0.925),
            ncol=len(conditions),
            frameon=False,
        )
        fig.subplots_adjust(left=0.11, right=0.98, bottom=0.15, top=0.78)
        figures_dir.mkdir(parents=True, exist_ok=True)
        fig.savefig(figures_dir / f"{filename}_{platform}.png", dpi=220, bbox_inches="tight")
        plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", default="results/exp3", type=Path)
    parser.add_argument("--out-dir", default=None, type=Path)
    args = parser.parse_args()

    results_dir = args.results_dir
    out_dir = args.out_dir or results_dir / "analysis"
    figures_dir = out_dir / "figures"

    rows = collect_runs(results_dir)
    if not rows:
        raise SystemExit(f"No Experiment 3 runs found under {results_dir}")

    write_csv(out_dir / "exp3_runs.csv", rows)
    write_csv(out_dir / "exp3_summary.csv", summarize(rows))

    plot_metric(
        rows,
        figures_dir,
        "01_rx_mbps_by_scenario",
        "Experiment 3 RX Traffic",
        "RX Mbps",
        "rx_mbps",
        CONDITIONS,
    )
    plot_metric(
        rows,
        figures_dir,
        "02_drop_rate_by_scenario",
        "Experiment 3 Subscriber Drop Rate",
        "Drop rate (%)",
        "drop_pct",
        CONDITIONS,
    )
    plot_metric(
        rows,
        figures_dir,
        "03_observer_cpu_by_scenario",
        "Experiment 3 Observer CPU",
        "Observer CPU (% of system)",
        "observer_cpu_norm_avg",
        OBSERVER_CONDITIONS,
    )
    plot_metric(
        rows,
        figures_dir,
        "04_observer_pss_by_scenario",
        "Experiment 3 Observer PSS Memory",
        "Observer PSS (KB)",
        "observer_mem_avg_kb",
        OBSERVER_CONDITIONS,
    )

    print(f"Wrote {len(rows)} run rows to {out_dir / 'exp3_runs.csv'}")
    print(f"Wrote summary to {out_dir / 'exp3_summary.csv'}")
    print(f"Wrote figures to {figures_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
