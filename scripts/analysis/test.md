| crate                 | test                                                         | miri    | gc-opts-1-miri | gc-opts-1-initial-PR-miri | gc-opts-1-miri-min-visit-size-64 | master-miri |
| --------------------- | ------------------------------------------------------------ | ------- | -------------- | ------------------------- | -------------------------------- | ----------- |
| crossbeam-deque-0.8.6 | steal_batch_injector_fifo                                    | FAIL    | ok             | ok                        | ok                               | ok          |
| crossbeam-deque-0.8.6 | steal_batch_injector_lifo                                    | FAIL    | ok             | ok                        | ok                               | ok          |
| http-1.4.1            | append_multiple_values                                       | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | as_header_name                                               | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | drain                                                        | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | drain_drop_immediately                                       | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | drain_entry                                                  | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | drain_forget                                                 | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | ensure_miri_itermut_not_violated                             | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | ensure_miri_sharedreadonly_not_violated                      | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | ensure_miri_valueitermut_not_violated                        | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | eq                                                           | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | equates_with_u16                                             | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | error::tests::inner_error_is_invalid_status_code             | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | extend_size_hint_above_capacity                              | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | extensions::test_extensions                                  | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | from_bytes                                                   | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | get_invalid                                                  | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::map::skip_duplicates_during_key_iteration            | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::map::test_bounds                                     | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::test_parse_standard_headers                    | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::test_standard_headers_into_bytes               | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_all_tokens                         | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_bounds                             | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_eq_hdr_name                        | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_hdr_name                      | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_lowercase                     | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_custom_long            | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_custom_long_symbol     | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_custom_long_uppercase  | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_custom_short           | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_custom_short_symbol    | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_custom_short_uppercase | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_custom_single_char     | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_empty                  | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_std                    | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_std_symbol             | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_from_static_std_uppercase          | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_invalid_name_lengths               | nomatch | ok             | ok                        | ok                               | nomatch     |
| http-1.4.1            | header::name::tests::test_parse_invalid_headers              | nomatch | ok             | ok                        | ok                               | nomatch     |

Runs missing listed tests (rerun these to complete the comparison):

| run                              | missing |
| -------------------------------- | ------- |
| gc-opts-1-miri                   | 256     |
| gc-opts-1-miri-min-visit-size-64 | 232     |
| gc-opts-1-initial-PR-miri        | 119     |
| miri                             | 66      |
| master-miri                      | 56      |