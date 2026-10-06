# Draws docs/media/behaviour-chart.png from the CSVs that docs/sim/main.swift writes.
#   cd docs/data && uv run --with matplotlib python ../sim/plot.py ../media/behaviour-chart.png
import csv, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
plt.rcParams.update({"font.size": 11, "axes.edgecolor": GRID, "axes.labelcolor": INK2,
    "xtick.color": INK2, "ytick.color": INK2, "axes.titlecolor": INK, "axes.titlesize": 12,
    "axes.titleweight": "bold", "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8, "figure.facecolor": SURF,
    "axes.facecolor": SURF})

sp = list(csv.DictReader(open("spring.csv")))
br = list(csv.DictReader(open("breaks.csv")))
di = list(csv.DictReader(open("distance.csv")))

fig, ax = plt.subplots(1, 3, figsize=(16, 4.6), dpi=100, gridspec_kw={"width_ratios": [1, 1, 1.4]})

t = [float(r["t"]) for r in sp]
ax[0].plot(t, [float(r["yaw_2hz"]) for r in sp], color=BLUE, lw=2, label="look-at yaw, 2 Hz (0 → 1 rad)")
ax[0].plot(t, [(1 - float(r["squash_6hz"])) / 0.1 for r in sp], color=ORANGE, lw=2, label="tap squash, 6 Hz (1 → 0.9 scale)")
ax[0].axhline(1, color=INK2, lw=0.8, ls="--")
ax[0].set_title("Spring.swift step response")
ax[0].set_xlabel("time (s)"); ax[0].set_ylabel("fraction of the way to the target")
ax[0].legend(frameon=False, loc="lower right", fontsize=10)

d = [float(r["distance_m"]) for r in di]
w = [float(r["waves_per_hour"]) for r in di]
ax[1].plot(d, w, color=BLUE, lw=2, marker="o", ms=8, mec=SURF, mew=2)
ax[1].set_title("Unprompted waves per hour vs distance")
ax[1].set_xlabel("your distance from the lamp (m)"); ax[1].set_ylabel("waves / hour (mean of 50 sim. hours)")
ax[1].set_ylim(0, 17)
ax[1].annotate("3–5 min cooldown caps it\nat ~14/h up close", (1.0, 14.2), (1.45, 11.5), fontsize=9.5, color=INK2,
               arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))
ax[1].annotate("none at 1.75 m or more", (2.0, 0), (1.95, 3.2), fontsize=9.5, color=INK2,
               arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))

runs = 6
for run in range(runs):
    pts = [r for r in br if int(r["run"]) == run and float(r["t_s"]) <= 1800]
    for kind, col, lab, size in (("glance", AQUA, "look around", 26), ("wave", ORANGE, "wave", 70)):
        xs = [float(r["t_s"]) / 60 for r in pts if r["pick"] == kind]
        ax[2].scatter(xs, [run] * len(xs), s=size, color=col, alpha=1, edgecolors=SURF, linewidths=0.8,
                      label=lab if run == 0 else None, zorder=3)
ax[2].set_yticks(range(runs)); ax[2].set_yticklabels([f"run {i+1}" for i in range(runs)])
ax[2].grid(axis="y", visible=False)
ax[2].set_xlim(0, 30); ax[2].invert_yaxis()
ax[2].set_title("Idle breaks over 30 min at 1 m (6 simulated runs)")
ax[2].set_xlabel("minutes")
ax[2].legend(frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.17), ncol=2, fontsize=10)

fig.tight_layout()
fig.savefig(sys.argv[1], facecolor=SURF)
