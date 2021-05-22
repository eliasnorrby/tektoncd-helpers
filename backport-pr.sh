#!/usr/bin/env bash

BASE_BRANCH=main

ERROR="Bad usage, see ${0##*/} -h"

read -r -d "" USAGE <<EOF
Given changes in a local branch of a fork and a list of releases to patch, open
PRs with the changes targeting the release branches of each respective release.

Usage: ${0##*/} [-h] <-r FILE> <-b FILE> <-t TITLE> [-p FORK] [branch]
  -r RELEASES File containing list of releases to patch
  -b BODY     File containing PR body
  -t TITLE    PR title
  -p FORK     Preview PR creation in FORK
  -h          Show usage

Example:
  ${0##*/} -r releases -b body update-doc-titles

EOF

if [ "$1" = "--help" ]; then
  echo "$USAGE" && exit 0
fi

while getopts r:b:t:p:h opt; do
  case $opt in
    r) RELEASE_FILE=$OPTARG                ;;
    b) BODY_FILE=$OPTARG                   ;;
    t) PR_TITLE=$OPTARG                    ;;
    p) FORK=$OPTARG                        ;;
    h) echo "$USAGE" && exit 0             ;;
    *) echo "$ERROR" && exit 1             ;;
  esac
done

BRANCH=${*:$OPTIND:1}
if [ -z "$BRANCH" ]; then
  BRANCH=$(git branch --show-current)
fi

OTHER_ARGS=${*:$OPTIND+1}

if [ -n "$OTHER_ARGS" ]; then
  echo "ERROR: Unprocessed positional arguments: $OTHER_ARGS"
  exit 1
fi

# Validation
if [ -z "$RELEASE_FILE" ] || [ -z "$BODY_FILE" ] || [ -z "$PR_TITLE" ]; then
  echo "Missing required arguments"
  echo "$USAGE" && exit 1
fi

verify_is_file() {
  if [ ! -f "$1" ]; then
    echo "Not a file: $1"
    exit 1
  fi
}

verify_valid_releases() {
  while read -r release; do
    if [ ! -f ".git/refs/remotes/upstream/$release" ]; then
      echo "No upstream branch upstream/$release found. Did you fetch the latest changes?"
      exit 1
    fi
  done < "$RELEASE_FILE"
}

verify_is_file "$RELEASE_FILE"
verify_is_file "$BODY_FILE"

verify_valid_releases "$RELEASE_FILE"

if [ ! -f ".git/refs/heads/$BRANCH" ]; then
  echo "$BRANCH is not available locally"
  exit 1
fi

# Work

_echo() {
  echo ">> $*"
}

prompt_return() {
  local message="$1"
  read -rp "$message"
}

handle_release() {
  local release=$1 choice
  local patch_branch=${BRANCH}-$release-patch
  local title="${PR_TITLE} ($release patch)"

  echo
  _echo "Attempting to patch $release ..."
  git checkout "$BRANCH"
  git checkout -b "${patch_branch}"

  git_rebase() {
    git rebase --onto "upstream/$release" "$BASE_BRANCH" "${patch_branch}" "$@"
  }
  
  if ! git_rebase; then
    _echo "Conflicts during rebase. How to proceed?"
    _echo "1) Retry using -X theirs"
    _echo "2) Resolve manually"
    _echo "3) Skip"

    read -rp "Select an option: " choice

    case $choice in
      1)
        git rebase --abort
        git_rebase -X theirs
        ;;
      2)
        _echo "Resolve conflicts and run 'git rebase --continue'"
        prompt_return "Press ENTER to continue"
        ;;
      3)
        _echo "Skipping"
        git rebase --abort
        return 1
        ;;
      *)
        _echo "Invalid choice: $choice, skipping"
        git rebase --abort
        return 1
        ;;
    esac
  fi

  _echo "Rebase complete. Take a look at the diff before pushing."

  prompt_return "Press Enter to push branch and open PR"

  if ! git push -u; then
    _echo "Could not push $patch_branch"
    return 1
  fi

  if [ -n "$FORK" ]; then
     gh pr create --base "$release" --body "This is a preview" --title "$title" --draft --repo "$FORK"
  elif ! gh pr create --base "$release" --body-file "$BODY_FILE" --title "$title" --draft; then
    _echo "Failed to open PR for $release"
    return 1
  fi
}

while read -r release; do
  if handle_release "$release"; then
    _echo "${release}: SUCCESS"
  else
    _echo "${release}: ERROR"
  fi
done < "$RELEASE_FILE"

exit

# Plan
# for each release
# - checkout local branch
# - create new branch with suffix
# - rebase onto upstream/release-branch
# - push to origin
# - open PR with body


