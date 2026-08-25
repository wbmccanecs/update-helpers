package JarClassIndexer;

use strict;
use warnings;
use File::Basename;
use File::Find;
use FindBin;

use Exporter 'import';
our @EXPORT_OK = qw(
    load_jar_class_index
    save_jar_to_class_index
    extract_jar_classes_and_packages
    get_known_jars
    get_jar_cache
);

use MyLogger qw(
    log_info
    log_warning
);

our %JAR_CACHE;  # $jar_name -> { classes => {}, packages => {} }
our %KNOWN_JARS; # $jar_name -> 1

# Helper: Strips leading IGNORE- prefix from JAR name for index standardization
sub _clean_jar_name {
    my ($jar_path_or_name) = @_;
    my $name = lc(basename($jar_path_or_name));
    $name =~ s/^ignore-//i;
    return $name;
}

sub get_known_jars {return \%KNOWN_JARS;}
sub get_jar_cache {return \%JAR_CACHE;}

sub load_jar_class_index {
    my ($verbose) = @_;
    my $script_dir = $FindBin::RealBin;
    my $index_file = "$script_dir/jar-class-index.txt";
    return unless -f $index_file;

    open(my $fh, '<', $index_file) or return;
    my $loaded_count = 0;

    while (my $line = <$fh>) {
        $line =~ s/[\r\n]*//g;
        $line =~ s/\s*#.*$//; # skip comments
        next if $line =~ /^\s*$/;

        my ($jar_name, $fqcn) = split(/\s*\|\s*/, $line, 2);
        next unless defined $jar_name && defined $fqcn && $jar_name ne '' && $fqcn ne '';
        next if $fqcn =~ /\$/;

        $jar_name = _clean_jar_name($jar_name);
        $KNOWN_JARS{$jar_name} = 1;

        $JAR_CACHE{$jar_name} ||= {
            classes  => {},
            packages => {},
        };

        my $data = $JAR_CACHE{$jar_name};
        $data->{classes}{$fqcn} = 1;

        my $clean_fqcn = $fqcn;
        $clean_fqcn =~ s/\$.*//;
        $data->{classes}{$clean_fqcn} = 1;

        if ($clean_fqcn =~ /^(.*)\.[^\.]+$/) {
            $data->{packages}{$1} = 1;
        }
        $loaded_count++;
    }
    close($fh);

    if ($verbose && $loaded_count > 0) {
        log_info("Loaded $loaded_count class entries for " . scalar(keys %KNOWN_JARS) . " JAR(s) from jar-class-index.txt");
    }
}

sub save_jar_to_class_index {
    my ($jar_name, $fqcns_ref) = @_;
    return unless defined $jar_name && defined $fqcns_ref;

    $jar_name = _clean_jar_name($jar_name);

    my $script_dir = $FindBin::RealBin;
    my $index_file = "$script_dir/jar-class-index.txt";

    open(my $fh, '>>', $index_file) or do {
        log_warning("[WARNING] Could not open $index_file for writing: $!");
        return;
    };

    if (@$fqcns_ref) {
        for my $fqcn (@$fqcns_ref) {
            print $fh "$jar_name|$fqcn\n";
        }
    }
    else {
        print $fh "$jar_name|fake.class.Name\n";
    }

    close($fh);
    log_info("[INFO] Persisted " . scalar(@$fqcns_ref) . " class entries for '$jar_name' to jar-class-index.txt");
}

sub extract_jar_classes_and_packages {
    my ($jar_path) = @_;
    my $jar_name = _clean_jar_name($jar_path);

    # Return cached index if already loaded or scanned
    if (exists $KNOWN_JARS{$jar_name} && exists $JAR_CACHE{$jar_name}) {
        return $JAR_CACHE{$jar_name};
    }

    my %classes;
    my %packages;
    my @extracted_fqcns;

    $JAR_CACHE{$jar_name} = {
        classes  => \%classes,
        packages => \%packages,
    };
    $KNOWN_JARS{$jar_name} = 1;

    return $JAR_CACHE{$jar_name} unless -f $jar_path;

    my @entry_paths;

    log_info("[INFO] Extracting jar classes: $jar_path");
    eval {
        require Archive::Zip;
        my $zip = Archive::Zip->new();
        if ($zip->read($jar_path) == Archive::Zip::AZ_OK()) {
            for my $member ($zip->members()) {
                push @entry_paths, $member->fileName();
            }
        }
    };

    if (!@entry_paths) {
        if (my @jar_entries = `jar tf "$jar_path" 2>/dev/null`) {
            @entry_paths = map {s/[\r\n]*//g;
                $_} @jar_entries;
        }
        elsif (my @unzip_entries = `unzip -Z1 "$jar_path" 2>/dev/null`) {
            @entry_paths = map {s/[\r\n]*//g;
                $_} @unzip_entries;
        }
    }

    for my $entry (@entry_paths) {
        if ($entry =~ /^([a-zA-Z0-9_\/\$]+)\.class$/i) {
            my $path = $1;
            next if $path =~ /(?:module-info|package-info)$/i;
            next if $path =~ /\$/;

            my $fqcn = $path;
            $fqcn =~ s#/#.#g;

            push @extracted_fqcns, $fqcn;
            $classes{$fqcn} = 1;

            if ($fqcn =~ /^(.*)\.[^\.]+$/) {
                $packages{$1} = 1;
            }
        }
    }

    save_jar_to_class_index($jar_name, \@extracted_fqcns);

    return $JAR_CACHE{$jar_name};
}

1;