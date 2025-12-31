---
name: issue-swarm
description: Spawns parallel coding agents to work on multiple GitHub issues using git worktrees. Use when asked to work on multiple issues in parallel, batch process issues, or run agents on a list of issues.
---

# Issue Swarm

Orchestrates parallel headless coding agents across isolated git worktrees to work on multiple GitHub issues simultaneously.

## Usage

Run the swarm script with issue numbers:

```bash
scripts/swarm.sh 48 50 52
```

Or with options:

```bash
scripts/swarm.sh --agent coder --model anthropic/claude-sonnet-4-20250514 48 50 52
```

## What It Does

For each issue number:

1. **Fetches** issue title and body from GitHub API
2. **Creates** a git worktree at `.worktrees/issue-<number>/`
3. **Creates** a branch `issue/<number>`
4. **Spawns** `opencode run` with the issue context as prompt
5. **Commits** changes (agent is instructed to commit)
6. **Logs** output to `.worktrees/issue-<number>.log`

All issues run in **parallel** using background jobs.

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--agent <name>` | opencode agent to use | (default agent) |
| `--model <provider/model>` | Model to use | (default model) |
| `--push` / `--no-push` | Push branches after completion | enabled |
| `--pr` / `--no-pr` | Create PRs after completion | enabled |
| `--cleanup` / `--no-cleanup` | Delete worktrees after success | enabled |

## Requirements

- `gh` CLI authenticated
- `opencode` installed
- Git repository with GitHub remote

## Monitoring

Watch progress:
```bash
tail -f .worktrees/issue-*.log
```

Check running jobs:
```bash
jobs -l
```

## Output Structure

```
.worktrees/
├── issue-48/           # Worktree for issue 48
├── issue-48.log        # Agent output log
├── issue-50/
├── issue-50.log
└── ...
```

## Example

```bash
# Work on 3 issues in parallel
scripts/swarm.sh 48 50 52

# With specific model and auto-push
scripts/swarm.sh --model anthropic/claude-sonnet-4-20250514 --push 48 50 52

# Using a custom agent
scripts/swarm.sh --agent coder 48 50 52
```

## Prompt Template

Each agent receives:

```
Work on GitHub Issue #<number>: <title>

<issue body>

Instructions:
1. Read the issue carefully and understand what needs to be done
2. Implement the changes described
3. Run tests to verify
4. Run linting
5. Commit your changes with a descriptive message referencing the issue
6. Summarize what you did
```
