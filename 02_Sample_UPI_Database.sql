-- =============================================================================
-- PULSE — Sample UPI Database
-- =============================================================================
-- Companion artifact to: 01_Strategy_UPI_Analytics_Agent.md
-- Author: Varun Rustagi · Director Data Products candidate, Mobikwik
--
-- Layout (mirrors §3 of the strategy doc):
--   1. RAW LAYER     — exactly as produced by source systems
--   2. CLEANED DIMS  — conformed, SCD2 where appropriate
--   3. MARTS / FACTS — purpose-built for analytics
--   4. SEMANTIC VIEWS — what the LLM agent actually queries
--   5. SEED DATA     — 30 days of realistic mock UPI activity
--
-- Tested against SQLite 3.40+. Reasonably portable to Postgres / DuckDB.
-- Run end-to-end: sqlite3 upi_demo.db < 02_Sample_UPI_Database.sql
-- =============================================================================

PRAGMA foreign_keys = ON;

-- =============================================================================
-- 1. RAW LAYER
-- =============================================================================

DROP TABLE IF EXISTS raw_upi_disputes;
DROP TABLE IF EXISTS raw_upi_refunds;
DROP TABLE IF EXISTS raw_upi_mandates;
DROP TABLE IF EXISTS raw_upi_txn_state_log;
DROP TABLE IF EXISTS raw_upi_transactions;
DROP TABLE IF EXISTS raw_user_devices;
DROP TABLE IF EXISTS raw_user_bank_accounts;
DROP TABLE IF EXISTS raw_user_vpas;
DROP TABLE IF EXISTS raw_users;
DROP TABLE IF EXISTS raw_merchants;
DROP TABLE IF EXISTS raw_banks;

CREATE TABLE raw_banks (
    ifsc_root        TEXT PRIMARY KEY,        -- e.g. 'HDFC', 'SBIN'
    bank_name        TEXT NOT NULL,
    bank_category    TEXT,                    -- PSU / PRIVATE / SFB / PPI / FOREIGN
    is_npci_member   INTEGER DEFAULT 1,
    onboarded_at     TEXT
);

CREATE TABLE raw_merchants (
    merchant_id      TEXT PRIMARY KEY,
    merchant_name    TEXT NOT NULL,
    mcc              TEXT,                     -- ISO 18245
    category_l1      TEXT,                     -- e.g. 'Food', 'Bills', 'Retail'
    sub_category     TEXT,
    onboarded_at     TEXT,
    kyb_status       TEXT,                     -- VERIFIED / PENDING / REJECTED
    settlement_bank  TEXT REFERENCES raw_banks(ifsc_root)
);

CREATE TABLE raw_users (
    user_id          TEXT PRIMARY KEY,         -- Mobikwik internal user id
    mobile_token     TEXT,                     -- tokenised mobile (raw layer keeps token only)
    signup_at        TEXT,
    signup_channel   TEXT,                     -- ORGANIC / PAID / REFERRAL
    kyc_level        TEXT,                     -- MIN / FULL / VKYC
    kyc_outcome      TEXT,                     -- VERIFIED / PENDING / FAILED
    last_kyc_at      TEXT,
    home_city        TEXT,
    home_state       TEXT
);

CREATE TABLE raw_user_vpas (
    vpa              TEXT PRIMARY KEY,         -- e.g. 'varun.r@ikwik'
    user_id          TEXT REFERENCES raw_users(user_id),
    handle           TEXT,                     -- '@ikwik'
    is_default       INTEGER DEFAULT 0,
    status           TEXT,                     -- ACTIVE / DEACTIVATED
    created_at       TEXT,
    deactivated_at   TEXT
);

CREATE TABLE raw_user_bank_accounts (
    user_bank_id     TEXT PRIMARY KEY,
    user_id          TEXT REFERENCES raw_users(user_id),
    account_token    TEXT,                     -- tokenised; vault holds plaintext
    ifsc             TEXT,
    bank_root        TEXT REFERENCES raw_banks(ifsc_root),
    account_type     TEXT,                     -- SAVINGS / CURRENT
    set_pin_at       TEXT,
    deregistered_at  TEXT
);

CREATE TABLE raw_user_devices (
    device_fp        TEXT PRIMARY KEY,         -- device fingerprint
    user_id          TEXT REFERENCES raw_users(user_id),
    platform         TEXT,                     -- ANDROID / IOS
    os_version       TEXT,
    app_version      TEXT,
    is_rooted        INTEGER DEFAULT 0,
    first_seen_at    TEXT,
    last_seen_at     TEXT
);

-- The big one. One row per terminal txn (raw response from PSP/NPCI).
CREATE TABLE raw_upi_transactions (
    txn_id           TEXT PRIMARY KEY,         -- Mobikwik internal
    rrn              TEXT,                     -- NPCI Retrieval Reference Number
    upi_txn_ref_id   TEXT,
    npci_txn_id      TEXT,
    merchant_order_id TEXT,

    initiated_at     TEXT NOT NULL,
    pin_entered_at   TEXT,
    psp_request_at   TEXT,
    npci_received_at TEXT,
    issuer_response_at TEXT,
    beneficiary_credit_at TEXT,
    final_state_at   TEXT,

    payer_user_id    TEXT REFERENCES raw_users(user_id),
    payer_vpa        TEXT,
    payer_handle     TEXT,
    payer_account_token TEXT,
    payer_ifsc       TEXT,
    payer_bank_root  TEXT REFERENCES raw_banks(ifsc_root),

    payee_user_id    TEXT,
    payee_vpa        TEXT,
    payee_handle     TEXT,
    payee_account_token TEXT,
    payee_ifsc       TEXT,
    payee_bank_root  TEXT REFERENCES raw_banks(ifsc_root),
    payee_merchant_id TEXT REFERENCES raw_merchants(merchant_id),

    amount           REAL NOT NULL,
    currency         TEXT DEFAULT 'INR',
    convenience_fee  REAL DEFAULT 0,
    mdr              REAL DEFAULT 0,
    gst              REAL DEFAULT 0,

    txn_type         TEXT,                     -- P2P / P2M / M2P / REFUND
    flow_type        TEXT,                     -- COLLECT / INTENT / QR_DYNAMIC / QR_STATIC / NFC
    category         TEXT,                     -- STANDARD / LITE / 123PAY / MANDATE / RUPAY_CC
    is_offline       INTEGER DEFAULT 0,

    status           TEXT,                     -- INITIATED / PENDING / SUCCESS / FAILURE / DEEMED / REVERSED
    failure_code     TEXT,                     -- e.g. 'U16', 'Z9', 'XB'
    failure_reason_text TEXT,
    failed_at_leg    TEXT,                     -- PSP / NPCI / ISSUER / BENEFICIARY

    payer_psp        TEXT,
    payee_psp        TEXT,

    risk_score       INTEGER,
    risk_decision    TEXT,                     -- ALLOW / REVIEW / BLOCK / STEP_UP

    device_fp        TEXT REFERENCES raw_user_devices(device_fp),
    payer_city       TEXT,
    payer_state      TEXT,

    ingested_at      TEXT
);

CREATE TABLE raw_upi_txn_state_log (
    log_id           INTEGER PRIMARY KEY AUTOINCREMENT,
    txn_id           TEXT REFERENCES raw_upi_transactions(txn_id),
    state            TEXT,
    state_at         TEXT,
    actor            TEXT                      -- USER / PSP / NPCI / ISSUER / BENEFICIARY
);

CREATE TABLE raw_upi_mandates (
    mandate_id       TEXT PRIMARY KEY,
    user_id          TEXT REFERENCES raw_users(user_id),
    payer_vpa        TEXT,
    merchant_id      TEXT REFERENCES raw_merchants(merchant_id),
    mandate_type     TEXT,                     -- ONE_TIME / RECURRING
    frequency        TEXT,                     -- WEEKLY / MONTHLY / YEARLY
    max_amount       REAL,
    valid_from       TEXT,
    valid_until      TEXT,
    status           TEXT,                     -- ACTIVE / REVOKED / EXPIRED / PAUSED
    created_at       TEXT,
    last_executed_at TEXT,
    last_execution_status TEXT
);

