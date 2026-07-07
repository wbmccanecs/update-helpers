#! /usr/bin/perl

use strict;
use warnings;
use Term::ANSIColor qw{:constants};

my $properties = "build.properties";
my $output = $properties.".new";

my ($help, $hibernate5) = (0) x 2;

for my $arg (@ARGV) {
    my $key = lc($arg);
    $hibernate5 = 1 if $key eq "5";
}

my $file_content;
open (my $in, "<", $properties)
    or die "Error: could not open '$properties': $!";
open (my $out, ">", $output)
    or die "Error: could not open '$output': $!";
#{
#    local $/;
#    $file_content = <$in>;
#}

my $xlate = {
    "https://git.mgicint.net/mgic_sysdev/claims_common" => 3656,
    "https://git.mgicint.net/mgic_sysdev/document_viewer_2025" => 2409,
    "https://git.mgicint.net/mgic_sysdev/mgic_business" => 2989,
    "https://git.mgicint.net/mgic_sysdev/mgic_client_jars" => 2986,
    "https://git.mgicint.net/mgic_sysdev/mgic_common" => 2997,
    "https://git.mgicint.net/mgic_sysdev/mgic_jaxb" => 3203,
    "https://git.mgicint.net/mgic_sysdev/mgic_mux" => 2995,
    "https://git.mgicint.net/mgic_sysdev/mgic_persistence" => 2996,
    "https://git.mgicint.net/mgic_sysdev/mgic_third_party_jars" => 2998,
    "https://git.mgicint.net/mgic_sysdev/mgic_entity" => 2992,
    "https://git.mgicint.net/mgic_sysdev/mgic_dao" => 2991,
    "https://git.mgicint.net/mgic_sysdev/mgic_webapp_template" => 3008,
};
my $override_branch = {
    "https://git.mgicint.net/mgic_sysdev/mgic_business" => "jakarta",
    "https://git.mgicint.net/mgic_sysdev/mgic_mux" => "spring6",
    "https://git.mgicint.net/mgic_sysdev/claims_common" => "spring6",
    "https://git.mgicint.net/mgic_sysdev/mgic_common" => "jakarta",
    "https://git.mgicint.net/mgic_sysdev/mgic_jaxb" => "jakarta",
    "https://git.mgicint.net/mgic_sysdev/document_viewer_2025" => "r16_CSU-71_spring6",
};
if ($hibernate5) {
    $override_branch->{"https://git.mgicint.net/mgic_sysdev/mgic_persistence"} = "spring6";
    $override_branch->{"https://git.mgicint.net/mgic_sysdev/mgic_entity"} = "spring6";
} else {
    $override_branch->{"https://git.mgicint.net/mgic_sysdev/mgic_persistence"} = "hibernate6";
    $override_branch->{"https://git.mgicint.net/mgic_sysdev/mgic_entity"} = "jakarta";
}

for my $k (keys %$override_branch) {
    $override_branch->{$xlate->{$k}} = $override_branch->{$k};
}
my $override_path = {
    "esb%2Fesb-common.jar" => "esb_common.git%2Fspring6%2Fesb-common.jar",
    "esb%2Fesb-services.jar" => "esb_common.git%2Fspring6%2Fesb-services.jar",
    "esb_common.git%2Fmaster%2Fesb-common.jar" => "esb_common.git%2Fspring6%2Fesb-common.jar",
    "esb_common.git%2Fmaster%2Fesb-services.jar" => "esb_common.git%2Fspring6%2Fesb-services.jar",
};

my @remove = (
    '.*/aopalliance-[\d\.]+.jar',
    '.*/asm.jar',
    '.*/commons-httpclient-\d',
    '.*/displaytag',
    '.*/dom4j-',
    '(.*/|^)hibernate',
    '.*/j2ee-[\d\.]+.jar',
    '.*/jaxb-',
    '.*/jaxen-',
    '.*/jstl-[\d\.]+.jar',
    '.*/jboss-transaction-api[-_\d\.]*',
    '.*/mgic-mq.jar',
    '.*/ojdbc8.jar',
    '.*/poi-(ooxml(-schemas)?)?[-\d\.]*\.jar',
    '.*/svnkit',
    '.*-src.jar',
    '.*/activation(-[\d\.]*|\.jar)',
    ".*/log4jdbc",
    '.*/jsr\d+',
    '.*/db2jcc.jar',
    '.*/fixedformat4j.jar',
);

while (<$in>) {
    s#^git@(.*):#https://$1/#;
    if ($_ =~ m#^(http.*) (.*) (?:origin/)?(.*) ([^,\\]*)([ ,\\]*)#) {
        # mgic.git.jars
        my ($project, $path, $branch, $dest, $eol) = ($1, $2, $3, $4, $5);
        $branch = "master" if $branch eq "HEAD";
        my $remove = $dest =~ m#/source/#;
        if (!$remove) {
            for my $re (@remove) {
                if ($dest =~ $re) {
                    $remove = 1;
                    warn BOLD YELLOW "Remove $dest" . RESET . "\n";
                    last;
                }
            }
        }

        if (! $remove) {
            (my $file = $path) =~ s#/#%2F#g;
            $file = $override_path->{$file} if defined $override_path->{$file};
            (my $target = $project) =~ s/\.git$//;
            $branch = $override_branch->{$target} if defined $override_branch->{$target};
            if (defined $xlate->{$target}) {
                warn BOLD GREEN "Rewrite " . $dest . RESET . "\n";
                print $out "https://git.mgicint.net/api/v4/projects/".$xlate->{$target}."/repository" .
                            "/files/".$file."/raw" .
                            "?ref=".$branch .
                            " ".$dest .
                            $eol."\n";
            }
            else {
                die $project;
            }
        }
    } elsif ($_ =~ m#^(http.*/(\d+)/.*/files/)(.*?)/raw\?ref=(\w+) (war/WEB-INF/[^ ,\\]*)([ ,\\]*)#) {
        # mgic.git.api.resources
        my ($url, $project, $file, $branch, $dest, $eol) = ($1, $2, $3, $4, $5, $6);

        my $remove = 0;
        for my $re (@remove) {
            if ($file =~ $re || $dest =~ $re) {
                $remove = 1;
                warn BOLD YELLOW "Remove $file" . RESET . "\n";
                last;
            }
        }

        if (! $remove) {
            my ($orig_branch, $orig_file) = ($branch, $file);
            $branch = $override_branch->{$project} if defined $override_branch->{$project};
            $file = $override_path->{$file} if defined $override_path->{$file};
            warn BOLD GREEN "Change " . $dest . " branch from '$orig_branch' to '$branch'" . RESET . "\n"
                if $orig_branch ne $branch;
            warn BOLD GREEN "Change " . $dest . " file from '$orig_file' to '$file'" . RESET . "\n"
                if $orig_file ne $file;
            print $out $url.$file."/raw?ref=".$branch .
                        " ".$dest .
                        $eol . "\n";
        }
    } elsif ($_ =~ m#^(http.*) ([^,\\]*)([ ,\\]*)#) {
        # mgic.jars
        my ($path, $dest, $eol) = ($1, $2, $3);

        my $remove = 0;
        for my $re (@remove) {
            if ($path =~ $re) {
                $remove = 1;
                warn BOLD YELLOW "Remove $path" . RESET . "\n";
                last;
            }
        }

        print $out $_ unless $remove;
    } else {
        $_ =~ s/^mgic.git.jars=/mgic.git.api.resources=/;
        print $out $_;
    }
}

exit 0;

