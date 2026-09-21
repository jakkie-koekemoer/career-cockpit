# Career History Reconciliation Runbook

## Objective

Merge the scattered history from chats, email, ATS accounts, employer sites, resumes, and Career Cockpit into one evidence-backed Supabase record without inventing facts, overwriting stronger evidence, or causing external actions.

Reconciliation is read-only outside Career Cockpit. It never sends a message, submits or retries an application, withdraws a candidacy, or changes an ATS profile.

## Evidence vocabulary

Every material value receives one of these labels:

| Label | Meaning | Treatment |
| --- | --- | --- |
| `verified` | Direct, durable evidence supports the value | May become the canonical value; retain the locator and date |
| `inferred` | Multiple clues support the value, but no direct proof exists | Keep visibly provisional; do not use for high-risk answers or submission state |
| `unknown` | No adequate evidence was found | Leave blank/unknown and assign a next action if material |
| `conflict` | Credible sources disagree | Preserve both claims and sources; do not select silently |

Evidence strength, from strongest to weakest, is normally:

1. ATS account status, employer confirmation page/number, employer email, signed offer, or interview booking.
2. The exact sent email with timestamp and attachments, or a saved submitted package.
3. Contemporaneous Cockpit activity with a source locator.
4. Contemporaneous chat or dated working note.
5. Undated recollection.

Use recency only between sources of comparable authority. A newer chat does not overrule an ATS confirmation without an explanation. Applicant-supplied corrections to personal facts are authoritative but must be logged as corrections.

## Before starting

1. Name the applicant scope: Jakkie, Maryka, or both. Never merge their records.
2. Create a batch identifier such as `reconcile-YYYYMMDD-person-sequence`.
3. Record the operator, start time, source date range, and baseline Cockpit counts by status.
4. Pause submissions, retries, and outbound messages for the scoped records.
5. Take a protected database export before bulk changes. Do not put the export in GitHub.

## Source inventory

Register each source before extracting from it:

| Source ID | System/account | Applicant | Date range | Accessed at | Complete? | Notes |
| --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  | yes/no/unknown |  |

Minimum inventory:

- Current `applications` and `application_activity` records in Supabase.
- All identified job-search chats, including approval and submission claims.
- Relevant email folders and searches for application, confirmation, interview, rejection, offer, and withdrawal messages.
- ATS accounts and employer portals where access is available.
- Canonical resumes in the Career Search Library plus any role-specific submitted copies.
- Existing local confirmation files or screenshots, if any.

Record an inaccessible source as inaccessible; do not treat it as empty.

## Procedure

### 1. Extract claims without resolving them

For every source, capture the original event time, capture time, applicant, employer, role, requisition ID, canonical URL, claimed action/state, package or message reference, and exact source locator. Preserve source wording for ambiguous states such as "received," "under review," or "no longer available."

### 2. Match and deduplicate roles

Use this identity order:

1. Applicant plus ATS/employer requisition ID.
2. Applicant plus canonical ATS URL.
3. Applicant plus normalised employer, role title, location, and posting window.

Different requisition IDs are different roles even when titles match. The same requisition pursued by Jakkie and Maryka is two applicant records. When identity is uncertain, link the candidates as `possible_duplicate`; do not merge them.

Choose one stable Cockpit ID and retain superseded IDs in the reconciliation note. Merge field by field, never by replacing the whole newer or older row.

### 3. Adjudicate each material field

For each value:

- Accept it as `verified` when direct evidence exists.
- Keep it `inferred` only when the inference and supporting locators are recorded.
- Use `unknown` when absent; do not fill with a likely answer.
- Use `conflict` when credible values disagree. Put both claims, both locators, the risk, and the person who must resolve it in the conflict log.

Never use inferred or conflicting values for identity, work authorisation, nationality, compensation history, dates, metrics, qualifications, criminal/medical/disability questions, references, or any legal declaration.

### 4. Reconstruct independent states

Determine listing, decision, application, and outreach state separately. Apply these rules:

- A closed listing does not prove rejection and does not erase a submitted application.
- An outreach message does not prove an application.
- A tailored resume or completed draft does not prove submission.
- A rejection proves an application outcome only when it identifies the applicant and role.
- A generic recruiter conversation does not prove recruiter-screen status for a particular requisition.
- `Applied`/`submitted` requires acceptable submission evidence below.

