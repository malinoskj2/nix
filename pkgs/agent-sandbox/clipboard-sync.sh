#!/usr/bin/env bash

clipboard_dir=$1
image=$clipboard_dir/image
change=$clipboard_dir/.change
temporary=$clipboard_dir/image.tmp.$$

cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT

# The watcher requests the generic image type so browser copies choose an image
# representation instead of the text/html representation they often offer first.
if [[ ${CLIPBOARD_STATE:-data} == data ]]; then
  cat >"$temporary"
  if [[ -s $temporary ]]; then
    mv -f -- "$temporary" "$image"
    exit
  fi
else
  cat >/dev/null
fi

rm -f -- "$image"
: >"$change"
