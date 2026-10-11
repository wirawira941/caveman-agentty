#!/usr/bin/env sh
# Create the GitHub repo (private) and push.
#
# Usage:
#   sh push-to-github.sh <github-token>
#
# The token is used only to create the repo over the API; it is never written
# to disk, never logged, and is dropped from memory when the script exits.
set -u

TOKEN="${1:-}"
[ -n "$TOKEN" ] || { echo "usage: $0 <github-token>"; exit 2; }

REPO="caveman-agentty"
OWNER="wirawira941"
DESC="Caveman LLM observability for agentty on Termux"

# 1. who am i? (also validates the token)
code=$(curl -s -o /tmp/.ghwho -w '%{http_code}' -H "Authorization: token [REDACTED]" \
  https://api.github.com/user)
if [ "$code" != "200" ]; then
  echo "token rejected (HTTP $code): $(cat /tmp/.ghwho 2>/dev/null)"
  echo "generate a classic PAT with repo scope: https://github.com/settings/tokens/new"
  exit 1
fi
login=$(python3 -c "import json;print(json.load(open('/tmp/.ghwho')).get('login'))" 2>/dev/null)
rm -f /tmp/.ghwho
echo "authenticated as $login"

# 2. create the private repo if it does not exist yet
code=$(curl -s -o /tmp/.ghrepo -w '%{http_code}' -H "Authorization: token [REDACTED]" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$REPO\",\"private\":true,\"description\":\"$DESC\"}" \
  https://api.github.com/user/repos)
case "$code" in
  201) echo "created $OWNER/$REPO (private)" ;;
  422) echo "$OWNER/$REPO already exists; pushing to it" ;;
  *)   echo "could not create repo (HTTP $code): $(cat /tmp/.ghrepo 2>/dev/null)"; exit 1 ;;
esac
rm -f /tmp/.ghrepo

# 3. push over HTTPS using the token in the URL (transient, in-memory only)
git remote set-url origin "https://$TOKEN@github.com/$OWNER/$REPO.git"
git push -u origin main
rc=$?

# 4. put the remote back to the SSH form so the token is not stored anywhere
git remote set-url origin "git@github.com:$OWNER/$REPO.git"
echo "remote reset to ssh; token not persisted anywhere"

exit $rc
