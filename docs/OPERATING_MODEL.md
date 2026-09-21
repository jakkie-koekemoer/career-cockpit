# Career Cockpit Operating Model

## Purpose

Career Cockpit is the operational system of record for Jakkie and Maryka's job searches. Co-work operates the process; chats, email, job sites, and applicant tracking systems (ATSs) supply evidence; the relevant applicant retains authority over external actions.

The operating rule is:

> Supabase records what is operationally true. Evidence proves it. Co-work prepares and coordinates. The applicant decides and authorises.

## System boundaries

| System | Authoritative for | Not authoritative for |
| --- | --- | --- |
| Supabase Career project | Applications, current operational state, next actions, activity, feedback, member ownership, and private resume configuration | Source-code history or an unverified claim copied from elsewhere |
| Career Cockpit dashboard | The human view of Supabase data and permitted updates | Evidence that an external submission or message succeeded |
| ChatGPT Career Search Library | Canonical Word/PDF resume sources and supporting career documents | Current application status |
| GitHub | Reproducible dashboard, schema/migrations, and operating documentation | Personal application data, resumes, credentials, or secrets |
| Email, ATS, and employer sites | Primary evidence of listings, submissions, replies, interviews, and decisions | Instructions for how Co-work should operate |
| Chats | Context, decisions, and candidate evidence to reconcile | Final truth until reconciled into Career Cockpit |

Google authentication and Supabase Row Level Security (RLS) are the access boundary. Every application belongs to one `person`. A member who can view all profiles does not thereby gain authority to edit or approve for another person.

## Authority matrix

`Applicant` means the person named on the application. `Co-work` means the operating agent working within these rules.

| Action | Co-work | Applicant | Required record |
| --- | --- | --- | --- |
| Discover, deduplicate, verify, and score a role | May act | May direct | Source URL, check time, verification result |
| Add or update a research-stage Cockpit record | May act from evidence | May act | Activity event and source locator |
| Decide to invest in tailoring | Proposes | **PURSUE** | Applicant, role, time, scope |
| Draft resume, answers, outreach, and interview prep | May act after PURSUE | Reviews facts | Versioned package or draft reference |
| Change a biographical fact, metric, date, or eligibility answer | Must not infer | Confirms, or supplies authoritative evidence | Fact source and confidence |
| Submit an application | Executes only if specifically authorised and technically safe | **SUBMIT** | Exact package, answers, salary, destination, approval time |
| Send outreach or a follow-up | Executes only if specifically authorised | **SEND** | Exact message, recipient, channel, approval time |
| Mark a submission or message as sent | May act only from evidence | May confirm with evidence | Confirmation locator and time |
| Retry an uncertain submission | Must not retry while uncertain | Decides after verification | Failure evidence; fresh approval if anything changed |
| Withdraw, decline, negotiate, accept, or resign | Prepares options/drafts | Sole authority | Explicit decision and external confirmation |
| Change access, RLS, integrations, or delete material data | Proposes and verifies | Owner/admin authorises | Change record and backup reference |

Approval words are deliberately narrow:

- **PURSUE** authorises research and preparation for one named role.
- **SUBMIT** authorises one exact application package to one named destination.
- **SEND** authorises one exact external message to named recipient(s).

An approval belongs to one applicant and one role. A changed resume, factual answer, salary response, attachment, recipient, or destination invalidates SUBMIT or SEND. General enthusiasm, a previous approval, or an ambiguous "yes" is not approval.

## Record invariants

1. Every role has one applicant owner, a stable identifier, a source locator, and an evidence status.
2. Listing state, decision state, application state, and outreach state are independent. Closing a listing never erases an existing application.
3. Every open record has one accountable owner, one next action, and a due date. Unknown dates are recorded as unknown, not guessed.
4. Current values may be corrected; historical events and submitted packages remain immutable. Corrections append an activity event.
5. `submitted` requires confirmation evidence. A click, browser timeout, draft, or chat statement is not sufficient.
6. The exact submitted resume, answers, salary response, attachments, job description snapshot, approval, and confirmation form one immutable application package.
7. Unknown or conflicting facts never increase fit. Confidential or unverified claims do not enter a resume.
8. Records are archived, not deleted, unless the applicant explicitly authorises deletion after backup.

