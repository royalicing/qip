#!/bin/sh
set -eu

QIP_BIN=${QIP_BIN:-./qip}
NODE_BIN=${NODE_BIN:-node}
NODE_ROUTER=${NODE_ROUTER:-npm/qip-router/qip-router.mjs}
DOC_URL="https://qip.dev/docs/router"
EXPECTED_COMMANDS="dev get head kindred list warc"

GO_HELP=$($QIP_BIN router --help)
NODE_HELP=$($NODE_BIN "$NODE_ROUTER" --help)

case "$GO_HELP" in
  *"$DOC_URL"*) ;;
  *) echo "qip router --help is missing $DOC_URL" >&2; exit 1 ;;
esac

case "$NODE_HELP" in
  *"$DOC_URL"*) ;;
  *) echo "qip-router --help is missing $DOC_URL" >&2; exit 1 ;;
esac

extract_commands() {
  awk '
    /^(Commands|Subcommands):$/ { in_commands = 1; next }
    in_commands && /^  [a-z]/ { print $1; next }
    in_commands && /^$/ { next }
    in_commands { exit }
  ' | tr '\n' ' ' | sed 's/ $//'
}

GO_COMMANDS=$(printf '%s\n' "$GO_HELP" | extract_commands)
NODE_COMMANDS=$(printf '%s\n' "$NODE_HELP" | extract_commands)

if [ "$GO_COMMANDS" != "$EXPECTED_COMMANDS" ]; then
  echo "unexpected qip router commands: $GO_COMMANDS" >&2
  exit 1
fi

if [ "$NODE_COMMANDS" != "$EXPECTED_COMMANDS" ]; then
  echo "unexpected qip-router commands: $NODE_COMMANDS" >&2
  exit 1
fi
