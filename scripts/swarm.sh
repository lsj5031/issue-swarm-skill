#!/usr/bin/env bash
set -euo pipefail

# Issue Swarm - Parallel GitHub issue processing with opencode
# Usage: swarm.sh [options] <issue-numbers...>

WORKTREE_DIR=".worktrees"
AGENT=""
MODEL=""
PUSH=true
CREATE_PR=true
CLEANUP=true
ISSUES=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --agent)
            AGENT="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --no-push)
            PUSH=false
            shift
            ;;
        --pr)
            CREATE_PR=true
            PUSH=true  # PR requires push
            shift
            ;;
        --no-pr)
            CREATE_PR=false
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --no-cleanup)
            CLEANUP=false
            shift
            ;;
        -h|--help)
            echo "Usage: swarm.sh [options] <issue-numbers...>"
            echo ""
            echo "Options:"
            echo "  --agent <name>    opencode agent to use"
            echo "  --model <m>       Model (provider/model format)"
            echo "  --push            Push branches after completion"
            echo "  --pr              Create PRs after completion"
            echo "  --cleanup         Delete worktrees after success"
            echo "  -h, --help        Show this help"
            exit 0
            ;;
        *)
            ISSUES+=("$1")
            shift
            ;;
    esac
done

if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo "Error: No issue numbers provided"
    echo "Usage: swarm.sh [options] <issue-numbers...>"
    exit 1
fi

# Ensure worktree directory exists
mkdir -p "$WORKTREE_DIR"

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [[ -z "$REPO" ]]; then
    echo "Error: Not in a GitHub repository or gh not authenticated"
    exit 1
fi

# Cleanup any leftover opencode servers from previous runs
pkill -f "opencode serve" 2>/dev/null || true
sleep 1

echo "🐝 Issue Swarm starting for $REPO"
echo "📋 Issues: ${ISSUES[*]}"
echo ""

# Define colors for parallel logs
COLORS=('\033[0;34m' '\033[0;32m' '\033[0;33m' '\033[0;35m' '\033[0;36m' '\033[0;31m')
NC='\033[0m' # No Color

