"""
Generate a synthetic dataset for EuroPay, a fictional European neobank.

The data is fake but built with realistic behaviour, so the SQL analyses
have real patterns to find (e.g. retention differs by acquisition channel,
KYC is stricter in some markets, a small number of accounts show fraud-like
transaction bursts).

Usage:
    python data/generate_data.py          # writes CSVs into data/raw/
"""

from pathlib import Path

import numpy as np
import pandas as pd

SEED = 42
N_CUSTOMERS = 25_000
START = pd.Timestamp("2025-01-01")
END = pd.Timestamp("2026-06-30 23:59:59")

COUNTRIES = {
    # country: (signup share, KYC approval rate, churn multiplier)
    "FR": (0.24, 0.91, 1.00),
    "IT": (0.20, 0.90, 0.80),
    "ES": (0.20, 0.92, 1.00),
    "DE": (0.16, 0.78, 1.20),
    "PT": (0.10, 0.93, 0.90),
    "NL": (0.10, 0.89, 1.05),
}
CHANNELS = {
    # channel: (signup share, base monthly churn probability)
    "organic": (0.35, 0.060),
    "paid_social": (0.30, 0.120),
    "referral": (0.20, 0.040),
    "partnership": (0.15, 0.070),
}
PLANS = {
    # plan: (starting share, monthly fee EUR, churn multiplier, monthly txn mean, FX spread)
    "standard": (0.80, 0.00, 1.00, 8, 0.0100),
    "plus": (0.12, 3.99, 0.80, 14, 0.0050),
    "premium": (0.08, 9.99, 0.50, 22, 0.0000),
}
CATEGORIES = {
    # category: (probability, lognormal mean, lognormal sigma, can be FX)
    "groceries": (0.26, 3.3, 0.6, False),
    "restaurants": (0.17, 3.2, 0.6, False),
    "shopping": (0.15, 3.8, 0.8, False),
    "transport": (0.10, 2.7, 0.7, False),
    "bills": (0.08, 4.2, 0.5, False),
    "travel": (0.08, 4.8, 0.9, True),
    "transfer": (0.10, 4.5, 1.0, False),
    "atm": (0.04, 4.1, 0.4, True),
    "fx_exchange": (0.02, 5.5, 0.8, True),
}
FX_PAIRS = ["EUR/GBP", "EUR/USD", "EUR/CHF", "EUR/MAD", "EUR/TRY", "EUR/AED"]
FX_WEIGHTS = [0.32, 0.30, 0.10, 0.12, 0.09, 0.07]
AGE_BANDS = ["18-24", "25-34", "35-44", "45-54", "55+"]
AGE_WEIGHTS = [0.22, 0.38, 0.22, 0.12, 0.06]

rng = np.random.default_rng(SEED)
OUT = Path(__file__).parent / "raw"
OUT.mkdir(parents=True, exist_ok=True)


def random_signup_dates(n):
    """Signups grow over time: weight later days more heavily."""
    days = (END.normalize() - START).days + 1
    weights = np.linspace(1.0, 2.2, days)
    weights /= weights.sum()
    offsets = rng.choice(days, size=n, p=weights)
    seconds = rng.integers(0, 86_400, size=n)
    return START + pd.to_timedelta(offsets, "D") + pd.to_timedelta(seconds, "s")


