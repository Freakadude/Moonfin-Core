#!/usr/bin/env bash
# Keeps the personal episode-requests build on top of the latest official release.
#
# Run daily by .github/workflows/follow-upstream.yml, which sets:
#   UPSTREAM         the official repository, such as Moonfin-Client/Moonfin-Core
#   UPSTREAM_BRANCH  its main branch
#   DEFAULT_BRANCH   this fork's default branch, where this script lives
#   FEATURE          the branch with the episode-requests changes
#   LABEL            how to name the project in messages, such as "Moonfin app"
#   TEST_CMD         a command that must pass before an update is published
#   FEATURE_WORDS    a pattern that, in the official release notes, hints that the
#                    official project now has episode requests of its own
#   FEATURE_CODE     a pattern that, in the official code, hints at the same
#   AFTER_UPDATE     what happens on the devices after an update, for the message
#   GH_TOKEN         the automation token (contents, workflows, actions, issues)
#
# Everything it wants to tell the owner becomes an issue in this fork, which GitHub
# emails. Titles starting with "⚠ Action needed" are the ones that need a look.
set -euo pipefail

REPO="$GITHUB_REPOSITORY"
RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
ASK="Open the Moonfin Episode Downloader project in Claude and ask it to look at this issue."

# One issue per title, ever, so a daily run doesn't repeat itself.
issue() {
  local title="$1" body="$2" label="${3:-}"
  if gh issue list -R "$REPO" --state all --limit 200 --json title -q '.[].title' | grep -Fxq "$title"; then
    echo "Already reported: $title"
    return
  fi
  local args=(--title "$title" --body "$body")
  if [ -n "$label" ]; then
    gh label create "$label" -R "$REPO" --color D93F0B --description "Something needs a look" >/dev/null 2>&1 || true
    args+=(--label "$label")
  fi
  gh issue create -R "$REPO" "${args[@]}"
}

