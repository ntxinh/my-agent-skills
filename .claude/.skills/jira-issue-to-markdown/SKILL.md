---
name: jira-issue-to-markdown
description: Translate a Jira issue (Bug, Story, Task, or Spike) into a developer-ready markdown spec for a full-stack SaaS web app. Use this skill whenever the user references a Jira ticket, issue, or issue key (like "ABC-123") and wants it converted, translated, formatted, expanded, or cleaned up into markdown — including when they paste a Jira description, share a Jira URL, or want missing acceptance criteria, edge cases, definition of done, security/performance requirements, or dependencies filled in. Also use when the Jira description includes screenshots/images that contain requirement text, since this skill extracts that text. Trigger this even if the user doesn't say "markdown" explicitly but is clearly asking to turn a Jira ticket into a proper spec, user story, or developer-ready document. The original reporter is usually a non-technical client writing in business language, so part of the value is converting their intent into a structured BA-style spec.
---

# Jira Issue → Markdown Spec

This skill converts a Jira issue — typically written by a non-technical client in plain business language — into a structured markdown spec a developer can act on. It fills in the BA-style sections clients usually omit (acceptance criteria, edge cases, definition of done, security/performance, dependencies) using SaaS-aware defaults, and it extracts any requirement text embedded in attached images.

The key principle: **never silently invent client intent**. Anything inferred is clearly marked so the BA, PM, Tech Lead, or QA can verify it before the team commits to building.

---

## Workflow

### 1. Get the issue content

The user might give you the issue in several ways:

- **Issue key only** (e.g., "ABC-123") or **Jira URL** → fetch via the Atlassian MCP. The user has Atlassian connected, so call `Atlassian:getAccessibleAtlassianResources` to find the cloudId, then `Atlassian:getJiraIssue` with the key. Request `responseContentFormat: "markdown"` so the description comes back clean. Pull `attachment` and `comment` fields too.
- **Pasted description text** → use it directly.
- **Screenshot of the Jira UI** → use vision to read the issue from the image.

If the user gave only a key and the Atlassian MCP isn't available or fails, ask them to paste the description rather than guessing.

### 2. Identify the issue type → pick the template

Map the Jira `issuetype` field to the right template in `assets/`:

| Jira issue type | Template file |
|---|---|
| Bug, Defect | `assets/bug-template.md` |
| Story, User Story, Improvement, Feature | `assets/story-template.md` |
| Task, Sub-task, Technical Task, Chore | `assets/task-template.md` |
| Spike, Research, Investigation | `assets/spike-template.md` |
| Epic | use `story-template.md` (note in the file that this is an epic-level summary; child tickets needed) |

If the type is unclear, ask the user — don't guess. The wrong template misses important sections.

Read the template file before filling it in. Don't reproduce it from memory; copy from the file so the structure stays exact.

### 3. Extract content from images

Jira clients commonly paste screenshots that contain real requirements (mockups with annotations, error messages, lists of fields). These must end up in the markdown.

For each image attached to the issue or pasted by the user:

1. Get the image into your context — either via the Atlassian MCP attachment URL, or by asking the user to upload it if the MCP can't fetch protected attachments.
2. Use vision to read every piece of text and describe what's depicted (UI element, flow diagram, error dialog, table, etc.).
3. Place the extracted content under a clearly labeled section in the markdown:

```markdown
## Content extracted from attached images

### `screenshot-2024-01-15.png` — Mockup of the export modal
The image shows a modal titled "Export data" with three radio options:
- CSV (selected by default)
- Excel (.xlsx)
- JSON

There is a date range picker labeled "Date range" with two fields ("From" / "To"), and a checkbox "Include archived items" (unchecked).

The primary button reads "Export" (blue, right-aligned). The secondary button reads "Cancel" (gray, left-aligned).
```

Don't just dump OCR — describe the structure, because layout often *is* the requirement. Note when text in the image conflicts with the issue description and surface that conflict.

### 4. Fill the template

Walk the template top to bottom. For each section:

- **If the client stated it** → write it directly. Keep the client's wording where it captures intent well; rephrase where their language is ambiguous, but preserve the business meaning in the Background/Context section.
- **If the client didn't state it** → consult `references/saas-inference-guide.md` for SaaS defaults relevant to that section, draft a sensible starting point, and **mark it as inferred** (see next step).
- **If you can't reasonably infer it** → leave the section with a placeholder like `_To be clarified with reporter._` rather than fabricating content.

### 5. Mark inferred content honestly

Two conventions, used together:

**For sections that are entirely inferred** (the client gave nothing for that section), put a callout at the top of the section:

```markdown
## Acceptance Criteria

> 💡 _Inferred from context — please verify with the reporter before development begins._

- [ ] AC1: ...
- [ ] AC2: ...
```

**For individual items mixed into a section** that has some client-stated content, append `_(inferred)_` to each inferred item:

```markdown
## Edge Cases
- Empty state when the user has no invoices yet
- Free-tier users shouldn't see the export button _(inferred)_
- Concurrent exports by two admins on the same workspace _(inferred)_
```

This visual distinction matters: a Tech Lead/QA reviewing the spec needs to see at a glance which items are real requirements vs. your suggestions. Don't be shy about marking — over-marking is safer than under-marking.

### 6. Save the markdown file

Filename convention: `{ISSUE-KEY}-{kebab-case-title}.md`

