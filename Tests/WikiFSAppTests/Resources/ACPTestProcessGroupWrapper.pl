#!/usr/bin/perl
use POSIX qw(setpgid);
setpgid(0, 0) == 0 or die "setpgid: $!";
open my $f, ">", $ENV{"ACP_TEST_PROCESS_MARKER"} or die "marker: $!";
print {$f} "$$\n";
close $f;
while (!-e $ENV{"ACP_TEST_PROCESS_READY"}) { select undef, undef, undef, 0.01; }
my $exe = $ENV{"ACP_TEST_REAL_AGENT"} or die "missing real agent";
exec {$exe} $exe, @ARGV;
die "exec: $!";
