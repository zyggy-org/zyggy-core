# shellcheck shell=bash
# A pseudo-terminal for bats (plan 23): the owner's consent terminal is a tty on the VM; in CI `script` from
# util-linux (bsdutils, Essential on Ubuntu) lends the command a pty on stdin and stdout. Loaded by m365.bats.

# run_on_pty <answers-file> <command…>: runs the command under `script -qfec` with the answers file as script's
# stdin (one answer per line; /dev/null when the command asks nothing), with the pty's echo off (-E never) so the
# typed answers never land on the screen ahead of the output; end of input reaches the command as Ctrl-D. Everything
# the command wrote to the pty lands in $BATS_TEST_TMPDIR/pty.out and is printed to stdout with the carriage
# returns removed; the return status is the command's (`-e`). Tests that assert "no tty" never use this: they
# run with `< /dev/null`.
run_on_pty() { # run_on_pty <answers-file> <command…>
  local answers="$1" out="$BATS_TEST_TMPDIR/pty.out" cmd rc=0
  shift
  cmd="$(printf '%q ' "$@")"
  SHELL=/bin/bash script -E never -qfec "$cmd" /dev/null < "$answers" > "$out" 2>&1 || rc=$?
  tr -d '\r' < "$out"
  return "$rc"
}