newer_than() { # is $1 a later version than $2?
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# --- The token -------------------------------------------------------------------------
expires=$(curl -sI -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/rate_limit \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="github-authentication-token-expiration" {print $2}')
if [ -n "$expires" ]; then
  days=$(( ( $(date -d "$expires" +%s) - $(date +%s) ) / 86400 ))
  echo "The automation token expires in $days days ($expires)"
  if [ "$days" -lt 14 ]; then
    issue "⚠ Action needed: the automation token expires on ${expires%% *}" \
"The token the automatic updates use runs out in $days days. After that, nothing updates any more.

Make a new one the same way as before (GitHub → Settings → Developer settings → Fine-grained tokens, only the two Moonfin forks, Contents, Workflows, Actions and Issues on Read and write) and replace the **AUTOMATION_TOKEN** secret in both forks (Settings → Secrets and variables → Actions)." needs-attention
  fi
fi

# --- Keep the daily run alive ----------------------------------------------------------
# GitHub pauses scheduled runs in a repository without commits for 60 days.
last=$(git log -1 --format=%ct "origin/$DEFAULT_BRANCH")
if [ $(( $(date +%s) - last )) -gt $(( 45 * 86400 )) ]; then
  keep=$(git commit-tree "origin/$DEFAULT_BRANCH^{tree}" -p "origin/$DEFAULT_BRANCH" \
    -m "Keep the daily upstream check running")
  git push -q origin "$keep:refs/heads/$DEFAULT_BRANCH"
  echo "Made a keep-alive commit on $DEFAULT_BRANCH"
fi

# --- Where things stand ----------------------------------------------------------------
git remote add upstream "https://github.com/$UPSTREAM.git" 2>/dev/null || true
git fetch -q upstream "$UPSTREAM_BRANCH" --tags
git checkout -q -B "$FEATURE" "origin/$FEATURE"

LATEST=$(gh release view -R "$UPSTREAM" --json tagName -q .tagName)
LATEST_URL=$(gh release view "$LATEST" -R "$UPSTREAM" --json url -q .url)
git fetch -q upstream "refs/tags/$LATEST:refs/tags/$LATEST" 2>/dev/null || true
FORK=$(git merge-base HEAD "upstream/$UPSTREAM_BRANCH")
# Official tags are plain versions such as 3.1.1. This fork's own build tags start with v.
BASE=$(git describe --tags --abbrev=0 --match '[0-9]*' "$FORK")
echo "$LABEL: the build is based on $BASE, the latest official release is $LATEST"

if ! newer_than "$LATEST" "$BASE"; then
  echo "Nothing new upstream."
  exit 0
fi

# --- Has the official project caught up? -----------------------------------------------
# Only what's new since the build's base counts: older code may mention the same words
# for other reasons.
hints=()
if gh release view "$LATEST" -R "$UPSTREAM" --json body -q .body | grep -qiE "$FEATURE_WORDS"; then
  hints+=("its release notes mention something like it")
fi
# Real code only: tests and comments mention Sonarr's commands for other reasons.
added=$(git diff "$BASE" "$LATEST" -- . ':(exclude,glob)**/*[Tt]est*/**' ':(exclude,glob)**/*[Tt]est*' \
  | grep -E '^\+' | grep -vE '^\+\s*(//|#|\*|/\*)' | grep -oiE "$FEATURE_CODE" | head -1 || true)
if [ -n "$added" ]; then
  hints+=("its new code contains \`$added\`")
fi
if [ "${#hints[@]}" -gt 0 ]; then
  issue "💡 The official $LABEL $LATEST may have episode requests built in" \
"The official **$LABEL** release **$LATEST** may already do what your episode-requests build adds: $(IFS=';'; echo "${hints[*]}" | sed 's/;/, and /g').

Release notes: $LATEST_URL

If it does, you could go back to the official version and stop maintaining your own. Your build is still updated as usual until you decide. $ASK"
fi

# --- Move the episode requests onto the new release ------------------------------------
OLD=$(git rev-parse HEAD)
if ! git rebase -q --onto "$LATEST" "$FORK"; then
  conflicts=$(git diff --name-only --diff-filter=U | sed 's/^/- /')
  git rebase --abort
  issue "⚠ Action needed: the official $LABEL $LATEST clashes with the episode requests" \
"The official **$LABEL** release **$LATEST** changed the same parts of these files as the episode requests, so the update couldn't be done automatically:

$conflicts

Nothing was changed: your devices keep the current version, based on $BASE.

Release notes: $LATEST_URL
Run: $RUN_URL

$ASK" needs-attention
  exit 0
fi

echo "Rebased onto $LATEST; checking it"
if ! bash -c "$TEST_CMD"; then
  issue "⚠ Action needed: the official $LABEL $LATEST breaks the episode requests" \
"The episode requests could be moved onto the official **$LABEL** release **$LATEST**, but the checks failed afterwards, so nothing was published. Your devices keep the current version, based on $BASE.

Release notes: $LATEST_URL
Run (the check's output is at the end): $RUN_URL

$ASK" needs-attention
  exit 0
fi

# Files both the official release and the episode requests changed. The checks passed, but
# these are the places where a change in behaviour would show.
touched=$(comm -12 \
  <(git diff --name-only "$FORK" "$LATEST" | sort) \
  <(git diff --name-only "$LATEST" HEAD | sort) | sed 's/^/- /')

git push -q --force-with-lease="$FEATURE:$OLD" origin "HEAD:$FEATURE"
echo "Published $FEATURE on top of $LATEST"

issue "✅ Updated to the official $LABEL $LATEST" \
"Your episode-requests build now sits on top of the official **$LABEL** release **$LATEST** (it was based on $BASE). The checks passed, and the new build is running now.

$AFTER_UPDATE

Release notes: $LATEST_URL
$( [ -n "$touched" ] && printf '\nThe official release also changed these files the episode requests touch. Everything still builds and passes its checks, but if something about episode requests behaves differently, this is where to look:\n%s\n' "$touched" )
If the build fails you'll get a separate \"⚠ Action needed\" issue. You can close this one."
