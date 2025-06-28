# KYC Platform

End‑to‑end Know‑Your‑Customer (KYC) flow built on **AWS Lambda, SQS, Textract, Rekognition, RDS (PostgreSQL)** and **Apify**.  This repository contains:

* Live architecture and data‑flow diagrams
* A step‑by‑step processing table with example payloads
* Patch SQL to bring the schema in line with the flow

---

## 📑 Quick Links

| Artifact                          | File                                                 |
| --------------------------------- | ---------------------------------------------------- |
| Process flow table (enum‑aligned) | [`kyc_flow_docs.md`](./kyc_flow_docs.md)             |
| Schema patch SQL                  | [`Kyc Schema Patch.sql`](./Kyc%20Schema%20Patch.sql) |

---

## 1  High‑Level Component Diagram

```mermaid
%%  KYC platform – component diagram 
graph TD

    %% ─────────  EXTERNAL ACTORS  ─────────
    subgraph "External Actors"
        User["User / Browser"]
        CSUI["CS Review UI"]
    end

    %% ─────────  AWS KYC PLATFORM  ───────
    subgraph "KYC Platform (AWS account)"
        direction TB

        S3[(S3 Bucket<br/>kyc-raw/…)]:::store

        FaceQ[[face-match SQS]]:::queue
        RegReqQ[[reg-request SQS]]:::queue
        RegRespQ[[reg-check-ingest SQS]]:::queue
        DecQ[[decision SQS]]:::queue

        DocScan[[doc_scan_lambda]]:::lambda
        ReqMaker[[reg_request_lambda]]:::lambda
        FaceMatch[[face_match_lambda]]:::lambda
        RegCheck[[reg_check_lambda]]:::lambda
        Decision[[decision_lambda]]:::lambda
        Expiry[[expiry_reminder_lambda]]:::lambda

        DB[(RDS PostgreSQL)]:::store
    end

    %% ─────────  SQL02 ON-PREM / EDGE  ─────────
    subgraph "SQL02 On-prem"
        OnPremSvc["onprem_upload_service"]:::lambda
        DataSyncAgent["AWS DataSync Agent"]:::source
    end

    %% ─────────  REGISTERS / APIFY  ───────
    subgraph APIFY_BOX["Registers / Apify scrapers"]
        direction LR
        ApifyGDC["GDC Register Scraper"]
        ApifyNMC["NMC Register Scraper"]
        ApifyGMC["GMC Register Scraper"]
        ApifyGPC["GPC Register Scraper"]
    end

    %% ─────────  AWS AI SERVICES  ─────────
    subgraph "AWS AI services"
        direction TB
        Textract[(Amazon Textract)]:::ai
        Rekog[(Amazon Rekognition)]:::ai
    end

    %% ─────────  NOTIFICATION  ───────────
    subgraph "Notifications"
        NotifySNS["SNS / Webhook"]
        NotifyEmail["Email to CS"]
    end

    %% ─────────  FLOWS ─────────
    User -->|"PUT ID & selfie"| OnPremSvc
    OnPremSvc -- "copy files" --> DataSyncAgent
    DataSyncAgent -->|"PUT objects"| S3

    S3 -- "ObjectCreated" --> DocScan
    DocScan -- "invoke OCR"       --> Textract
    Textract -- "JSON result"     --> DocScan
    DocScan -- "rows to DB"       --> DB
    DocScan -- "msg user_id"      --> FaceQ
    DocScan -- "msg reg_no/type"  --> RegReqQ

    FaceQ --> FaceMatch
    FaceMatch -- "invoke compare/liveness" --> Rekog
    Rekog -- "JSON result"                 --> FaceMatch
    FaceMatch -- "row face_checks"         --> DB
    FaceMatch -- "msg user_id"             --> DecQ

    RegReqQ --> ReqMaker
    ReqMaker -- "HTTP POST"      --> APIFY_BOX
    APIFY_BOX -- "JSON response" --> RegRespQ

    RegRespQ --> RegCheck
    RegCheck -- "row reg_checks" --> DB
    RegCheck -- "msg user_id"    --> DecQ

    DecQ --> Decision
    Decision -- "insert kyc_decisions⏎update users" --> DB
    Decision -- "PASS"          --> NotifySNS
    Decision -- "MANUAL_REVIEW" --> NotifyEmail

    Expiry -- "select expiring IDs" --> DB
    Expiry -- "90/30/7-day emails"  --> NotifyEmail
    Expiry -- "force re-upload"     --> User

    %% ─────────  STYLING  ─────────
    classDef lambda fill:#004B76,stroke:#fff,color:#fff;
    classDef queue  fill:#C0D4E4,stroke:#004B76,color:#000;
    classDef store  fill:#F8F8F8,stroke:#555,color:#000;
    classDef source fill:#FFF4CE,stroke:#C09,color:#000;
    classDef ai     fill:#7A5FD0,stroke:#fff,color:#fff;

    class OnPremSvc,DocScan,ReqMaker,FaceMatch,RegCheck,Decision,Expiry lambda;
    class FaceQ,RegReqQ,RegRespQ,DecQ queue;
    class S3,DB store;
    class DataSyncAgent source;
    class Textract,Rekog ai;
```

