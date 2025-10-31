#!/bin/sh -l

# Check which type of credential the init container created
if [ -f /mnt/reg-token-store/jit ]; then
  echo "INFO: Found JIT config, using --jitconfig"
  JIT="$(cat /mnt/reg-token-store/jit)"
  ./run.sh --jitconfig "$JIT"
elif [ -f /mnt/reg-token-store/regtoken ]; then
  echo "INFO: Found classic registration token, configuring runner"
  REGTOKEN="$(cat /mnt/reg-token-store/regtoken)"

  # Determine registration URL based on environment
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    # Repository-level runner
    RUNNER_URL="https://github.com/${GITHUB_REPOSITORY}"
    echo "INFO: Registering as repository-level runner for $GITHUB_REPOSITORY"
  elif [ -n "${GITHUB_ORG:-}" ]; then
    # Organization-level runner
    RUNNER_URL="https://github.com/${GITHUB_ORG}"
    echo "INFO: Registering as organization-level runner for $GITHUB_ORG"
  else
    echo "ERROR: Neither GITHUB_REPOSITORY nor GITHUB_ORG is set"
    exit 1
  fi

  # Configure and run
  ./config.sh --unattended --url "$RUNNER_URL" --token "$REGTOKEN" --ephemeral
  ./run.sh
else
  echo "ERROR: Neither /mnt/reg-token-store/jit nor /mnt/reg-token-store/regtoken found"
  exit 1
fi
