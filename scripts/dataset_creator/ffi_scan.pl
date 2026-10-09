#!/usr/bin/env perl
#
# ffi_scan.pl
#
#   Reads a NUL-separated list of *.rs files on stdin (e.g. from `rg -l -0`)
#   and prints one line per C / C++ FFI ABI literal found in them:
#       <file>\t<literal>        e.g.  src/ffi.rs<TAB>extern "C"
#
#   Shared by the extern "C" scanners (count_extern_c.sh, download_extern_c.sh,
#   fetch_lists/fetch_*_c_ffi_crates.sh, capslock/fetch_capslock_ffi_crates.sh).
#   A single-line regex can't do this: the attribute that marks a block as
#   not-C sits on the line(s) above it. Skipped (not C FFI):
#       #[wasm_bindgen] extern "C" { .. }          JavaScript imports
#       #[cfg_attr(.., wasm_bindgen)] extern "C"   same, behind a cfg
#       #[link(wasm_import_module = "..")] extern "C" { .. }
#                                                  wasm host imports
#   Only the attributes directly on the item count (doc comments and other
#   attributes in between are fine), so `pub`, `unsafe`, and `extern"C"` (no
#   space) all still match.

use strict;
use warnings;

# An attribute, allowing brackets nested two deep: #[a(b = [c])], #![...].
my $attr = qr/#!?\[(?:[^\[\]]++|\[(?:[^\[\]]++|\[[^\[\]]*+\])*+\])*+\]/;
# What may sit between the attributes and `extern`: more attributes, comments,
# whitespace (one char at a time, so this can't backtrack exponentially).
my $lead = qr/(?:$attr|\/\/[^\n]*+|\/\*.*?\*\/|\s)*/s;
my $vis  = qr/(?:pub(?:\s*\([^)]*\))?\s+)?(?:unsafe\s+)?/;
my $abi  = qr/extern\s*"(?:C|C-unwind|C\+\+)"/;
my $skip = qr/wasm_bindgen|wasm_import_module/;

local $/ = "\0";
while (my $file = <STDIN>) {
    chomp $file;
    next if $file eq '';
    open(my $fh, '<', $file) or next;
    my $src = do { local $/; <$fh> };
    close $fh;
    next unless defined $src;
    while ($src =~ /($lead)$vis($abi)/g) {
        my ($pre, $lit) = ($1, $2);
        next if grep { /$skip/ } ($pre =~ /($attr)/g);
        $lit =~ s/\s+//;
        $lit =~ s/^extern/extern /;
        print "$file\t$lit\n";
    }
}