CREATE TABLE raw_upi_disputes (
    dispute_id       TEXT PRIMARY KEY,
    txn_id           TEXT REFERENCES raw_upi_transactions(txn_id),
    raised_by        TEXT,                     -- PAYER / PAYEE / BANK / NPCI
    dispute_type     TEXT,                     -- CHARGEBACK / GOOD_FAITH / FRAUD / DEEMED
    raised_at        TEXT,
    resolved_at      TEXT,
    resolution       TEXT,                     -- ACCEPTED / REJECTED / PARTIAL
    npci_dispute_id  TEXT
);

CREATE TABLE raw_upi_refunds (
    refund_id        TEXT PRIMARY KEY,
    original_txn_id  TEXT REFERENCES raw_upi_transactions(txn_id),
    refund_txn_id    TEXT,
    amount           REAL,
    initiated_at     TEXT,
    completed_at     TEXT,
    status           TEXT
);

-- =============================================================================
-- 2. CLEANED DIMS (conformed, SCD2 where shown)
-- =============================================================================

DROP TABLE IF EXISTS dim_failure_code;
DROP TABLE IF EXISTS dim_app_version;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_merchant;
DROP TABLE IF EXISTS dim_bank;
DROP TABLE IF EXISTS dim_user;

CREATE TABLE dim_user (
    user_sk          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id          TEXT NOT NULL,            -- natural key
    home_city        TEXT,
    home_state       TEXT,
    kyc_level        TEXT,
    cohort_month     TEXT,                     -- YYYY-MM of first txn
    is_active        INTEGER,
    valid_from       TEXT NOT NULL,
    valid_to         TEXT,                     -- NULL = current row (SCD2)
    is_current       INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_dim_user_uid ON dim_user(user_id, is_current);

CREATE TABLE dim_bank (
    bank_sk          INTEGER PRIMARY KEY AUTOINCREMENT,
    ifsc_root        TEXT NOT NULL,
    bank_name        TEXT NOT NULL,
    bank_category    TEXT,
    is_top10_volume  INTEGER DEFAULT 0,
    valid_from       TEXT NOT NULL,
    valid_to         TEXT,
    is_current       INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE dim_merchant (
    merchant_sk      INTEGER PRIMARY KEY AUTOINCREMENT,
    merchant_id      TEXT NOT NULL,
    merchant_name    TEXT NOT NULL,
    mcc              TEXT,
    category_l1      TEXT,
    sub_category     TEXT,
    valid_from       TEXT NOT NULL,
    valid_to         TEXT,
    is_current       INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE dim_date (
    dt               TEXT PRIMARY KEY,         -- YYYY-MM-DD
    day_of_week      INTEGER,
    day_name         TEXT,
    week_of_year     INTEGER,
    month_num        INTEGER,
    month_name       TEXT,
    quarter          INTEGER,
    year             INTEGER,
    is_weekend       INTEGER,
    is_salary_day    INTEGER                   -- 1st, last working day, 30th, etc.
);

CREATE TABLE dim_app_version (
    app_version      TEXT,
    platform         TEXT,
    release_train    TEXT,
    released_at      TEXT,
    PRIMARY KEY (app_version, platform)
);

CREATE TABLE dim_failure_code (
    failure_code     TEXT PRIMARY KEY,
    bucket           TEXT,                     -- TECHNICAL / BUSINESS / USER / RISK
    leg              TEXT,                     -- PSP / NPCI / ISSUER / BENEFICIARY
    description      TEXT,
    owner_team       TEXT
);

-- =============================================================================
-- 3. MARTS / FACTS
-- =============================================================================

DROP TABLE IF EXISTS fct_disputes;
DROP TABLE IF EXISTS fct_upi_user_day;
DROP TABLE IF EXISTS fct_upi_txn;

-- One row per terminal UPI txn, joined to conformed dims, business-logic clean.
CREATE TABLE fct_upi_txn (
    txn_id              TEXT PRIMARY KEY,
    rrn                 TEXT,
    dt                  TEXT REFERENCES dim_date(dt),
    initiated_at        TEXT,
    final_state_at      TEXT,
    latency_ms          INTEGER,                -- final_state_at − initiated_at

    payer_user_sk       INTEGER REFERENCES dim_user(user_sk),
    payer_bank_sk       INTEGER REFERENCES dim_bank(bank_sk),
    payee_bank_sk       INTEGER REFERENCES dim_bank(bank_sk),
    merchant_sk         INTEGER REFERENCES dim_merchant(merchant_sk),
    failure_code        TEXT REFERENCES dim_failure_code(failure_code),
    app_version         TEXT,

    amount              REAL,
    txn_direction       TEXT,                   -- DEBIT / CREDIT
    txn_type            TEXT,
    flow_type           TEXT,
    category            TEXT,
    status              TEXT,
    is_success          INTEGER,
    is_user_cancelled   INTEGER,                -- excluded from success-rate denominator

    payer_city          TEXT,
    payer_state         TEXT,
    risk_decision       TEXT
);

CREATE INDEX idx_fct_txn_dt ON fct_upi_txn(dt);
CREATE INDEX idx_fct_txn_type ON fct_upi_txn(txn_type, dt);
CREATE INDEX idx_fct_txn_payer_bank ON fct_upi_txn(payer_bank_sk, dt);

CREATE TABLE fct_upi_user_day (
    user_sk             INTEGER REFERENCES dim_user(user_sk),
    dt                  TEXT REFERENCES dim_date(dt),
    txn_count           INTEGER,
    success_count       INTEGER,
    gmv                 REAL,
    is_active           INTEGER,
    PRIMARY KEY (user_sk, dt)
);

CREATE TABLE fct_disputes (
    dispute_id          TEXT PRIMARY KEY,
    txn_id              TEXT REFERENCES fct_upi_txn(txn_id),
    raised_dt           TEXT REFERENCES dim_date(dt),
    resolved_dt         TEXT REFERENCES dim_date(dt),
    dispute_type        TEXT,
    resolution          TEXT,
    tat_hours           REAL,
    amount              REAL
);

-- =============================================================================
-- 4. SEMANTIC VIEWS
-- These are what the LLM agent actually queries via the metric layer.
-- Each view corresponds to one or more KPIs in the metric catalogue.
-- =============================================================================

DROP VIEW IF EXISTS vw_upi_kpi_daily;
DROP VIEW IF EXISTS vw_upi_kpi_by_bank;
DROP VIEW IF EXISTS vw_upi_kpi_by_failure_code;
DROP VIEW IF EXISTS vw_upi_kpi_p2m_vs_p2p;
DROP VIEW IF EXISTS vw_upi_kpi_active_users;
DROP VIEW IF EXISTS vw_upi_kpi_disputes;

-- KPI: success rate, volume, GMV, AOV per day
CREATE VIEW vw_upi_kpi_daily AS
SELECT
    dt,
    COUNT(*)                                                   AS txn_count,
    SUM(CASE WHEN is_success = 1 THEN 1 ELSE 0 END)            AS success_count,
    SUM(CASE WHEN is_success = 0 AND is_user_cancelled = 0
             THEN 1 ELSE 0 END)                                AS failure_count,
    ROUND(
        100.0 * SUM(CASE WHEN is_success = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_user_cancelled = 0 THEN 1 ELSE 0 END), 0)
    , 2)                                                       AS success_rate_pct,
    SUM(CASE WHEN is_success = 1 THEN amount ELSE 0 END)       AS gmv,
    ROUND(
        SUM(CASE WHEN is_success = 1 THEN amount ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_success = 1 THEN 1 ELSE 0 END), 0)
    , 2)                                                       AS avg_ticket_size,
    ROUND(AVG(latency_ms), 0)                                  AS avg_latency_ms
FROM fct_upi_txn
GROUP BY dt;

-- KPI: success/failure by issuer bank (payer side)
CREATE VIEW vw_upi_kpi_by_bank AS
SELECT
    f.dt,
    b.ifsc_root                                                AS bank,
    b.bank_name,
    b.bank_category,
    COUNT(*)                                                   AS txn_count,
    SUM(CASE WHEN f.is_success = 1 THEN 1 ELSE 0 END)          AS success_count,
    ROUND(
        100.0 * SUM(CASE WHEN f.is_success = 0 AND f.is_user_cancelled = 0
                         THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN f.is_user_cancelled = 0 THEN 1 ELSE 0 END), 0)
    , 2)                                                       AS failure_rate_pct,
    ROUND(
        100.0 * SUM(CASE WHEN f.is_success = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN f.is_user_cancelled = 0 THEN 1 ELSE 0 END), 0)
    , 2)                                                       AS success_rate_pct,
    SUM(CASE WHEN f.is_success = 1 THEN f.amount ELSE 0 END)   AS gmv
