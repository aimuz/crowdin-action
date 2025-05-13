#!/bin/sh

# Default values for action outputs
echo "pull_request_url=" >> $GITHUB_OUTPUT
echo "pull_request_number=" >> $GITHUB_OUTPUT

if [ "$INPUT_DEBUG_MODE" = true ] || [ -n "$RUNNER_DEBUG" ]; then
  echo '---------------------------'
  printenv
  echo '---------------------------'
fi

upload_sources() {
  if [ -n "$INPUT_UPLOAD_SOURCES_ARGS" ]; then
    UPLOAD_SOURCES_OPTIONS="${UPLOAD_SOURCES_OPTIONS} ${INPUT_UPLOAD_SOURCES_ARGS}"
  fi

  echo "UPLOAD SOURCES"
  crowdin upload sources "$@" $UPLOAD_SOURCES_OPTIONS
}

upload_translations() {
  if [ -n "$INPUT_UPLOAD_LANGUAGE" ]; then
    UPLOAD_TRANSLATIONS_OPTIONS="${UPLOAD_TRANSLATIONS_OPTIONS} --language=${INPUT_UPLOAD_LANGUAGE}"
  fi

  if [ "$INPUT_AUTO_APPROVE_IMPORTED" = true ]; then
    UPLOAD_TRANSLATIONS_OPTIONS="${UPLOAD_TRANSLATIONS_OPTIONS} --auto-approve-imported"
  fi

  if [ "$INPUT_IMPORT_EQ_SUGGESTIONS" = true ]; then
    UPLOAD_TRANSLATIONS_OPTIONS="${UPLOAD_TRANSLATIONS_OPTIONS} --import-eq-suggestions"
  fi

  if [ -n "$INPUT_UPLOAD_TRANSLATIONS_ARGS" ]; then
    UPLOAD_TRANSLATIONS_OPTIONS="${UPLOAD_TRANSLATIONS_OPTIONS} ${INPUT_UPLOAD_TRANSLATIONS_ARGS}"
  fi

  echo "UPLOAD TRANSLATIONS"
  crowdin upload translations "$@" $UPLOAD_TRANSLATIONS_OPTIONS
}

download_sources() {
  if [ -n "$INPUT_DOWNLOAD_SOURCES_ARGS" ]; then
    DOWNLOAD_SOURCES_OPTIONS="${DOWNLOAD_SOURCES_OPTIONS} ${INPUT_DOWNLOAD_SOURCES_ARGS}"
  fi

  echo "DOWNLOAD SOURCES"
  crowdin download sources "$@" $DOWNLOAD_SOURCES_OPTIONS
}

download_translations() {
  if [ -n "$INPUT_DOWNLOAD_LANGUAGE" ]; then
    DOWNLOAD_TRANSLATIONS_OPTIONS="${DOWNLOAD_TRANSLATIONS_OPTIONS} --language=${INPUT_DOWNLOAD_LANGUAGE}"
  elif [ -n "$INPUT_LANGUAGE" ]; then #back compatibility for older versions
    DOWNLOAD_TRANSLATIONS_OPTIONS="${DOWNLOAD_TRANSLATIONS_OPTIONS} --language=${INPUT_LANGUAGE}"
  fi

  if [ "$INPUT_SKIP_UNTRANSLATED_STRINGS" = true ]; then
    DOWNLOAD_TRANSLATIONS_OPTIONS="${DOWNLOAD_TRANSLATIONS_OPTIONS} --skip-untranslated-strings"
  fi

  if [ "$INPUT_SKIP_UNTRANSLATED_FILES" = true ]; then
    DOWNLOAD_TRANSLATIONS_OPTIONS="${DOWNLOAD_TRANSLATIONS_OPTIONS} --skip-untranslated-files"
  fi

  if [ "$INPUT_EXPORT_ONLY_APPROVED" = true ]; then
    DOWNLOAD_TRANSLATIONS_OPTIONS="${DOWNLOAD_TRANSLATIONS_OPTIONS} --export-only-approved"
  fi

  if [ -n "$INPUT_DOWNLOAD_TRANSLATIONS_ARGS" ]; then
    DOWNLOAD_TRANSLATIONS_OPTIONS="${DOWNLOAD_TRANSLATIONS_OPTIONS} ${INPUT_DOWNLOAD_TRANSLATIONS_ARGS}"
  fi

  echo "DOWNLOAD TRANSLATIONS"
  crowdin download "$@" $DOWNLOAD_TRANSLATIONS_OPTIONS
}