# Function to process a single issue
process_issue() {
    local issue_num=$1
    local color_idx=$2
    local color="${COLORS[$color_idx % ${#COLORS[@]}]}"
    local tag="${color}[Issue #$issue_num]${NC}"
    
    local worktree_path="$WORKTREE_DIR/issue-$issue_num"
    local log_file="$WORKTREE_DIR/issue-$issue_num.log"
    local branch_name="issue/$issue_num"

    echo -e "$tag Starting..." | tee "$log_file"

    # Fetch issue details
    local issue_json
    issue_json=$(gh issue view "$issue_num" --json title,body 2>>"$log_file")
    if [[ -z "$issue_json" ]]; then
        echo -e "$tag ❌ Failed to fetch issue" | tee -a "$log_file"
        return 1
    fi

    local title
    local body
    title=$(echo "$issue_json" | jq -r '.title')
    body=$(echo "$issue_json" | jq -r '.body // "No description provided"')

    echo -e "$tag Title: $title" | tee -a "$log_file"

    # Clean up any stale worktree references
    git worktree prune 2>/dev/null || true

    # Check if worktree already exists
    if [[ -d "$worktree_path" ]]; then
        echo -e "$tag Worktree exists, reusing..." | tee -a "$log_file"
    else
        # Remove stale worktree dir if exists
        rm -rf "$worktree_path" 2>/dev/null || true

        # Create branch and worktree
        # First check if branch exists
        if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
            echo -e "$tag Branch exists, creating worktree..." | tee -a "$log_file"
            git worktree add -f "$worktree_path" "$branch_name" 2>>"$log_file"
        else
            echo -e "$tag Creating new branch and worktree..." | tee -a "$log_file"
            git worktree add -f -b "$branch_name" "$worktree_path" 2>>"$log_file"
        fi
    fi

    # Build the prompt
    local prompt="Work on GitHub Issue #$issue_num: $title

$body

Instructions:
1. Read the issue carefully and understand what needs to be done
2. Implement the changes described
3. Run tests to verify your changes work
4. Run linting and formatting
5. Commit your changes with a descriptive message that references issue #$issue_num
6. Summarize what you did at the end"

    # Start opencode server for this worktree, then send message via API
    local port=$((4100 + issue_num % 1000))

    echo -e "$tag Starting opencode server on port $port..." | tee -a "$log_file"

    # Start server in background (use absolute path for log)
    local abs_log_file
    abs_log_file="$(pwd)/$log_file"
    (cd "$worktree_path" && opencode serve --port "$port" >> "$abs_log_file" 2>&1) &
    local server_pid=$!

    # Wait for server to be ready
    local retries=30
    while ! curl -s "http://127.0.0.1:$port/doc" > /dev/null 2>&1; do
        sleep 1
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            echo -e "$tag ❌ Server failed to start" | tee -a "$log_file"
            kill $server_pid 2>/dev/null || true
            return 1
        fi
    done

    echo -e "$tag Server ready, starting event stream..." | tee -a "$log_file"

    # Stream events to log file for visibility (filter to interesting events)
    (curl -s -N "http://127.0.0.1:$port/event" 2>/dev/null | while read -r line; do
        # Parse SSE data lines
        if [[ "$line" == data:* ]]; then
            data="${line#data:}"
            # Extract event type and relevant info
            event_type=$(echo "$data" | jq -r '.type // .payload.type // empty' 2>/dev/null)
            case "$event_type" in
                message.part.updated)
                    part_type=$(echo "$data" | jq -r '.properties.part.type // .payload.properties.part.type // empty' 2>/dev/null)
                    case "$part_type" in
                        text)
                            # Show text delta (agent thinking)
                            delta=$(echo "$data" | jq -r '.properties.delta // .payload.properties.delta // empty' 2>/dev/null)

                            if [[ -n "$delta" ]]; then
                                echo -ne "${color}${delta}${NC}"
                            fi
                            ;;
                        tool)
                            # Show tool calls
                            tool=$(echo "$data" | jq -r '.properties.part.tool // .payload.properties.part.tool // empty' 2>/dev/null)
                            status=$(echo "$data" | jq -r '.properties.part.state.status // .payload.properties.part.state.status // empty' 2>/dev/null)
                            
                            if [[ "$status" == "running" ]]; then
                                title=$(echo "$data" | jq -r '.properties.part.state.title // .payload.properties.part.state.title // empty' 2>/dev/null)
                                input=$(echo "$data" | jq -r '.properties.part.state.input // .payload.properties.part.state.input // empty' 2>/dev/null)
                                command=$(echo "$input" | jq -r '.command // empty' 2>/dev/null)
                                
                                echo ""
                                echo -e "${tag} 🛠️  $tool: $title"
                                if [[ -n "$command" ]]; then
                                    echo -e "${tag}    Command: $command"
                                fi
                            elif [[ "$status" == "completed" ]]; then
                                output=$(echo "$data" | jq -r '.properties.part.state.output // .payload.properties.part.state.output // empty' 2>/dev/null)
                                # Truncate output if too long
                                short_output=$(echo "$output" | head -c 200 | tr '\n' ' ')
                                if [[ ${#output} -gt 200 ]]; then
                                    short_output="$short_output..."
                                fi
                                echo -e "${tag}    Output: $short_output"
                            fi
                            ;;
                    esac
                    ;;
                session.error)
                    error=$(echo "$data" | jq -r '.properties.error.message // .properties.error // .payload.properties.error.message // .payload.properties.error // empty' 2>/dev/null)
                    [[ -n "$error" ]] && echo -e "${tag} ERROR: $error"
                    ;;
            esac
        fi
    done) 2>&1 | tee -a "$abs_log_file" &
    local event_pid=$!

    echo -e "$tag Creating session..." | tee -a "$log_file"

    # Create session
    local session_response
    session_response=$(curl -s -X POST "http://127.0.0.1:$port/session" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Issue #$issue_num\"}")

    local session_id
    session_id=$(echo "$session_response" | jq -r '.id')

    if [[ -z "$session_id" || "$session_id" == "null" ]]; then
        echo -e "$tag ❌ Failed to create session" | tee -a "$log_file"
        kill $server_pid 2>/dev/null || true
        return 1
    fi

    echo -e "$tag Session $session_id created, sending prompt..." | tee -a "$log_file"

    # Build message body with model and optional agent
    local message_body

    if [[ -n "$AGENT" ]]; then
        if [[ -n "$MODEL" ]]; then
            local provider="${MODEL%%/*}"
            local mod="${MODEL#*/}"
            message_body=$(jq -n \
                --arg text "$prompt" \
                --arg providerID "$provider" \
                --arg modelID "$mod" \
                --arg agent "$AGENT" \
                '{
                    parts: [{type: "text", text: $text}],
                    model: {providerID: $providerID, modelID: $modelID},
                    agent: $agent
                }')
        else
            message_body=$(jq -n \
                --arg text "$prompt" \
                --arg agent "$AGENT" \
                '{
                    parts: [{type: "text", text: $text}],
                    agent: $agent
                }')
        fi
    elif [[ -n "$MODEL" ]]; then
        local provider="${MODEL%%/*}"
        local mod="${MODEL#*/}"
        message_body=$(jq -n \
            --arg text "$prompt" \
            --arg providerID "$provider" \
            --arg modelID "$mod" \
            '{
                parts: [{type: "text", text: $text}],
                model: {providerID: $providerID, modelID: $modelID}
            }')
    else
        message_body=$(jq -n \
            --arg text "$prompt" \
            '{
                parts: [{type: "text", text: $text}]
            }')
    fi

    echo -e "$tag Request: $(echo "$message_body" | jq -c 'del(.parts)')" | tee -a "$log_file"
    echo -e "$tag Running agent..." | tee -a "$log_file"

    local response
    local http_code
    response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:$port/session/$session_id/message" \
        -H "Content-Type: application/json" \
        -d "$message_body" \
        --max-time 1800)

    # Extract HTTP code from last line
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    # Log response summary
    local success=true
    if [[ "$http_code" != "200" ]]; then
        echo -e "$tag HTTP $http_code - Error: $(echo "$response" | head -c 500)" | tee -a "$log_file"
        success=false
    else
        echo -e "$tag Full agent response:" | tee -a "$log_file"
        echo "$response" | jq . 2>/dev/null | tee -a "$log_file" || echo "$response" | tee -a "$log_file"
        local part_count=$(echo "$response" | jq '.parts | length' 2>/dev/null || echo "0")
        local last_part=$(echo "$response" | jq -c '.parts[-1]' 2>/dev/null | head -c 300)
        echo -e "$tag Response: $part_count parts, last: $last_part" | tee -a "$log_file"
    fi
    echo -e "$tag Agent completed" | tee -a "$log_file"

    # Cleanup server and event stream
    kill $event_pid 2>/dev/null || true
    kill $server_pid 2>/dev/null || true

    if [[ "$success" == "true" ]]; then
        echo -e "$tag ✅ Agent completed" | tee -a "$log_file"

        # Push if requested
        if [[ "$PUSH" == true ]]; then
            echo -e "$tag Pushing branch..." | tee -a "$log_file"
            (cd "$worktree_path" && git push -u origin "$branch_name" 2>&1) | tee -a "$log_file"
        fi

        # Create PR if requested
        if [[ "$CREATE_PR" == true ]]; then
            # Verify we have commits to PR
            if (cd "$worktree_path" && git diff --quiet HEAD origin/main 2>/dev/null); then
                 echo -e "$tag ❌ No changes detected compared to main, marking as failed..." | tee -a "$log_file"
                 return 1
            else
                echo -e "$tag Creating PR..." | tee -a "$log_file"
                if ! (cd "$worktree_path" && gh pr create --fill --body "Closes #$issue_num" 2>&1) | tee -a "$log_file"; then
                    echo -e "$tag ⚠️ PR creation failed (likely already exists), continuing..." | tee -a "$log_file"
                fi
            fi
        fi

        # Cleanup if requested
        if [[ "$CLEANUP" == true ]]; then
            echo -e "$tag Cleaning up worktree..." | tee -a "$log_file"
            git worktree remove "$worktree_path" 2>>"$log_file" || true
        fi
        return 0
    else
        echo -e "$tag ❌ Agent failed (HTTP $http_code)" | tee -a "$log_file"
        return 1
    fi
}

# Export function and variables for parallel execution
export -f process_issue
export WORKTREE_DIR AGENT MODEL PUSH CREATE_PR CLEANUP

# Track PIDs for parallel execution
declare -A PIDS

# Trap to handle interruption
cleanup_swarm() {
    echo ""
    echo "🛑 Swarm interrupted! Cleaning up..."
    
    # Kill all background issue processors
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    
    # Kill all opencode servers started by this script (assuming we own them)
    # We use a broader kill pattern here since we don't have server PIDs in the main process
    pkill -f "opencode serve" 2>/dev/null || true
    
    echo "Cleanup complete."
    exit 1
}

trap cleanup_swarm SIGINT SIGTERM

echo "🚀 Spawning ${#ISSUES[@]} parallel agents..."
echo ""

# Start all issues in parallel (with small stagger to avoid plugin install race)
idx=0
for issue_num in "${ISSUES[@]}"; do
    process_issue "$issue_num" "$idx" &
    PIDS[$issue_num]=$!
    echo "  Started issue #$issue_num (PID: ${PIDS[$issue_num]})"
    idx=$((idx + 1))
    sleep 2  # Brief stagger to avoid concurrent plugin initialization
done

echo ""
echo "⏳ Waiting for all agents to complete..."
echo "   Monitor with: tail -f $WORKTREE_DIR/issue-*.log"
echo ""

# Wait for all and collect results
FAILED=()
SUCCEEDED=()

for issue_num in "${ISSUES[@]}"; do
    if wait "${PIDS[$issue_num]}"; then
        SUCCEEDED+=("$issue_num")
    else
        FAILED+=("$issue_num")
    fi
done

# Summary
echo ""
echo "═══════════════════════════════════════"
echo "🐝 Swarm Complete"
echo "═══════════════════════════════════════"
echo "✅ Succeeded: ${SUCCEEDED[*]:-none}"
echo "❌ Failed: ${FAILED[*]:-none}"
echo ""
echo "Logs: $WORKTREE_DIR/issue-*.log"
echo "Worktrees: $WORKTREE_DIR/issue-*/"

# Exit with error if any failed
[[ ${#FAILED[@]} -eq 0 ]]
