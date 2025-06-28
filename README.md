# KYC Platform

End‑to‑end Know‑Your‑Customer (KYC) flow built on **AWS Lambda, SQS, Textract, Rekognition, RDS (PostgreSQL)** and **Apify**.  This repository contains:

* Live architecture and data‑flow diagrams (Mermaid)
* A step‑by‑step processing table with example payloads
* Patch SQL to bring the schema in line with the flow

> GitHub renders Mermaid automatically – just open this README and the graphs will paint themselves.

---

## 📁 Quick Links

| Artifact                          | File                                                 |
| --------------------------------- | ---------------------------------------------------- |
| Process flow table (enum‑aligned) | [`kyc_flow_docs.md`](./kyc_flow_docs.md)             |
| Schema patch SQL                  | [`Kyc Schema Patch.sql`](./Kyc%20Schema%20Patch.sql) |

---

## 1  High‑Level Component Diagram

```mermaid
%%  KYC platform – component diagram (simplified)
graph TD
  subgraph "External Actors"
    User["User / Browser"]
    CSUI["CS Review UI"]
  end

  subgraph "KYC Platform (AWS account)"
    S3[(S3: kyc-raw/...)]
    FaceQ[[face-match SQS]]
    RegReqQ[[reg-request SQS]]
    RegRespQ[[reg-check-ingest SQS]]
    DecQ[[decision SQS]]

    DocScan[doc_scan_lambda]
    ReqMaker[reg_request_lambda]
    FaceMatch[face_match_lambda]
    RegCheck[reg_check_lambda]
    Decision[decision_lambda]
    Expiry[expiry_reminder_lambda]

    DB[(RDS PostgreSQL)]
  end

  subgraph "SQL02 On‑prem"
    OnPrem[onprem_upload_service]
    DataSync[AWS DataSync Agent]
  end

  subgraph "Registers / Apify"
    ApifyGMC["GMC Scraper"]
  end

  subgraph "AWS AI"
    Textract[(Textract)]
    Rekog[(Rekognition)]
  end

  User --> OnPrem --> DataSync --> S3
  S3 --> DocScan
  DocScan -.-> Textract -.-> DocScan
  DocScan --> FaceQ & RegReqQ
  FaceQ --> FaceMatch -.-> Rekog -.-> FaceMatch --> DecQ
  RegReqQ --> ReqMaker --> ApifyGMC --> RegRespQ --> RegCheck --> DecQ
  DecQ --> Decision --> DB

  classDef lambda fill:#004b76,stroke:#fff,color:#fff;
  class DocScan,ReqMaker,FaceMatch,RegCheck,Decision,Expiry lambda;
```

---

## 2  Detailed Flow Diagram (with AI round‑trips & fan‑in queue)

```mermaid
%%  KYC flow – full round‑trip AI calls + clarified SNS name
<REPLACE_WITH_FINAL_FLOW_DIAGRAM_CODE>
```

*The `<REPLACE_WITH_FINAL_FLOW_DIAGRAM_CODE>` placeholder is replaced in the actual file with the full Mermaid code from the latest flow diagram (kept identical to* **kyc\_flow\_docs.md** *to avoid drift).*

---

## 3  Process Step Descriptions (Enum-Aligned)

<details>
<summary>Click to expand step‑by‑step table</summary>