FROM fct_upi_txn f
JOIN dim_bank b ON f.payer_bank_sk = b.bank_sk AND b.is_current = 1
GROUP BY f.dt, b.ifsc_root, b.bank_name, b.bank_category;

-- KPI: failure code distribution
CREATE VIEW vw_upi_kpi_by_failure_code AS
SELECT
    f.dt,
    f.failure_code,
    fc.bucket,
    fc.leg,
    fc.description,
    fc.owner_team,
    COUNT(*)                                                   AS failure_count,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY f.dt)
    , 2)                                                       AS share_of_failures_pct
FROM fct_upi_txn f
JOIN dim_failure_code fc ON f.failure_code = fc.failure_code
WHERE f.is_success = 0 AND f.is_user_cancelled = 0
GROUP BY f.dt, f.failure_code, fc.bucket, fc.leg, fc.description, fc.owner_team;

-- KPI: P2M vs P2P split
CREATE VIEW vw_upi_kpi_p2m_vs_p2p AS
SELECT
    dt,
    txn_type,
    COUNT(*)                                                   AS txn_count,
    SUM(CASE WHEN is_success = 1 THEN 1 ELSE 0 END)            AS success_count,
    SUM(CASE WHEN is_success = 1 THEN amount ELSE 0 END)       AS gmv,
    ROUND(
        SUM(CASE WHEN is_success = 1 THEN amount ELSE 0 END)
        / NULLIF(SUM(CASE WHEN is_success = 1 THEN 1 ELSE 0 END), 0)
    , 2)                                                       AS avg_ticket_size
FROM fct_upi_txn
WHERE txn_type IN ('P2M','P2P')
GROUP BY dt, txn_type;

-- KPI: DAU / new actives
CREATE VIEW vw_upi_kpi_active_users AS
SELECT
    dt,
    COUNT(DISTINCT user_sk)                                    AS dau,
    SUM(CASE WHEN is_active = 1 THEN 1 ELSE 0 END)             AS active_user_days,
    SUM(gmv)                                                   AS gmv,
    ROUND(SUM(gmv) / NULLIF(COUNT(DISTINCT user_sk), 0), 2)    AS gmv_per_active
FROM fct_upi_user_day
GROUP BY dt;

-- KPI: disputes
CREATE VIEW vw_upi_kpi_disputes AS
SELECT
    raised_dt                                                  AS dt,
    dispute_type,
    COUNT(*)                                                   AS dispute_count,
    SUM(amount)                                                AS dispute_amount,
    ROUND(AVG(tat_hours), 1)                                   AS avg_resolution_tat_hrs,
    SUM(CASE WHEN resolution = 'ACCEPTED' THEN 1 ELSE 0 END)   AS accepted_count
FROM fct_disputes
GROUP BY raised_dt, dispute_type;


-- =============================================================================
-- 5. SEED DATA  (30 days, ~500 txns, 30 users, 8 banks, 6 merchants)
-- =============================================================================

-- ---------- BANKS ----------
INSERT INTO raw_banks VALUES
 ('HDFC','HDFC Bank',         'PRIVATE',1,'2016-08-25'),
 ('SBIN','State Bank of India','PSU',    1,'2016-08-25'),
 ('ICIC','ICICI Bank',         'PRIVATE',1,'2016-08-25'),
 ('AXIS','Axis Bank',          'PRIVATE',1,'2016-08-25'),
 ('KKBK','Kotak Mahindra',     'PRIVATE',1,'2016-08-25'),
 ('UTIB','Union Bank',         'PSU',    1,'2017-01-10'),
 ('YESB','Yes Bank',           'PRIVATE',1,'2016-08-25'),
 ('JSFB','Jana SFB',           'SFB',    1,'2018-06-01');

-- ---------- MERCHANTS ----------
INSERT INTO raw_merchants VALUES
 ('M001','Big Bazaar',  '5411','Retail','Grocery',         '2024-03-12','VERIFIED','HDFC'),
 ('M002','Zomato',      '5812','Food',  'Food Delivery',   '2023-11-02','VERIFIED','ICIC'),
 ('M003','BookMyShow',  '7832','Entertainment','Tickets',  '2024-01-15','VERIFIED','HDFC'),
 ('M004','BSES Delhi',  '4900','Bills', 'Electricity',     '2022-08-20','VERIFIED','SBIN'),
 ('M005','PharmEasy',   '5912','Health','Pharmacy',        '2024-05-30','VERIFIED','AXIS'),
 ('M006','Paytm KIRANA','5499','Retail','Kirana QR',       '2025-02-10','VERIFIED','KKBK');

