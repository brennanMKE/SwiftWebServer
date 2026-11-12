#!/bin/bash
# Prints an auth credential line (#0093) for a Basic user: NAME:$pbkdf2-sha256$…
# The password is prompted for (not echoed) or read from standard input when it is not a
# terminal. Append the line to the file named by "auth.basic.file", or put it in
# "auth.basic.users" / the variable named by "auth.basic.usersEnv".
#
#   scripts/hash-password.sh alice >> Root/users.htpasswd
#   printf '%s\n' "$PASSWORD" | scripts/hash-password.sh alice --iterations 600000

set -euo pipefail
if [ $# -lt 1 ]; then
    echo "usage: $0 USER [--iterations N]" >&2
    exit 2
fi
user="$1"
shift
cd "$(dirname "$0")/.."
swift build -c release -j 2 --product sws-bench >&2
if [ -t 0 ]; then
    read -r -s -p "Password for $user: " password
    echo >&2
    printf '%s\n' "$password" | .build/release/sws-bench hash-password --user "$user" "$@"
else
    .build/release/sws-bench hash-password --user "$user" "$@"
fi
