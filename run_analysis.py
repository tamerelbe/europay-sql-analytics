"""
Build the EuroPay database, run every analysis in sql/, and save the
results (CSV + Markdown) and charts.

Usage:
    python data/generate_data.py   # once, to create the CSVs
    python run_analysis.py
"""

from pathlib import Path

import duckdb
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick

ROOT = Path(__file__).parent
SQL_DIR, RESULTS, CHARTS = ROOT / "sql", ROOT / "results", ROOT / "charts"
RESULTS.mkdir(exist_ok=True)
CHARTS.mkdir(exist_ok=True)

NAVY, BLUE, GREY = "#1F3864", "#4A78C2", "#9AA5B1"
plt.rcParams.update({
    "font.size": 10, "svg.fonttype": "none", "svg.hashsalt": "europay", "axes.spines.top": False, "axes.spines.right": False,
    "axes.titleweight": "bold", "axes.titlesize": 12, "figure.dpi": 150,
})


def run_sql_files(con):
    con.execute((SQL_DIR / "00_schema.sql").read_text())
    outputs = {}
    for f in sorted(SQL_DIR.glob("[0-9][0-9]_*.sql")):
        if f.name.startswith("00_"):
            continue
        df = con.execute(f.read_text()).df()
        for col in df.select_dtypes(include=["datetime64"]).columns:
            if (df[col].dt.time.astype(str) == "00:00:00").all():
                df[col] = df[col].dt.date
        outputs[f.stem] = df
        df.to_csv(RESULTS / f"{f.stem}.csv", index=False)
        (RESULTS / f"{f.stem}.md").write_text(
            df.astype(object).where(df.notna(), None).to_markdown(index=False, floatfmt=",.2f", missingval="–") + "\n")
        print(f"✓ {f.stem:<26} {len(df):>4} rows")
    return outputs


def chart_kpis(df):
    fig, ax1 = plt.subplots(figsize=(9, 4))
    ax1.bar(df["month"], df["monthly_active_users"], width=20, color=BLUE, label="Monthly active users")
    ax1.set_ylabel("Monthly active users")
    ax2 = ax1.twinx()
    ax2.plot(df["month"], df["total_revenue_eur"], color=NAVY, lw=2.5, marker="o", ms=4, label="Revenue (€)")
    ax2.set_ylabel("Revenue (€)")
    ax2.yaxis.set_major_formatter(mtick.StrMethodFormatter("€{x:,.0f}"))
    ax2.spines["top"].set_visible(False)
    ax1.set_title("Active users and revenue grow together month over month")
    fig.legend(loc="upper left", bbox_to_anchor=(0.08, 0.88), frameon=False)
    fig.tight_layout()
    fig.savefig(CHARTS / "01_monthly_kpis.svg", metadata={"Date": None})
    plt.close(fig)


def chart_funnel(df):
    d = df[df["country"] != "ALL"].sort_values("overall_conversion_pct")
    fig, ax = plt.subplots(figsize=(7, 3.6))
    colors = [NAVY if c == "DE" else GREY for c in d["country"]]
    ax.barh(d["country"], d["overall_conversion_pct"], color=colors)
    for y, v in enumerate(d["overall_conversion_pct"]):
        ax.text(v + 0.5, y, f"{v:.1f}%", va="center")
    ax.set_xlabel("Sign-up to first transaction (%)")
    ax.set_title("Germany converts worst: KYC approval is the bottleneck")
    ax.set_xlim(0, max(d["overall_conversion_pct"]) * 1.15)
    fig.tight_layout()
    fig.savefig(CHARTS / "02_onboarding_funnel.svg", metadata={"Date": None})
    plt.close(fig)


def chart_cohorts(df):
    d = df.set_index(df["cohort_month"].astype(str).str[:7])[["m1_pct", "m3_pct", "m6_pct", "m12_pct"]].astype(float)
    fig, ax = plt.subplots(figsize=(7, 6))
    im = ax.imshow(d.values, cmap="Blues", aspect="auto", vmin=0, vmax=100)
    ax.set_xticks(range(4), ["Month 1", "Month 3", "Month 6", "Month 12"])
    ax.set_yticks(range(len(d)), d.index)
    for i in range(d.shape[0]):
        for j in range(d.shape[1]):
            v = d.values[i, j]
            if v == v and v > 0:  # skip NaN / not-yet-observable
                ax.text(j, i, f"{v:.0f}%", ha="center", va="center",
                        color="white" if v > 55 else NAVY, fontsize=8)
    ax.set_title("Cohort retention: share still active after N months")
    fig.colorbar(im, ax=ax, fraction=0.03, format="%.0f%%")
    fig.tight_layout()
    fig.savefig(CHARTS / "03_cohort_retention.svg", metadata={"Date": None})
    plt.close(fig)


def chart_ltv(df):
    d = df[df["cut"] == "channel"].sort_values("avg_revenue_6m_eur")
    fig, ax = plt.subplots(figsize=(7, 3.4))
    colors = [NAVY if v == d["avg_revenue_6m_eur"].max() else GREY for v in d["avg_revenue_6m_eur"]]
    ax.barh(d["value"], d["avg_revenue_6m_eur"], color=colors)
    for y, v in enumerate(d["avg_revenue_6m_eur"]):
        ax.text(v + 0.1, y, f"€{v:.2f}", va="center")
    ax.set_xlabel("Average revenue per customer, first 6 months (€)")
    ax.set_title("Referred customers are worth the most")
    ax.set_xlim(0, d["avg_revenue_6m_eur"].max() * 1.2)
    fig.tight_layout()
    fig.savefig(CHARTS / "05_channel_ltv.svg", metadata={"Date": None})
    plt.close(fig)


def chart_fx(df):
    d = df.sort_values("rank")
    fig, ax = plt.subplots(figsize=(7, 3.6))
    ax.bar(d["fx_pair"], d["fx_revenue_eur"], color=BLUE)
    ax.yaxis.set_major_formatter(mtick.StrMethodFormatter("€{x:,.0f}"))
    ax2 = ax.twinx()
    ax2.plot(d["fx_pair"], d["cumulative_pct"], color=NAVY, marker="o", lw=2)
    ax2.set_ylim(0, 105)
    ax2.yaxis.set_major_formatter(mtick.PercentFormatter())
    ax2.spines["top"].set_visible(False)
    ax.set_title("Two corridors bring most FX revenue")
    ax.set_ylabel("FX revenue")
    ax2.set_ylabel("Cumulative share")
    fig.tight_layout()
    fig.savefig(CHARTS / "06_fx_corridors.svg", metadata={"Date": None})
    plt.close(fig)


def main():
    con = duckdb.connect(str(ROOT / "europay.duckdb"))
    out = run_sql_files(con)
    chart_kpis(out["01_monthly_kpis"])
    chart_funnel(out["02_onboarding_funnel"])
    chart_cohorts(out["03_cohort_retention"])
    chart_ltv(out["05_channel_ltv"])
    chart_fx(out["06_fx_corridors"])
    print("Charts saved to charts/")


if __name__ == "__main__":
    main()
