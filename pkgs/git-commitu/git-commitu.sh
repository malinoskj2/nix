#!/usr/bin/env bash
# Arguments are ignored; the message is always written in Git's editor.

git -c commit.gpgsign=false commit
