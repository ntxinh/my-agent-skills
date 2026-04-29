# SaaS Inference Guide

When the client's Jira description omits the structured sections developers need (Acceptance Criteria, Edge Cases, Definition of Done, Security/Performance, Dependencies), use this guide to draft sensible defaults for a full-stack SaaS web app context.

**Always mark inferred content** so the BA/PM/Tech Lead/QA knows what came from the client and what came from your inference. Use the convention defined in `SKILL.md`.

---

## Acceptance Criteria

If the client described a desired outcome but didn't write Given/When/Then, derive 2–5 AC items by walking the happy path they implied and converting each verifiable step.

**Heuristic:** every verb the client used ("user can export", "admin sees", "email is sent") becomes a candidate AC. Phrase each as observable behavior, not implementation.

**Example translation:**
- Client wrote: *"We need customers to be able to download their invoices as PDFs from the billing page."*
- Inferred ACs:
  - Given a user is on the billing page, when they click "Download" on any invoice row, then a PDF of that invoice downloads.
  - Given an invoice is still being generated, when the user clicks "Download," then they see a clear "not ready" state instead of an error.
  - Given a user does not have billing permission, when they view the billing page, then the download button is not visible.

If the client's description is too vague to extract specific ACs, write a single placeholder AC and flag the section for clarification — don't invent product behavior wholesale.

---

## Edge Cases

For a SaaS web app, the recurring edge-case categories are reliably:

**Auth & permissions**
- Unauthenticated user hits the page/endpoint
- Authenticated user without the required role/permission
- Session expires mid-action
- User belongs to multiple tenants/workspaces

**Tenant isolation (multi-tenant SaaS)**
- User from tenant A attempts to access tenant B's resource by guessing an ID
- Soft-deleted records leaking into queries
- Cross-tenant data shown in aggregates/exports

**Plan tier**
- Feature only available on paid plan — free user attempts the action
- User downgrades while using a paid-only feature (mid-session)
- Trial period expires during the workflow
- Usage limit hit (seats, API calls, storage)

**Data state**
- Empty state (user has zero items yet)
- Very large dataset (1000+ items, pagination, performance)
- Stale / cached data after a write
- Concurrent edits by two users on the same record (last-write-wins vs. conflict)

**Input validation**
- Empty string, whitespace-only, very long strings
- Special characters / Unicode / emoji
- Pasted HTML or scripts (XSS surface)
- Numbers out of expected range (negative, zero, max int)

**Network & device**
- Slow connection / partial form submission
- User navigates away mid-request
- Mobile vs. desktop viewport
- Browser tab is backgrounded / inactive

Pick the 3–5 most relevant categories for the specific feature — don't list all of them on every ticket.

---

## Security / Performance Requirements

Default flags worth raising for almost every SaaS feature:

**Security**
- Auth check: who can call this endpoint / see this UI?
- Authorization check: within authorized users, who can act on *this specific resource*? (RBAC + record-level)
- PII / sensitive data: does this read or write personal/financial/health data? If yes, audit log it.
- Input sanitization & output encoding (XSS, SQL injection if raw queries)
- Rate limiting on any user-triggered network call
- No secrets/API keys in client code or logs

**Performance**
- Expected query cost: does this hit the DB with N+1 or unindexed columns?
- Pagination on any list that could exceed ~100 items
- Caching strategy (and cache invalidation on writes)
- Heavy operations move to background jobs, not request thread

Trim this list to what actually applies to the ticket — don't bloat the spec with checkboxes that are irrelevant.

---

## Dependencies / Blockers

Things to look for that the client likely didn't name:

- **Backend ↔ frontend coupling:** if the story changes a UI, is there a matching API change? (Often a separate task.)
- **Schema migrations:** any new column / table / index? That's a separate task that must ship first.
- **Third-party services:** does this need a Stripe / SendGrid / S3 / OAuth provider change? Configuration / credentials needed?
- **Feature flags:** is this rolling out behind a flag? Who toggles it?
- **Design assets:** are mockups / icons / copy ready?
- **Legal / compliance:** GDPR, SOC2, accessibility (WCAG) — does this touch any of those?

If you can identify a likely dependency, list it as a candidate and flag it for the team to confirm.

---

## Definition of Done

The user-provided templates already include strong DoD checklists. Use them as-is — don't add or remove items unless the ticket genuinely needs it.

If the ticket is user-facing, the DoD should always include:
- Tested on the supported browser matrix (or at least Chrome + Safari + Firefox latest)
- Mobile viewport sanity-checked if responsive
- Telemetry / analytics event added if there's a new user action worth tracking
- Documentation / changelog updated

---

## Severity (Bugs only)

If the client didn't mark severity, infer from impact language:

| Client said something like... | Severity |
|---|---|
| "the whole app is down", "no one can log in", "we're losing data" | Critical |
| "this feature is broken for everyone", "blocking work" | High |
| "annoying but we can work around it", "happens sometimes" | Medium |
| "minor display issue", "typo", "alignment off" | Low |

When in doubt, pick one tier lower than the client's emotional tone suggests — clients tend to over-escalate. But never go below Medium for anything that mentions data loss, billing, or auth.

---

## Reporter language → developer language

Common translations from client phrasing to developer-readable intent:

| Client wrote | Likely means |
|---|---|
| "It's broken" | Functional regression — get steps to reproduce |
| "It's slow" | Performance issue — need timing data, dataset size, browser |
| "Customers are complaining" | Affects multiple users — high severity, get scope |
| "We need a button for X" | New UI affordance — but X is the actual feature |
| "Make it work like [Competitor]" | Investigate competitor behavior, then write ACs |
| "Just like before" | There was prior behavior — find the regression point |
| "Should be obvious" | Implicit expectation — surface it as an explicit AC |

When you do these translations, preserve the **business intent** in the Background/Context section so reviewers can sanity-check your interpretation.
