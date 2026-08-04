#!/usr/bin/perl

use strict;
use warnings;

use File::Basename;
use File::Copy;

my ($src_dir, $dest_dir) = @ARGV;

if (!$src_dir || !$dest_dir || !-d $src_dir || !-d $dest_dir) {
    die "Usage: perl sync-jars.pl <src_folder> <dest_folder>\n";
}

# Helper: Compare two version strings (returns 1 if v1 > v2, -1 if v1 < v2, 0 if v1 == v2)
sub compare_versions {
    my ($v1, $v2) = @_;
    return 0 if $v1 eq $v2;

    my @v1_parts = ($v1 =~ /(\d+)/g);
    my @v2_parts = ($v2 =~ /(\d+)/g);
    my $max_len = scalar @v1_parts > scalar @v2_parts ? scalar @v1_parts : scalar @v2_parts;

    for (my $i = 0; $i < $max_len; $i++) {
        my $p1 = $v1_parts[$i] // 0;
        my $p2 = $v2_parts[$i] // 0;
        return 1 if $p1 > $p2;
        return -1 if $p1 < $p2;
    }
    return 0;
}

# Helper: Extract base artifact name and version string from JAR filename
# e.g., "commons-lang3-3.12.0.jar" -> name: "commons-lang3", version: "3.12.0"
sub parse_jar_name {
    my ($file) = @_;
    if ($file =~ /^(.+?)-(\d+(?:\.\d+)*(?:[.-][A-Za-z0-9]+)*)\.jar$/i) {
        return ($1, $2);
    }
    return (undef, undef);
}

# 1. Index destination JARs by base name
my %dest_jars;
opendir(my $dh_dest, $dest_dir) or die "Cannot open $dest_dir: $!";
while (my $file = readdir($dh_dest)) {
    next unless $file =~ /\.jar$/i;
    my ($name, $version) = parse_jar_name($file);
    if ($name && $version) {
        $dest_jars{$name} = { file => $file, version => $version };
    }
}
closedir($dh_dest);

# 2. Inspect source JARs and replace if version is higher
opendir(my $dh_src, $src_dir) or die "Cannot open $src_dir: $!";
while (my $file = readdir($dh_src)) {
    next unless $file =~ /\.jar$/i;
    my ($src_name, $src_version) = parse_jar_name($file);
    next unless $src_name && $src_version;

    if (exists $dest_jars{$src_name}) {
        my $dest_entry = $dest_jars{$src_name};
        my $cmp = compare_versions($src_version, $dest_entry->{version});

        if ($cmp > 0) {
            my $src_path = "$src_dir/$file";
            my $dest_old = "$dest_dir/" . $dest_entry->{file};
            my $dest_new = "$dest_dir/$file";

            print "[UPGRADE] $src_name: $dest_entry->{version} -> $src_version\n";
            unlink $dest_old or warn "Could not remove old JAR $dest_old: $!\n";
            copy($src_path, $dest_new) or warn "Failed to copy $file to $dest_dir: $!\n";
        }
    }
}
closedir($dh_src);

exit 0;