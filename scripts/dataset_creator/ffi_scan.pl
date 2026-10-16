#!/usr/bin/env perl
#
# ffi_scan.pl [ROOT]
#
#   Reads a NUL-separated list of *.rs files on stdin (e.g. from `rg -l -0`)
#   and prints one line per C / C++ FFI ABI literal found in them:
#       <file>\t<literal>        e.g.  src/ffi.rs<TAB>extern "C"
#
#   ROOT (optional) is the crate directory the files were found under; paths
#   are judged relative to it (see "Not code" below).
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
#
#   Not code (skipped, so e.g. syn's `/// extern "C" { .. }` docs and
#   proptest's `prop_compose!` tests don't count):
#       comments, including doc comments and their code examples
#       string literals (other than the ABI string itself), e.g. "extern \"C\""
#       items under #[cfg(test)] / #[cfg(all(test, ..))], and whole files
#           marked #![cfg(test)]
#       files under tests/, benches/ or examples/ directories

use strict;
use warnings;
use Encode qw(decode);

my $root = shift // '';
$root =~ s{/+$}{};

# An attribute, allowing brackets nested two deep: #[a(b = [c])], #![...].
my $attr = qr/#!?\[(?:[^\[\]]++|\[(?:[^\[\]]++|\[[^\[\]]*+\])*+\])*+\]/;
# What may sit between the attributes and `extern`: more attributes and
# whitespace (comments are already blanked out by mask()).
my $lead = qr/(?:$attr|\s)*/;
my $vis  = qr/(?:pub(?:\s*\([^)]*\))?\s+)?(?:unsafe\s+)?/;
my $abi  = qr/extern\s*"(?:C|C-unwind|C\+\+)"/;
my $skip = qr/wasm_bindgen|wasm_import_module/;

# Rust tokens that can hide an `extern "C"` that isn't code. Block comments
# nest in Rust. A char literal is tried before strings so '"' isn't taken as
# the start of a string; a lifetime ('a) has no closing quote and won't match.
my $token = qr{
    (?<block> /\* (?: [^/*]++ | /(?!\*) | \*(?!/) | (?&block) )*+ \*/ )
  | //[^\n]*+
  | \bb?r(?<h>\#*+)".*?"\k<h>
  | (?:\bb)?'(?: [^'\\\n] | \\(?: x[0-9a-fA-F]{2} | u\{[0-9a-fA-F_]{1,8}\} | [^\n] ) )'
  | b?"(?: [^"\\]++ | \\. )*+"
}xs;

# Blank a token out, keeping newlines so nothing else moves. The ABI string
# of `extern "C"` is itself a string literal, so keep those.
sub blank { (my $s = shift) =~ s/[^\n]/ /g; $s }
sub mask {
    my $src = shift;
    $src =~ s{$token}{ $& =~ /^"(?:C|C-unwind|C\+\+)"$/ ? $& : blank($&) }ge;
    return $src;
}

# #[cfg(test)] / #[cfg(all(test, ..))] -- but not #[cfg(not(test))].
my $cfg_test = qr/#\[\s*cfg\s*\(\s*(?:all\s*\(\s*)?test\s*[,)]/;
my $braces   = qr/(?<br>\{(?:[^{}]++|(?&br))*+\})/;

# Blank out every item under a cfg(test) attribute: from the attribute to the
# end of the item's { .. } body, or to its `;` for a body-less item.
sub drop_cfg_test {
    my $src = shift;
    while ($src =~ /$cfg_test/g) {
        my $start = $-[0];
        pos($src) = $start;
        $src =~ /\G$attr[^{;]*+/gc or last;
        my $end = pos($src);
        if ($src =~ /\G$braces/gc) { $end = pos($src) }
        elsif ($src =~ /\G;/gc)    { $end = pos($src) }
        substr($src, $start, $end - $start) = blank(substr($src, $start, $end - $start));
        pos($src) = $end;
    }
    return $src;
}

local $/ = "\0";
while (my $file = <STDIN>) {
    chomp $file;
    next if $file eq '';
    my $rel = $file;
    $rel = substr($rel, length($root) + 1) if $root ne '' && index($rel, "$root/") == 0;
    next if "/$rel" =~ m{/(?:tests|benches|examples)/};
    open(my $fh, '<:raw', $file) or next;
    my $src = do { local $/; <$fh> };
    close $fh;
    next unless defined $src;
    $src = decode('UTF-8', $src);              # bad bytes become U+FFFD
    $src = mask($src);
    next if $src =~ /#!\[\s*cfg\s*\(\s*test\s*\)\s*\]/;
    $src = drop_cfg_test($src);
    while ($src =~ /($lead)$vis($abi)/g) {
        my ($pre, $lit) = ($1, $2);
        next if grep { /$skip/ } ($pre =~ /($attr)/g);
        $lit =~ s/\s+//;
        $lit =~ s/^extern/extern /;
        print "$file\t$lit\n";
    }
}