### 5. Reconstruct the application package

For every confirmed or approved application, identify as many of these as possible:

- Job description snapshot and source URL.
- Resume and cover letter filenames, version IDs, and SHA-256 hashes.
- Application answers, salary response, eligibility declarations, and attachments.
- SUBMIT approval locator and timestamp.
- Submission destination, submit-intent timestamp, confirmation evidence, and `applied_at`.

Do not alter historical submitted artifacts to match a later correction. Record the correction and use it in future packages.

### 6. Write to Career Cockpit

Write the resolved current value and append an `application_activity` event for every material import or correction. Each event should contain:

- Batch ID and actor.
- Original event time and reconciliation time.
- Evidence label and locator.
- Previous value, new value, and reason when corrected.

Recommended activity types are `reconciliation_imported`, `source_conflict_flagged`, `fact_corrected`, `approval_recovered`, `submission_confirmed`, and `submission_uncertain`. Do not backdate the database audit timestamp; store the original event time in the event detail or dedicated event-time field.

### 7. Quality check and release the freeze

Run these checks before closing the batch:

- Source counts reconcile to imported, duplicate, irrelevant, inaccessible, or unresolved counts.
- Every Cockpit row belongs to the correct person.
- No confirmed application lacks evidence and no evidence-backed application is hidden as an unapplied closed role.
- Every non-terminal record has an owner, next action, and due date.
- Every conflict and unknown high-risk fact has an owner and resolution action.
- At least 10% of reconciled records, plus every submission and offer, are checked against the original source by a second pass.
- The post-reconciliation export and batch summary are stored securely.

The applicant signs off the exception list, not every uncontested import. Resume normal operations only after uncertain submissions and identity conflicts are visible in the active queue.

## Submission evidence standard

Acceptable confirmation evidence is one or more of:

- Employer/ATS confirmation page with role and confirmation number or timestamp.
- Employer/ATS confirmation email tied to the applicant and role.
- Authenticated ATS account showing the submitted application and date.
- For email applications, the sent message with final attachments and successful delivery state.

Insufficient on its own:

- The submit button was clicked.
- The browser redirected, timed out, or closed.
- A draft, tailored resume, or chat says the application was completed.
- An application appears in browsing history.

Store a durable locator, not a fragile browser session URL. Where practical, record a redacted screenshot/PDF reference, message ID or confirmation number, capture time, and file hash. Keep sensitive evidence outside the public repository.

### Uncertain-submission protocol

1. Record a `submission_intents` row before the external submit action.
2. If confirmation is missing, stop. Mark `submission_uncertain`; do not click again.
3. Check the confirmation page state, ATS application history, and email, allowing for delayed email.
4. If evidence confirms success, record `submitted`, evidence, and `applied_at`.
5. If direct evidence proves failure and no application exists, return to `approved`. Reuse the approval only for the exact unchanged package and destination; otherwise obtain a new SUBMIT.
6. If the outcome remains unknown, leave it uncertain, assign the applicant a verification action, and contact support/employer only under an approved SEND message.

## Working templates

### Role worksheet

| Field | Value | Evidence label | Source locator | Event date | Notes |
| --- | --- | --- | --- | --- | --- |
| Applicant |  |  |  |  |  |
| Employer / role |  |  |  |  |  |
| Requisition ID / URL |  |  |  |  |  |
| Listing state |  |  |  |  |  |
| Decision state |  |  |  |  |  |
| Application state |  |  |  |  |  |
| Outreach state |  |  |  |  |  |
| Package / approval |  |  |  |  |  |
| Confirmation |  |  |  |  |  |
| Next action / owner / due |  |  |  |  |  |

### Conflict log

| Conflict ID | Applicant / role | Field | Claim A + source | Claim B + source | Risk | Owner | Resolution / due |
| --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |

### Batch summary

```text
Batch ID:
Applicant scope:
Source date range:
Sources complete / inaccessible:
Claims reviewed:
Roles created / updated / deduplicated:
Confirmed submissions recovered:
Uncertain submissions:
Conflicts / unknown high-risk facts:
Spot-check result:
Pre-change backup:
Post-change export:
Applicant sign-off and date:
```

## Ongoing rule

After the historical reconciliation, reconcile new evidence directly into Career Cockpit during the same work session. Chats may explain a decision, but the Cockpit record and activity trail must carry the operational outcome before the task is considered complete.
