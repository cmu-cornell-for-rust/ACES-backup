# Servo-fonts BSAN Teardown UB — Fix Report (v2)

## Subagent status
- Spawned TeardownUbFix task agent — FAILED (usage_limit_reached)
- Fix implemented locally by parent agent

## Root cause (v1 failed)
1. usable_size in FreeType hooks reads jemalloc metadata (BSAN OOB)
2. v1 removed hook usable_size but ft_free never decremented FREETYPE_MEMORY_USAGE
3. MallocSizeOf still called ops.malloc_size_of on FT pointers (also uses usable_size)

## v2 fix
- HashMap pointer->size tracking for ft_alloc/ft_free/ft_realloc
- MallocSizeOf returns FREETYPE_MEMORY_USAGE only

## ACES verify
./aces/scripts/deploy.sh && ssh ... PREFLIGHT_FORCE=1 ./scripts/run_servo_fonts_one_job.sh 4:00 32
