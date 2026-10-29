#!/bin/sh
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! "$ROOT/install-android.sh"; then
 printf '\nSetup did not complete. Review the message above, then retry.\nPress Return to close.\n'
 IFS= read -r answer
 exit 1
fi
printf '\nSetup complete. Open Okestra Menu or Okestra Device from Applications.\nPress Return to close.\n'
IFS= read -r answer