create_pull_request() {
  BRANCH="${1}"

  AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
  HEADER="Accept: application/json"

  export INPUT_GITHUB_API_BASE_URL="git.tongdiaotech.com"
  if [ -n "$INPUT_GITHUB_API_BASE_URL" ]; then
    REPO_URL="https://${INPUT_GITHUB_API_BASE_URL}/api/v1/repos/${GITHUB_REPOSITORY}"
  else
    REPO_URL="https://api.${INPUT_GITHUB_BASE_URL}/api/v1/repos/${GITHUB_REPOSITORY}"
  fi

  ORG_NAME=$(echo "${GITHUB_REPOSITORY}" | cut -d'/' -f1)
  PULLS_URL="${REPO_URL}/pulls"

  auth_status=$(curl -sL --write-out '%{http_code}' --output /dev/null -H "${AUTH_HEADER}" -H "${HEADER}" "${PULLS_URL}")
  if [[ $auth_status -eq 403 || "$auth_status" -eq 401 ]] ; then
    echo "FAILED TO AUTHENTICATE USING 'GITHUB_TOKEN' CHECK TOKEN IS VALID"
    echo "pull_request_url=" >> $GITHUB_OUTPUT
    echo "pull_request_number=" >> $GITHUB_OUTPUT
    exit 1
  fi

  echo "CHECK IF PULL REQUEST ALREADY EXIST"

  if [ -n "$INPUT_PULL_REQUEST_BASE_BRANCH_NAME" ]; then
    BASE_BRANCH="$INPUT_PULL_REQUEST_BASE_BRANCH_NAME"
  else
    if [ -n "$GITHUB_HEAD_REF" ]; then
      BASE_BRANCH=${GITHUB_HEAD_REF}
    else
      BASE_BRANCH=${GITHUB_REF#refs/heads/}
    fi
  fi

  # Check existing PRs
  pull_requests_response=$(curl -sSL -H "${AUTH_HEADER}" -H "${HEADER}" "${PULLS_URL}?state=open")
  PULL_REQUESTS=$(echo "$pull_requests_response" | jq --raw-output '.[] | select(.head.ref == "'$BRANCH'") | .head.ref')

  if echo "$PULL_REQUESTS" | grep -xq "$BRANCH"; then
    echo "PULL REQUEST ALREADY EXIST"
  else
    echo "CREATE PULL REQUEST"

    if [ -n "$INPUT_PULL_REQUEST_BODY" ]; then
      BODY=",\"body\":\"${INPUT_PULL_REQUEST_BODY//$'\n'/\\n}\""
    fi

    PULL_RESPONSE_DATA=$(jq -n --arg pr_title "${INPUT_PULL_REQUEST_TITLE}" \
                                --arg base_branch "${BASE_BRANCH}" \
                                --arg branch "${BRANCH}" \
                                --arg body "${BODY}" \
                                "{title: \$pr_title, base: \$base_branch, head: \"${ORG_NAME}:${BRANCH}\" ${BODY}}")

    # create pull request
    PULL_RESPONSE=$(curl -sSL -H "${AUTH_HEADER}" -H "${HEADER}" -X POST --data "${PULL_RESPONSE_DATA}" "${PULLS_URL}")

    set +x
    PULL_REQUESTS_URL=$(echo "${PULL_RESPONSE}" | jq -r '.html_url')
    PULL_REQUESTS_NUMBER=$(echo "${PULL_RESPONSE}" | jq -r '.number')
    view_debug_output

    if [ -n "$PULL_REQUESTS_URL" ]; then
      echo "pull_request_url=$PULL_REQUESTS_URL" >> $GITHUB_OUTPUT
    fi

    if [ -n "$PULL_REQUESTS_NUMBER" ]; then
      echo "pull_request_number=$PULL_REQUESTS_NUMBER" >> $GITHUB_OUTPUT
    fi

    if [ "$PULL_REQUESTS_URL" = null ]; then
      echo "FAILED TO CREATE PULL REQUEST"
      echo "RESPONSE: ${PULL_RESPONSE}"
      exit 1
    fi

    echo "PULL REQUEST CREATED: ${PULL_REQUESTS_URL}"
  fi
}

push_to_branch() {
  BRANCH=${INPUT_LOCALIZATION_BRANCH_NAME}

  REPO_URL="https://${GITHUB_ACTOR}:${GITHUB_TOKEN}@${INPUT_GITHUB_BASE_URL}/${GITHUB_REPOSITORY}.git"

  echo "CONFIGURING GIT USER"
  git config --global user.email "${INPUT_GITHUB_USER_EMAIL}"
  git config --global user.name "${INPUT_GITHUB_USER_NAME}"

  if [ "$INPUT_SKIP_REF_CHECKOUT" != true ]; then
    CHECKOUT=${GITHUB_HEAD_REF:-${GITHUB_REF}}
    CHECKOUT=${CHECKOUT#refs/heads/}
    CHECKOUT=${CHECKOUT#refs/tags/}
    git checkout "${CHECKOUT}"
  fi

  if [ -n "$(git show-ref refs/heads/${BRANCH})" ]; then
    git checkout "${BRANCH}"
  else
    git checkout -b "${BRANCH}"
  fi

  git add .

  if [ ! -n "$(git status -s)" ]; then
    echo "NOTHING TO COMMIT"
    return
  fi

  echo "PUSH TO BRANCH ${BRANCH}"
  git commit --no-verify -m "${INPUT_COMMIT_MESSAGE}"
  git push --no-verify --force "${REPO_URL}"

  if [ "$INPUT_CREATE_PULL_REQUEST" = true ]; then
    create_pull_request "${BRANCH}"
  fi
}

view_debug_output() {
  if [ "$INPUT_DEBUG_MODE" = true ] || [ -n "$RUNNER_DEBUG" ]; then
    set -x
  fi
}

setup_commit_signing() {
  echo "FOUND PRIVATE KEY, WILL SETUP GPG KEYSTORE"

  echo "${INPUT_GPG_PRIVATE_KEY}" > private.key

  gpg --import --batch private.key

  GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format=long | grep -o "rsa\d\+\/\(\w\+\)" | head -n1 | sed "s/rsa\d\+\/\(\w\+\)/\1/")
  GPG_KEY_OWNER_NAME=$(gpg --list-secret-keys --keyid-format=long | grep  "uid" | sed "s/.\+] \(.\+\) <\(.\+\)>/\1/")
  GPG_KEY_OWNER_EMAIL=$(gpg --list-secret-keys --keyid-format=long | grep  "uid" | sed "s/.\+] \(.\+\) <\(.\+\)>/\2/")
  echo "Imported key information:"
  echo "      Key id: ${GPG_KEY_ID}"
  echo "  Owner name: ${GPG_KEY_OWNER_NAME}"
  echo " Owner email: ${GPG_KEY_OWNER_EMAIL}"

  git config --global user.signingkey "$GPG_KEY_ID"
  git config --global commit.gpgsign true

  export GPG_TTY=$(tty)
  # generate sign to store passphrase in cache for "git commit"
  echo "test" | gpg --clearsign --pinentry-mode=loopback --passphrase "${INPUT_GPG_PASSPHRASE}" > /dev/null 2>&1

  rm private.key
}

echo "STARTING CROWDIN ACTION"

cd "${GITHUB_WORKSPACE}" || exit 1

git config --global --add safe.directory $GITHUB_WORKSPACE

view_debug_output

set -e

#SET OPTIONS
set -- --no-progress --no-colors

if [ "$INPUT_DEBUG_MODE" = true ] || [ -n "$RUNNER_DEBUG" ]; then
  set -- "$@" --verbose --debug
fi

if [ -n "$INPUT_CROWDIN_BRANCH_NAME" ]; then
  set -- "$@" --branch="${INPUT_CROWDIN_BRANCH_NAME}"
fi

if [ -n "$INPUT_CONFIG" ]; then
  set -- "$@" --config="${INPUT_CONFIG}"
fi

if [ "$INPUT_DRYRUN_ACTION" = true ]; then
  set -- "$@" --dryrun
fi

#SET CONFIG OPTIONS
if [ -n "$INPUT_PROJECT_ID" ]; then
  set -- "$@" --project-id=${INPUT_PROJECT_ID}
fi

if [ -n "$INPUT_TOKEN" ]; then
  set -- "$@" --token="${INPUT_TOKEN}"
fi

if [ -n "$INPUT_BASE_URL" ]; then
  set -- "$@" --base-url="${INPUT_BASE_URL}"
fi

if [ -n "$INPUT_BASE_PATH" ]; then
  set -- "$@" --base-path="${INPUT_BASE_PATH}"
fi

if [ -n "$INPUT_SOURCE" ]; then
  set -- "$@" --source="${INPUT_SOURCE}"
fi

if [ -n "$INPUT_TRANSLATION" ]; then
  set -- "$@" --translation="${INPUT_TRANSLATION}"
fi

if [ -n "$INPUT_COMMAND_ARGS" ]; then
  set -- "$@" ${INPUT_COMMAND_ARGS}
fi

#EXECUTE COMMANDS

if [ -n "$INPUT_COMMAND" ]; then
  echo "RUNNING COMMAND crowdin $INPUT_COMMAND $INPUT_COMMAND_ARGS"
  crowdin $INPUT_COMMAND $INPUT_COMMAND_ARGS

  # in this case, we don't need to continue executing any further default behavior
  exit 0
fi

if [ "$INPUT_UPLOAD_SOURCES" = true ]; then
  upload_sources "$@"
fi

if [ "$INPUT_UPLOAD_TRANSLATIONS" = true ]; then
  upload_translations "$@"
fi

if [ "$INPUT_DOWNLOAD_SOURCES" = true ]; then
  download_sources "$@"

  if [ "$INPUT_PUSH_SOURCES" = true ]; then
    [ -z "${GITHUB_TOKEN}" ] && {
      echo "CAN NOT FIND 'GITHUB_TOKEN' IN ENVIRONMENT VARIABLES"
      exit 1
    }

    [ -n "${INPUT_GPG_PRIVATE_KEY}" ] && {
      setup_commit_signing
    }

    push_to_branch
  fi
fi

if [ "$INPUT_DOWNLOAD_TRANSLATIONS" = true ]; then
  download_translations "$@"

  if [ "$INPUT_PUSH_TRANSLATIONS" = true ]; then
    [ -z "${GITHUB_TOKEN}" ] && {
      echo "CAN NOT FIND 'GITHUB_TOKEN' IN ENVIRONMENT VARIABLES"
      exit 1
    }

    [ -n "${INPUT_GPG_PRIVATE_KEY}" ] && {
      setup_commit_signing
    }

    push_to_branch
  fi
fi

if [ "$INPUT_DOWNLOAD_BUNDLE" ]; then
  echo "DOWNLOADING BUNDLE $INPUT_DOWNLOAD_BUNDLE"

  crowdin bundle download $INPUT_DOWNLOAD_BUNDLE $@

  if [ "$INPUT_PUSH_TRANSLATIONS" = true ]; then
      [ -z "${GITHUB_TOKEN}" ] && {
        echo "CAN NOT FIND 'GITHUB_TOKEN' IN ENVIRONMENT VARIABLES"
        exit 1
      }

      [ -n "${INPUT_GPG_PRIVATE_KEY}" ] && {
        setup_commit_signing
      }

      push_to_branch
    fi
fi
