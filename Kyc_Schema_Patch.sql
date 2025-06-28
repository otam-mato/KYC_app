-- ░░░ KYC Platform – Initial Schema ░░░
-- Author: me  |  Creates all tables, enums, PK/FK relations and indexes
-- Compatible with PostgreSQL ≥ 12.  Run in an empty database or inside a transaction.

/*───────────────────────────── 1. Enum types ─────────────────────────────*/

CREATE TYPE reg_type_enum AS ENUM ('GDC', 'NMC', 'GMC', 'GPC');

CREATE TYPE id_doc_status_enum AS ENUM (
  'NEW',        -- uploaded, awaiting OCR
  'OCR_DONE',   -- parsed by Textract
  'VERIFIED',   -- ID accepted as genuine
  'REJECTED',   -- failed manual or automatic check
  'EXPIRED'     -- past expiry_date (handled by cron)
);

CREATE TYPE user_status_enum AS ENUM ('NEW', 'PENDING', 'VERIFIED', 'REVIEW', 'REJECTED');

CREATE TYPE kyc_decision_enum AS ENUM ('PASS', 'FAIL', 'MANUAL_REVIEW');

/*───────────────────────────── 2. Tables ────────────────────────────────*/

-- Users (one row per account / KYC subject)
CREATE TABLE users (
  id           BIGSERIAL PRIMARY KEY,
  email        VARCHAR(254) NOT NULL UNIQUE,
  reg_no       VARCHAR(50),
  reg_type     reg_type_enum,
  status       user_status_enum DEFAULT 'NEW' NOT NULL,
  created_at   TIMESTAMPTZ     DEFAULT NOW() NOT NULL
);

-- Original ID document metadata + file pointer
CREATE TABLE id_documents (
  id              BIGSERIAL PRIMARY KEY,
  user_id         BIGINT REFERENCES users(id) ON DELETE CASCADE,
  s3_key_original TEXT    NOT NULL,
  doc_type        VARCHAR(40),
  status          id_doc_status_enum DEFAULT 'NEW' NOT NULL,
  expiry_date     DATE,
  created_at      TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Raw selfie upload metadata
CREATE TABLE selfies (
  id         BIGSERIAL PRIMARY KEY,
  user_id    BIGINT REFERENCES users(id) ON DELETE CASCADE,
  s3_key     TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Textract OCR + parsed fields
CREATE TABLE doc_scans (
  id              BIGSERIAL PRIMARY KEY,
  id_document_id  BIGINT REFERENCES id_documents(id) ON DELETE CASCADE,
  textract_json   JSONB NOT NULL,
  parsed_name     TEXT,
  parsed_dob      DATE,
  parsed_expiry   DATE,
  parser_version  VARCHAR(40),
  completed_at    TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Rekognition face comparison + liveness results
CREATE TABLE face_checks (
  id              BIGSERIAL PRIMARY KEY,
  user_id         BIGINT REFERENCES users(id)        ON DELETE CASCADE,
  selfie_id       BIGINT REFERENCES selfies(id)      ON DELETE CASCADE,
  id_document_id  BIGINT REFERENCES id_documents(id) ON DELETE CASCADE,
  match_score     NUMERIC,
  liveness_pass   BOOLEAN,
  rekognition_job_id VARCHAR(100),
  completed_at    TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Register (Apify) lookup results
CREATE TABLE reg_checks (
  id              BIGSERIAL PRIMARY KEY,
  user_id         BIGINT REFERENCES users(id) ON DELETE CASCADE,
  snapshot_date   DATE,
  matched_name    BOOLEAN,
  matched_status  BOOLEAN,
  raw_response_json JSONB,
  checked_at      TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Final KYC verdict (one row per user; updated only by decision process)
CREATE TABLE kyc_decisions (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT REFERENCES users(id) ON DELETE CASCADE,
  decision    kyc_decision_enum NOT NULL,
  reasons     TEXT[] DEFAULT ARRAY[]::TEXT[],
  decided_at  TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  UNIQUE (user_id)  -- idempotency for decision_lambda
);

/*───────────────────────────── 3. Indexes ───────────────────────────────*/

-- Speed up fan‑in look‑ups for decision_lambda
CREATE INDEX idx_face_checks_user_id  ON face_checks(user_id);
CREATE INDEX idx_reg_checks_user_id   ON reg_checks(user_id);

-- Helpful for analytics / duplicates
CREATE INDEX idx_id_documents_status  ON id_documents(status);
CREATE INDEX idx_users_status         ON users(status);

/*───────────────────────────── 4. End ───────────────────────────────────*/

-- All done ✔︎