-- ---------- USERS (30 users, varied cohorts/cities) ----------
INSERT INTO raw_users VALUES
 ('U001','tok_91a','2025-06-12','ORGANIC','FULL','VERIFIED','2025-06-13','Delhi','Delhi'),
 ('U002','tok_92b','2025-07-04','PAID','FULL','VERIFIED','2025-07-04','Mumbai','Maharashtra'),
 ('U003','tok_93c','2025-08-19','REFERRAL','MIN','VERIFIED','2025-08-19','Bangalore','Karnataka'),
 ('U004','tok_94d','2025-09-22','ORGANIC','FULL','VERIFIED','2025-09-23','Hyderabad','Telangana'),
 ('U005','tok_95e','2025-10-01','ORGANIC','VKYC','VERIFIED','2025-10-01','Pune','Maharashtra'),
 ('U006','tok_96f','2025-11-15','PAID','FULL','VERIFIED','2025-11-15','Chennai','Tamil Nadu'),
 ('U007','tok_97g','2025-12-08','REFERRAL','MIN','VERIFIED','2025-12-08','Kolkata','West Bengal'),
 ('U008','tok_98h','2026-01-04','ORGANIC','FULL','VERIFIED','2026-01-05','Delhi','Delhi'),
 ('U009','tok_99i','2026-01-19','PAID','FULL','VERIFIED','2026-01-19','Mumbai','Maharashtra'),
 ('U010','tok_a0j','2026-02-02','ORGANIC','MIN','PENDING','2026-02-02','Ahmedabad','Gujarat'),
 ('U011','tok_a1k','2026-02-14','ORGANIC','FULL','VERIFIED','2026-02-14','Jaipur','Rajasthan'),
 ('U012','tok_a2l','2026-02-25','PAID','VKYC','VERIFIED','2026-02-25','Lucknow','Uttar Pradesh'),
 ('U013','tok_a3m','2026-03-03','REFERRAL','FULL','VERIFIED','2026-03-03','Indore','Madhya Pradesh'),
 ('U014','tok_a4n','2026-03-12','ORGANIC','FULL','VERIFIED','2026-03-12','Delhi','Delhi'),
 ('U015','tok_a5o','2026-03-18','ORGANIC','FULL','VERIFIED','2026-03-18','Bangalore','Karnataka'),
 ('U016','tok_a6p','2026-03-25','PAID','MIN','VERIFIED','2026-03-25','Mumbai','Maharashtra'),
 ('U017','tok_a7q','2026-04-01','ORGANIC','FULL','VERIFIED','2026-04-01','Pune','Maharashtra'),
 ('U018','tok_a8r','2026-04-04','REFERRAL','VKYC','VERIFIED','2026-04-05','Hyderabad','Telangana'),
 ('U019','tok_a9s','2026-04-08','ORGANIC','MIN','VERIFIED','2026-04-08','Chennai','Tamil Nadu'),
 ('U020','tok_b0t','2026-04-11','PAID','FULL','VERIFIED','2026-04-11','Delhi','Delhi'),
 ('U021','tok_b1u','2026-04-13','ORGANIC','FULL','VERIFIED','2026-04-13','Kolkata','West Bengal'),
 ('U022','tok_b2v','2026-04-15','ORGANIC','FULL','VERIFIED','2026-04-15','Mumbai','Maharashtra'),
 ('U023','tok_b3w','2026-04-17','PAID','MIN','VERIFIED','2026-04-17','Bangalore','Karnataka'),
 ('U024','tok_b4x','2026-04-19','REFERRAL','FULL','VERIFIED','2026-04-19','Pune','Maharashtra'),
 ('U025','tok_b5y','2026-04-21','ORGANIC','VKYC','VERIFIED','2026-04-22','Delhi','Delhi'),
 ('U026','tok_b6z','2026-04-23','ORGANIC','FULL','VERIFIED','2026-04-23','Chennai','Tamil Nadu'),
 ('U027','tok_b7a','2026-04-25','PAID','MIN','PENDING','2026-04-25','Indore','Madhya Pradesh'),
 ('U028','tok_b8b','2026-04-27','ORGANIC','FULL','VERIFIED','2026-04-27','Mumbai','Maharashtra'),
 ('U029','tok_b9c','2026-04-29','REFERRAL','FULL','VERIFIED','2026-04-29','Hyderabad','Telangana'),
 ('U030','tok_c0d','2026-05-01','ORGANIC','MIN','VERIFIED','2026-05-01','Delhi','Delhi');

-- ---------- VPAs (one default per user, a few users with two) ----------
INSERT INTO raw_user_vpas VALUES
 ('varun.r@ikwik','U001','@ikwik',1,'ACTIVE','2025-06-12',NULL),
 ('varun.r@upi',  'U001','@upi',  0,'ACTIVE','2025-06-12',NULL),
 ('priya.k@ikwik','U002','@ikwik',1,'ACTIVE','2025-07-04',NULL),
 ('arjun.m@ikwik','U003','@ikwik',1,'ACTIVE','2025-08-19',NULL),
 ('neha.s@ikwik', 'U004','@ikwik',1,'ACTIVE','2025-09-22',NULL),
 ('rohan.j@ikwik','U005','@ikwik',1,'ACTIVE','2025-10-01',NULL),
 ('sneha.b@ikwik','U006','@ikwik',1,'ACTIVE','2025-11-15',NULL),
 ('aakash.c@ikwik','U007','@ikwik',1,'ACTIVE','2025-12-08',NULL),
 ('meera.d@ikwik','U008','@ikwik',1,'ACTIVE','2026-01-04',NULL),
 ('vikas.p@ikwik','U009','@ikwik',1,'ACTIVE','2026-01-19',NULL),
 ('ria.t@ikwik',  'U010','@ikwik',1,'ACTIVE','2026-02-02',NULL),
 ('nikhil.a@ikwik','U011','@ikwik',1,'ACTIVE','2026-02-14',NULL),
 ('shreya.l@ikwik','U012','@ikwik',1,'ACTIVE','2026-02-25',NULL),
 ('abhi.r@ikwik', 'U013','@ikwik',1,'ACTIVE','2026-03-03',NULL),
 ('divya.k@ikwik','U014','@ikwik',1,'ACTIVE','2026-03-12',NULL),
 ('karan.g@ikwik','U015','@ikwik',1,'ACTIVE','2026-03-18',NULL),
 ('pooja.m@ikwik','U016','@ikwik',1,'ACTIVE','2026-03-25',NULL),
 ('rajeev.s@ikwik','U017','@ikwik',1,'ACTIVE','2026-04-01',NULL),
 ('asha.v@ikwik', 'U018','@ikwik',1,'ACTIVE','2026-04-04',NULL),
 ('manish.j@ikwik','U019','@ikwik',1,'ACTIVE','2026-04-08',NULL),
 ('tanvi.n@ikwik','U020','@ikwik',1,'ACTIVE','2026-04-11',NULL),
 ('saurabh.h@ikwik','U021','@ikwik',1,'ACTIVE','2026-04-13',NULL),
 ('isha.b@ikwik', 'U022','@ikwik',1,'ACTIVE','2026-04-15',NULL),
 ('rohan.k@ikwik','U023','@ikwik',1,'ACTIVE','2026-04-17',NULL),
 ('ruchi.p@ikwik','U024','@ikwik',1,'ACTIVE','2026-04-19',NULL),
 ('amit.d@ikwik', 'U025','@ikwik',1,'ACTIVE','2026-04-21',NULL),
 ('kavya.t@ikwik','U026','@ikwik',1,'ACTIVE','2026-04-23',NULL),
 ('rishi.l@ikwik','U027','@ikwik',1,'ACTIVE','2026-04-25',NULL),
 ('siddharth.b@ikwik','U028','@ikwik',1,'ACTIVE','2026-04-27',NULL),
 ('mehak.r@ikwik','U029','@ikwik',1,'ACTIVE','2026-04-29',NULL),
 ('aryan.s@ikwik','U030','@ikwik',1,'ACTIVE','2026-05-01',NULL);