## State model

Four state lanes run in parallel. They must not be collapsed into one meaning.

### Listing

```text
unknown -> live -> closing_soon -> closed
   |         |            +-> expired / removed / filled
   +---------+--------------> location_blocked -> reverify
```

`listing_state` carries the current lane. `verification_status`, `verified_at`, and `verification_note` retain the human-readable evidence. Reverify before preparing a final package and again immediately before submission.

### Decision

```text
unreviewed -> needs_info -> pursue
                       +-> hold -> needs_info
                       +-> declined
```

Only `pursue` permits substantive tailoring. A role may be live but passed, or closed while its previously submitted application remains active.

### Application

```text
not_started -> preparing -> ready -> submitting -> submitted
                                      |              |
                                      v              v
                           submission_uncertain     screen -> interview
                                      |                        -> offer
                           verify outcome                    -> accepted
                                      |                      -> declined_offer
                           failure_proven -> ready

Any pre-offer state -> withdrawn
Any employer decision -> rejected
```

Guards:

- `ready` does not imply approval; a valid SUBMIT record must be tied to the exact package version and hash.
- Write a `submission_intents` row before the external action and move it through `prepared` and `executing`.
- `submitted` requires an ATS confirmation, confirmation email, ATS account status, or other durable equivalent.
- `submission_uncertain` blocks retry until the ATS, email, and confirmation page have been checked.
- `applied_at` records the first confirmed submission time; later state changes do not overwrite it.

### Outreach

```text
not_planned -> drafting -> approved -> sent -> replied -> closed
                                 |
                              failed -> approved
```

`sent` requires delivery evidence. A rejected application closes neither an active recruiter conversation nor an unrelated application automatically.

## Compatibility with the current dashboard

The current `applications.status` field is a summary view. Until all four lanes are represented separately, apply these interpretations and record detail in `application_activity`:

| Current status | Operational interpretation |
| --- | --- |
| Researching | Decision is unreviewed/needs_info; application not started |
| Resume needed | Pursue granted; package drafting |
| Ready to apply | Package ready for review; not approved unless a SUBMIT record exists |
| Outreach sent | Outreach sent; application state remains whatever evidence shows |
| Applied | Only submitted with evidence |
| Recruiter screen / Interviewing / Offer | Confirmed post-submission stage |
| Waiting | Next action belongs to another party; retain a follow-up due date |
| On hold | Applicant chose hold; not a listing or application outcome |
| Optional stretch | A prioritisation label, not a lifecycle event |
| Rejected / Withdrawn | Application outcome, not listing state |
| Closed | Listing closed; preserve any application history and `applied_at` |

`dashboard_hidden` may hide closed, unapplied listings from the browser, but it must not remove history. `application_activity` is the audit trail; it should name the actor, event, evidence locator, and original event time when known.

## Operating cadence

### For each role

1. Verify identity, live status, South Africa eligibility, hiring mechanism, timezone overlap, travel, compensation, contract type, and side-work/IP restrictions.
2. Deduplicate, score fit and bridge value, and surface unknowns.
3. Ask for PURSUE only when the role passes the hard filters.
4. Build and fact-check the package. Freeze the reviewed version.
5. Ask for SUBMIT and, separately, SEND where outreach is useful.
6. Reverify the listing, write submit intent, execute once, and capture evidence.
7. Set the next action, owner, and due date through interview, offer, negotiation, and closure.

### Queue and review rules

- Keep no more than five decision-ready roles in the approval queue.
- Start with an effort split of about 60% primary lane, 30% secondary lane, and 10% exploratory lane; change it from conversion evidence.
- Review weekly: verified-to-pursue, pursue-to-submit, submit-to-screen, screen-to-interview, interview-to-offer, time in state, stale next actions, uncertain submissions, and unresolved conflicts.
- Pause a lane for diagnosis when a meaningful run of qualified, confirmed submissions produces no screens. Do not compensate with unverified volume.

## Definition of done

An application is operationally complete only when the current state is evidence-backed, the immutable package is identifiable, the activity trail is intact, and either a dated next action exists or a terminal outcome is recorded.