| Step   | Trigger / Source                        | Service                  | Action                            | DB Writes                                                       | Example Columns                                                                                                        | Next                                  |
| ------ | --------------------------------------- | ------------------------ | --------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| **0**  | User uploads ID & selfie → on-prem → S3 | `onprem_upload_service`  | Accept files, create user/doc     | `users` INSERT<br>`id_documents` INSERT (`status='NEW'`)        | - `email = dr.jane@example.com`<br>- `reg_no = 6143219`<br>- `status = PENDING`<br>- `doc_type = passport`             | *(none)*                              |
| **1**  | `S3:ObjectCreated` event                | `doc_scan_lambda`        | Textract OCR, parse metadata      | `doc_scans` INSERT<br>`selfies` INSERT<br>`id_documents` UPDATE | - `parsed_name = JANE ANN DOE`<br>- `parsed_dob = 1985-02-14`<br>- `expiry_date = 2032-05-01`<br>- `status = OCR_DONE` | `face-match` SQS<br>`reg-request` SQS |
| **2**  | SQS: face-match                         | `face_match_lambda`      | Rekognition face + liveness check | `face_checks` INSERT                                            | - `match_score = 0.93`<br>- `liveness_pass = true`                                                                     | `decision` SQS                        |
| **3**  | SQS: reg-request                        | `reg_request_lambda`     | Call Apify scraper (async)        | —                                                               | —                                                                                                                      | *(wait Apify)*                        |
| **3a** | Apify returns result                    | *(Apify)*                | Publish response to SQS           | —                                                               | —                                                                                                                      | `reg-check-ingest` SQS                |
| **3b** | SQS: reg-check-ingest                   | `reg_check_lambda`       | Store register results            | `reg_checks` INSERT                                             | - `matched_name = true`<br>- `matched_status = true`                                                                   | `decision` SQS                        |
| **4**  | SQS: decision                           | `decision_lambda`        | Aggregate and decide KYC result   | `kyc_decisions` INSERT<br>`users` UPDATE                        | - `decision = PASS`<br>- `status = VERIFIED`                                                                           | SNS / Email                           |
| **5**  | Manual override                         | —                        | CS approves / rejects             | `kyc_decisions` UPDATE<br>`users` UPDATE                        | —                                                                                                                      | —                                     |
| **6**  | Weekly CloudWatch Event                 | `expiry_reminder_lambda` | Notify about expiring IDs         | *(read-only)*                                                   | - IDs within 90/30/7 days                                                                                              | Notify topic                          |

</details>

---

## 4  Entity‑Relationship Diagram

```mermaid
erDiagram
  users {
    BIGSERIAL id PK
    VARCHAR email
    VARCHAR reg_no
    reg_type_enum reg_type
    user_status_enum status
    TIMESTAMPTZ created_at
  }

  id_documents {
    BIGSERIAL id PK
    BIGINT user_id FK
    TEXT s3_key_original
    VARCHAR doc_type
    id_doc_status_enum status
    DATE expiry_date
    TIMESTAMPTZ created_at
  }

  selfies {
    BIGSERIAL id PK
    BIGINT user_id FK
    TEXT s3_key
    TIMESTAMPTZ created_at
  }

  doc_scans {
    BIGSERIAL id PK
    BIGINT id_document_id FK
    JSONB textract_json
    TEXT parsed_name
    DATE parsed_dob
    DATE parsed_expiry
    VARCHAR parser_version
    TIMESTAMPTZ completed_at
  }

  face_checks {
    BIGSERIAL id PK
    BIGINT user_id FK
    BIGINT selfie_id FK
    BIGINT id_document_id FK
    NUMERIC match_score
    BOOLEAN liveness_pass
    VARCHAR rekognition_job_id
    TIMESTAMPTZ completed_at
  }

  reg_checks {
    BIGSERIAL id PK
    BIGINT user_id FK
    DATE snapshot_date
    BOOLEAN matched_name
    BOOLEAN matched_status
    JSONB raw_response_json
    TIMESTAMPTZ checked_at
  }

  kyc_decisions {
    BIGSERIAL id PK
    BIGINT user_id FK
    kyc_decision_enum decision
    TEXT[] reasons
    TIMESTAMPTZ decided_at
  }

  users ||--o{ id_documents
  users ||--o{ selfies
  users ||--o{ face_checks
  users ||--o{ reg_checks
  users ||--o{ kyc_decisions
  id_documents ||--o{ doc_scans
  id_documents ||--o{ face_checks
  selfies ||--o{ face_checks
```

---

### Running Locally

```bash
psql $DB_URL -f "Kyc Schema Patch.sql"
```

---

### Contributing

PRs welcome – please update diagrams + docs if queue names, enum values, or DB tables change.
