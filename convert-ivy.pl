#! /usr/bin/perl

use strict;
use warnings;
use File::stat;
use File::Find;
use File::Basename;
use FindBin;
use Cwd 'abs_path';
use Term::ANSIColor qw{:constants};
use version;

my ($help, $hibernate5, $no_ui, $audit_deps, $verbose) = (0) x 5;

for my $arg (@ARGV) {
    my $key = lc($arg);
    $help = 1 if $key eq "-h" || $key eq "--help";
    $hibernate5 = 1 if $key eq "5" || $key eq "--hibernate5";
    $no_ui = 1 if $key eq "noui" || $key eq "headless" || $key eq "--no-ui";
    $audit_deps = 1 if $key eq "audit" || $key eq "--audit-deps";
    $verbose = 1 if $key eq "-v" || $key eq "--verbose";
}

if ($help) {
    print "Usage: perl convert-ivy.pl [options]\n";
    print "Options:\n";
    print "  -h, --help          Show this help message\n";
    print "  5, --hibernate5     Use Hibernate 5.x dependencies\n";
    print "  noui, headless      Prune UI dependencies for headless mode\n";
    print "  audit, --audit-deps Audit dependencies and remove unused ones\n";
    exit;
}

sub main {
    my %unused_deps_to_drop;
    my $ivy_file = "ivy.xml";
    my $output_file = "ivy.xml.new";
    my $deps_file = ".deps";

    # Load persistent flat file JAR class index
    load_jar_class_index();

    my $libdir = (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';

    my @src_dirs = ('src', 'test', 'deploy');

    log_error("Both mgic-entity-custom.jar and mgic-entity-master.jar exist. Please remove one of them.")
        if -e "$libdir/mgic-entity-custom.jar" && -e "$libdir/mgic-entity-master.jar";

    # Extract base packages from Spring annotations
    my @base_packages = extract_base_packages(\@src_dirs);

    if ($audit_deps) {
        log_file_check($libdir);

        my @external_sources = load_mgic_src_mappings($libdir);
        push @src_dirs, @external_sources;

        my ($unused_ref, $used_ref) = audit_dependencies(\@src_dirs, $libdir, \@base_packages);
        %unused_deps_to_drop = %$unused_ref;
    }

    my %used_deps_to_keep = extract_all_referenced_packages(\@src_dirs, (-d 'war' ? 'war' : undef), \@base_packages);

    my @remove_packages = (
        "commons-httpclient",
        "commons-logging",
        "commons-pool",
        'jandex',
        "log4jdbc",
        "^powermock-",
        "easymock",
        "httpcore",
        'taglibs-standard-impl',
        "javax.activation",
    );

    if ($no_ui) {
        log_info("--- HEADLESS MODE ACTIVE: Pruning UI dependencies ---");
        push @remove_packages, (
            "spring-webmvc",
            "spring-websocket",
            "sitemesh",
            "jakarta.servlet.jsp-api",
            "jakarta.servlet.jsp.jstl",
            "jakarta.servlet.jsp.jstl-api",
            "displaytag",
            "encoder-jakarta-jsp",
            "cas-client-core",
            "nimbus-jose-jwt"
        );
    }

    my $recommendations = {
        'esapi'        => 'convert Query to use bind parameters and remove esapi dependency',
        'apereo'       => 'convert to EmployeeFormBasedAuthForLDAP and remove apereo dependencies',
        'commons-lang' => 'convert all classes to use commons-lang3, try to remove commons-lang dependency',
    };

    my $update = load_update_data();

    if ($hibernate5) {
        $update->{"hibernate-core-jakarta"} = { org => "org.hibernate", name => "hibernate-core-jakarta", rev => "5.6.15.Final" };
        $update->{"hibernate-jpamodelgen"} = { org => "org.hibernate", name => "hibernate-jpamodelgen", rev => "5.6.15.Final" };

        $update->{"hibernate-core"} = $update->{"hibernate-core-jakarta"};
        push @remove_packages, "hibernate-community-dialects";
    }
    else {
        $update->{"hibernate-core-jakarta"} = $update->{"hibernate-core"};
    }

    my $add_if_missing = {};
    my %globally_add_deps = ();

    my $keep_if_exists = {
        "commons-lang" => "commons-lang3",
        "httpclient"   => "httpclient5",
        "httpcore"     => "httpclient5",
    };

    my $exclusions = {};
    my @packages;

    # 1. READ ORIGINAL IVY.XML
    my $file_content;
    open(my $in, "<", $ivy_file)
        or die "Error: could not open '$ivy_file': $!";
    {
        local $/;
        $file_content = <$in>;
    }
    close($in);

    my $changes_made = 0;
    check_and_inject_smtp_dependencies(\$file_content, \$changes_made, \@src_dirs, $update);

    # Pre-scan ivy.xml to track direct dependencies
    my %present_deps;
    while ($file_content =~ /<dependency\s+(?:[^>]*?\s+)?name="([^"]+)"/g) {
        $present_deps{$1} = 1;
    }

    # ------------------------------------------------------------------
    # STAGE 1: IN-PLACE UPDATES (Preserves existing <exclude> tags in $file_content)
    # ------------------------------------------------------------------
    $file_content =~ s{
    ^ (\s*)(?!<--)
    (<dependency\s+
        (?:[^>]|"[^"]*")*?
        (?:
            \s*/>
            |
            \s*>
            (?:
                (?!</dependency>)
                (?!<dependency\s+)
                .
            )*?
            </dependency>
        )
    )
}{
        my $leading_whitespace = defined $1 ? $1 : '';
        my $dependency_block = $2;

        my ($dep_org, $dep_name, $current_rev);
        $dep_org = $1 if $dependency_block =~ /\borg="([^"]*)"/;
        $dep_name = $1 if $dependency_block =~ /\bname="([^"]*)"/;
        $current_rev = $1 if $dependency_block =~ /\brev="([^"]*)"/;

        my $replacement_str = "";

        unless (defined $dep_org and defined $dep_name) {
            $replacement_str = $leading_whitespace . $dependency_block;
        }
        elsif (exists $keep_if_exists->{$dep_name} && grep {$keep_if_exists->{$dep_name} eq $_} @packages) {
            log_warning("Keep $dep_name");
            $replacement_str = $leading_whitespace . $dependency_block;
        }
        elsif (grep {$dep_name =~ $_} @remove_packages && !($update->{$dep_name} && ($update->{$dep_name}->{keep} || $update->{$dep_name}->{snyk}))) {
            log_info("Remove $dep_name");
            $changes_made += 1;
        }
        elsif ($unused_deps_to_drop{$dep_name} && !($update->{$dep_name} && ($update->{$dep_name}->{keep} || $update->{$dep_name}->{snyk}))) {
            log_info("Remove unused dependency $dep_name (no active imports in src/)");
            $changes_made += 1;
        }
        elsif (grep {$dep_name eq $_} @packages) {
            log_warning("Remove duplicate dependency $dep_name");
            $changes_made += 1;
        }
        else {
            push @packages, $dep_name;

            my $modified_dependency_block = $dependency_block;
            my $update_entry_ref = $update->{$dep_name};

            if (defined $update_entry_ref) {
                $update_entry_ref->{"conf"} = 'runtime->default' unless $update_entry_ref->{"conf"};
                my $should_keep_rev = 0;
                my $new_rev_candidate = $update_entry_ref->{rev};

                my $update_dep_name = $update_entry_ref->{name} || $dep_name;
                my $is_package_name_changing = ($update_entry_ref->{org} ne $dep_org || $update_dep_name ne $dep_name);
                if (defined $current_rev && !$is_package_name_changing && !$should_keep_rev) {
                    my $cmp = version_compare($current_rev, $new_rev_candidate);
                    if ($cmp > 0) {
                        log_warning("Keep current rev for $dep_org:$dep_name: $current_rev");
                        $should_keep_rev = 1;
                    }
                }

                if (!$should_keep_rev) {
                    foreach my $key (keys %$update_entry_ref) {
                        next if $key eq "keep" or $key eq "snyk";
                        my $new_val = $update_entry_ref->{$key};
                        $new_val = $current_rev if $key eq 'rev' && $should_keep_rev;

                        if ($modified_dependency_block =~ s/\b$key="([^"]*)"/$key="$new_val"/i) {
                            log_success("Update $dep_name:$key to $new_val") unless $1 eq $new_val;
                            $changes_made += 1 unless $1 eq $new_val;
                        }
                        else {
                            log_warning("$dep_org,$dep_name attempting to add missing $key attribute");
                            if ($modified_dependency_block =~ s# /># $key="$new_val" />#) {
                                # Attribute added
                            }
                        }
                    }
                }

                if (exists $recommendations->{$dep_name}) {
                    log_info($recommendations->{$dep_name});
                }
            }

            # Strip old inner <exclude> tags from $file_content so dynamic exclusions can be freshly generated
            $modified_dependency_block =~ s{\s*<exclude\s+[^/>]+/>}{}g;

            # If removing excludes left an empty open/close tag pair, collapse it to a self-closing tag
            $modified_dependency_block =~ s{>\s*</dependency>}{ />};

            $replacement_str = $leading_whitespace . $modified_dependency_block;
        }

        $replacement_str;
    }mxseg;

    # ------------------------------------------------------------------
    # STAGE 2: CREATE TEMPORARY CLEAN XML FOR show-deps
    # ------------------------------------------------------------------
    my $clean_content = $file_content;

    # Strip inner <exclude> tags ONLY in $clean_content so show-deps can evaluate raw transitives
    $clean_content =~ s{
        (<dependency\s+(?:[^"'>]|"[^"]*"|'[^']*')+?)
        (?:\s*/>|\s*>\s*(?:<exclude\s+[^/>]+/>\s*)*\s*</dependency>)
    }{$1 />}gsx;

    my $clean_file = "$ivy_file-clean";
    open(my $clean_fh, ">", $clean_file)
        or die "Error: could not write clean file '$clean_file': $!";
    print $clean_fh $clean_content;
    close $clean_fh;
    log_info("Wrote temporary clean stage-1 file to $clean_file");

    # Run show-deps against the temporary clean file
    update_deps_file($clean_file, $deps_file, $changes_made > 0);

    # unlink $clean_file;

    # ------------------------------------------------------------------
    # STAGE 3: TRANSITIVE ANALYSIS & DYNAMIC EXCLUSION GENERATION
    # ------------------------------------------------------------------
    my %global_excludes = extract_global_exclusions($file_content);
    my $remove_redundant_transitives_versioned = generate_transitive_map_from_deps($deps_file);

    # Now detect unused dependencies (after transitive map is available)
    my $unused_by_scope_ref = find_unused_dependencies($file_content, \%used_deps_to_keep, $update, \@remove_packages, $keep_if_exists, \@packages, $remove_redundant_transitives_versioned, $libdir);
    for my $unused_dep (keys %$unused_by_scope_ref) {
        $unused_deps_to_drop{$unused_dep} = 1;
    }

    # Compute surviving direct dependencies
    my %surviving_deps;
    while ($file_content =~ /<dependency\s+(?:[^>]*?\s+)?name="([^"]+)"/g) {
        $surviving_deps{$1} = 1;
    }

    # Remove redundant direct dependencies fully satisfied by surviving parents
    for my $dep_name (keys %surviving_deps) {
        my $current_rev;
        if ($file_content =~ /<dependency\b[^>]*?\bname="\Q$dep_name\E"[^>]*?\brev="([^"]+)"/s) {
            $current_rev = $1;
        }
        if (defined $current_rev && should_remove_transitive($dep_name, $current_rev, $update, \%used_deps_to_keep, \%surviving_deps, $remove_redundant_transitives_versioned)) {
            $file_content =~ s{
                ^ \s*
                <dependency\b
                (?:[^>"']|"[^"]*"|'[^']*')*?
                \bname="\Q$dep_name\E"
                (?:[^>"']|"[^"]*"|'[^']*')*?
                (?:
                    />
                    |
                    >\s*.*?\s*</dependency>
                )
                \r?\n?
            }{}gmsx;
            delete $surviving_deps{$dep_name};
            $changes_made += 1;
        }
    }

    # Pass intact $file_content so is_already_excluded_in_xml accurately checks pre-existing rules
    generate_dynamic_exclusions_from_deps(
        $deps_file,
        \%surviving_deps,
        $exclusions,
        \%global_excludes,
        $update,
        $add_if_missing,
        \%globally_add_deps,
        $file_content
    );

    # ------------------------------------------------------------------
    # STAGE 4: APPEND NEW EXCLUSIONS TO $file_content
    # ------------------------------------------------------------------
    for my $dep_name (keys %$exclusions) {
        my $dep_exclusions = $exclusions->{$dep_name};
        next unless defined $dep_exclusions && @$dep_exclusions > 0;

        # Match the complete <dependency>...</dependency> or <dependency ... /> block
        $file_content =~ s{
            ^ (\s*)
            (
                <dependency\b
                (?:[^>"']|"[^"]*"|'[^']*')*?
                \bname="\Q$dep_name\E"
                (?:[^>"']|"[^"]*"|'[^']*')*?
            )
            (
                />
                |
                >([ \t]*\r?\n)?(.*?)[ \t]*</dependency>
            )
        }{
            my $indent = $1;
            my $open_tag = $2;
            my $full_close = $3;
            my $has_newline = $4 // '';
            my $existing_inner = $5 // '';

            my $ex_indent = $indent . '    ';

            # Deduplicate against pre-existing rules
            my @new_rules;
            for my $rule (@$dep_exclusions) {
                my $mod = $rule->{module};
                my $group = $rule->{org};

                my $already_present = 0;

                # Check for existing org + module/name rule
                if (defined $group && defined $mod) {
                    if ($existing_inner =~ /<exclude\s+[^>]*\borg="\Q$group\E"[^>]*\b(?:module|name)="\Q$mod\E"/i ||
                        $existing_inner =~ /<exclude\s+[^>]*\b(?:module|name)="\Q$mod\E"[^>]*\borg="\Q$group\E"/i) {
                        $already_present = 1;
                    }
                }
                # Check for org-only rule
                elsif (defined $group && !defined $mod) {
                    if ($existing_inner =~ /<exclude\s+[^>]*\borg="\Q$group\E"(?![^>]*\b(?:module|name)=)/i) {
                        $already_present = 1;
                    }
                    else {
                        # Remove specific module excludes for this org since org-level exclude subsumes them
                        $existing_inner =~ s{^[ \t]*<exclude\s+[^>]*\borg="\Q$group\E"[^>]*\/>[ \t]*\r?\n?}{}gm;
                    }
                }
                # Check for module/name-only rule
                elsif (!defined $group && defined $mod) {
                    if ($existing_inner =~ /<exclude\s+[^>]*\b(?:module|name)="\Q$mod\E"/i) {
                        $already_present = 1;
                    }
                }

                push @new_rules, $rule unless $already_present;
            }

            if (@new_rules) {
                my $ex_xml = generate_exclusion_xml(\@new_rules, $ex_indent);
                if ($existing_inner ne '') {
                    "${indent}${open_tag}>\n${existing_inner}${ex_xml}\n${indent}</dependency>";
                }
                else {
                    "${indent}${open_tag}>${ex_xml}\n${indent}</dependency>";
                }
            }
            else {
                $&;
            }
        }gmsxe;
    }

    insert_missing_dependencies(\$file_content, $add_if_missing, $update, $exclusions);

    # Write final output to ivy.xml.new
    open(my $out, ">", $output_file)
        or die "Error: could not open '$output_file': $!";
    print $out $file_content;
    close $out;
    log_success("Successfully updated $output_file");

    if ($audit_deps) {
        report_missing_transitive_imports(\@src_dirs, $deps_file, 'C:/Tomcat10/lib');
    }
}

main();
exit 0;

sub generate_exclusion_xml {
    my ($rules_ref, $base_indent) = @_;
    my @keyOrder = ("org", "module", "name");
    my $exclusions_xml = '';

    if (defined $rules_ref && @$rules_ref > 0) {
        foreach my $rule (@$rules_ref) {
            $exclusions_xml .= qq!\n$base_indent<exclude!;
            for my $attribute (@keyOrder) {
                if (defined $rule->{$attribute}) {
                    $exclusions_xml .= qq! $attribute="$rule->{$attribute}"!;
                }
            }
            $exclusions_xml .= " />";
        }
    }
    return $exclusions_xml;
}

sub normalize_version {
    my $ver_str = shift;

    if ($ver_str) {
        $ver_str =~ s/([.-])([A-Za-z][\w+]*)/_\L$2/g;
        # remove syntactic sugar and hope for the best
        $ver_str =~ s/_\w+$//;
        # add missing 'v' at front of version string
        $ver_str = "v" . $ver_str unless $ver_str =~ m/^v/;
    }

    return $ver_str;
}

sub escape_whitespace {
    my $str = shift;
    $str =~ s/\r/\\r/g;
    $str =~ s/\n/\\n/g;
    $str =~ s/\t/\\t/g;
    $str =~ s/ /_/g;

    $str;
}

# Helper: Returns 1 if $v1 > $v2, -1 if $v1 < $v2, 0 if $v1 == $v2
sub version_compare {
    my ($v1, $v2) = @_;
    return 0 if $v1 eq $v2;

    # Clean versions to numeric components (e.g., "10.9.1.RELEASE" -> "10.9.1")
    my @v1_parts = map {$_ // 0} ($v1 =~ /(\d+)/g);
    my @v2_parts = map {$_ // 0} ($v2 =~ /(\d+)/g);

    my $max_length = scalar @v1_parts > scalar @v2_parts ? scalar @v1_parts : scalar @v2_parts;

    for (my $i = 0; $i < $max_length; $i++) {
        my $p1 = $v1_parts[$i] // 0;
        my $p2 = $v2_parts[$i] // 0;

        return 1 if $p1 > $p2;
        return -1 if $p1 < $p2;
    }

    return 0;
}

my %JAR_CACHE;  # $jar_name -> { classes => {}, packages => {}, prefixes => {} }
my %KNOWN_JARS; # $jar_name -> 1

sub load_jar_class_index {
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

        $jar_name = lc($jar_name);
        $KNOWN_JARS{$jar_name} = 1;

        $JAR_CACHE{$jar_name} ||= {
            classes  => {},
            packages => {},
            prefixes => {},
        };

        my $data = $JAR_CACHE{$jar_name};
        $data->{classes}{$fqcn} = 1;

        my $clean_fqcn = $fqcn;
        $clean_fqcn =~ s/\$.*//;
        $data->{classes}{$clean_fqcn} = 1;

        if ($clean_fqcn =~ /^(.*)\.[^\.]+$/) {
            my $pkg = $1;
            $data->{packages}{$pkg} = 1;

            my @parts = split(/\./, $pkg);
            for (my $i = 2; $i <= scalar(@parts); $i++) {
                my $prefix = join('.', @parts[0 .. $i - 1]);
                $data->{prefixes}{$prefix} = 1;
            }
        }
        $loaded_count++;
    }
    close($fh);
    log_info("Loaded $loaded_count class entries for " . scalar(keys %KNOWN_JARS) . " JAR(s) from jar-class-index.txt") if $loaded_count > 0 && $verbose;
}

sub save_jar_to_class_index {
    my ($jar_name, $fqcns_ref) = @_;
    return unless defined $jar_name && defined $fqcns_ref;

    my $script_dir = $FindBin::RealBin;
    my $index_file = "$script_dir/jar-class-index.txt";

    open(my $fh, '>>', $index_file) or do {
        log_warning("Could not open $index_file for writing: $!");
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
    log_info("Persisted " . scalar(@$fqcns_ref) . " class entries for '$jar_name' to jar-class-index.txt");
}

sub extract_jar_classes_and_packages {
    my ($jar_path) = @_;
    my $jar_name = lc(basename($jar_path));

    # 1. Return cached index if already loaded from flat file or scanned earlier
    if (exists $KNOWN_JARS{$jar_name} && exists $JAR_CACHE{$jar_name}) {
        return $JAR_CACHE{$jar_name};
    }

    my %classes;
    my %packages;
    my %prefixes;
    my @extracted_fqcns;

    $JAR_CACHE{$jar_name} = {
        classes  => \%classes,
        packages => \%packages,
        prefixes => \%prefixes,
    };
    $KNOWN_JARS{$jar_name} = 1;

    return $JAR_CACHE{$jar_name} unless -f $jar_path;

    my @entry_paths;

    log_info("Extracting jar classes: " . $jar_path);
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
            next if $path =~ /\$/; # Skip inner and anonymous classes containing '$'

            my $fqcn = $path;
            $fqcn =~ s#/#.#g;

            push @extracted_fqcns, $fqcn;
            $classes{$fqcn} = 1;

            if ($fqcn =~ /^(.*)\.[^\.]+$/) {
                my $pkg = $1;
                $packages{$pkg} = 1;

                my @parts = split(/\./, $pkg);
                for (my $i = 2; $i <= scalar(@parts); $i++) {
                    my $prefix = join('.', @parts[0 .. $i - 1]);
                    $prefixes{$prefix} = 1;
                }
            }
        }
    }

    # Save to flat file for future runs
    save_jar_to_class_index($jar_name, \@extracted_fqcns);

    return $JAR_CACHE{$jar_name};
}

sub find_jars_for_dependency {
    my ($dep_name, $update_ref, $libdir) = @_;
    my @found_jars;

    my $entry = $update_ref->{$dep_name} if $update_ref;
    my $name = ($entry && $entry->{name}) ? $entry->{name} : $dep_name;
    my $org = $entry->{org} if $entry;

    my @search_dirs;
    $libdir ||= (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';
    push @search_dirs, $libdir if -d $libdir;

    my %seen_jars;

    for my $dir (@search_dirs) {
        find({
            wanted   => sub {
                return unless -f $_ && $_ =~ /\.jar$/i;
                my $jar_path = $_;
                my $jar_name = lc(basename($jar_path));

                if ($jar_name =~ /^\Q$dep_name\E(?:-[0-9].*|\.jar)$/i ||
                    $jar_name =~ /^\Q$name\E(?:-[0-9].*|\.jar)$/i ||
                    ($org && $jar_name =~ /^\Q$org\E[.-]\Q$name\E(?:-[0-9].*|\.jar)$/i)) {
                    if (!$seen_jars{$jar_path}) {
                        push @found_jars, $jar_path;
                        $seen_jars{$jar_path} = 1;
                    }
                }
            },
            no_chdir => 1,
        }, $dir);
    }

    return @found_jars;
}

sub is_dep_used {
    my ($dep_name, $update_ref, $used_deps_ref, $libdir) = @_;
    return 0 unless defined $dep_name && defined $used_deps_ref && %$used_deps_ref;

    return 1 if exists $used_deps_ref->{$dep_name};

    $libdir ||= (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';

    # 1. DIRECT JAR INSPECTION: Look inside matching JAR file(s) and extract classes
    my @matching_jars = find_jars_for_dependency($dep_name, $update_ref, $libdir);
    if (@matching_jars) {
        for my $jar_path (@matching_jars) {
            my $jar_data = extract_jar_classes_and_packages($jar_path);
            my $classes_ref = $jar_data->{classes};
            my $packages_ref = $jar_data->{packages};
            my $prefixes_ref = $jar_data->{prefixes};

            for my $ref_pkg (keys %$used_deps_ref) {
                if (exists $classes_ref->{$ref_pkg} ||
                    exists $packages_ref->{$ref_pkg} ||
                    exists $prefixes_ref->{$ref_pkg}) {
                    # log_info("JAR inspection verified '$dep_name' is USED (found '$ref_pkg' inside " . basename($jar_path) . ")");
                    return 1;
                }
            }
        }
    }

    my $entry = $update_ref->{$dep_name} if $update_ref;
    my $org = $entry->{org} if $entry;
    my $name = ($entry && $entry->{name}) ? $entry->{name} : $dep_name;

    my @patterns;
    if (defined $org) {
        push @patterns, quotemeta($org);
        my $base_org = $org;
        if ($base_org =~ s/\.(orm|core|client5|data|v2)$//i) {
            push @patterns, quotemeta($base_org);
        }
    }

    my $clean_name = $name;
    $clean_name =~ s/^(spring|commons|jakarta|javax|log4j|slf4j|jackson|hibernate|itext|tika)-//i;

    if (defined $org && $clean_name ne '') {
        my $sub_pkg = "$org.$clean_name";
        push @patterns, quotemeta($sub_pkg);
        if ($org =~ /^(.*?)\.[^\.]+$/) {
            push @patterns, quotemeta("$1.$clean_name");
        }
    }

    my $dot_name = $name;
    $dot_name =~ s/[-_]/\\./g;
    push @patterns, $dot_name;

    my $raw_name = $name;
    $raw_name =~ s/[-_]//g;
    push @patterns, quotemeta($raw_name) if length($raw_name) > 3;

    for my $ref_pkg (keys %$used_deps_ref) {
        for my $pat (@patterns) {
            if ($ref_pkg =~ /^$pat\b/i || $ref_pkg =~ /\b$pat\b/i) {
                return 1;
            }
        }
    }

    return 0;
}

sub find_unused_dependencies {
    my ($file_content, $used_deps_ref, $update_ref, $remove_packages_ref, $keep_if_exists_ref, $packages_ref, $transitive_map_ref, $libdir) = @_;
    my %unused_deps;

    log_info("Analyzing declared dependencies against actual usage...");

    # Extract all declared dependencies and their current revisions from ivy.xml (order-agnostic)
    my %all_declared_deps;
    while ($file_content =~ /<dependency\b([^>]+)>/g) {
        my $attrs = $1;
        my $name = $1 if $attrs =~ /\bname="([^"]+)"/;
        my $rev = $1 if $attrs =~ /\brev="([^"]+)"/;
        if (defined $name) {
            $all_declared_deps{$name} = $rev // '';
        }
    }

    my %kept_deps;

    # PASS 1: Identify all directly used, explicitly kept, keep=1, snyk dependencies
    for my $dep_name (keys %all_declared_deps) {
        # Check keep=1 flag in revision-updates.txt
        if ($update_ref && exists $update_ref->{$dep_name} && $update_ref->{$dep_name}->{keep}) {
            log_info("Keeping dependency '$dep_name' (flagged keep=1 in revision-updates.txt)");
            $kept_deps{$dep_name} = 1;
            next;
        }

        # Check snyk=SNYK flag in revision-updates.txt
        if ($update_ref && exists $update_ref->{$dep_name} && $update_ref->{$dep_name}->{snyk}) {
            log_info("Keeping dependency '$dep_name' (resolvesg snyk=$update_ref->{$dep_name}->{snyk} in revision-updates.txt)");
            $kept_deps{$dep_name} = 1;
            next;
        }

        # Check keep_if_exists rule
        if ($keep_if_exists_ref && exists $keep_if_exists_ref->{$dep_name}) {
            if (grep {$keep_if_exists_ref->{$dep_name} eq $_} @$packages_ref) {
                $kept_deps{$dep_name} = 1;
                next;
            }
        }

        # Skip explicit removal list
        if ($remove_packages_ref && grep {$dep_name =~ $_} @$remove_packages_ref) {
            next;
        }

        # Check if dependency or its JAR classes are directly referenced in source code
        if (is_dep_used($dep_name, $update_ref, $used_deps_ref, $libdir)) {
            $kept_deps{$dep_name} = 1;
        }
    }

    # PASS 2: Evaluate remaining dependencies against transitives of ALL kept parents
    for my $dep_name (keys %all_declared_deps) {
        next if $kept_deps{$dep_name};
        next if ($remove_packages_ref && grep {$dep_name =~ $_} @$remove_packages_ref);

        my $is_transitive = 0;
        my $is_version_override = 0;

        if ($transitive_map_ref && %$transitive_map_ref) {
            for my $parent_dep (keys %kept_deps) {
                if (exists $transitive_map_ref->{$parent_dep} &&
                    exists $transitive_map_ref->{$parent_dep}->{$dep_name}) {

                    $is_transitive = 1;

                    # Get effective direct revision vs transitive revision
                    my $direct_rev = $update_ref->{$dep_name}->{rev} if (exists $update_ref->{$dep_name});
                    $direct_rev ||= $all_declared_deps{$dep_name};

                    my $transitive_rev = $transitive_map_ref->{$parent_dep}->{$dep_name};

                    # If direct version > transitive version (e.g. 3.0.0 > 2.0.0), KEEP direct dependency
                    if (defined $direct_rev && defined $transitive_rev && $direct_rev ne '' && $transitive_rev ne '') {
                        if (version_compare($direct_rev, $transitive_rev) > 0) {
                            $is_version_override = 1;
                            log_success("Keeping direct dependency $dep_name ($direct_rev > $transitive_rev via parent '$parent_dep') to enforce version override");
                            last;
                        }
                    }
                }
            }
        }

        # Keep if it's a higher version override; drop only if fully satisfied at equal/lower version
        if ($is_version_override) {
            $kept_deps{$dep_name} = 1;
        }
        elsif ($is_transitive) {
            $kept_deps{$dep_name} = 1;
        }
        else {
            $unused_deps{$dep_name} = 1;
        }
    }

    if (keys %unused_deps) {
        log_warning("Found " . scalar(keys %unused_deps) . " unused dependencies: " . join(", ", sort keys %unused_deps));
    }
    else {
        log_info("All declared dependencies are in use.");
    }

    return \%unused_deps;
}

sub should_remove_transitive {
    my ($dep_name, $current_rev, $update_ref, $used_deps_ref, $surviving_deps_ref, $remove_redundant_transitives_versioned) = @_;

    return 0 unless defined $current_rev;
    return 0 unless defined $remove_redundant_transitives_versioned
        && ref($remove_redundant_transitives_versioned) eq 'HASH';

    # 1. Guardrail: Keep if 'keep' flag is set in update hash
    if ($update_ref && exists $update_ref->{$dep_name} && $update_ref->{$dep_name}->{keep}) {
        return 0;
    }

    # 1a. Guardrail: Keep if 'snyk' flag is set in update hash
    if ($update_ref && exists $update_ref->{$dep_name} && $update_ref->{$dep_name}->{snyk}) {
        return 0;
    }

    my $target_rev = $update_ref->{$dep_name}->{rev} if defined $update_ref && exists $update_ref->{$dep_name};
    my $effective_rev = $target_rev || $current_rev;

    my $max_transitive_rev;

    # 2. Find the HIGHEST transitive version supplied across ALL surviving parents
    for my $parent_pkg (keys %$remove_redundant_transitives_versioned) {
        if ($surviving_deps_ref && exists $surviving_deps_ref->{$parent_pkg}) {
            my $targets = $remove_redundant_transitives_versioned->{$parent_pkg};

            if (exists $targets->{$dep_name}) {
                my $transitive_rev = $targets->{$dep_name};

                if (!defined $max_transitive_rev ||
                    version_compare($transitive_rev, $max_transitive_rev) > 0) {
                    $max_transitive_rev = $transitive_rev;
                }
            }
        }
    }

    # 3. If any surviving parent provides a version >= direct version, Ivy will resolve it automatically
    if (defined $max_transitive_rev) {
        my $cmp = version_compare($effective_rev, $max_transitive_rev);

        if ($cmp <= 0) {
            log_info("Dropping redundant direct dependency $dep_name ($effective_rev <= $max_transitive_rev satisfied by surviving transitives)");
            return 1;
        }
        else {
            log_success("Keeping direct dependency $dep_name ($effective_rev > $max_transitive_rev across all transitives)");
            return 0;
        }
    }

    return 0;
}

sub update_deps_file {
    my ($ivy_file, $deps_file, $force_update) = @_;
    $ivy_file ||= 'ivy.xml';
    my $ant_bin = (-e '/c/ant/bin/ant') ? '/c/ant/bin/ant' : 'ant';
    my $ant_cmd = "$ant_bin -f my-build.xml show-deps -Divy.file=$ivy_file";

    log_info("INFO: Generating $deps_file from Ant show-deps target...");

    my $ant_fh;
    unless (open($ant_fh, "$ant_cmd 2>&1 |")) {
        if (-e $deps_file) {
            log_warning("Failed to run Ant command ($!). Re-using existing $deps_file.");
            return;
        }
        die "Failed to execute Ant command: $!\n";
    }

    my @filtered_lines;

    while (my $line = <$ant_fh>) {
        if ($line =~ /\[ivy:dependencytree\]\s*(.*)$/) {
            my $content = $1;

            # Keep the root header
            if ($content =~ /^Dependency tree/) {
                push @filtered_lines, $content . "\n";
                next;
            }

            # Match lines with branch connectors (+- or \-)
            if ($content =~ /^(.*?)(?:[\+\\]\-)(.*)$/) {
                # Keep the whole tree so we can map deep transitives
                push @filtered_lines, $content . "\n";
            }
        }
        elsif ($line =~ /Target "show-deps" does not exist/) {
            log_error("update my-build.xml");
            return;
        }
    }
    close($ant_fh);

    open(my $deps_out, '>', $deps_file) or die "Could not write to $deps_file: $!\n";
    print $deps_out @filtered_lines;
    close($deps_out);

    if (!(stat($deps_file))->size) {
        log_error("FAILURE: could not generate " . $deps_file);
    }
    else {
        log_success("SUCCESS: Updated $deps_file with direct and 1st-generation dependencies.");
    }
}

sub get_declared_ivy_dependencies {
    my ($ivy_file) = @_;
    my %declared_deps;

    return %declared_deps unless -f $ivy_file;

    open(my $fh, '<', $ivy_file) or return %declared_deps;
    while (my $line = <$fh>) {
        if ($line =~ /<dependency\s+.*?name="([^"]+)"/) {
            $declared_deps{$1} = 1;
        }
    }
    close($fh);

    return %declared_deps;
}

sub extract_all_referenced_packages {
    my ($src_dirs_ref, $webapp_dir, $base_packages_ref) = @_;
    my %referenced_packages;

    my @src_dirs = ref($src_dirs_ref) eq 'ARRAY' ? @{$src_dirs_ref} : ($src_dirs_ref);
    @src_dirs = grep {-d $_} @src_dirs;

    my @local_dirs = grep {$_ !~ m{^\.\./}} @src_dirs;
    my @mgic_dirs = grep {$_ =~ m{^\.\./}} @src_dirs;

    log_info("Scanning local source directories (" . join(', ', @local_dirs) . ")...");

    my %local_references;

    my $register_local = sub {
        my ($raw) = @_;
        return unless defined $raw;
        $raw =~ s#[\r\n\s]+##g;

        return unless $raw =~ /^[a-zA-Z][a-zA-Z0-9_]*\.[a-zA-Z0-9_]+\.[a-zA-Z0-9_\.]+/;
        return if $raw =~ /^(http|https|ftp|mailto|www|com\.sun|org\.w3c\.dom)/i;
        return if $raw =~ /\.(xsd|xml|html|jsp|properties|png|jpg|gif|css|js)$/i;

        $local_references{$raw} = 1;
        my $pkg = $raw;
        if ($pkg =~ s#\.[A-Z][a-zA-Z0-9_]*$##) {
            $local_references{$pkg} = 1;
        }
    };

    # 1. Scan Local Directories (src, test)
    if (@local_dirs) {
        find({
            wanted   => sub {
                my $file = $File::Find::name;
                return unless -f $file && $file =~ /\.(java|xml|properties|factories)$/i;

                open(my $fh, '<', $file) or return;
                while (my $line = <$fh>) {
                    if ($line =~ /^\s*import\s+(?:static\s+)?([a-zA-Z0-9_\.\*]+)\s*;\s*$/) {
                        my $imp = $1;
                        $imp =~ s#\.\*$##;
                        $register_local->($imp);
                    }
                    while ($line =~ /(?:Class\.forName|loadClass)\s*\(\s*"([a-zA-Z0-9_\.]+)"\s*\)/g) {
                        $register_local->($1);
                    }
                    while ($line =~ /([a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+)\.class\b/g) {
                        $register_local->($1);
                    }
                    while ($line =~ /(?:driverClassName|dialect|class|type|factory-method)="([a-zA-Z0-9_\.]+)"/g) {
                        $register_local->($1);
                    }
                    while ($line =~ /<Logger\s+[^>]*?name="([a-zA-Z0-9_\.]+)"/g) {
                        $register_local->($1);
                    }
                    while ($line =~ /"([a-zA-Z][a-zA-Z0-9_]*\.[a-zA-Z0-9_]+\.[a-zA-Z0-9_\.]+)"/g) {
                        $register_local->($1);
                    }
                }
                close($fh);
            },
            no_chdir => 1
        }, @local_dirs);
    }

    # 2. Scan webapp_dir ONLY for web/presentation assets
    if (defined $webapp_dir && -d $webapp_dir) {
        find({
            wanted   => sub {
                my $file = $File::Find::name;
                return unless -f $file && $file =~ /\.(xml|jsp|jspf|tag|tld)$/i;
                open(my $fh, '<', $file) or return;
                while (my $line = <$fh>) {
                    while ($line =~ /(?:class|type|value|driverClassName|dialect)="([a-zA-Z0-9_\.]+)"/g) {
                        $register_local->($1);
                    }
                    if ($line =~ /%@\s*page\s+.*?import="([^"]+)"/) {
                        for my $imp (split /\s*,\s*/, $1) {
                            $imp =~ s#\.\*$##;
                            $register_local->($imp);
                        }
                    }
                }
                close($fh);
            },
            no_chdir => 1
        }, $webapp_dir);
    }

    %referenced_packages = %local_references;

    # 3. Scan Mgic External Directories with Reachability Propagation
    if (@mgic_dirs) {
        log_info("Scanning external mgic directories (" . join(', ', @mgic_dirs) . ") for reachability...") if $verbose;

        my %mgic_class_imports; # FQCN -> { pkg => '...', imports => [...] }

        find({
            wanted   => sub {
                my $file = $File::Find::name;
                return unless -f $file && $file =~ /\.java$/i;

                open(my $fh, '<', $file) or return;
                my $pkg_decl = '';
                my $class_name = '';
                my @file_imports;

                while (my $line = <$fh>) {
                    if ($line =~ /^\s*package\s+([a-zA-Z0-9_\.]+)\s*;\s*$/) {
                        $pkg_decl = $1;
                    }
                    elsif ($line =~ /\b(?:public\s+|protected\s+)?(?:class|interface|enum|record)\s+([a-zA-Z0-9_]+)/) {
                        $class_name = $1 unless $class_name;
                    }

                    if ($line =~ /^\s*import\s+(?:static\s+)?([a-zA-Z0-9_\.\*]+)\s*;\s*$/) {
                        my $imp = $1;
                        $imp =~ s#\.\*$##;
                        push @file_imports, $imp;
                    }
                    while ($line =~ /(?:Class\.forName|loadClass)\s*\(\s*"([a-zA-Z0-9_\.]+)"\s*\)/g) {
                        push @file_imports, $1;
                    }
                    while ($line =~ /([a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+)\.class\b/g) {
                        push @file_imports, $1;
                    }
                    while ($line =~ /"([a-zA-Z][a-zA-Z0-9_]*\.[a-zA-Z0-9_]+\.[a-zA-Z0-9_\.]+)"/g) {
                        push @file_imports, $1;
                    }
                }
                close($fh);

                if ($pkg_decl && $class_name) {
                    my $fqcn = "$pkg_decl.$class_name";
                    $mgic_class_imports{$fqcn} = {
                        pkg     => $pkg_decl,
                        imports => \@file_imports
                    };
                }
            },
            no_chdir => 1
        }, @mgic_dirs);

        my $is_class_imported = sub {
            my ($fqcn, $pkg_decl, $ref_keys) = @_;
            return 1 if exists $ref_keys->{$fqcn};
            return 1 if exists $ref_keys->{$pkg_decl};
            for my $ref (keys %$ref_keys) {
                if ($fqcn eq $ref || $fqcn =~ /^\Q$ref\E\./) {
                    return 1;
                }
            }
            return 0;
        };

        # Level 1: Mgic classes directly imported in local folders (src, test)
        my %reachable_level1;
        my %level1_imports;

        for my $fqcn (keys %mgic_class_imports) {
            my $info = $mgic_class_imports{$fqcn};
            if ($is_class_imported->($fqcn, $info->{pkg}, \%local_references)) {
                $reachable_level1{$fqcn} = 1;
                for my $imp (@{$info->{imports}}) {
                    $level1_imports{$imp} = 1;
                    my $p = $imp;
                    $level1_imports{$p} = 1 if $p =~ s#\.[A-Z][a-zA-Z0-9_]*$##;
                }
            }
        }

        # Level 2: Mgic classes directly imported by Level 1 classes
        my %reachable_level2;
        my %level2_imports;

        for my $fqcn (keys %mgic_class_imports) {
            next if $reachable_level1{$fqcn};
            my $info = $mgic_class_imports{$fqcn};
            if ($is_class_imported->($fqcn, $info->{pkg}, \%level1_imports)) {
                $reachable_level2{$fqcn} = 1;
                for my $imp (@{$info->{imports}}) {
                    $level2_imports{$imp} = 1;
                    my $p = $imp;
                    $level2_imports{$p} = 1 if $p =~ s#\.[A-Z][a-zA-Z0-9_]*$##;
                }
            }
        }

        for my $imp (keys %level1_imports, keys %level2_imports) {
            $referenced_packages{$imp} = 1;
        }

        log_info("Reachable mgic classes: " . (scalar keys %reachable_level1) . " (Direct local), " . (scalar keys %reachable_level2) . " (1-hop indirect)") if $verbose;
    }

    log_success("Extracted " . (scalar keys %referenced_packages) . " active package/class references.");
    return %referenced_packages;
}

sub audit_dependencies {
    my ($src_dirs, $libdir, $base_packages_ref) = @_;
    my %unused_deps;
    my %used_deps;
    my %class_to_deps;
    my $file_types = 'jsp|xml|properties';

    log_info("Auditing dependencies in directories: @$src_dirs");

    my $dependencies = detect_dependencies($src_dirs, $file_types);

    # Traverse source directories
    for my $src_dir (@$src_dirs) {
        find(sub {
            return unless -f $_ && $_ =~ /\.java$/;
            my $class_file = $File::Find::name;
            open my $fh, '<', $class_file or return;

            while (my $line = <$fh>) {
                if ($line =~ /import\s+([a-zA-Z0-9_.]+);/) {
                    my $import = $1;
                    $class_to_deps{$class_file}{$import} = 1;
                }
            }
            close $fh;
        }, $src_dir);
    }

    # Analyze dependencies
    for my $class (keys %class_to_deps) {
        for my $import (keys %{$class_to_deps{$class}}) {
            if ($import =~ /^(?:java|javax)\./) {
                next; # Skip standard Java RI libraries
            }
            $used_deps{$import} = 1;
        }
    }

    return (\%unused_deps, \%used_deps);
}

sub filter_dependencies {
    my ($used_deps_ref, $all_deps_ref) = @_;
    my %filtered_deps;

    for my $dep (keys %$all_deps_ref) {
        if (exists $used_deps_ref->{$dep}) {
            $filtered_deps{$dep} = $all_deps_ref->{$dep};
        }
    }

    return \%filtered_deps;
}

sub generate_transitive_map_from_deps {
    my ($deps_file) = @_;
    my %dynamic_transitives;

    return \%dynamic_transitives unless -e $deps_file;

    open(my $fh, '<', $deps_file) or return \%dynamic_transitives;

    my @stack;

    while (my $line = <$fh>) {
        chomp $line;

        if ($line =~ /^(.*?)(?:[\+\\]\-)\s*(.*?)$/) {
            my $prefix = $1;
            my $payload = $2;

            my $depth = length($prefix) / 3;

            if ($payload =~ /([^#]+)#([^;]+);([^\s]+)/) {
                my $org = $1;
                my $name = $2;
                my $rev = $3;

                $stack[$depth] = $name;

                if ($depth > 0 && defined $stack[0]) {
                    my $root_parent = $stack[0];

                    # Store the LOWEST (native) version seen under this parent.
                    # When top-level ivy.xml forces a higher version, Ivy prints both the forced
                    # version and the native POM version under the parent. Taking the MIN version
                    # captures the parent's true requirement.
                    if (!exists $dynamic_transitives{$root_parent}{$name} ||
                        version_compare($rev, $dynamic_transitives{$root_parent}{$name}) < 0) {
                        $dynamic_transitives{$root_parent}{$name} = $rev;
                    }
                }
            }
        }
    }
    close($fh);

    return \%dynamic_transitives;
}

sub generate_dynamic_exclusions_from_deps {
    my ($deps_file, $surviving_deps_ref, $exclusions_ref, $global_excludes_ref, $update_ref, $add_if_missing_ref, $globally_add_deps_ref, $file_content) = @_;

    return unless -e $deps_file;

    # Pre-pass: Build a map of the HIGHEST direct dependency version for each module
    # This prevents unnecessary excludes when one direct version is sufficient
    my %max_direct_versions;

    # First, try to get versions from $update_ref (updated dependencies)
    if (defined $update_ref) {
        for my $dep_name (keys %$update_ref) {
            my $rev = $update_ref->{$dep_name}->{rev};
            if (defined $rev) {
                if (!exists $max_direct_versions{$dep_name} ||
                    version_compare($rev, $max_direct_versions{$dep_name}) > 0) {
                    $max_direct_versions{$dep_name} = $rev;
                }
            }
        }
    }

    # Second, extract CURRENT revisions directly from ivy.xml for all direct dependencies
    # This catches dependencies that are not in $update_ref
    if (defined $file_content) {
        # Handle both attribute orders: name before rev and rev before name
        while ($file_content =~ /<dependency\s+([^>]+)>/g) {
            my $attrs = $1;
            my $name;
            my $rev;
            $name = $1 if $attrs =~ /\bname="([^"]+)"/;
            $rev = $1 if $attrs =~ /\brev="([^"]+)"/;

            if (defined $name && defined $rev) {
                # Use the version from ivy.xml if it's higher or not yet recorded
                if (!exists $max_direct_versions{$name} ||
                    version_compare($rev, $max_direct_versions{$name}) > 0) {
                    $max_direct_versions{$name} = $rev;
                }
            }
        }
    }

    open(my $fh, '<', $deps_file) or return;

    my @stack;
    my %pending_exclusions; # $root_parent -> $org -> { $name => $rev }

    # Orgs that Snyk/security scanners need explicitly excluded at the dependency level
    my %always_exclude_orgs = (
        'org.bouncycastle' => 1,
    );

    while (my $line = <$fh>) {
        chomp $line;

        if ($line =~ /^(.*?)(?:[\+\\]\-)\s*(.*?)$/) {
            my $prefix = $1;
            my $payload = $2;

            my $depth = length($prefix) / 3;

            if ($payload =~ /([^#]+)#([^;]+);([^\s]+)/) {
                my $org = $1;
                my $name = $2;
                my $rev = $3;

                $stack[$depth] = $name;

                if ($depth > 0 && defined $stack[0]) {
                    my $root_parent = $stack[0];

                    my $is_mismatched = 0;

                    # RULE A: Explicitly forced org-level exclusions (for Snyk visibility)
                    if (exists $always_exclude_orgs{$org}) {
                        $is_mismatched = 1;
                    }
                    # RULE B: Exact module match in update ref / surviving deps with version difference
                    # NEW POLICY: Apply version comparison logic - only exclude if direct < transitive
                    elsif (exists $update_ref->{$name} && exists $surviving_deps_ref->{$name}) {
                        my $update_rev = $update_ref->{$name}->{rev};
                        my $parent_update_rev = $update_ref->{$root_parent}->{rev} if exists $update_ref->{$root_parent};
                        if (defined $update_rev && $update_rev ne $rev) {
                            # Version differs - only mark as mismatched if direct < transitive
                            my $cmp = version_compare($update_rev, $rev);
                            if ($cmp < 0) {
                                # Direct version is older than transitive - add exclude
                                if (!defined $parent_update_rev || $parent_update_rev ne $update_rev) {
                                    $is_mismatched = 1;
                                }
                            }
                            # If direct >= transitive, don't add exclude (new policy)
                        }
                    }
                    # RULE C: Direct dependency present without explicit update rule
                    # NEW POLICY: Only add exclude if ALL direct versions are OLDER than transitive
                    elsif (exists $surviving_deps_ref->{$name}) {
                        my $max_direct = $max_direct_versions{$name};
                        if (defined $max_direct) {
                            # Compare the HIGHEST direct version against the transitive
                            my $cmp = version_compare($max_direct, $rev);
                            if ($cmp < 0) {
                                # Even the highest direct version is older than this transitive
                                # Add exclude to force the transitive version
                                $is_mismatched = 1;
                            }
                            # If $cmp >= 0, the highest direct version covers this transitive, no exclude needed
                        }
                        else {
                            # No direct version found, exclude conservatively
                            $is_mismatched = 1;
                        }
                    }

                    if ($is_mismatched) {
                        # Queue for dependency-level exclusion on the root parent
                        if ($name ne $root_parent) {
                            $pending_exclusions{$root_parent}{$org}{$name} = $rev;
                        }

                        # Check for promotion if needed
                        if (exists $update_ref->{$name} && !exists $surviving_deps_ref->{$name}) {
                            if (defined $globally_add_deps_ref && !exists $globally_add_deps_ref->{$name}) {
                                $globally_add_deps_ref->{$name} = 1;
                                if (defined $add_if_missing_ref) {
                                    $add_if_missing_ref->{$root_parent} ||= [];
                                    push @{$add_if_missing_ref->{$root_parent}}, $name
                                        unless grep {$_ eq $name} @{$add_if_missing_ref->{$root_parent}};
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    close($fh);

    # EVALUATE PENDING EXCLUSIONS AND BUILD XML RULES
    for my $root_parent (keys %pending_exclusions) {
        $exclusions_ref->{$root_parent} ||= [];

        for my $org (keys %{$pending_exclusions{$root_parent}}) {
            my $modules_ref = $pending_exclusions{$root_parent}{$org};
            my @modules = keys %$modules_ref;

            # If 2+ transitives share the org OR it's a forced org (BouncyCastle), write org-level exclude
            if (@modules >= 2 || exists $always_exclude_orgs{$org}) {
                my $already_excluded = 0;
                for my $rule (@{$exclusions_ref->{$root_parent}}) {
                    if (defined $rule->{org} && $rule->{org} eq $org && !defined $rule->{module}) {
                        $already_excluded = 1;
                        last;
                    }
                }

                if (!$already_excluded) {
                    push @{$exclusions_ref->{$root_parent}}, { org => $org };
                    log_info("Generated local dependency-level exclusion for '$org' under parent '$root_parent'");
                }
            }
            else {
                for my $mod (@modules) {
                    my $already_excluded = 0;
                    for my $rule (@{$exclusions_ref->{$root_parent}}) {
                        if ((defined $rule->{org} && $rule->{org} eq $org) &&
                            (defined $rule->{module} && $rule->{module} eq $mod)) {
                            $already_excluded = 1;
                            last;
                        }
                    }

                    if (!$already_excluded) {
                        push @{$exclusions_ref->{$root_parent}}, { org => $org, module => $mod };
                        log_info("Generated local org+module exclusion for '$org#$mod' under parent '$root_parent'");
                    }
                }
            }
        }
    }
}

sub extract_global_exclusions {
    my ($xml_content) = @_;
    my %global_excludes;

    # Match standalone <exclude org="..." module="..." /> tags outside of <dependency> blocks
    # or simple global tags like <exclude module="foo"/> / <exclude org="bar"/>
    while ($xml_content =~ /<exclude\s+([^>]+)\/>/g) {
        my $attrs = $1;
        my $org = $1 if $attrs =~ /\borg="([^"]+)"/;
        my $module = $1 if $attrs =~ /\bmodule="([^"]+)"/;
        my $name = $1 if $attrs =~ /\bname="([^"]+)"/; # Some ivy configs use name instead of module

        my $target = $module || $name;

        if (defined $target) {
            $global_excludes{$target} = 1;
        }
        if (defined $org && !defined $target) {
            # Globally excluded by organization
            $global_excludes{"org:$org"} = 1;
        }
    }

    return %global_excludes;
}

sub promote_transitive_updates_to_add_if_missing {
    my ($deps_file, $promotions_ref, $inject_deps_ref, $file_content_ref) = @_;

    return unless -e $deps_file && defined $promotions_ref;

    open(my $fh, '<', $deps_file) or return;

    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^[\s|\\+\-]+//;

        if ($line =~ /^([^#]+)#([^;]+);/) {
            my $org = $1;
            my $dep_name = $2;

            # Only promote if explicitly defined in $promotions_ref
            if (exists $promotions_ref->{$dep_name}) {
                my $target = $promotions_ref->{$dep_name};
                my $new_name = $target->{name} || $dep_name;

                if ($$file_content_ref !~ /name="\Q$new_name\E"/) {
                    unless (exists $inject_deps_ref->{$new_name}) {
                        $inject_deps_ref->{$new_name} = {
                            org  => $target->{org} || $org,
                            rev  => $target->{rev},
                            conf => $target->{conf} || 'runtime->default',
                        };
                        log_info("Promoting '$dep_name' -> '$new_name' ($target->{rev}) as direct dependency");
                    }
                }
            }
        }
    }
    close($fh);
}

sub process_parent_triggered_additions {
    my ($file_content_ref, $add_if_missing_ref, $update_ref, $exclusions_ref) = @_;

    my @insertions_to_apply = ();

    for my $trigger_pkg_name (keys %$add_if_missing_ref) {
        my $trigger_dep_block_regex = qr{
            (
                \s+
                <dependency\s+
                (?:[^>]|"[^"]*")*?
                name="$trigger_pkg_name"
                (?:[^>]|"[^"]*")*?
                (?:
                    \s*/>
                    |
                    >
                    (?:
                        (?!</dependency>)
                        (?!<dependency\s+)
                        .
                    )*?
                    </dependency>
                )
            )
        }xms;

        if ($$file_content_ref =~ m/(.*?)($trigger_dep_block_regex)/s) {
            my $match_end_offset = length($1) + length($2);
            my $matched_trigger_block = $2;

            my $trigger_base_indent = '';
            if ($matched_trigger_block =~ s{^(\s*)}{ $trigger_base_indent = $1;
                '' }se) {
                my @lines = split(/\r?\n/, $trigger_base_indent);
                if (@lines > 0 && $lines[-1] =~ /^(\s*)/) {
                    $trigger_base_indent = $1;
                }
            }

            my $trigger_deps = $add_if_missing_ref->{$trigger_pkg_name};
            my $xml_to_insert = '';

            for my $pkg (@$trigger_deps) {
                my $dep = $update_ref->{$pkg};
                next unless defined $dep;

                my $org = $dep->{org};
                my $name = $dep->{name} || $pkg;

                my $exists_regex = qr{
                    \s*
                    <dependency\s+
                    (?:[^>]|"[^"]*")*?
                    org="$org"
                    (?:[^>]|"[^"]*")*?
                    name="$name"
                    (?:[^>]|"[^"]*")*?
                    (?:
                        \s*/>
                        |
                        >
                        (?:
                            (?!</dependency>)
                            (?!<dependency>)
                            .
                        )*?
                        </dependency>
                    )
                }xms;

                if ($$file_content_ref !~ $exists_regex) {
                    my $current_dep_tag_indent = $trigger_base_indent;
                    my $dep_exclusions = $exclusions_ref->{$name} || $exclusions_ref->{"$org,$name"};

                    my $exclusions_xml = generate_exclusion_xml($dep_exclusions, $current_dep_tag_indent . '    ', $name);

                    my $new_dep_xml;
                    my $conf = $dep->{conf} || 'runtime->default';
                    if (length $exclusions_xml > 0) {
                        $new_dep_xml = qq!\n$current_dep_tag_indent<dependency org="$org" name="$name" rev="$dep->{rev}" conf="$conf">$exclusions_xml$current_dep_tag_indent</dependency>!;
                    }
                    else {
                        $new_dep_xml = qq!\n$current_dep_tag_indent<dependency org="$org" name="$name" rev="$dep->{rev}" conf="$conf" />!;
                    }

                    log_info("Add missing $trigger_pkg_name dependency $name");
                    $xml_to_insert .= $new_dep_xml;
                }
            }

            if (length $xml_to_insert > 0) {
                push @insertions_to_apply, { pos => $match_end_offset, text => $xml_to_insert };
            }
        }
    }

    # Apply in reverse order to preserve string positional offsets
    @insertions_to_apply = sort {$b->{pos} <=> $a->{pos}} @insertions_to_apply;

    foreach my $insertion (@insertions_to_apply) {
        substr($$file_content_ref, $insertion->{pos}, 0) = $insertion->{text};
    }
}

sub insert_missing_dependencies {
    my ($file_content_ref, $add_if_missing_ref, $update_ref, $exclusions_ref) = @_;

    # 1. Process parent-triggered additions ONLY if explicitly listed in $add_if_missing
    if (defined $add_if_missing_ref && %$add_if_missing_ref) {
        process_parent_triggered_additions($file_content_ref, $add_if_missing_ref, $update_ref, $exclusions_ref);
    }

    # 2. Determine indentation based on existing dependency tags
    my $indentation = '    ';
    while ($$file_content_ref =~ m{^(\s*)<dependency\s+}gm) {
        $indentation = $1 if defined $1;
    }
}

# Enhance dependency detection to include JSP, XML, and properties files
sub detect_dependencies {
    my ($src_dirs, $file_types) = @_;
    my %dependencies;

    for my $dir (@$src_dirs) {
        find({
            wanted   => sub {
                return unless -f $_;
                my $file = $File::Find::name;

                if ($file =~ /\.(?:jsp|xml|properties)$/) {
                    log_info("Scanning file: $file") if $verbose;

                    open my $fh, '<', $file or do {
                        log_warning("Could not open file: $file: $!");
                        return;
                    };

                    while (my $line = <$fh>) {
                        # Example regex for detecting dependencies (adjust as needed)
                        if ($line =~ /<dependency\s+org="([^"]+)"\s+name="([^"]+)"/) {
                            my $dependency = "$1:$2";
                            $dependencies{$dependency}++;
                            log_info("Detected dependency: $dependency in $file");
                        }
                    }

                    close $fh;
                }
            },
            no_chdir => 1
        },
            $dir);
    }

    return \%dependencies;
}

# Add logging for dependency detection
sub log_info {
    my ($message) = @_;
    print BOLD CYAN "[INFO] $message" . RESET . "\n";
}

sub log_warning {
    my ($message) = @_;
    print BOLD YELLOW "[WARNING] $message" . RESET . "\n";
}

sub log_error {
    my ($message) = @_;
    print BOLD RED "[ERROR] $message" . RESET . "\n";
}

sub log_success {
    my ($message) = @_;
    print BOLD GREEN "[SUCCESS] $message" . RESET . "\n";
}

# Add logging for file existence checks
sub log_file_check {
    my ($file_path) = @_;
    if (-e $file_path) {
        log_info("File exists: $file_path");
    }
    else {
        log_warning("File does not exist: $file_path");
    }
}

sub report_missing_transitive_imports {
    my ($src_dirs_ref, $deps_file, $extra_lib_dir) = @_;

    my @src_dirs = ref($src_dirs_ref) eq 'ARRAY' ? @{$src_dirs_ref} : ($src_dirs_ref);
    my @local_dirs = grep {$_ !~ m{^\.\./}} @src_dirs;
    my @mgic_dirs = grep {$_ =~ m{^\.\./}} @src_dirs;

    return unless @mgic_dirs;

    log_info("--- AUDITING MISSING IMPORTS FROM REACHABLE MGIC CLASSES ---");

    # ------------------------------------------------------------------
    # Step 1: Collect Local References (src/, test/)
    # ------------------------------------------------------------------
    my %local_references;
    find({
        wanted   => sub {
            return unless -f $_ && $_ =~ /\.java$/i;
            open(my $fh, '<', $_) or return;
            while (my $line = <$fh>) {
                if ($line =~ /^\s*import\s+(?:static\s+)?([a-zA-Z0-9_\.\*]+)\s*;\s*$/) {
                    my $imp = $1;
                    $imp =~ s#\.\*$##;
                    $local_references{$imp} = 1;
                }
            }
            close($fh);
        },
        no_chdir => 1
    }, @local_dirs);

    # ------------------------------------------------------------------
    # Step 2: Parse mgic_dirs & Identify Reachable Classes + Their Imports
    # ------------------------------------------------------------------
    my %mgic_classes; # FQCN -> { pkg => '...', imports => [ ... ] }

    find({
        wanted   => sub {
            return unless -f $_ && $_ =~ /\.java$/i;
            open(my $fh, '<', $_) or return;
            my $pkg = '';
            my $class_name = '';
            my @file_imports;

            while (my $line = <$fh>) {
                if ($line =~ /^\s*package\s+([a-zA-Z0-9_\.]+)\s*;\s*$/) {
                    $pkg = $1;
                }
                elsif ($line =~ /\b(?:public\s+|protected\s+)?(?:class|interface|enum|record)\s+([a-zA-Z0-9_]+)/) {
                    $class_name = $1 unless $class_name;
                }
                if ($line =~ /^\s*import\s+(?:static\s+)?([a-zA-Z0-9_\.\*]+)\s*;\s*$/) {
                    my $imp = $1;
                    $imp =~ s#\.\*$##;
                    push @file_imports, $imp unless $imp =~ /^(java|javax)\./; # Ignore Java SE
                }
            }
            close($fh);

            if ($pkg && $class_name) {
                my $fqcn = "$pkg.$class_name";
                $mgic_classes{$fqcn} = {
                    pkg     => $pkg,
                    imports => \@file_imports
                };
            }
        },
        no_chdir => 1
    }, @mgic_dirs);

    my %reachable_mgic_imports; # Raw Import -> Triggering Mgic FQCN

    for my $fqcn (keys %mgic_classes) {
        my $info = $mgic_classes{$fqcn};
        my $pkg = $info->{pkg};

        my $is_reachable = 0;
        if (exists $local_references{$fqcn} || exists $local_references{$pkg}) {
            $is_reachable = 1;
        }
        else {
            for my $ref (keys %local_references) {
                if ($fqcn eq $ref || $fqcn =~ /^\Q$ref\E\./) {
                    $is_reachable = 1;
                    last;
                }
            }
        }

        if ($is_reachable) {
            for my $imp (@{$info->{imports}}) {
                $reachable_mgic_imports{$imp} ||= [];
                push @{$reachable_mgic_imports{$imp}}, $fqcn;
            }
        }
    }

    # ------------------------------------------------------------------
    # Step 3: Collect Provided Dependencies (.deps + Tomcat shared lib)
    # ------------------------------------------------------------------
    my %provided_modules;

    # A. Parse .deps file
    if (-e $deps_file) {
        open(my $dfh, '<', $deps_file);
        while (my $line = <$dfh>) {
            if ($line =~ /([^#\s]+)#([^;]+);/) {
                my $org = $1;
                my $name = $2;
                $provided_modules{$name} = 1;
                $provided_modules{"$org.$name"} = 1;
                $provided_modules{$org} = 1;
            }
        }
        close($dfh);
    }

    # B. Inspect extra container lib dir (e.g. C:/tomcat10/lib) ONLY if passed
    if (defined $extra_lib_dir && -d $extra_lib_dir) {
        log_info("Including container library directory in audit: $extra_lib_dir");

        # Standard container provided packages (Servlet API, IBM MQ, XML parsers, etc.)
        $provided_modules{'org.w3c.dom'} = 1;
        $provided_modules{'org.xml.sax'} = 1;

        find({
            wanted   => sub {
                return unless -f $_ && $_ =~ /\.jar$/i;
                my $jar_name = lc(basename($_));

                # Add heuristic mappings based on JAR names in Tomcat lib
                if ($jar_name =~ /mq|wmq/i) {
                    $provided_modules{'com.ibm.mq'} = 1;
                    $provided_modules{'com.ibm.msg'} = 1;
                }
                elsif ($jar_name =~ /servlet|jsp|el-api|catalina|tomcat/i) {
                    $provided_modules{'jakarta.servlet'} = 1;
                    $provided_modules{'org.apache.catalina'} = 1;
                }

                # Extract actual package names from jar entries using 'jar tf' or 'unzip -l'
                my $jar_path = $_;
                if (my @entries = `jar tf "$jar_path" 2>/dev/null`) {
                    for my $entry (@entries) {
                        if ($entry =~ /^([a-zA-Z0-9_\/]+)\/[^\/]+\.class$/) {
                            my $pkg = $1;
                            $pkg =~ s#/#.#g;
                            $provided_modules{$pkg} = 1;
                        }
                    }
                }
            },
            no_chdir => 1
        }, $extra_lib_dir);
    }

    # ------------------------------------------------------------------
    # Step 4: Cross-Reference & Report Missing Imports
    # ------------------------------------------------------------------
    my $missing_count = 0;

    for my $needed_import (sort keys %reachable_mgic_imports) {
        my $is_satisfied = 0;

        for my $prov (keys %provided_modules) {
            if ($needed_import =~ /^\Q$prov\E\b/i || $prov =~ /^\Q$needed_import\E\b/i) {
                $is_satisfied = 1;
                last;
            }
            my $clean_prov = $prov;
            $clean_prov =~ s/^(spring|commons|jakarta|javax|log4j|slf4j|jackson|hibernate|ignite)-//i;
            if ($needed_import =~ /\b\Q$clean_prov\E\b/i) {
                $is_satisfied = 1;
                last;
            }
        }

        # Ignore internal MGIC packages
        if ($needed_import =~ /^com\.mgic\./) {
            $is_satisfied = 1;
        }

        if (!$is_satisfied) {
            $missing_count++;
            my $triggers = join(', ', @{$reachable_mgic_imports{$needed_import}});
            log_warning("MISSING DEPENDENCY PROVIDER: '$needed_import'");
            log_info("   └─ Required by reachable class(es): $triggers");
        }
    }

    if ($missing_count == 0) {
        log_success("All imports required by reachable MGIC classes are satisfied!");
    }
    else {
        log_error("Found $missing_count missing dependency provider(s).");
    }
}

sub load_update_data {
    my $script_dir = $FindBin::RealBin;
    my $update_hash_file = "$script_dir/revision-updates.txt";
    my $hash = {};

    if (-e $update_hash_file) {
        open my $fh, '<', $update_hash_file or die "Cannot open $update_hash_file: $!";
        while (my $line = <$fh>) {
            $line =~ s/[\r\n]*//g;
            $line =~ s/\s*#.*$//; # remove comments

            next if $line =~ /^\s*$/ || $line =~ /^key,/; # Skip empty lines and header

            if ($line =~ /=>/) {
                # convert old dependency to new dependency format (e.g., "old => new")
                my ($old, $new) = split /\s*=>\s*/, $line;
                log_warning("missing key: $new") unless exists $hash->{$new};
                $hash->{$old} = $hash->{$new};
            }
            else {
                my @fields = split /[:,]\s*/, $line;
                my $key = shift @fields;
                for my $field (@fields) {
                    my ($attribute, $value) = split /=/, $field, 2;
                    log_warning("mismatched key: $key <=> $value") if $attribute eq 'name' && $value ne $key;
                    $hash->{$key}{$attribute} = $value;
                }
            }
        }
        close $fh;
    }
    else {
        die "Update hash file $update_hash_file not found!";
    }

    $hash;
}

sub load_mgic_src_mappings {
    my ($libdir) = @_;
    my @detected_dirs;
    my $script_dir = $FindBin::RealBin;
    my $mapping_file = "$script_dir/mgic-src-mappings.txt";

    return @detected_dirs unless -e $mapping_file;

    open my $fh, '<', $mapping_file or die "Cannot open $mapping_file: $!";
    my %seen_paths;

    while (my $line = <$fh>) {
        $line =~ s/[\r\n]*//g;
        $line =~ s/\s*#.*$//;     # Remove comments
        next if $line =~ /^\s*$/; # Skip empty lines

        # Split into JAR name and everything else (paths string)
        my ($jar_name, $paths_str) = split /\s+/, $line, 2;
        next unless defined $jar_name && defined $paths_str;

        # If the JAR exists in lib/ or WEB-INF/lib, include all associated src paths
        if (-e "$libdir/$jar_name") {
            my @src_paths = split /\s+/, $paths_str;
            for my $src_path (@src_paths) {
                if (-d $src_path && !$seen_paths{$src_path}) {
                    push @detected_dirs, $src_path;
                    $seen_paths{$src_path} = 1;
                }
            }
        }
    }
    close $fh;

    return @detected_dirs;
}

sub extract_base_packages {
    my ($src_dirs_ref) = @_;
    my @base_packages;

    my @src_dirs = ref($src_dirs_ref) eq 'ARRAY' ? @{$src_dirs_ref} : ($src_dirs_ref);
    @src_dirs = grep {-d $_} @src_dirs;

    log_info("Extracting base packages from \@ComponentScan and \@EnableJpaRepositories annotations...");

    # Scan for Spring configuration classes with relevant annotations
    find({
        wanted   => sub {
            return unless -f $_ && $_ =~ /\.java$/i;
            open(my $fh, '<', $_) or return;
            my $content = do {
                local $/;
                <$fh>
            };
            close($fh);

            # Look for @ComponentScan, @EnableJpaRepositories, @EntityScan, @EnableElasticsearchRepositories, or @SpringBootApplication annotations
            while ($content =~ /\@(?:ComponentScan|EnableJpaRepositories|EntityScan|EnableElasticsearchRepositories|SpringBootApplication)\s*(?:\([^)]*?\b(?:basePackages|scanBasePackages)\s*=\s*\{([^}]+)\})?/g) {
                if (defined $1) {
                    # Extract package names from basePackages array
                    my $packages_str = $1;
                    while ($packages_str =~ /"([a-zA-Z0-9_.]+)"/g) {
                        push @base_packages, $1;
                    }
                }
            }

            # Check for single basePackage string without explicit array syntax
            if ($content =~ /\@(?:ComponentScan|EnableJpaRepositories|EntityScan|EnableElasticsearchRepositories|SpringBootApplication)\s*\(\s*(?:basePackages|scanBasePackages)\s*=\s*"([^"]+)"\s*\)/) {
                push @base_packages, $1;
            }

            # Also extract packages of classes referenced in @Import or @ContextConfiguration
            while ($content =~ /\@(?:Import|ContextConfiguration)\s*\(\s*(?:classes\s*=\s*)?\{?([^}]+)\}?\s*\)/g) {
                my $classes_str = $1;
                while ($classes_str =~ /([a-zA-Z0-9_.]+)\.class/g) {
                    my $full_ref = $1;
                    if ($full_ref =~ /^(.*)\.[A-Z][a-zA-Z0-9_]*$/) {
                        push @base_packages, $1;
                    }
                }
            }
        },
        no_chdir => 1
    }, @src_dirs);

    # Remove duplicates and sort
    my %seen;
    @base_packages = grep {!$seen{$_}++} @base_packages;

    if (@base_packages) {
        log_info("Found base packages: " . join(', ', @base_packages));
        return @base_packages;
    }
    else {
        log_warning("No \@ComponentScan or \@EnableJpaRepositories annotations found. Using all source directories.");
        return ();
    }
}

sub package_matches_base_packages {
    my ($package, $base_packages_ref) = @_;

    return 1 if !@$base_packages_ref; # If no base packages specified, match all

    for my $base_pkg (@$base_packages_ref) {
        if ($package eq $base_pkg || $package =~ /^\Q$base_pkg\E\./) {
            return 1;
        }
    }
    return 0;
}

sub check_and_inject_smtp_dependencies {
    my ($file_content_ref, $changes_made_ref, $src_dirs_ref, $update_ref) = @_;

    my $has_smtp = 0;
    my @search_dirs = grep {-d $_} @$src_dirs_ref;
    push @search_dirs, 'war' if -d 'war';

    # 1. Scan for log4j2 XML files containing an <SMTP> element (using basename)
    find({
        wanted   => sub {
            my $filename = basename($_);
            return unless -f $_ && $filename =~ /^log4j2(?:-.*)?\.xml$/i;

            open(my $fh, '<', $_) or return;
            while (my $line = <$fh>) {
                if ($line =~ /<SMTP\b/i) {
                    $has_smtp = 1;
                    last;
                }
            }
            close($fh);
        },
        no_chdir => 1
    }, @search_dirs);

    return unless $has_smtp;

    log_info("Detected <SMTP> appender in log4j2 configuration.");

    my @required_deps = ('angus-mail', 'log4j-jakarta-smtp');

    # 2. ALWAYS set keep = 1 if <SMTP> exists (whether already in ivy.xml or newly injected)
    for my $dep (@required_deps) {
        $update_ref->{$dep} ||= {};
        $update_ref->{$dep}->{keep} = 1;
    }

    # 3. Inject any missing dependencies directly into $file_content
    for my $dep_name (@required_deps) {
        if ($$file_content_ref !~ /<dependency\b[^>]*?\bname="\Q$dep_name\E"/s) {
            my $entry = $update_ref->{$dep_name} || {};
            my $org = $entry->{org} || ($dep_name eq 'angus-mail' ? 'org.eclipse.angus' : 'org.apache.logging.log4j');
            my $rev = $entry->{rev} || ($dep_name eq 'angus-mail' ? '2.0.3' : '2.26.1');
            my $conf = $entry->{conf} || 'runtime->default';

            # Match indentation of existing dependency tags
            my $indent = '        ';
            if ($$file_content_ref =~ m{^(\s*)<dependency\s+}m) {
                $indent = $1;
            }

            my $new_dep_xml = qq!${indent}<dependency org="$org" name="$dep_name" rev="$rev" conf="$conf" />\n!;

            # Insert right before </dependencies>
            if ($$file_content_ref =~ s{(^[ \t]*</dependencies>)}{${new_dep_xml}${1}}m) {
                log_success("Added missing SMTP dependency: $dep_name ($rev)");
                $$changes_made_ref++;
            }
        }
    }
}

__END__
