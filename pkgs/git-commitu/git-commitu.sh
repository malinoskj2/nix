#!/usr/bin/env bash
# Run git commit with GPG signing disabled.
#
# Arguments are ignored; the message is always written in Git's editor.

git -c commit.gpgsign=false commit
