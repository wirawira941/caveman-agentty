#!/usr/bin/env sh
# Create the private GitHub repo and push.
#
#   sh create-and-push.sh <github-token>
#
# SSH can create repos on GitHub, so this does it over the API and then pushes
# over SSH. The token is used for one API call only: it is never written to
# disk, never stored in the git remote, and never logged.
set -u
R=/data/data/com.termux/files/home/caveman-agentty

TOKEN="${1:-}"
[ -n "$TOKEN" ] || { echo "usage: $0 <github-token>"; exit 2; }
OWNER="wirawira941"
REPO="caveman-agentty"

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token [REDACTED]" \
  https://api.github.com/user)
[ "$code" = "200" ] || { echo "token rejected (HTTP $code)"; exit 1; }

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token [REDACTED]" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$REPO\",\"private\":true,\"description\":\"Caveman LLM observability for agentty on Termux\"}" \
  https://api.github.com/user/repos)
case "$code" in
  201) echo "created $OWNER/$REPO (private)" ;;
  422) echo "$OWNER/$REPO already exists" ;;
  *)   echo "could not create repo (HTTP $code)"; exit 1 ;;
esac

git -C "$R" remote remove origin 2>/dev/null
git -C "$R" remote add origin "git@github.com:$OWNER/$REPO.git"
git -C "$R" push -u origin main