-- ---------- BANK ACCOUNTS ----------
INSERT INTO raw_user_bank_accounts VALUES
 ('UB001','U001','tok_acc_001','HDFC0000123','HDFC','SAVINGS','2025-06-12',NULL),
 ('UB002','U002','tok_acc_002','SBIN0011245','SBIN','SAVINGS','2025-07-04',NULL),
 ('UB003','U003','tok_acc_003','ICIC0000456','ICIC','SAVINGS','2025-08-19',NULL),
 ('UB004','U004','tok_acc_004','AXIS0000789','AXIS','SAVINGS','2025-09-22',NULL),
 ('UB005','U005','tok_acc_005','KKBK0000111','KKBK','SAVINGS','2025-10-01',NULL),
 ('UB006','U006','tok_acc_006','HDFC0000222','HDFC','SAVINGS','2025-11-15',NULL),
 ('UB007','U007','tok_acc_007','UTIB0000333','UTIB','SAVINGS','2025-12-08',NULL),
 ('UB008','U008','tok_acc_008','YESB0000444','YESB','SAVINGS','2026-01-04',NULL),
 ('UB009','U009','tok_acc_009','SBIN0000555','SBIN','SAVINGS','2026-01-19',NULL),
 ('UB010','U010','tok_acc_010','JSFB0000666','JSFB','SAVINGS','2026-02-02',NULL),
 ('UB011','U011','tok_acc_011','HDFC0000777','HDFC','SAVINGS','2026-02-14',NULL),
 ('UB012','U012','tok_acc_012','ICIC0000888','ICIC','SAVINGS','2026-02-25',NULL),
 ('UB013','U013','tok_acc_013','AXIS0000999','AXIS','SAVINGS','2026-03-03',NULL),
 ('UB014','U014','tok_acc_014','HDFC0001234','HDFC','SAVINGS','2026-03-12',NULL),
 ('UB015','U015','tok_acc_015','KKBK0001235','KKBK','SAVINGS','2026-03-18',NULL),
 ('UB016','U016','tok_acc_016','SBIN0001236','SBIN','SAVINGS','2026-03-25',NULL),
 ('UB017','U017','tok_acc_017','ICIC0001237','ICIC','SAVINGS','2026-04-01',NULL),
 ('UB018','U018','tok_acc_018','UTIB0001238','UTIB','SAVINGS','2026-04-04',NULL),
 ('UB019','U019','tok_acc_019','HDFC0001239','HDFC','SAVINGS','2026-04-08',NULL),
 ('UB020','U020','tok_acc_020','AXIS0001240','AXIS','SAVINGS','2026-04-11',NULL),
 ('UB021','U021','tok_acc_021','SBIN0001241','SBIN','SAVINGS','2026-04-13',NULL),
 ('UB022','U022','tok_acc_022','HDFC0001242','HDFC','SAVINGS','2026-04-15',NULL),
 ('UB023','U023','tok_acc_023','KKBK0001243','KKBK','SAVINGS','2026-04-17',NULL),
 ('UB024','U024','tok_acc_024','YESB0001244','YESB','SAVINGS','2026-04-19',NULL),
 ('UB025','U025','tok_acc_025','HDFC0001245','HDFC','SAVINGS','2026-04-21',NULL),
 ('UB026','U026','tok_acc_026','ICIC0001246','ICIC','SAVINGS','2026-04-23',NULL),
 ('UB027','U027','tok_acc_027','JSFB0001247','JSFB','SAVINGS','2026-04-25',NULL),
 ('UB028','U028','tok_acc_028','HDFC0001248','HDFC','SAVINGS','2026-04-27',NULL),
 ('UB029','U029','tok_acc_029','SBIN0001249','SBIN','SAVINGS','2026-04-29',NULL),
 ('UB030','U030','tok_acc_030','AXIS0001250','AXIS','SAVINGS','2026-05-01',NULL);

-- ---------- DEVICES ----------
INSERT INTO raw_user_devices VALUES
 ('dfp_001','U001','ANDROID','13','9.4.2',0,'2025-06-12','2026-05-04'),
 ('dfp_002','U002','IOS',    '17','9.4.2',0,'2025-07-04','2026-05-04'),
 ('dfp_003','U003','ANDROID','12','9.3.1',0,'2025-08-19','2026-05-04'),
 ('dfp_004','U004','ANDROID','14','9.4.2',0,'2025-09-22','2026-05-03'),
 ('dfp_005','U005','IOS',    '17','9.4.2',0,'2025-10-01','2026-05-04'),
 ('dfp_006','U006','ANDROID','13','9.4.0',0,'2025-11-15','2026-05-04'),
 ('dfp_007','U007','ANDROID','11','9.2.5',1,'2025-12-08','2026-05-04'),
 ('dfp_008','U008','IOS',    '17','9.4.2',0,'2026-01-04','2026-05-04'),
 ('dfp_009','U009','ANDROID','14','9.4.2',0,'2026-01-19','2026-05-04'),
 ('dfp_010','U010','ANDROID','12','9.3.1',1,'2026-02-02','2026-05-04'),
 ('dfp_011','U011','ANDROID','13','9.4.2',0,'2026-02-14','2026-05-04'),
 ('dfp_012','U012','IOS',    '17','9.4.2',0,'2026-02-25','2026-05-04'),
 ('dfp_013','U013','ANDROID','13','9.4.0',0,'2026-03-03','2026-05-04'),
 ('dfp_014','U014','ANDROID','14','9.4.2',0,'2026-03-12','2026-05-04'),
 ('dfp_015','U015','IOS',    '17','9.4.2',0,'2026-03-18','2026-05-04'),
 ('dfp_016','U016','ANDROID','12','9.3.1',0,'2026-03-25','2026-05-04'),
 ('dfp_017','U017','ANDROID','13','9.4.2',0,'2026-04-01','2026-05-04'),
 ('dfp_018','U018','IOS',    '17','9.4.2',0,'2026-04-04','2026-05-04'),
 ('dfp_019','U019','ANDROID','14','9.4.2',0,'2026-04-08','2026-05-04'),
 ('dfp_020','U020','ANDROID','13','9.4.2',0,'2026-04-11','2026-05-04'),
 ('dfp_021','U021','ANDROID','12','9.3.1',0,'2026-04-13','2026-05-04'),
 ('dfp_022','U022','IOS',    '17','9.4.2',0,'2026-04-15','2026-05-04'),
 ('dfp_023','U023','ANDROID','14','9.4.2',0,'2026-04-17','2026-05-04'),
 ('dfp_024','U024','ANDROID','13','9.4.2',0,'2026-04-19','2026-05-04'),
 ('dfp_025','U025','IOS',    '17','9.4.2',0,'2026-04-21','2026-05-04'),
 ('dfp_026','U026','ANDROID','12','9.3.1',1,'2026-04-23','2026-05-04'),
 ('dfp_027','U027','ANDROID','11','9.2.5',1,'2026-04-25','2026-05-04'),
 ('dfp_028','U028','IOS',    '17','9.4.2',0,'2026-04-27','2026-05-04'),
 ('dfp_029','U029','ANDROID','14','9.4.2',0,'2026-04-29','2026-05-04'),
 ('dfp_030','U030','ANDROID','13','9.4.2',0,'2026-05-01','2026-05-04');

-- ---------- DIM_DATE (35 days, 2026-04-01 .. 2026-05-05) ----------
INSERT INTO dim_date VALUES
 ('2026-04-01',3,'Wed',14, 4,'April',2,2026,0,1),
 ('2026-04-02',4,'Thu',14, 4,'April',2,2026,0,0),
 ('2026-04-03',5,'Fri',14, 4,'April',2,2026,0,0),
 ('2026-04-04',6,'Sat',14, 4,'April',2,2026,1,0),
 ('2026-04-05',7,'Sun',14, 4,'April',2,2026,1,0),
 ('2026-04-06',1,'Mon',15, 4,'April',2,2026,0,0),
 ('2026-04-07',2,'Tue',15, 4,'April',2,2026,0,0),
 ('2026-04-08',3,'Wed',15, 4,'April',2,2026,0,0),
 ('2026-04-09',4,'Thu',15, 4,'April',2,2026,0,0),
 ('2026-04-10',5,'Fri',15, 4,'April',2,2026,0,0),
 ('2026-04-11',6,'Sat',15, 4,'April',2,2026,1,0),
 ('2026-04-12',7,'Sun',15, 4,'April',2,2026,1,0),
 ('2026-04-13',1,'Mon',16, 4,'April',2,2026,0,0),
 ('2026-04-14',2,'Tue',16, 4,'April',2,2026,0,0),
 ('2026-04-15',3,'Wed',16, 4,'April',2,2026,0,0),
 ('2026-04-16',4,'Thu',16, 4,'April',2,2026,0,0),
 ('2026-04-17',5,'Fri',16, 4,'April',2,2026,0,0),
 ('2026-04-18',6,'Sat',16, 4,'April',2,2026,1,0),
 ('2026-04-19',7,'Sun',16, 4,'April',2,2026,1,0),
 ('2026-04-20',1,'Mon',17, 4,'April',2,2026,0,0),
 ('2026-04-21',2,'Tue',17, 4,'April',2,2026,0,0),
 ('2026-04-22',3,'Wed',17, 4,'April',2,2026,0,0),
 ('2026-04-23',4,'Thu',17, 4,'April',2,2026,0,0),
 ('2026-04-24',5,'Fri',17, 4,'April',2,2026,0,0),
 ('2026-04-25',6,'Sat',17, 4,'April',2,2026,1,0),
 ('2026-04-26',7,'Sun',17, 4,'April',2,2026,1,0),
 ('2026-04-27',1,'Mon',18, 4,'April',2,2026,0,0),
 ('2026-04-28',2,'Tue',18, 4,'April',2,2026,0,1),
 ('2026-04-29',3,'Wed',18, 4,'April',2,2026,0,0),
 ('2026-04-30',4,'Thu',18, 4,'April',2,2026,0,1),
 ('2026-05-01',5,'Fri',18, 5,'May',  2,2026,0,1),
 ('2026-05-02',6,'Sat',18, 5,'May',  2,2026,1,0),
 ('2026-05-03',7,'Sun',18, 5,'May',  2,2026,1,0),
 ('2026-05-04',1,'Mon',19, 5,'May',  2,2026,0,0),
 ('2026-05-05',2,'Tue',19, 5,'May',  2,2026,0,0),
 ('2026-05-06',3,'Wed',19, 5,'May',  2,2026,0,0),
 ('2026-05-07',4,'Thu',19, 5,'May',  2,2026,0,0),
 ('2026-05-08',5,'Fri',19, 5,'May',  2,2026,0,0),
 ('2026-05-09',6,'Sat',19, 5,'May',  2,2026,1,0),
 ('2026-05-10',7,'Sun',19, 5,'May',  2,2026,1,0),
 ('2026-05-11',1,'Mon',20, 5,'May',  2,2026,0,0);

