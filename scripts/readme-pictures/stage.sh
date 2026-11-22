#!/bin/bash
# Stages the README's pictures in a throwaway copy of pi² (README.md here has the steps): makes the sample repositories,
# gives the copy the stand-in server as an endpoint, makes three projects and their agents, sends each orchestrator
# its first message, makes three chats, and turns computer use on for one agent. Every approval but Forge's
# `git push` is allowed as it comes, so that one stays waiting for the pictures.
#
#   scripts/readme-pictures/stage.sh <suffix> <folder> [port]
#
# <suffix> is a copy `scripts/test-copy start` started from this checkout, and every request goes through
# `scripts/test-copy`, which refuses any other. <folder> is where the sample repositories go (reset.sh), such as
# /Users/Shared/Projects. [port] is the stand-in server's (server.mjs), 47291 by default.
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 <suffix> <folder> [port]" >&2; exit 2; }
S=$1
base=${2%/}
port=${3:-47291}
here=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
copy="$here/../test-copy"
call() { "$copy" call "$S" "$@"; }
O='"provider":"custom-ollama"'
log() { echo "== $*"; }

curl -fsS "http://127.0.0.1:$port/v1/models" >/dev/null || { echo "The stand-in server is not answering on port $port: start server.mjs first." >&2; exit 1; }
"$here/reset.sh" "$base"

call endpoints.save "{\"name\":\"Ollama\",\"baseUrl\":\"http://127.0.0.1:$port/v1\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"qwen3-coder:30b\",\"name\":\"Qwen3 Coder 30B\",\"contextWindow\":262144},{\"id\":\"gpt-oss:120b\",\"name\":\"GPT-OSS 120B\",\"contextWindow\":131072},{\"id\":\"gemma3:27b\",\"name\":\"Gemma 3 27B\",\"contextWindow\":131072}]}" >/dev/null
call settings.setAgentDefault "{\"model\":{$O,\"modelId\":\"gpt-oss:120b\"}}" >/dev/null

project() { # <name> → "<project id> <orchestrator's conversation>"
	local made id conversation orchestrator
	made=$(call projects.create "{\"folder\":\"$base/$1\"}")
	id=$(echo "$made" | jq -r .result.id)
	conversation=$(echo "$made" | jq -r .result.conversation)
	orchestrator=$(call projects.list | jq -r ".result.projects[] | select(.id==\"$id\") | .orchestratorId")
	call agents.save "{\"agent\":{\"id\":\"$orchestrator\",\"name\":\"Orchestrator\",\"model\":{$O,\"modelId\":\"gpt-oss:120b\"}}}" >/dev/null
	echo "$id $conversation"
}
agent() { # <project id> <name> <colour> <access> <model> → the agent's id
	call projects.addAgent "{\"projectId\":\"$1\",\"agent\":{\"name\":\"$2\",\"color\":\"$3\",\"access\":\"$4\",\"model\":{$O,\"modelId\":\"$5\"}}}" | jq -r .result.id
}

# Agents in different projects have names of their own, since Usage lists agents by name only.
read -r SP SC < <(project storefront)
agent "$SP" Forge orange ask qwen3-coder:30b >/dev/null
agent "$SP" Quill pink full gemma3:27b >/dev/null
agent "$SP" Atlas blue full gpt-oss:120b >/dev/null
scout=$(agent "$SP" Scout green full gemma3:27b)
call projects.set "{\"id\":\"$SP\",\"settings\":{\"wakeOnReports\":true}}" >/dev/null
for rule in "Never push to main; every change goes through a pull request." "Run npm test before asking for a review."; do
	call projects.rules.add "{\"projectId\":\"$SP\",\"binds\":\"everyone\",\"text\":\"$rule\"}" >/dev/null
done
call memory.add "{\"projectId\":\"$SP\",\"text\":\"Tax rates live in src/tax; Canadian addresses keep the province in shipping.province since the new address form.\"}" >/dev/null || true
read -r DP DC < <(project docs-site)
agent "$DP" Wren teal full gemma3:27b >/dev/null
read -r MP MC < <(project mobile-app)
agent "$MP" Sage green full gemma3:27b >/dev/null

"$copy" show "$S" 'project:storefront#now' --hub both
call submit "{\"id\":$SC,\"text\":\"Customers in Canada were charged the wrong tax at checkout this week. Find out why and fix it. And the order confirmation email still shows the old logo, can you swap it?\"}" >/dev/null
call submit "{\"id\":$DC,\"text\":\"The API reference still documents the v1 endpoints. Bring it up to date for v2 before the launch on Thursday.\"}" >/dev/null
call submit "{\"id\":$MC,\"text\":\"Last night's TestFlight build failed. Can you find out why?\"}" >/dev/null
sleep 3
call conversation.rename "{\"id\":$SC,\"title\":\"Canadian tax and the email logo\"}" >/dev/null
call conversation.rename "{\"id\":$DC,\"title\":\"API reference for v2\"}" >/dev/null
call conversation.rename "{\"id\":$MC,\"title\":\"The failed TestFlight build\"}" >/dev/null

# Chat mode: the pictured chat last, so that it is the newest.
chat() { # <title> [message]
	local id
	id=$(call conversation.create "{\"chat\":true,\"model\":{$O,\"modelId\":\"gpt-oss:120b\"}}" | jq -r .result.id)
	call submit "{\"id\":$id,\"text\":\"${2:-$1}\"}" >/dev/null
	sleep 2
	call conversation.rename "{\"id\":$id,\"title\":\"$1\"}" >/dev/null
	echo "$id"
}
chat "Regex for Canadian postal codes" >/dev/null
chat "Reply to a customer about a late parcel" >/dev/null
CHAT=$(chat "GST, HST and PST for an online shop" "What's the difference between GST, HST and PST in Canada? Which applies to an online shop?")

# Computer use for Scout, to picture its section of the agent's settings. Nothing here asks macOS for anything.
call agents.save "{\"agent\":{\"id\":\"$scout\",\"name\":\"Scout\",\"computer\":{\"enabled\":true,\"apps\":[\"com.apple.iWork.Numbers\",\"com.apple.Preview\",\"com.apple.TextEdit\"],\"ask\":true}}}" >/dev/null

# Allow every approval but Forge's push (the worktree for Forge, its edit, its test file, its test run and commit).
for _ in $(seq 1 90); do
	item=$(call needs.list '{}' | jq -c '[.result.items[] | select(.kind=="approval")][0] // empty')
	if [[ -n $item ]]; then
		if echo "$item" | grep -q 'git push'; then log "Forge's push is waiting"; break; fi
		echo "$item" | jq -r '"allowing \(.agentName): \(.tool) \(.arguments | tostring | .[0:100])"'
		"$copy" answer "$S" "$(echo "$item" | jq -r .conversationId)" allow
	fi
	sleep 2
done

titled() { "$copy" conversations "$S" | awk -F'\t' -v t="$1" '$2 == t { print $1; exit }'; }
ATLAS=$(titled "Run the checkout end-to-end suite")
cat <<EOF
== Staged. Conversations: storefront's orchestrator $SC, docs-site's $DC, mobile-app's $MC, Atlas's $ATLAS, the chat $CHAT.
   Scout is $scout.
   Scout's report and the decision come about 40 seconds after the start; Atlas's end-to-end suite runs about
   9 minutes, so take the hub, Dashboard and panes pictures within that (README.md here).
EOF
