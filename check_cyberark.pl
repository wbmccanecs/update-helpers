#! /usr/bin/perl

use strict;
use warnings; # Highly recommended
use File::Find;
use File::Basename;
use File::Spec;
use Term::ANSIColor qw{:constants};
use LWP::UserAgent; # Added for HTTP requests
use IO::Socket::SSL; # Added for SSL handling

my $file_count = 0;

my $wanted_sub = sub {
    if (-d $_) {
        (my $full_path_relative = $File::Find::name) =~ s#\\#/#g;
        if (
            $full_path_relative =~ '/.git$' ||
            $full_path_relative =~ '/target$' ||
            $full_path_relative =~ '/build$' ||
            $full_path_relative =~ '/node_modules$' ||
            $full_path_relative =~ '/bin$' ||
            $full_path_relative =~ '/out$' ||
            $full_path_relative =~ '/deploy$' ||
            $full_path_relative =~ '/reports$' ||
            $full_path_relative =~ '/test-automation$' ||
            $full_path_relative =~ '/test-bin$' ||
            $full_path_relative =~ '/war/META-INF$' ||
            $full_path_relative =~ '/war/WEB-INF/classes$' ||
            $full_path_relative =~ '/war/WEB-INF/lib$' ||
            $full_path_relative =~ '/.settings$' 
        ) {
            $File::Find::prune = 1;
            return;
        }
    }

    return unless -f $_;

    my $file_path_raw = $File::Find::name;
    return unless $file_path_raw =~ m#/config/#;

    my ($filename, $dirs, $suffix) = fileparse($file_path_raw, qr/\.[^.]*$/);
    return unless lc $suffix eq '.java';

    open my $fh, "<", $_ or do {
        warn BOLD YELLOW "Warning: could not open $file_path_raw: $!" . RESET . "\n";
        return;
    };

    ++$file_count;

    # Slurp or line-by-line check
    while (my $line = <$fh>) {
        if ($line =~ /pam-ccp.pr.mgicint.net/) {
            # Extract URL inside quotes
            if (my ($url) = $line =~ /"(https?:\/\/pam-ccp\.pr\.mgicint\.net\/.*?)"/) {
                
                unless ($url =~ /AppId=/ && $url =~ /Object=/) {
                    warn BOLD RED "$file_path_raw: invalid cyberark URI format ($url)" . RESET . "\n";
                    next;
                }

                print BOLD CYAN "Testing: $url" . RESET . "\n";

                # PERFORM THE WEBPAGE PULL
		my $result = `curl -k -s -L "$url"`;

                if ($? == 0 && $result =~ /Content|Password|UserName/i) {
                    print BOLD GREEN "  [OK] Success! Content received." . RESET . "\n";
                } else {
		    my $status_code = `curl -k -s -o /dev/null -w "%{http_code}" "$url"`;
                    warn BOLD RED "  [FAIL] HTTP Error: " . $status_code . RESET . "\n";
                }
            }
        }
    }
    close $fh;
};

find($wanted_sub, '.');

print BOLD WHITE "\nProcessed $file_count files." . RESET . "\n";
exit 0;