---

## 2  Detailed Flow Diagram (with AI round‑trips & fan‑in queue)

```mermaid
%%  KYC flow – full round-trip AI calls + clarified SNS name
graph TD
    %% ─────────── Sources & Triggers ───────────
    USER_UPLOAD[User uploads<br/>ID + selfie]
    FOLDER[(On-prem images<br/>folder on MS SQL server)]
    DATASYNC[AWS DataSync<br/>agent]
    S3[(S3 bucket<br/>kyc-raw/...)]
    APIFY[Apify<br/>register scraper]
    CRON[Weekly<br/>expiry scheduler]
    CSUI[CS Manual<br/>Review UI]

    %% ─────────── AI services ───────────
    Textract[(Amazon Textract)]
    Rekog[(Amazon Rekognition)]

    %% ─────────── Lambda workers ───────────
    DOC[doc_scan_lambda]
    FACE[face_match_lambda]
    REG[reg_check_lambda]
    REQ[reg_request_lambda]
    DEC[decision_lambda]
    REM[expiry_reminder_lambda]

    %% ─────────── Queues / Topics ───────────
    Q_FACE[face-match SQS]
    Q_REQ[reg-request SQS]
    Q_RESP[reg-check-ingest SQS]
    Q_DEC[decision SQS]

    CSMAIL[Email to CS]
    NOTIFY_SNS[SNS / Webhook<br/>to product]

    %% ─────────── RDS (table-level) ───────────
    subgraph DB[Relational DB]
        USERS[(users)]
        IDDOC[(id_documents)]
        SCANS[(doc_scans)]
        SELFIES[(selfies)]
        FACES[(face_checks)]
        REGCHK[(reg_checks)]
        KYC[(kyc_decisions)]
    end

    %% ───── 0  User upload → local folder → S3
    USER_UPLOAD -- "Write files" --> FOLDER
    FOLDER -->|DataSync job| DATASYNC
    DATASYNC -->|PUT objects| S3
    S3 -- ObjectCreated --> DOC

    %% ───── 1  doc_scan_lambda
    DOC -- "INSERT doc_scans"  --> SCANS
    DOC -- "INSERT selfies"    --> SELFIES
    DOC -- "UPDATE id_documents" --> IDDOC
    DOC -- "msg: user_id"               --> Q_FACE
    DOC -- "msg: reg_type + reg_no"     --> Q_REQ

    %% ───── AI service calls (outbound & return)
    DOC -. "OCR" .-> Textract
    Textract -. "JSON result" .-> DOC

    FACE -. "Compare & liveness" .-> Rekog
    Rekog -. "JSON result" .-> FACE

    %% ───── 2  face_match_lambda
    Q_FACE --> FACE
    FACE -- "INSERT face_checks" --> FACES
    %% (fan-in) FACE → decision queue
    FACE -->|msg: user_id| Q_DEC

    %% ───── 3  Apify request / response
    Q_REQ --> REQ
    REQ -- "HTTP request<br/>(reg_type, reg_no, user_id)" --> APIFY
    APIFY -- "JSON {user_id …}" --> Q_RESP

    %% ───── 3a  reg_check_lambda
    Q_RESP --> REG
    REG -- "INSERT reg_checks" --> REGCHK
    %% (fan-in) REG → decision queue (label offset for clarity)
    REG -. "msg: user_id" .-> Q_DEC

    %% ───── 4  decision_lambda
    Q_DEC --> DEC
    DEC -- "INSERT kyc_decisions" --> KYC
    DEC -- "UPDATE users"         --> USERS
    DEC -- PASS           --> NOTIFY_SNS
    DEC -- MANUAL_REVIEW  --> CSMAIL

    %% ───── 5  CS manual review
    CSUI -- "Approve / Reject" --> KYC

    %% ───── 6  Expiry reminder
    CRON --> REM
    REM -- "SELECT expiry then send<br/>90/30/7-day emails" --> NOTIFY_SNS

    %% ─────────── Styling ───────────
    classDef lambda fill:#004b76,stroke:#fff,color:#fff;
    class DOC,FACE,REG,REQ,DEC,REM lambda;

    classDef queue fill:#c0d4e4,stroke:#004b76,color:#000;
    class Q_FACE,Q_REQ,Q_RESP,Q_DEC queue;

    classDef source fill:#fff4ce,stroke:#c09,stroke-width:1px,color:#000;
    class USER_UPLOAD,FOLDER,DATASYNC,APIFY,CRON,CSUI,CSMAIL,NOTIFY_SNS source;

    classDef ai fill:#7a5fd0,stroke:#fff,color:#fff;
    class Textract,Rekog ai;

    classDef db fill:#f8f8f8,stroke:#555,color:#000;

```
---

