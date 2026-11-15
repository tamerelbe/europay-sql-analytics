-- =====================================================================
-- 00_schema.sql
-- Creates the EuroPay tables and loads the generated CSVs.
-- Engine: DuckDB (PostgreSQL-compatible SQL)
-- =====================================================================

CREATE OR REPLACE TABLE customers (
    customer_id          INTEGER PRIMARY KEY,
    signup_ts            TIMESTAMP NOT NULL,
    country              VARCHAR(2) NOT NULL,
    age_band             VARCHAR NOT NULL,
    acquisition_channel  VARCHAR NOT NULL,
    referred_by          INTEGER            -- customer_id of the referrer (NULL if none)
);

CREATE OR REPLACE TABLE onboarding_events (
    customer_id  INTEGER NOT NULL,
    event_type   VARCHAR NOT NULL,          -- signup > kyc_submitted > kyc_approved > card_activated > first_transaction
    event_ts     TIMESTAMP NOT NULL
);

CREATE OR REPLACE TABLE plan_history (
    customer_id  INTEGER NOT NULL,
    plan         VARCHAR NOT NULL,          -- standard | plus | premium
    valid_from   TIMESTAMP NOT NULL,
    valid_to     TIMESTAMP                  -- NULL = current plan
);

CREATE OR REPLACE TABLE plan_fees (
    plan             VARCHAR PRIMARY KEY,
    monthly_fee_eur  DECIMAL(6, 2) NOT NULL
);

CREATE OR REPLACE TABLE transactions (
    txn_id           BIGINT PRIMARY KEY,
    customer_id      INTEGER NOT NULL,
    txn_ts           TIMESTAMP NOT NULL,
    category         VARCHAR NOT NULL,
    amount_eur       DECIMAL(12, 2) NOT NULL,
    is_fx            BOOLEAN NOT NULL,
    fx_pair          VARCHAR,
    fx_fee_eur       DECIMAL(10, 2) NOT NULL,
    interchange_eur  DECIMAL(10, 4) NOT NULL,
    status           VARCHAR NOT NULL        -- completed | declined | refunded
);

INSERT INTO customers         SELECT * FROM read_csv_auto('data/raw/customers.csv');
INSERT INTO onboarding_events SELECT * FROM read_csv_auto('data/raw/onboarding_events.csv');
INSERT INTO plan_history      SELECT * FROM read_csv_auto('data/raw/plan_history.csv');
INSERT INTO plan_fees         SELECT * FROM read_csv_auto('data/raw/plan_fees.csv');
INSERT INTO transactions      SELECT * FROM read_csv_auto('data/raw/transactions.csv');

-- Analysis-friendly view: only money that actually moved
CREATE OR REPLACE VIEW completed_txns AS
SELECT *
FROM transactions
WHERE status = 'completed';
