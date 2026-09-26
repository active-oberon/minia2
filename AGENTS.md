# MiniA2 build checks

Before a build or release, check whether source or test changes altered the modules each target compiles. Regenerate `configs/moduleListA64.txt` with `tests/gen-a64-stdlib.sh`, review the diff, and add missing modules to other target lists when needed. Verify with the relevant target build; do not rely on leftover object files.