## 3  A step‑by‑step processing table with example payloads

| #      | Trigger / Source                                                      | Lambda / Service                             | What it does                                                                  | **DB writes / updates**                                         | **Columns populated → example data**                                                                                                                                                                                                                                                                                                                            | Next queue / topic                                     |
|--------|----------------------------------------------------------------------|----------------------------------------------|--------------------------------------------------------------------------------|------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------|
| **0**  | **User** uploads ID + selfie → on-prem folder → **AWS DataSync** push | **`onprem_upload_service`**                  | • Accept files locally (traffic over AWS VPN)<br>• Create *minimal* seed rows | `users` INSERT<br>`id_documents` INSERT (`status='NEW'`)        | **`users`** → `email="dr.jane@example.com"`, `reg_no="6143219"`, `reg_type='GMC'`, `status='PENDING'`, `created_at=NOW()`<br>**`id_documents`** → `user_id=42`, `s3_key_original="kyc-raw/42/passport.jpg"`, `doc_type='passport'`, `status='NEW'`, `created_at=NOW()`                                                                                         | *(none – DataSync copies → S3)*                        |
| **1**  | **S3:ObjectCreated** (`kyc-raw/…`)                                   | **`doc_scan_lambda`**                        | Textract ⇒ parser ⇒ store scan & selfie metadata                              | `doc_scans` INSERT<br>`selfies` INSERT<br>`id_documents` UPDATE | **`doc_scans`** → `id_document_id=17`, `textract_json='{…}'`, `parsed_name="JANE ANN DOE"`, `parsed_dob='1985-02-14'`, `parsed_expiry='2032-05-01'`, `parser_version='1.0.0'`, `completed_at=NOW()`<br>**`selfies`** → `user_id=42`, `s3_key="kyc-raw/42/selfie.jpg"`, `created_at=NOW()`<br>**`id_documents`** → `status='OCR_DONE'`, `expiry_date='2032-05-01'` | **`face-match` SQS**<br>**`reg-request` SQS**          |
| **2**  | Msg on **`face-match` SQS**                                           | **`face_match_lambda`**                      | Rekognition face match + liveness                                             | `face_checks` INSERT                                            | **`face_checks`** → `user_id=42`, `selfie_id=23`, `id_document_id=17`, `match_score=0.93`, `liveness_pass=true`, `rekognition_job_id='abcd-1234'`, `completed_at=NOW()`                                                                                                                                                                                         | **`decision` SQS**                                     |
| **3**  | Msg on **`reg-request` SQS**                                          | **`reg_request_lambda`**                     | HTTP **POST** to Apify register scraper (`reg_type`, `reg_no`, `user_id`)     | —                                                               | —                                                                                                                                                                                                                                                                                                                                                               | *(callout to Apify – async)*                           |
| **3a** | **Apify** scrape finishes                                             | Publishes JSON to **`reg-check-ingest` SQS** | —                                                                             | —                                                               | —                                                                                                                                                                                                                                                                                                                                                               | **`reg-check-ingest` SQS**                             |
| **3b** | Msg on **`reg-check-ingest` SQS**                                     | **`reg_check_lambda`**                       | Compare Apify result to ID **and store raw payload**                          | `reg_checks` INSERT                                             | **`reg_checks`** →<br>• `user_id = 42`<br>• `snapshot_date = '2025-06-26'`<br>• `matched_name = true`<br>• `matched_status = true`<br>• `raw_response_json = '{"name":"JANE ANN DOE","status":"Licensed","reg_no":"6143219", …}'`<br>• `checked_at = NOW()`                                                                                                     | **`decision` SQS** (same `user_id`)                    |
| **4**  | Msg on **`decision` SQS**                                             | **`decision_lambda`**                        | Aggregate latest face + reg results → verdict                                 | `kyc_decisions` INSERT<br>`users` UPDATE                        | **`kyc_decisions`** → `user_id=42`, `decision='PASS'`, `reasons='{}'`, `decided_at=NOW()`<br>**`users`** → `status='VERIFIED'`                                                                                                                                                                                                                                   | SNS/Webhook (*PASS*)<br>Email to CS (*MANUAL_REVIEW*) |
| **5**  | CS Manual Review UI                                                   | —                                            | Human approve / reject override                                               | `kyc_decisions` UPDATE<br>`users` UPDATE                        | e.g. reviewer flips → `kyc_decisions.decision='PASS'`, `users.status='VERIFIED'`                                                                                                                                                                                                                                                                               | —                                                      |
| **6**  | **Weekly** CloudWatch EventRule                                       | **`expiry_reminder_lambda`**                 | Query soon-expiring IDs → send 90 / 30 / 7-day reminders                      | *(read-only)*                                                   | `SELECT user_id, expiry_date FROM id_documents WHERE expiry_date < CURRENT_DATE + INTERVAL '90 days'`                                                                                                                                                                                                                                                           | Email / push topic                                     |


