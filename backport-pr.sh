#!/usr/bin/env bash

# After merging a PR to main, this script can be used to backport the changes
# to a number of previous releases by opening PRs targeting their respective
# release branches.
#
# Strategy:
# for each release
# - checkout branch containing wanted changes
# - create new branch with suffix
# - rebase onto upstream/release-branch
#   - if rebase fails, offer options for resolving conflicts
# - push to origin
# - open PR with body and title

BASE_BRANCH=main

ERROR="Bad usage, see ${0##*/} -h"

read -r -d "" USAGE <<EOF
Given changes in a local branch of a fork and a list of releases to patch, open
PRs with the changes targeting the release branches of each respective release.

Usage: ${0##*/} [-hlc] <-r FILE> <-b FILE> <-t TITLE> [-p FORK] [-B BASE] [branch]
  -r RELEASES File containing list of releases to patch
  -b BODY     File containing PR body
  -t TITLE    PR title
  -p FORK     Preview PR creation in FORK
  -B BASE     Rebase base (default: $BASE_BRANCH)
  -l          Only do local work
  -c          Continue: open PRs for existing branches
  -h          Show usage

If no branch is given, the currently checked out branch is used.

Example:
  ${0##*/} -r releases -b body -t "Fix stuff" update-doc-titles
  # Don't push or open PRs:
  ${0##*/} -r releases -b body -t "Fix stuff" -l
  # On finding existing branches, open PRs using them instead of failing:
  ${0##*/} -r releases -b body -t "Fix stuff" -c
  # Useful after running locally with -l

EOF

if [ "$1" = "--help" ]; then
  echo "$USAGE" && exit 0
fi

while getopts r:b:t:p:B:lch opt; do
  case $opt in
    r) RELEASE_FILE=$OPTARG                ;;
    b) BODY_FILE=$OPTARG                   ;;
    t) PR_TITLE=$OPTARG                    ;;
    p) FORK=$OPTARG                        ;;
    B) BASE=$OPTARG                        ;;
    l) LOCAL_ONLY=true                     ;;
    c) CONTINUE=true                       ;;
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

_echo() {
  echo ">> $*"
}

prompt_return() {
  local message="$1"
  read -rp "$message" </dev/tty
}

handle_release() {
  local release=$1 choice
  local patch_branch=${BRANCH}-$release-patch
  local title="${PR_TITLE} ($release patch)"

  # Operations

  git_push() {
    if ! git push -u; then
      _echo "Could not push $patch_branch"
      return 1
    fi
  }

  git_rebase() {
    git rebase --onto "upstream/$release" "${BASE:-$BASE_BRANCH}" "${patch_branch}" "$@"
  }
  
  gh_pr_create() {
    if [ -n "$FORK" ]; then
       gh pr create --base "$release" --body "This is a preview" --title "$title" --draft --repo "$FORK"
    elif ! gh pr create --base "$release" --body-file "$BODY_FILE" --title "$title" --draft; then
      _echo "Failed to open PR for $release"
      return 1
    fi
  }

  publish_changes() {
    local action
    if [ "$LOCAL_ONLY" = "true" ]; then
      return
    fi

    _echo "Rebase complete. Take a look at the diff before pushing."

    read -rp "Press Enter to push branch and open PR or type 'skip' to skip: " action </dev/tty

    if [ "$action" = "skip" ]; then
      return
    fi
    git_push
    gh_pr_create
  }

  echo
  _echo "Attempting to patch $release ..."
  git checkout "$BRANCH"
  if ! git checkout -b "${patch_branch}"; then
    _echo "Assuming work on $release is already done"
    if [ "$CONTINUE" != "true" ]; then
      _echo "Skipping"
      return
    fi
    git checkout "${patch_branch}" || return 1
    publish_changes
    return
  fi

  if ! git_rebase; then
    _echo "Conflicts during rebase. How to proceed?"
    _echo "1) Retry using -X theirs"
    _echo "2) Retry using -X ours"
    _echo "3) Resolve manually"
    _echo "4) Skip"

    read -rp "Select an option: " choice </dev/tty

    case $choice in
      1)
        git rebase --abort
        if ! git_rebase -X theirs; then
          _echo "Still failing, fix manually"
          prompt_return "Press ENTER to continue"
        fi
        ;;
      2)
        git rebase --abort
        if ! git_rebase -X ours; then
          _echo "Attempting to fix by removing missing files..."
          git status --porcelain | grep '^DU' | cut -d " " -f2 | xargs git rm
          if ! GIT_EDITOR=true git rebase --continue; then
            _echo "Still failing, fix manually"
            prompt_return "Press ENTER to continue"
          fi
        fi
        ;;
      3)
        _echo "Resolve conflicts and run 'git rebase --continue'"
        prompt_return "Press ENTER to continue"
        ;;
      4)
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

  publish_changes

}

while read -r release; do
  if handle_release "$release"; then
    _echo "${release}: SUCCESS"
  else
    _echo "${release}: ERROR"
  fi
done < "$RELEASE_FILE"

git checkout "$BRANCH"
exit
