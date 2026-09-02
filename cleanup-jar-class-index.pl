#! /usr/bin/perl

use strict;
use warnings;
use File::Copy qw(move);
use Time::Piece;

# Usage: perl cleanup-jar-class-index.pl [path/to/jar-class-index.txt]
# Backs up the original file to jar-class-index.txt.bak.YYYYMMDDHHMMSS
# Keeps the newest two revisions per artifact (version-aware comparison).

my $file = shift || 'jar-class-index.txt';
unless (-f $file) {
    die "File not found: $file\n";
}

# Read all lines
open my $fh, '<', $file or die "Cannot open $file: $!\n";
my @lines = <$fh>;
close $fh;

# Parse lines into structure: base -> version -> [counts]
my %map;
my @order; # track base seen order

foreach my $line (@lines) {
    chomp $line;
    next unless length $line;
    my ($jar, $rest) = split /\|/, $line, 2;
    next unless defined $jar;

    # Try to split jar name into base and version. Match last hyphen followed by digit
    # e.g. jackson-databind-2.22.1.jar -> base=jackson-databind, ver=2.22.1
    my $base;
    my $ver;
    if ($jar =~ /^(.*)-([0-9][A-Za-z0-9\.\-+]*)\.jar$/) {
        $base = $1;
        $ver = $2;
    }
    else {
        # Fallback: treat entire jar filename (without .jar) as base, use empty version
        if ($jar =~ /^(.*)\.jar$/) {
            $base = $1;
            $ver = '';
        }
        else {
            $base = $jar;
            $ver = '';
        }
    }

    unless (exists $map{$base}) {
        push @order, $base;
    }

    push @{$map{$base}{$ver}}, $line;
}

# Version compare helper (returns 1 if v1>v2, -1 if v1<v2, 0 if equal)
sub version_compare {
    my ($v1, $v2) = @_;
    return 0 if defined $v1 && defined $v2 && $v1 eq $v2;

    # Treat empty as very small
    return -1 if (!defined $v1 || $v1 eq '') && (defined $v2 && $v2 ne '');
    return 1 if (defined $v1 && $v1 ne '') && (!defined $v2 || $v2 eq '');
    return 0 if (!defined $v1 || $v1 eq '') && (!defined $v2 || $v2 eq '');

    # Extract numeric components
    my @p1 = ($v1 =~ /(\d+)/g);
    my @p2 = ($v2 =~ /(\d+)/g);

    my $max = @p1 > @p2 ? @p1 : @p2;
    for (my $i = 0; $i < $max; $i++) {
        my $f1 = $p1[$i] // 0;
        my $f2 = $p2[$i] // 0;
        return 1 if $f1 > $f2;
        return -1 if $f1 < $f2;
    }

    # Fallback: lexicographic compare
    return $v1 cmp $v2;
}

# Determine for each base the top 2 versions to keep
my %keep_versions;
for my $base (@order) {
    my @vers = keys %{$map{$base}};
    # sort versions descending using version_compare
    my @sorted = sort {version_compare($b, $a)} @vers;

    # keep top two
    my @top = @sorted[0 .. ($#sorted < 1 ? $#sorted : 1)];
    $keep_versions{$base} = { map {$_ => 1} @top };
}

# Backup original
my $t = localtime;
my $stamp = $t->strftime('%Y%m%d%H%M%S');
my $bak = "$file.bak.$stamp";
move($file, $bak) or die "Failed to backup $file to $bak: $!\n";

# Write filtered file preserving original ordering of lines for kept versions
open my $out, '>', $file or die "Cannot write $file: $!\n";
my $kept_count = 0;
foreach my $line (@lines) {
    chomp $line;
    next unless length $line;
    my ($jar, $rest) = split /\|/, $line, 2;
    next unless defined $jar;

    my ($base, $ver);
    if ($jar =~ /^(.*)-([0-9][A-Za-z0-9\.\-+]*)\.jar$/) {
        $base = $1;
        $ver = $2;
    }
    else {
        if ($jar =~ /^(.*)\.jar$/) {
            $base = $1;
            $ver = '';
        }
        else {
            $base = $jar;
            $ver = '';
        }
    }

    if (exists $keep_versions{$base} && $keep_versions{$base}{$ver}) {
        print $out $line, "\n";
        $kept_count++;
    }
}
close $out;

print "Backup created: $bak\n";
print "Wrote $kept_count lines to $file (preserving up to 2 latest revisions per artifact)\n";

exit 0;
