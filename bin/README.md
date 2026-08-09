# Public command

`bin/sysup` is the repository's only public executable. It detects the host
family and `exec`s the corresponding private backend from `lib/sysup`,
preserving arguments, signals, and exit status.

Dependency managers such as shdeps normally expose this file through a symlink
in `~/.local/bin`. The launcher deliberately resolves every symlink hop without
using GNU-only `readlink -f`, then loads detection and the backend from that
same provider checkout. Looking up `archup` or `debup` on `PATH` would let an
unrelated command split the dispatcher from its policy, so those names are not
public fallbacks.

Keep this launcher compatible with Bash 3.2. It is also the code path that must
explain an unsupported host; using newer syntax here would replace that useful
message with a parser error on stock macOS.