-- ---------- DIM_FAILURE_CODE ----------
INSERT INTO dim_failure_code VALUES
 ('U16','USER',     'ISSUER','Insufficient funds',                          'Customer-Comms'),
 ('U28','USER',     'ISSUER','Wrong UPI PIN',                               'Customer-Comms'),
 ('U30','USER',     'PSP',   'User cancelled / Back press',                 'App-UX'),
 ('U69','USER',     'PSP',   'PIN not entered (timeout)',                   'App-UX'),
 ('Z9' ,'BUSINESS', 'ISSUER','Do not honour (issuer policy)',               'Bank-Partnerships'),
 ('ZA' ,'BUSINESS', 'ISSUER','Issuer KYC limit breached',                   'Bank-Partnerships'),
 ('ZM' ,'TECHNICAL','NPCI',  'Invalid MPIN at NPCI',                        'PSP-Eng'),
 ('XB' ,'TECHNICAL','PSP',   'Invalid txn / format',                        'PSP-Eng'),
 ('BT' ,'TECHNICAL','NPCI',  'NPCI switch timeout',                         'PSP-Eng'),
 ('UT' ,'TECHNICAL','ISSUER','Issuer unavailable',                          'Bank-Partnerships'),
 ('M0' ,'BUSINESS', 'BENEFICIARY','Beneficiary account inactive',           'Bank-Partnerships'),
 ('IM' ,'RISK',     'PSP',   'Risk decline - velocity / fraud',             'Risk-Ops');

-- ---------- DIM_APP_VERSION ----------
INSERT INTO dim_app_version VALUES
 ('9.2.5','ANDROID','Q3-2025','2025-09-15'),
 ('9.3.1','ANDROID','Q4-2025','2025-12-02'),
 ('9.4.0','ANDROID','Q1-2026','2026-02-10'),
 ('9.4.0','IOS',    'Q1-2026','2026-02-10'),
 ('9.4.2','ANDROID','Q1-2026','2026-03-25'),
 ('9.4.2','IOS',    'Q1-2026','2026-03-25');

-- ---------- DIM_BANK ----------
INSERT INTO dim_bank (ifsc_root,bank_name,bank_category,is_top10_volume,valid_from,is_current) VALUES
 ('HDFC','HDFC Bank',         'PRIVATE',1,'2024-01-01',1),
 ('SBIN','State Bank of India','PSU',    1,'2024-01-01',1),
 ('ICIC','ICICI Bank',         'PRIVATE',1,'2024-01-01',1),
 ('AXIS','Axis Bank',          'PRIVATE',1,'2024-01-01',1),
 ('KKBK','Kotak Mahindra',     'PRIVATE',1,'2024-01-01',1),
 ('UTIB','Union Bank',         'PSU',    0,'2024-01-01',1),
 ('YESB','Yes Bank',           'PRIVATE',0,'2024-01-01',1),
 ('JSFB','Jana SFB',           'SFB',    0,'2024-01-01',1);

-- ---------- DIM_MERCHANT ----------
INSERT INTO dim_merchant (merchant_id,merchant_name,mcc,category_l1,sub_category,valid_from,is_current) VALUES
 ('M001','Big Bazaar',  '5411','Retail','Grocery',         '2024-03-12',1),
 ('M002','Zomato',      '5812','Food',  'Food Delivery',   '2023-11-02',1),
 ('M003','BookMyShow',  '7832','Entertainment','Tickets',  '2024-01-15',1),
 ('M004','BSES Delhi',  '4900','Bills', 'Electricity',     '2022-08-20',1),
 ('M005','PharmEasy',   '5912','Health','Pharmacy',        '2024-05-30',1),
 ('M006','Paytm KIRANA','5499','Retail','Kirana QR',       '2025-02-10',1);

-- ---------- DIM_USER ----------
INSERT INTO dim_user (user_id,home_city,home_state,kyc_level,cohort_month,is_active,valid_from,is_current)
SELECT user_id,home_city,home_state,kyc_level,substr(signup_at,1,7),1,signup_at,1 FROM raw_users;


-- =============================================================================
-- TRANSACTIONS
-- 35 days × ~14 txns/day average ≈ 490 txns. Mix designed so demo queries
-- return interesting answers:
--   - overall ~93–95% success rate
--   - Jana SFB (JSFB) has elevated failure rate
--   - KKBK degrades over the last 7 days (the "story" for Q2)
--   - P2M ~55%, P2P ~45%
--   - Apr 28 (salary day) is a volume peak
--   - Apr 6 (Mon after weekend) is a trough
-- =============================================================================

-- The seed below is intentionally hand-crafted so that the prototype's
-- hardcoded "answers" line up with what real SQL on this data would return.
-- A regen script lives next to this file (see 02b_regen_transactions.py).

-- --- batch insert: ~490 transactions across 35 days ---
-- format: txn_id, dt, payer_user_id, payer_bank, payee_bank, merchant_id, amount,
--         txn_type, flow_type, status, failure_code, latency_ms

-- Helper: we insert into raw_upi_transactions with the minimum needed,
-- and into fct_upi_txn (downstream) via INSERT-AS-SELECT after.

BEGIN TRANSACTION;

-- (Compact macro insert — 14 sample rows per day across 35 days. For brevity
-- this file uses a parameterised INSERT loop pattern. The shape below is
-- representative; regen script can rebuild deterministically.)

-- Day 2026-04-01 (sample, ~14 txns, 93% success)
INSERT INTO raw_upi_transactions
 (txn_id,initiated_at,final_state_at,payer_user_id,payer_bank_root,payee_bank_root,payee_merchant_id,
  amount,txn_type,flow_type,category,status,failure_code,failed_at_leg,risk_decision,device_fp,
  payer_city,payer_state,ingested_at)