---

## 4  Entity‑Relationship Diagram

```mermaid
erDiagram
    %% direction LR   %% ← Uncomment if your renderer supports L-to-R layout

    users {
        BIGSERIAL        id PK
        VARCHAR(254)     email
        VARCHAR(50)      reg_no
        reg_type_enum    reg_type
        user_status_enum status
        TIMESTAMPTZ      created_at
    }

    id_documents {
        BIGSERIAL         id PK
        BIGINT            user_id FK
        TEXT              s3_key_original
        VARCHAR(40)       doc_type
        id_doc_status_enum status
        DATE              expiry_date
        TIMESTAMPTZ       created_at
    }

    selfies {
        BIGSERIAL      id PK
        BIGINT         user_id FK
        TEXT           s3_key
        TIMESTAMPTZ    created_at
    }

    doc_scans {
        BIGSERIAL      id PK
        BIGINT         id_document_id FK
        JSONB          textract_json
        TEXT           parsed_name
        DATE           parsed_dob
        DATE           parsed_expiry
        VARCHAR(40)    parser_version
        TIMESTAMPTZ    completed_at
    }

    face_checks {
        BIGSERIAL      id PK
        BIGINT         user_id FK
        BIGINT         selfie_id FK
        BIGINT         id_document_id FK
        NUMERIC        match_score
        BOOLEAN        liveness_pass
        VARCHAR(100)   rekognition_job_id
        TIMESTAMPTZ    completed_at
    }

    reg_checks {
        BIGSERIAL      id PK
        BIGINT         user_id FK
        DATE           snapshot_date
        BOOLEAN        matched_name
        BOOLEAN        matched_status
        JSONB          raw_response_json
        TIMESTAMPTZ    checked_at
    }

    kyc_decisions {
        BIGSERIAL        id PK
        BIGINT           user_id FK
        kyc_decision_enum decision
        TEXT[]           reasons
        TIMESTAMPTZ      decided_at
    }

    %% ─────── Relationships (each FK exactly once) ───────
    users        ||--o{ id_documents  : "users.id → id_documents.user_id"
    users        ||--o{ selfies       : "users.id → selfies.user_id"
    users        ||--o{ face_checks   : "users.id → face_checks.user_id"
    users        ||--o{ reg_checks    : "users.id → reg_checks.user_id"
    users        ||--o{ kyc_decisions : "users.id → kyc_decisions.user_id"

    id_documents ||--o{ doc_scans     : "id_documents.id → doc_scans.id_document_id"
    id_documents ||--o{ face_checks   : "id_documents.id → face_checks.id_document_id"

    selfies      ||--o{ face_checks   : "selfies.id → face_checks.selfie_id"
```

---

### Running Locally

1. Clone this repo and open `README.md`
2. Apply database migration:

```bash
psql $DB_URL -f "Kyc Schema Patch.sql"
```

3. Deploy infra (`cdk deploy` / Terraform / SAM) using the same resource names.

---

### Contributing

PRs are welcome!  Please update diagrams & docs if you change queues, enum values, or add tables.
