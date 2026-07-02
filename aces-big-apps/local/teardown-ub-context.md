# Servo-fonts BSAN Teardown UB — Full Context for Fix Agent
(see task context — symptom: test passes, UB on teardown; patch v1 removed usable_size but ft_free missing decrement and MallocSizeOf still uses ops.malloc_size_of)