def main():
    # ---------------- customers ----------------
    country = rng.choice(list(COUNTRIES), N_CUSTOMERS, p=[v[0] for v in COUNTRIES.values()])
    channel = rng.choice(list(CHANNELS), N_CUSTOMERS, p=[v[0] for v in CHANNELS.values()])
    start_plan = rng.choice(list(PLANS), N_CUSTOMERS, p=[v[0] for v in PLANS.values()])
    signup = random_signup_dates(N_CUSTOMERS)
    order = np.argsort(signup.values)
    country, channel, start_plan = country[order], channel[order], start_plan[order]
    signup = pd.DatetimeIndex(signup.values[order])
    ids = np.arange(1, N_CUSTOMERS + 1)

    # referrals: a referred customer points to an earlier customer (creates chains)
    referred_by = np.full(N_CUSTOMERS, np.nan)
    for i in np.where(channel == "referral")[0]:
        if i > 50:
            # favour recent customers so referral chains form
            j = int(rng.integers(max(0, i - 3000), i))
            referred_by[i] = ids[j]

    customers = pd.DataFrame({
        "customer_id": ids,
        "signup_ts": signup,
        "country": country,
        "age_band": rng.choice(AGE_BANDS, N_CUSTOMERS, p=AGE_WEIGHTS),
        "acquisition_channel": channel,
        "referred_by": pd.array(referred_by, dtype="Int64"),
    })

    # ---------------- onboarding funnel ----------------
    funnel_rows = []
    activated = {}
    for cid, ts, ctry in zip(ids, signup, country):
        funnel_rows.append((cid, "signup", ts))
        t = ts
        steps = [
            ("kyc_submitted", 0.86, 0.5),
            ("kyc_approved", COUNTRIES[ctry][1], 1.5),
            ("card_activated", 0.88, 3.0),
            ("first_transaction", 0.92, 2.0),
        ]
        ok = True
        for name, p, mean_days in steps:
            if rng.random() > p:
                ok = False
                break
            t = t + pd.Timedelta(hours=float(rng.exponential(mean_days * 24)))
            if t > END:
                ok = False
                break
            funnel_rows.append((cid, name, t))
        if ok:
            activated[cid] = t
    funnel = pd.DataFrame(funnel_rows, columns=["customer_id", "event_type", "event_ts"])

    # ---------------- plans, churn and transactions ----------------
    plan_rows, txn_frames = [], []
    cat_names = list(CATEGORIES)
    cat_p = np.array([v[0] for v in CATEGORIES.values()])
    cat_p /= cat_p.sum()

    cust_idx = {cid: k for k, cid in enumerate(ids)}
    for cid, first_txn in activated.items():
        k = cust_idx[cid]
        plan = start_plan[k]
        ctry, chan = country[k], channel[k]

        # plan history (possible single upgrade)
        plan_rows.append((cid, plan, signup[k]))
        upgrade_ts = None
        if plan == "standard" and rng.random() < 0.14:
            upgrade_ts = first_txn + pd.Timedelta(days=float(rng.gamma(2.0, 45)))
            new_plan = "premium" if rng.random() < 0.35 else "plus"
            if upgrade_ts < END:
                plan_rows.append((cid, new_plan, upgrade_ts))
            else:
                upgrade_ts = None

        # lifetime: geometric number of active months
        p_churn = CHANNELS[chan][1] * COUNTRIES[ctry][2] * PLANS[plan][2]
        months_active = rng.geometric(min(p_churn, 0.95))
        last_active = min(first_txn + pd.Timedelta(days=30.4 * months_active), END)

        span_days = max((last_active - first_txn).total_seconds() / 86_400, 1)
        rate = PLANS[plan][3] * rng.lognormal(0, 0.35) / 30.4
        n = max(1, rng.poisson(rate * span_days))
        offs = np.sort(rng.uniform(0, span_days, n))
        ts = first_txn + pd.to_timedelta(offs, "D")

        cats = rng.choice(cat_names, n, p=cat_p)
        mu = np.array([CATEGORIES[c][1] for c in cats])
        sd = np.array([CATEGORIES[c][2] for c in cats])
        amount = np.round(rng.lognormal(mu, sd), 2)
        can_fx = np.array([CATEGORIES[c][3] for c in cats])
        is_fx = can_fx & (rng.random(n) < np.where(cats == "fx_exchange", 1.0, 0.45))

        # current plan at time of each transaction (for FX spread)
        cur_plan = np.full(n, plan, dtype=object)
        if upgrade_ts is not None:
            cur_plan[ts >= upgrade_ts] = plan_rows[-1][1]
        spread = np.array([PLANS[p][4] for p in cur_plan])

        fx_pair = np.where(is_fx, rng.choice(FX_PAIRS, n, p=FX_WEIGHTS), None)
        fx_fee = np.where(is_fx, np.round(amount * spread, 2), 0.0)
        card_spend = ~np.isin(cats, ["transfer", "fx_exchange", "atm"])
        interchange = np.where(card_spend, np.round(amount * 0.002, 4), 0.0)
        status = rng.choice(["completed", "declined", "refunded"], n, p=[0.96, 0.03, 0.01])

        txn_frames.append(pd.DataFrame({
            "customer_id": cid, "txn_ts": ts, "category": cats, "amount_eur": amount,
            "is_fx": is_fx, "fx_pair": fx_pair, "fx_fee_eur": fx_fee,
            "interchange_eur": interchange, "status": status,
        }))

    # inject fraud-like bursts: many large card payments within minutes
    fraud_ids = rng.choice(list(activated), 60, replace=False)
    fraud_truth = []
    for cid in fraud_ids:
        t0 = activated[cid] + pd.Timedelta(days=float(rng.uniform(5, 120)))
        if t0 > END:
            continue
        fraud_truth.append(int(cid))
        m = int(rng.integers(6, 11))
        ts = t0 + pd.to_timedelta(np.sort(rng.uniform(0, 9, m)), "min")
        amount = np.round(rng.uniform(250, 900, m), 2)
        txn_frames.append(pd.DataFrame({
            "customer_id": cid, "txn_ts": ts, "category": "shopping", "amount_eur": amount,
            "is_fx": False, "fx_pair": None, "fx_fee_eur": 0.0,
            "interchange_eur": np.round(amount * 0.002, 4), "status": "completed",
        }))

    txns = pd.concat(txn_frames, ignore_index=True)
    txns = txns[txns["txn_ts"] <= END].sort_values("txn_ts", ignore_index=True)
    txns.insert(0, "txn_id", np.arange(1, len(txns) + 1))
    txns["txn_ts"] = txns["txn_ts"].dt.floor("s")

    plans = pd.DataFrame(plan_rows, columns=["customer_id", "plan", "valid_from"])
    plans = plans.sort_values(["customer_id", "valid_from"])
    plans["valid_to"] = plans.groupby("customer_id")["valid_from"].shift(-1)

    fees = pd.DataFrame(
        [(p, v[1]) for p, v in PLANS.items()], columns=["plan", "monthly_fee_eur"]
    )

    customers["signup_ts"] = customers["signup_ts"].dt.floor("s")
    funnel["event_ts"] = funnel["event_ts"].dt.floor("s")

    customers.to_csv(OUT / "customers.csv", index=False)
    funnel.to_csv(OUT / "onboarding_events.csv", index=False)
    plans.to_csv(OUT / "plan_history.csv", index=False)
    fees.to_csv(OUT / "plan_fees.csv", index=False)
    txns.to_csv(OUT / "transactions.csv", index=False)
    # ground truth for the injected bursts, used only to score query 08 (never joined in the analysis)
    pd.DataFrame({"customer_id": sorted(fraud_truth)}).to_csv(OUT / "fraud_labels.csv", index=False)

    print(f"customers:          {len(customers):>9,}")
    print(f"onboarding events:  {len(funnel):>9,}")
    print(f"plan history rows:  {len(plans):>9,}")
    print(f"transactions:       {len(txns):>9,}")


if __name__ == "__main__":
    main()
