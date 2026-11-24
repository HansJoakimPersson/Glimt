#!/usr/bin/perl
use strict;
use warnings;

# Greet each name.
my @names = qw(Glimt Perl);
for my $name (@names) {
    print "Hej $name: ", 42, "\n";
}