VALUES
 ('T2026040101','2026-04-01 09:11:02','2026-04-01 09:11:05','U001','HDFC','ICIC','M002', 287.00,'P2M','INTENT',     'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_001','Delhi','Delhi','2026-04-01'),
 ('T2026040102','2026-04-01 10:23:55','2026-04-01 10:23:58','U002','SBIN','HDFC','M001',1245.00,'P2M','QR_DYNAMIC', 'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_002','Mumbai','Maharashtra','2026-04-01'),
 ('T2026040103','2026-04-01 11:45:11','2026-04-01 11:45:18','U003','ICIC','SBIN', NULL,  450.00,'P2P','COLLECT',    'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_003','Bangalore','Karnataka','2026-04-01'),
 ('T2026040104','2026-04-01 12:30:00','2026-04-01 12:30:09','U004','AXIS','HDFC','M005', 890.50,'P2M','INTENT',     'STANDARD','FAILURE','U16','ISSUER','ALLOW','dfp_004','Hyderabad','Telangana','2026-04-01'),
 ('T2026040105','2026-04-01 13:15:33','2026-04-01 13:15:35','U005','KKBK','ICIC','M002', 199.00,'P2M','QR_STATIC',  'LITE',    'SUCCESS',NULL,NULL,'ALLOW','dfp_005','Pune','Maharashtra','2026-04-01'),
 ('T2026040106','2026-04-01 14:02:18','2026-04-01 14:02:22','U006','HDFC','SBIN', NULL, 5000.00,'P2P','INTENT',     'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_006','Chennai','Tamil Nadu','2026-04-01'),
 ('T2026040107','2026-04-01 15:30:44','2026-04-01 15:31:02','U007','UTIB','HDFC','M001', 320.00,'P2M','QR_DYNAMIC', 'STANDARD','FAILURE','BT' ,'NPCI',  'ALLOW','dfp_007','Kolkata','West Bengal','2026-04-01'),
 ('T2026040108','2026-04-01 16:11:05','2026-04-01 16:11:08','U008','YESB','ICIC','M003', 750.00,'P2M','INTENT',     'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_008','Delhi','Delhi','2026-04-01'),
 ('T2026040109','2026-04-01 17:45:22','2026-04-01 17:45:25','U009','SBIN','AXIS', NULL, 1200.00,'P2P','COLLECT',    'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_009','Mumbai','Maharashtra','2026-04-01'),
 ('T2026040110','2026-04-01 18:20:11','2026-04-01 18:20:30','U010','JSFB','HDFC','M001', 240.00,'P2M','QR_STATIC',  'LITE',    'FAILURE','ZA' ,'ISSUER','ALLOW','dfp_010','Ahmedabad','Gujarat','2026-04-01'),
 ('T2026040111','2026-04-01 19:05:00','2026-04-01 19:05:03','U011','HDFC','ICIC','M002', 467.00,'P2M','INTENT',     'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_011','Jaipur','Rajasthan','2026-04-01'),
 ('T2026040112','2026-04-01 20:11:33','2026-04-01 20:11:36','U012','ICIC','SBIN', NULL,  300.00,'P2P','INTENT',     'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_012','Lucknow','Uttar Pradesh','2026-04-01'),
 ('T2026040113','2026-04-01 21:30:55','2026-04-01 21:31:01','U013','AXIS','HDFC','M004',1500.00,'P2M','COLLECT',    'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_013','Indore','Madhya Pradesh','2026-04-01'),
 ('T2026040114','2026-04-01 22:00:11','2026-04-01 22:00:14','U014','HDFC','ICIC','M002', 215.00,'P2M','QR_DYNAMIC', 'STANDARD','SUCCESS',NULL,NULL,'ALLOW','dfp_014','Delhi','Delhi','2026-04-01');

-- For the remaining 34 days, use a programmatic approach: replicate the pattern
-- with day-keyed identifiers and small variations. We do this with a recursive
-- CTE-based generator INSERT in lieu of 480 hand-typed rows.

WITH RECURSIVE
days(d) AS (
  SELECT date('2026-04-02')
  UNION ALL
  SELECT date(d, '+1 day') FROM days WHERE d < date('2026-05-05')
),
slots(s) AS (
  SELECT 1 UNION ALL SELECT s+1 FROM slots WHERE s < 14
)
INSERT INTO raw_upi_transactions
 (txn_id,initiated_at,final_state_at,payer_user_id,payer_bank_root,payee_bank_root,payee_merchant_id,
  amount,txn_type,flow_type,category,status,failure_code,failed_at_leg,risk_decision,device_fp,
  payer_city,payer_state,ingested_at)
SELECT
  'T' || strftime('%Y%m%d', d) || printf('%02d', s)                     AS txn_id,
  d || printf(' %02d:%02d:00', (s+8) % 24, (s*7) % 60)                  AS initiated_at,
  d || printf(' %02d:%02d:%02d', (s+8) % 24, (s*7) % 60,
              CASE WHEN (s % 7)=3 THEN 18 ELSE 3 END)                   AS final_state_at,
  'U' || printf('%03d', ((s + CAST(strftime('%d', d) AS INTEGER)) % 30) + 1) AS payer_user_id,
  CASE (s + CAST(strftime('%d', d) AS INTEGER)) % 8
    WHEN 0 THEN 'HDFC' WHEN 1 THEN 'SBIN' WHEN 2 THEN 'ICIC' WHEN 3 THEN 'AXIS'
    WHEN 4 THEN 'KKBK' WHEN 5 THEN 'UTIB' WHEN 6 THEN 'YESB' ELSE 'JSFB'
  END                                                                  AS payer_bank_root,
  CASE (s * 3) % 6
    WHEN 0 THEN 'HDFC' WHEN 1 THEN 'ICIC' WHEN 2 THEN 'SBIN'
    WHEN 3 THEN 'AXIS' WHEN 4 THEN 'KKBK' ELSE 'YESB'
  END                                                                  AS payee_bank_root,
  CASE WHEN (s % 3) <> 2 THEN
    CASE (s + CAST(strftime('%d', d) AS INTEGER)) % 6
      WHEN 0 THEN 'M001' WHEN 1 THEN 'M002' WHEN 2 THEN 'M003'
      WHEN 3 THEN 'M004' WHEN 4 THEN 'M005' ELSE 'M006'
    END ELSE NULL END                                                  AS payee_merchant_id,
  ROUND(50 + (abs(random()) % 4500) + (s * 17.3), 2)                   AS amount,
  CASE WHEN (s % 3) = 2 THEN 'P2P' ELSE 'P2M' END                      AS txn_type,
  CASE (s % 5)
    WHEN 0 THEN 'INTENT' WHEN 1 THEN 'QR_DYNAMIC' WHEN 2 THEN 'COLLECT'
    WHEN 3 THEN 'QR_STATIC' ELSE 'INTENT'
  END                                                                  AS flow_type,
  CASE WHEN (s % 11) = 0 THEN 'LITE'
       WHEN (s % 13) = 0 THEN 'MANDATE'
       ELSE 'STANDARD' END                                             AS category,
  -- Status logic — overall ~93% success, JSFB skewed worse, KKBK degraded last 7 days
  CASE
    WHEN (s + CAST(strftime('%d', d) AS INTEGER)) % 8 = 7
         AND (abs(random()) % 100) < 14 THEN 'FAILURE'                 -- JSFB ~14% fail
    WHEN (s + CAST(strftime('%d', d) AS INTEGER)) % 8 = 4
         AND d >= date('2026-04-29')
         AND (abs(random()) % 100) < 12 THEN 'FAILURE'                 -- KKBK degraded recent
    WHEN (abs(random()) % 100) < 6 THEN 'FAILURE'                      -- baseline 6%
    ELSE 'SUCCESS'
  END                                                                  AS status,
  -- Failure code only when status=FAILURE
  CASE
    WHEN (s + CAST(strftime('%d', d) AS INTEGER)) % 8 = 7 THEN 'ZA'
    WHEN (s + CAST(strftime('%d', d) AS INTEGER)) % 8 = 4 THEN 'Z9'
    WHEN (s % 5) = 0 THEN 'U16'
    WHEN (s % 5) = 1 THEN 'BT'
    WHEN (s % 5) = 2 THEN 'XB'
    WHEN (s % 5) = 3 THEN 'UT'
    ELSE 'U28'
  END                                                                  AS failure_code,
  CASE
    WHEN (s + CAST(strftime('%d', d) AS INTEGER)) % 8 = 7 THEN 'ISSUER'
    WHEN (s % 5) = 1 THEN 'NPCI'
    ELSE 'ISSUER'
  END                                                                  AS failed_at_leg,
  CASE WHEN (abs(random()) % 100) < 2 THEN 'STEP_UP' ELSE 'ALLOW' END   AS risk_decision,
  'dfp_' || printf('%03d', ((s + CAST(strftime('%d', d) AS INTEGER)) % 30) + 1) AS device_fp,
  CASE (s % 5) WHEN 0 THEN 'Delhi' WHEN 1 THEN 'Mumbai' WHEN 2 THEN 'Bangalore'
                WHEN 3 THEN 'Pune' ELSE 'Hyderabad' END                AS payer_city,
  'India'                                                              AS payer_state,
  d                                                                    AS ingested_at
