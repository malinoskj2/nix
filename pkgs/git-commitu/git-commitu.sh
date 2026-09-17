#!/usr/bin/env bash

# temporarily disable GPG signing and commit
git -c commit.gpgsign=false commit
