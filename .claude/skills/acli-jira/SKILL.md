---
name: acli-jira
description: >
  Use this skill whenever the user wants to interact with Jira using the `acli jira` CLI tool.
  Triggers include: creating, editing, viewing, searching, or transitioning Jira issues/work items;
  managing Jira projects, boards, sprints, filters, dashboards, or fields via command line;
  any mention of "acli", "acli jira", "Jira CLI", or tasks like "create a Jira ticket from terminal",
  "search Jira issues with JQL", "transition issue to Done", "assign Jira issue", "add a comment to Jira issue".
  Always prefer this skill over the Atlassian MCP when the user wants to use the CLI.
---

# acli jira — Atlassian CLI for Jira

This skill teaches Claude how to use `acli jira`, the official Atlassian CLI for Jira Cloud.

**Docs:** https://developer.atlassian.com/cloud/acli/reference/commands/jira/

---

## Setup & Auth

```bash
# Login (interactive browser flow)
acli jira auth login

# Check current auth status
acli jira auth status

# Switch between authenticated accounts
acli jira auth switch

# Logout
acli jira auth logout
```

---

## Command Tree

```
acli jira
├── auth          login / logout / status / switch
├── board         list / view
├── dashboard     list / view
├── field         list
├── filter        list / view
├── project       archive / create / delete / list / restore / update / view
├── sprint        list-workitems
└── workitem      archive / assign / attachment-delete / attachment-list /
                  clone / comment-create / comment-delete / comment-list /
                  comment-update / comment-visibility / create / create-bulk /
                  delete / edit / link / search / transition / unarchive /
                  view / watcher-remove
```

For full flag details, see `references/commands.md`.

---

## Most Common Workflows

### Search for issues (JQL)
```bash
acli jira workitem search --jql "project = MYPROJ AND status = 'In Progress'"
acli jira workitem search --jql "assignee = @me AND sprint in openSprints()" --paginate
acli jira workitem search --jql "project = TEAM" --fields "key,summary,assignee,status" --csv
acli jira workitem search --jql "project = TEAM" --limit 50 --json
acli jira workitem search --jql "project = TEAM" --count  # just the number
```

### View a work item
```bash
acli jira workitem view --key KEY-123
acli jira workitem view --key "KEY-1,KEY-2" --json
```

### Create a work item
```bash
acli jira workitem create --summary "Fix login bug" --project "MYPROJ" --type "Bug"
acli jira workitem create --summary "New feature" --project "MYPROJ" --type "Story" \
  --assignee "user@example.com" --label "frontend,urgent"
acli jira workitem create --summary "Epic title" --project "MYPROJ" --type "Epic"
# With parent (subtask):
acli jira workitem create --summary "Subtask" --project "MYPROJ" --type "Subtask" --parent KEY-10
# From a file:
acli jira workitem create --from-file "workitem.txt" --project "PROJ" --type "Bug"
# Using JSON (generate template first):
acli jira workitem create --generate-json   # creates workitem.json template
acli jira workitem create --from-json "workitem.json"
```

### Edit a work item
```bash
acli jira workitem edit --key "KEY-1" --summary "Updated summary"
acli jira workitem edit --key "KEY-1,KEY-2" --assignee "user@example.com"
acli jira workitem edit --jql "project = TEAM AND status = 'To Do'" --labels "sprint-ready" --yes
acli jira workitem edit --key "KEY-1" --remove-assignee
```

### Transition (change status)
```bash
acli jira workitem transition --key "KEY-1" --status "In Progress"
acli jira workitem transition --key "KEY-1,KEY-2" --status "Done" --yes
acli jira workitem transition --jql "project = TEAM AND assignee = @me" --status "In Review"
```

### Assign a work item
```bash
acli jira workitem assign --key "KEY-1" --assignee "user@example.com"
acli jira workitem assign --key "KEY-1" --assignee "@me"    # self-assign
```

### Comment on a work item
```bash
acli jira workitem comment-create --key "KEY-1" --comment "Investigated, fix in KEY-2"
acli jira workitem comment-list --key "KEY-1"
acli jira workitem comment-update --key "KEY-1" --comment-id 10001 --comment "Updated note"
acli jira workitem comment-delete --key "KEY-1" --comment-id 10001
```

### Clone a work item
```bash
acli jira workitem clone --key "KEY-1"
acli jira workitem clone --key "KEY-1" --summary "Clone of KEY-1 for sprint 2"
```

### Delete a work item
```bash
acli jira workitem delete --key "KEY-1" --yes
```

### Archive / Unarchive
```bash
acli jira workitem archive --key "KEY-1,KEY-2" --yes
acli jira workitem unarchive --key "KEY-1"
```

### Bulk create
```bash
acli jira workitem create-bulk --from-json "bulk.json"
```

---

## Projects

```bash
acli jira project list
acli jira project view --key "MYPROJ"
acli jira project create --name "New Project" --key "NP" --type "scrum"
acli jira project update --key "MYPROJ" --name "Renamed Project"
acli jira project archive --key "MYPROJ"
acli jira project delete --key "MYPROJ" --yes
acli jira project restore --key "MYPROJ"
```

---

## Boards, Filters, Dashboards, Fields

```bash
# Boards
acli jira board list
acli jira board view --id 10001

# Filters
acli jira filter list
acli jira filter view --id 10001

# Dashboards
acli jira dashboard list
acli jira dashboard view --id 10001

# Fields
acli jira field list
```

---

## Sprints

```bash
# List work items in a sprint
acli jira sprint list-workitems --sprint-id 10001
acli jira sprint list-workitems --sprint-id 10001 --json
```

---

## Attachments

```bash
acli jira workitem attachment-list --key "KEY-1"
acli jira workitem attachment-delete --key "KEY-1" --attachment-id 10001
```

---

## Linking Work Items

```bash
acli jira workitem link --key "KEY-1" --link-type "blocks" --linked-key "KEY-2"
```

---

## Output Formats

Most commands support:
- `--json` — machine-readable JSON output
- `--csv` — CSV output (search only)
- `--web` — open in browser (search only)
- `--count` — show count only (search only)
- `--paginate` — auto-paginate all results (search only)
- `--fields "key,summary,assignee"` — select which fields to display (search only)

---

## Tips

- Use `@me` as shorthand for the currently authenticated user's email/account ID (e.g. `--assignee @me`).
- Use `--yes` / `-y` to skip confirmation prompts in scripts.
- Use `--ignore-errors` to continue bulk operations when individual items fail.
- JQL is the most powerful way to target multiple work items in `edit`, `transition`, and `search`.
- Use `--generate-json` on `create` or `edit` to get a template JSON file you can fill in for complex payloads.
- `--from-file` reads the summary from the first line and description from the rest of the file.

---

## Quick Reference Card

| Task | Command |
|---|---|
| Search issues by JQL | `acli jira workitem search --jql "..."` |
| View issue | `acli jira workitem view --key KEY-1` |
| Create issue | `acli jira workitem create --summary "..." --project PROJ --type Task` |
| Edit issue | `acli jira workitem edit --key KEY-1 --summary "..."` |
| Transition status | `acli jira workitem transition --key KEY-1 --status "Done"` |
| Assign | `acli jira workitem assign --key KEY-1 --assignee @me` |
| Add comment | `acli jira workitem comment-create --key KEY-1 --comment "..."` |
| List projects | `acli jira project list` |
| List sprint items | `acli jira sprint list-workitems --sprint-id ID` |
| Auth status | `acli jira auth status` |