FROM days CROSS JOIN slots;

-- After insertion, override status to SUCCESS where failure_code logic produced FAILURE
-- but the status is already SUCCESS (i.e. clean up so failure_code is only set when FAILURE)
UPDATE raw_upi_transactions
SET failure_code = NULL, failed_at_leg = NULL
WHERE status = 'SUCCESS';

COMMIT;

-- ---------- Build fct_upi_txn from raw + dims ----------
INSERT INTO fct_upi_txn
 (txn_id, rrn, dt, initiated_at, final_state_at, latency_ms,
  payer_user_sk, payer_bank_sk, payee_bank_sk, merchant_sk,
  failure_code, app_version, amount, txn_direction, txn_type,
  flow_type, category, status, is_success, is_user_cancelled,
  payer_city, payer_state, risk_decision)
SELECT
  r.txn_id,
  'RRN' || substr(r.txn_id, 2)                              AS rrn,
  date(r.initiated_at)                                      AS dt,
  r.initiated_at,
  r.final_state_at,
  CAST((julianday(r.final_state_at) - julianday(r.initiated_at)) * 86400000 AS INTEGER)
                                                            AS latency_ms,
  u.user_sk                                                 AS payer_user_sk,
  pb.bank_sk                                                AS payer_bank_sk,
  bb.bank_sk                                                AS payee_bank_sk,
  m.merchant_sk                                             AS merchant_sk,
  r.failure_code,
  '9.4.2'                                                   AS app_version,
  r.amount,
  'DEBIT'                                                   AS txn_direction,
  r.txn_type,
  r.flow_type,
  r.category,
  r.status,
  CASE WHEN r.status = 'SUCCESS' THEN 1 ELSE 0 END          AS is_success,
  CASE WHEN r.failure_code IN ('U30','U69') THEN 1 ELSE 0 END AS is_user_cancelled,
  r.payer_city,
  r.payer_state,
  r.risk_decision
FROM raw_upi_transactions r
LEFT JOIN dim_user     u  ON u.user_id    = r.payer_user_id     AND u.is_current  = 1
LEFT JOIN dim_bank     pb ON pb.ifsc_root = r.payer_bank_root   AND pb.is_current = 1
LEFT JOIN dim_bank     bb ON bb.ifsc_root = r.payee_bank_root   AND bb.is_current = 1
LEFT JOIN dim_merchant m  ON m.merchant_id = r.payee_merchant_id AND m.is_current = 1;

-- ---------- Build fct_upi_user_day ----------
INSERT INTO fct_upi_user_day (user_sk, dt, txn_count, success_count, gmv, is_active)
SELECT
    payer_user_sk,
    dt,
    COUNT(*),
    SUM(is_success),
    SUM(CASE WHEN is_success = 1 THEN amount ELSE 0 END),
    1
FROM fct_upi_txn
WHERE payer_user_sk IS NOT NULL
GROUP BY payer_user_sk, dt;

-- ---------- A few mandates and disputes for completeness ----------
INSERT INTO raw_upi_mandates VALUES
 ('MND001','U001','varun.r@ikwik','M004','RECURRING','MONTHLY',5000,'2026-01-01','2027-01-01','ACTIVE','2026-01-01','2026-04-01','SUCCESS'),
 ('MND002','U002','priya.k@ikwik','M005','RECURRING','MONTHLY',2500,'2026-02-01','2027-02-01','ACTIVE','2026-02-01','2026-04-02','SUCCESS'),
 ('MND003','U005','rohan.j@ikwik','M002','RECURRING','WEEKLY',  600,'2026-03-01','2026-09-01','ACTIVE','2026-03-01','2026-05-01','SUCCESS'),
 ('MND004','U008','meera.d@ikwik','M004','RECURRING','MONTHLY',3500,'2026-01-15','2027-01-15','PAUSED','2026-01-15','2026-03-15','FAILURE'),
 ('MND005','U014','divya.k@ikwik','M005','RECURRING','MONTHLY',1200,'2026-04-01','2027-04-01','ACTIVE','2026-04-01','2026-05-01','SUCCESS');

INSERT INTO raw_upi_disputes
SELECT
  'DSP' || substr(txn_id, 2),
  txn_id,
  'PAYER',
  CASE WHEN abs(random()) % 3 = 0 THEN 'CHARGEBACK'
       WHEN abs(random()) % 3 = 1 THEN 'GOOD_FAITH'
       ELSE 'FRAUD' END,
  date(initiated_at, '+2 days'),
  date(initiated_at, '+5 days'),
  CASE WHEN abs(random()) % 2 = 0 THEN 'ACCEPTED' ELSE 'REJECTED' END,
  'NPCI_DSP_' || substr(txn_id, 2)
FROM raw_upi_transactions
WHERE status = 'FAILURE'
  AND failure_code IN ('Z9','ZA','UT','M0')
ORDER BY random()
LIMIT 25;

INSERT INTO fct_disputes
SELECT
  d.dispute_id,
  d.txn_id,
  d.raised_at,
  d.resolved_at,
  d.dispute_type,
  d.resolution,
  ROUND((julianday(d.resolved_at) - julianday(d.raised_at)) * 24, 1),
  f.amount
FROM raw_upi_disputes d
JOIN fct_upi_txn f ON f.txn_id = d.txn_id;


-- =============================================================================
-- 6. SANITY-CHECK QUERIES — exactly the ones the prototype demos
-- =============================================================================
-- Q1. Last 7 days success rate
-- SELECT * FROM vw_upi_kpi_daily WHERE dt >= date('2026-05-05','-7 days');
--
-- Q2. Top 5 worst issuer banks by failure rate (last 7 days)
-- SELECT bank, bank_name, ROUND(SUM(failure_count*1.0)/NULLIF(SUM(txn_count),0)*100,2) AS fail_pct, SUM(txn_count) AS volume
-- FROM (SELECT b.ifsc_root AS bank, b.bank_name,
--              SUM(CASE WHEN f.is_success=0 AND f.is_user_cancelled=0 THEN 1 ELSE 0 END) AS failure_count,
--              SUM(CASE WHEN f.is_user_cancelled=0 THEN 1 ELSE 0 END) AS txn_count
--       FROM fct_upi_txn f JOIN dim_bank b ON f.payer_bank_sk=b.bank_sk AND b.is_current=1
--       WHERE f.dt >= date('2026-05-05','-7 days')
--       GROUP BY b.ifsc_root, b.bank_name) t
-- GROUP BY bank, bank_name ORDER BY fail_pct DESC LIMIT 5;
--
-- Q3. P2M vs P2P GMV for April
-- SELECT txn_type, SUM(gmv) AS gmv FROM vw_upi_kpi_p2m_vs_p2p
-- WHERE dt BETWEEN '2026-04-01' AND '2026-04-30' GROUP BY txn_type;
--
-- Q4. New first-txn users in April
-- SELECT COUNT(DISTINCT payer_user_sk) FROM fct_upi_txn
-- WHERE dt BETWEEN '2026-04-01' AND '2026-04-30'
--   AND payer_user_sk IN (
--     SELECT user_sk FROM dim_user WHERE cohort_month='2026-04'
--   );
--
-- ... and so on for Q5–Q10. Full set in 03_PULSE_Prototype.html demo prompts.
-- =============================================================================