Example: `ABC-1234-export-invoices-as-pdf.md`

If there's no issue key (raw paste), use just the kebab-case title plus a short timestamp.

Save into `/mnt/user-data/outputs/` and present the file to the user with `present_files`.

---

## Filling missing sections — read the inference guide

`references/saas-inference-guide.md` has section-by-section guidance for inferring AC, edge cases, security/performance flags, dependencies, severity, and DoD in a full-stack SaaS context. Read it whenever you're filling those sections from inference rather than client-stated content. It also contains a translation table for common client phrasings ("it's slow," "we need a button for X") that helps you extract real intent.

---

## Worked example

**Input — Jira issue ABC-456:**

> **Title:** Customers can't see their invoices on mobile
>
> **Type:** Bug
>
> **Description:** Hey — multiple customers have emailed support saying when they open the billing page on their phone they just see a blank screen. It works fine on my laptop. This is happening to paying customers so it's pretty urgent. Attached a screenshot from one of them.
>
> **Attachment:** `customer-screenshot.png` — shows an iPhone Safari screen with the company header and footer visible but a large blank white area in the middle where the invoice list should be.

**Output — `ABC-456-customers-cant-see-invoices-on-mobile.md`:**

```markdown
# ABC-456 — Customers can't see their invoices on mobile

**Type:** Bug
**Reporter:** [client name]
**Source:** [Jira URL]

---

## Summary
The billing page renders blank in the invoice list area on mobile browsers, while desktop renders correctly.

## User Story Context
Paying customers viewing the billing page on mobile devices.

## Steps to Reproduce
> 💡 _Inferred from the screenshot and description — please verify exact steps with the reporter._
1. Log in as a paying customer on a mobile browser (iOS Safari confirmed; other mobile browsers unknown).
2. Navigate to the billing page.
3. Observe the page area where the invoice list should render.

## Expected Result
The invoice list renders on mobile the same way (or a responsive equivalent of) the desktop view.

## Actual Result
The header and footer render correctly, but the invoice list area is blank. (Confirmed via attached customer screenshot — see "Content extracted from attached images" below.)

## Environment
- Browser & version: iOS Safari (version unknown — _to be confirmed with reporter_)
- OS & device: iPhone (model unknown)
- User account / tenant: Multiple paying customers — exact accounts to confirm
- Frequency: [x] Always (per multiple customer reports)  [ ] Intermittent  [ ] One-time

## Severity
[ ] Critical  [x] High (feature broken for paying customers on a primary device class)  [ ] Medium  [ ] Low

## Acceptance Criteria
- [ ] Invoice list renders correctly on iOS Safari (latest 2 versions)
- [ ] Invoice list renders correctly on Android Chrome (latest 2 versions) _(inferred)_
- [ ] No regression on desktop browsers _(inferred)_
- [ ] Layout is usable at 375px viewport width (iPhone SE) _(inferred)_

## Edge Cases to Verify
> 💡 _Inferred — please verify scope with the reporter._
- Customers with zero invoices (empty state on mobile)
- Customers with many invoices (pagination/scroll on mobile)
- Free-tier users (does the page even apply?)
- Slow mobile connection (loading state visible?)

## Security / Performance Flags
- [ ] Does this expose any user data? — No additional exposure expected
- [x] Does this affect performance under load? — Mobile rendering may be tied to payload size; check
- [ ] Does this bypass any permission checks? — No

## Dependencies / Blockers
- Blocked by: None known _(inferred)_
- Related tickets: Search Jira for prior mobile/billing tickets

## Definition of Done
- [ ] Fix implemented and peer-reviewed
- [ ] Unit tests cover the fix
- [ ] QA verified on iOS Safari and Android Chrome on staging
- [ ] No new errors in logs post-deploy
- [ ] Product owner sign-off

## Content extracted from attached images

### `customer-screenshot.png` — iPhone Safari billing page
The image shows an iPhone Safari window. The company logo and primary navigation are visible at the top. The footer (with copyright and links) is visible at the bottom. The center area, which on desktop contains the invoice list table, is entirely blank/white. No error message is visible. The URL bar shows the billing page route.
```

Notice in the example:
- Client-stated content (severity = High because they said "paying customers... pretty urgent") is unmarked.
- Things inferred from a SaaS bug-fix lens (Android Chrome support, empty/many-invoices edge cases, no permission impact) are clearly tagged.
- The image content is described, not just OCR'd.
- Things genuinely unknown (browser version, account IDs) are flagged as needing reporter confirmation rather than fabricated.

---

## Edge cases for the skill itself

- **Empty description, only images:** the markdown's "Summary" comes from the image content; flag everything else as needing reporter input.
- **Issue is in a non-English language:** preserve original language quotes in the Background section, but write the structured sections (AC, edge cases, DoD) in English (or in whatever language the user requests).
- **Issue type is custom or unrecognized:** ask the user which template fits best; don't auto-pick.
- **Multiple issues at once:** produce one markdown file per issue. Use `present_files` with all of them.
- **Comments contain the real requirements:** common when clients clarify in comments. Pull comment content too and merge into the appropriate section, attributing as needed (e.g., "Per follow-up comment from [reporter]: ...").
- **Atlassian MCP returns the description in ADF (Atlassian Document Format) JSON:** request `responseContentFormat: "markdown"` to avoid hand-parsing ADF. If markdown isn't available for the field, fall back to ADF and convert.
