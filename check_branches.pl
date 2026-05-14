#!/usr/bin/perl
use strict;
use warnings;
use File::Spec;

# The directory containing all your git clones
my $root_dir = '.'; 

opendir(my $dh, $root_dir) or die "Cannot open $root_dir: $!";

while (my $dir = readdir($dh)) {
    next if $dir =~ /^\./; 
    my $path = File::Spec->catdir($root_dir, $dir);
    next unless -d File::Spec->catdir($path, ".git");

    chdir($path) or next;

    # 1. Check if both branches exist locally
    my $has_spring6 = `git branch --list spring6`;
    my $has_master  = `git branch --list master`;

    if (!$has_spring6 || !$has_master) {
        #        print "  - [SKIP] Missing one or both branches (master/spring6).\n";
        chdir('..');
        next;
    }
    print "Checking repo: $dir\n";

    # 2. History Check: Is master merged into spring6?
    # --is-ancestor returns 0 if true, 1 if false
    system("git merge-base --is-ancestor master spring6");
    my $is_merged = ($? >> 8) == 0;

    # 3. Get last code commit timestamps (excluding bookkeeping merges)
    my $master_time = `git log -1 --no-merges --format=%at master 2>/dev/null`;
    my $spring_time = `git log -1 --no-merges --format=%at spring6 2>/dev/null`;

    chomp($master_time);
    chomp($spring_time);

    # 4. Reporting
    if ($is_merged) {
        print "  - [HISTORY] OK: master is fully merged into spring6.\n";
    } else {
        print "  - [HISTORY] WARNING: master contains commits NOT in spring6 history.\n";
    }

    if ($master_time && $spring_time) {
        if ($spring_time > $master_time) {
            print "  - [TIMELINE] OK: Last spring6 code change is newer than master.\n";
        } else {
            print "  - [TIMELINE] FAIL: master has newer code than spring6.\n";
        }
    }

    chdir('..');
    print "-" x 40 . "\n";
}
closedir($dh);

exit 0;
