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
    print "  audit, --audit-deps Audit dependencies and remove unused/redundant ones\n";
    exit;
}

# Internal script metadata fields that should NOT be injected as XML attributes
my %internal_metadata_keys = map {$_ => 1} qw(keep snyk keep_both replace_from replace_to);

sub main {
    my %unused_deps_to_drop;
    my $ivy_file = "ivy.xml";
    my $output_file = "ivy.xml.new";
    my $deps_file = ".deps";

    load_jar_class_index();

    my $libdir = (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';
    my @src_dirs = ('src', 'test', 'deploy');

    log_error("Both mgic-entity-custom.jar and mgic-entity-master.jar exist. Please remove one of them.")
        if -e "$libdir/mgic-entity-custom.jar" && -e "$libdir/mgic-entity-master.jar";

    if ($audit_deps) {
        log_file_check($libdir);
        my @external_sources = load_mgic_src_mappings($libdir);
        push @src_dirs, @external_sources;
    }

    # Extract base packages from Spring annotations
    my @base_packages = extract_base_packages(\@src_dirs);

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

    my $dependency_conflicts = {
        'log4j-slf4j2-impl' => [
            { org => 'org.apache.logging.log4j', name => 'log4j-to-slf4j' },
            { org => 'ch.qos.logback', name => "logback-classic" },
            { org => 'ch.qos.logback', name => "logback-core" },
        ],
    };

    my $api_provider_map = {
        'angus-mail' => [ 'jakarta.mail' ],
    };

    my $exclusions = {};
    my @packages;
    my %internal_metadata_keys = map {$_ => 1} qw(keep snyk keep_both replace_from replace_to);

    # 1. READ ORIGINAL IVY.XML
    my $file_content;
    open(my $in, "<", $ivy_file) or die "Error: could not open '$ivy_file': $!";
    {
        local $/;
        $file_content = <$in>;
    }
    close($in);

    my $changes_made = 0;
    check_and_inject_smtp_dependencies(\$file_content, \$changes_made, \@src_dirs, $update);

    my %present_deps;
    while ($file_content =~ /<dependency\s+(?:[^>]*?\s+)?name="([^"]+)"/g) {
        $present_deps{$1} = 1;
    }

    my $remove_redundant_transitives_versioned = {};

    # ------------------------------------------------------------------
    # PRE-PASS AUDIT: DETECT UNUSED BEFORE STAGE 1 REPLACEMENT
    # ------------------------------------------------------------------
    if ($audit_deps) {
        my $clean_content = $file_content;
        $clean_content =~ s{
            (<dependency\s+(?:[^"'>]|"[^"]*"|'[^']*')+?)
            (?:\s*/>|\s*>\s*(?:<exclude\s+[^/>]+/>\s*)*\s*</dependency>)
        }{$1 />}gsx;

        my $clean_file = "$ivy_file-clean";
        open(my $clean_fh, ">", $clean_file) or die "Error: could not write clean file '$clean_file': $!";
        print $clean_fh $clean_content;
        close $clean_fh;

        update_deps_file($clean_file, $deps_file, $changes_made > 0);
        $remove_redundant_transitives_versioned = generate_transitive_map_from_deps($deps_file);

        my $unused_ref = find_unused_dependencies(
            $file_content, \%used_deps_to_keep, $update,
            \@remove_packages, \@packages, $remove_redundant_transitives_versioned,
            $libdir, $api_provider_map, $add_if_missing
        );
        %unused_deps_to_drop = %$unused_ref;
    }

    # ------------------------------------------------------------------
    # STAGE 1: IN-PLACE UPDATES & REMOVALS
    # ------------------------------------------------------------------
    $file_content =~ s{
    ^ ([ \t]*)
    (?: <!-- \s* (SNYK-[^>]+?) \s* --> \s* \r?\n [ \t]* )?
    (
        <dependency \s+
        (?: [^>] | "[^"]*" )*?
        (?:
            \s*/>
            |
            \s*>
            (?:
                (?!</dependency>)
                (?!<dependency \s+)
                .
            )*?
            </dependency>
        )
    )
    [ \t]* \r?\n?
}{
        my $leading_whitespace = defined $1 ? $1 : '';
        my $snyk_comment = $2;
        my $dependency_block = $3;

        my ($dep_org, $dep_name, $current_rev);
        $dep_org = $1 if $dependency_block =~ /\borg="([^"]*)"/;
        $dep_name = $1 if $dependency_block =~ /\bname="([^"]*)"/;
        $current_rev = $1 if $dependency_block =~ /\brev="([^"]*)"/;

        my $replacement_str = "";

        unless (defined $dep_org and defined $dep_name) {
            $replacement_str = $leading_whitespace . ($snyk_comment ? "<!-- $snyk_comment -->\n$leading_whitespace" : "") . $dependency_block . "\n";
        }
        elsif ($update->{$dep_name} && $update->{$dep_name}->{keep_both} && $update->{$dep_name}->{replace_to} && $present_deps{$update->{$dep_name}->{replace_to}}) {
            log_warning("Keep $dep_name (both $dep_name and " . $update->{$dep_name}->{replace_to} . " present in ivy.xml)");
            push @packages, $dep_name;
            $replacement_str = $leading_whitespace . ($snyk_comment ? "<!-- $snyk_comment -->\n$leading_whitespace" : "") . $dependency_block . "\n";
        }
        elsif (grep {$dep_name =~ $_} @remove_packages && !($update->{$dep_name} && $update->{$dep_name}->{keep})) {
            log_info("Remove $dep_name");
            $changes_made += 1;
            $replacement_str = ""; # Deletes Snyk comment + dependency tag + newline
        }
        elsif ($unused_deps_to_drop{$dep_name} && !($update->{$dep_name} && $update->{$dep_name}->{keep})) {
            log_info("Remove unused dependency $dep_name (no active imports in src/)");
            $changes_made += 1;
            $replacement_str = ""; # Deletes Snyk comment + dependency tag + newline
        }
        elsif (grep {$dep_name eq $_} @packages) {
            log_warning("Remove duplicate dependency $dep_name");
            $changes_made += 1;
            $replacement_str = ""; # Deletes Snyk comment + dependency tag + newline
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
                        next if $internal_metadata_keys{$key};
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

            $modified_dependency_block =~ s{\s*<exclude\s+[^/>]+/>}{}g;
            $modified_dependency_block =~ s{>\s*</dependency>}{ />};

            my $comment_prefix = $snyk_comment ? "<!-- $snyk_comment -->\n$leading_whitespace" : "";
            $replacement_str = $leading_whitespace . $comment_prefix . $modified_dependency_block . "\n";
        }

        $replacement_str;
    }mxseg;

    # Compute surviving direct dependencies
    my %surviving_deps;
    while ($file_content =~ /<dependency\s+(?:[^>]*?\s+)?name="([^"]+)"/g) {
        $surviving_deps{$1} = 1;
    }

    if ($audit_deps) {
        promote_snyk_transitives(
            $remove_redundant_transitives_versioned,
            \%surviving_deps,
            $update,
            \$file_content,
            \$changes_made
        );

        for my $dep_name (keys %surviving_deps) {
            my $current_rev;
            if ($file_content =~ /<dependency\b[^>]*?\bname="\Q$dep_name\E"[^>]*?\brev="([^"]+)"/s) {
                $current_rev = $1;
            }
            if (defined $current_rev && should_remove_transitive($dep_name, $current_rev, $update, \%used_deps_to_keep, \%surviving_deps, $remove_redundant_transitives_versioned)) {
                if (remove_dependency_tag(\$file_content, $dep_name)) {
                    delete $surviving_deps{$dep_name};
                    $changes_made += 1;
                }
            }
        }
    }

    my %global_excludes = extract_global_exclusions($file_content);

    enforce_dependency_conflicts(
        $dependency_conflicts,
        $remove_redundant_transitives_versioned,
        \%surviving_deps,
        \$file_content,
        $exclusions,
        \$changes_made);

    enforce_snyk_comments(\$file_content, $update, \$changes_made);

    if ($audit_deps) {
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
    }

    # ------------------------------------------------------------------
    # STAGE 4: APPEND NEW EXCLUSIONS TO $file_content
    # ------------------------------------------------------------------
    for my $dep_name (keys %$exclusions) {
        my $dep_exclusions = $exclusions->{$dep_name};
        next unless defined $dep_exclusions && @$dep_exclusions > 0;

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
            my @new_rules;

            for my $rule (@$dep_exclusions) {
                my $mod = $rule->{module};
                my $group = $rule->{org};

                my $already_present = 0;

                if (defined $group && defined $mod) {
                    if ($existing_inner =~ /<exclude\s+[^>]*\borg="\Q$group\E"[^>]*\b(?:module|name)="\Q$mod\E"/i ||
                        $existing_inner =~ /<exclude\s+[^>]*\b(?:module|name)="\Q$mod\E"[^>]*\borg="\Q$group\E"/i) {
                        $already_present = 1;
                    }
                }
                elsif (defined $group && !defined $mod) {
                    if ($existing_inner =~ /<exclude\s+[^>]*\borg="\Q$group\E"(?![^>]*\b(?:module|name)=)/i) {
                        $already_present = 1;
                    }
                    else {
                        $existing_inner =~ s{^[ \t]*<exclude\s+[^>]*\borg="\Q$group\E"[^>]*\/>[ \t]*\r?\n?}{}gm;
                    }
                }
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

    open(my $out, ">", $output_file) or die "Error: could not open '$output_file': $!";
    print $out $file_content;
    close $out;
    log_success("Successfully updated $output_file");

    if ($audit_deps) {
        report_missing_transitive_imports(\@src_dirs, $deps_file, 'C:/Tomcat10/lib');
    }
}

main();
exit 0;

sub remove_dependency_tag {
    my ($file_content_ref, $dep_name) = @_;

    my $count = $$file_content_ref =~ s{
        ^ [ \t]*
        (?: <!-- \s* SNYK-[^>]+? \s* --> \s* \r?\n [ \t]* )?
        <dependency \b
        (?: [^>"'] | "[^"]*" | '[^']*' )*?
        \bname="\Q$dep_name\E"
        (?: [^>"'] | "[^"]*" | '[^']*' )*?
        (?:
            />
            |
            >\s*.*?\s*</dependency>
        )
        [ \t]* \r?\n?
    }{}gmsx;

    return $count;
}

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
    my @extracted_fqcns;

    $JAR_CACHE{$jar_name} = {
        classes  => \%classes,
        packages => \%packages,
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
                $packages{$1} = 1;
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
    my ($dep_name, $update_ref, $used_deps_ref, $libdir, $api_provider_map) = @_;
    return 0 unless defined $dep_name && defined $used_deps_ref && %$used_deps_ref;

    return 1 if exists $used_deps_ref->{$dep_name};

    if (exists $api_provider_map->{$dep_name}) {
        for my $api_pkg (@{$api_provider_map->{$dep_name}}) {
            for my $ref_pkg (keys %$used_deps_ref) {
                return 1 if $ref_pkg =~ /^\Q$api_pkg\E\b/i;
            }
        }
    }

    my $entry = $update_ref->{$dep_name} if $update_ref;
    my $name = ($entry && $entry->{name}) ? $entry->{name} : $dep_name;
    my $org = $entry->{org} if $entry;

    # 1. CHECK INDEXED CLASS DATA (From jar-class-index.txt or lib/ JARs)
    $libdir ||= (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';
    my @matching_jars = find_jars_for_dependency($dep_name, $update_ref, $libdir);

    my %jars_to_check;
    for my $j (@matching_jars) {
        $jars_to_check{lc(basename($j))} = $j;
    }

    for my $known_jar (keys %KNOWN_JARS) {
        if ($known_jar =~ /^\Q$dep_name\E(?:-[0-9].*|\.jar)$/i ||
            $known_jar =~ /^\Q$name\E(?:-[0-9].*|\.jar)$/i ||
            ($org && $known_jar =~ /^\Q$org\E[.-]\Q$name\E(?:-[0-9].*|\.jar)$/i)) {
            $jars_to_check{$known_jar} ||= undef;
        }
    }

    if (%jars_to_check) {
        for my $jar_key (keys %jars_to_check) {
            my $jar_data = $jars_to_check{$jar_key}
                ? extract_jar_classes_and_packages($jars_to_check{$jar_key})
                : $JAR_CACHE{$jar_key};

            next unless $jar_data;

            my $classes_ref = $jar_data->{classes};
            my $packages_ref = $jar_data->{packages};

            for my $ref_pkg (keys %$used_deps_ref) {
                if ((defined $classes_ref && exists $classes_ref->{$ref_pkg}) ||
                    (defined $packages_ref && exists $packages_ref->{$ref_pkg})) {
                    return 1;
                }
            }
        }
        # Index or JAR exists and contains zero active imports
        return 0;
    }

    # 2. STRICT FALLBACK PATTERNS (Only if JAR is not in index and not in lib/)
    if (defined $org) {
        my $clean_name = $name;
        $clean_name =~ s/^(spring|commons|jakarta|javax|log4j|slf4j|jackson|hibernate|tika)-//i;

        my %candidate_pkgs;
        if ($clean_name ne '') {
            my $base_org = $org;
            $base_org =~ s/\.[^\.]+$//;                   # Strip trailing group level like .core -> com.fasterxml.jackson
            $candidate_pkgs{"$base_org.$clean_name"} = 1; # com.fasterxml.jackson.databind
        }

        for my $ref_pkg (keys %$used_deps_ref) {
            for my $cand (keys %candidate_pkgs) {
                if ($ref_pkg eq $cand || $ref_pkg =~ /^\Q$cand\E\./i) {
                    return 1;
                }
            }
        }
    }

    return 0;
}

sub is_dep_or_transitive_used {
    my ($dep_name, $update_ref, $used_deps_ref, $libdir, $api_provider_map, $transitive_map_ref) = @_;

    # 1. Check if the parent dependency itself is directly used in source code
    return 1 if is_dep_used($dep_name, $update_ref, $used_deps_ref, $libdir, $api_provider_map);

    # 2. Check if any transitive child brought in by this parent provides classes used in source code
    if ($transitive_map_ref && exists $transitive_map_ref->{$dep_name}) {
        for my $child_dep (keys %{$transitive_map_ref->{$dep_name}}) {
            if (is_dep_used($child_dep, $update_ref, $used_deps_ref, $libdir, $api_provider_map)) {
                log_info("Keeping direct dependency '$dep_name' because its transitive child '$child_dep' is in use.");
                return 1;
            }
        }
    }

    return 0;
}

sub is_provided_by_kept_deps {
    my ($target_dep, $kept_deps_ref, $transitive_map_ref) = @_;

    return 1 if exists $kept_deps_ref->{$target_dep};

    if ($transitive_map_ref) {
        for my $kept_parent (keys %$kept_deps_ref) {
            if (exists $transitive_map_ref->{$kept_parent} &&
                exists $transitive_map_ref->{$kept_parent}{$target_dep}) {
                return 1;
            }
        }
    }

    return 0;
}

sub find_unused_dependencies {
    my ($file_content, $used_deps_ref, $update_ref, $remove_packages_ref, $packages_ref, $transitive_map_ref, $libdir, $api_provider_map, $add_if_missing_ref) = @_;
    my %unused_deps;

    log_info("Analyzing declared dependencies against actual usage...");

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

    # PASS 1: Identify all directly used or explicitly kept direct dependencies
    for my $dep_name (keys %all_declared_deps) {
        if ($update_ref && exists $update_ref->{$dep_name} && $update_ref->{$dep_name}->{keep_both} && $update_ref->{$dep_name}->{replace_to} && $all_declared_deps{$update_ref->{$dep_name}->{replace_to}}) {
            $kept_deps{$dep_name} = 1;
            next;
        }
        if ($update_ref && exists $update_ref->{$dep_name} && $update_ref->{$dep_name}->{keep}) {
            $kept_deps{$dep_name} = 1;
            next;
        }
        if ($remove_packages_ref && grep {$dep_name =~ $_} @$remove_packages_ref) {
            next;
        }

        if (is_dep_used($dep_name, $update_ref, $used_deps_ref, $libdir, $api_provider_map)) {
            $kept_deps{$dep_name} = 1;
        }
    }

    # PASS 2: Evaluate unused dependencies and promote children ONLY if not provided elsewhere
    for my $dep_name (keys %all_declared_deps) {
        next if $kept_deps{$dep_name};
        next if ($remove_packages_ref && grep {$dep_name =~ $_} @$remove_packages_ref);

        if ($transitive_map_ref && exists $transitive_map_ref->{$dep_name}) {
            for my $child_dep (keys %{$transitive_map_ref->{$dep_name}}) {
                if (is_dep_used($child_dep, $update_ref, $used_deps_ref, $libdir, $api_provider_map)) {
                    # Promote ONLY if no surviving parent dependency provides it
                    unless (is_provided_by_kept_deps($child_dep, \%kept_deps, $transitive_map_ref)) {
                        log_warning("Parent '$dep_name' is unused, but required child '$child_dep' is not provided by any kept dependency; promoting '$child_dep' to direct.");

                        if ($add_if_missing_ref && $update_ref && exists $update_ref->{$child_dep}) {
                            $add_if_missing_ref->{$dep_name} ||= [];
                            push @{$add_if_missing_ref->{$dep_name}}, $child_dep
                                unless grep {$_ eq $child_dep} @{$add_if_missing_ref->{$dep_name}};

                            $kept_deps{$child_dep} = 1;
                        }
                    }
                }
            }
        }

        $unused_deps{$dep_name} = 1;
    }

    if (keys %unused_deps) {
        log_warning("Found " . scalar(keys %unused_deps) . " unused dependencies: " . join(", ", sort keys %unused_deps));
    }

    return \%unused_deps;
}

sub should_remove_transitive {
    my ($dep_name, $current_rev, $update_ref, $used_deps_ref, $surviving_deps_ref, $remove_redundant_transitives_versioned) = @_;

    return 0 unless defined $current_rev;
    return 0 unless defined $remove_redundant_transitives_versioned
        && ref($remove_redundant_transitives_versioned) eq 'HASH';

    # Guardrails
    if ($update_ref && exists $update_ref->{$dep_name} && $update_ref->{$dep_name}->{keep}) {
        return 0;
    }

    my $target_rev = $update_ref->{$dep_name}->{rev} if defined $update_ref && exists $update_ref->{$dep_name};
    my $effective_rev = $target_rev || $current_rev;

    my $max_transitive_rev;

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

            if ($content =~ /^Dependency tree/) {
                push @filtered_lines, $content . "\n";
                next;
            }

            if ($content =~ /^(.*?)(?:[\+\\]\-)(.*)$/) {
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

    if (@mgic_dirs) {
        log_info("Scanning external mgic directories (" . join(', ', @mgic_dirs) . ") for reachability...") if $verbose;

        my %mgic_class_imports;

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

    for my $class (keys %class_to_deps) {
        for my $import (keys %{$class_to_deps{$class}}) {
            if ($import =~ /^(?:java|javax)\./) {
                next;
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

    my %max_direct_versions;

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

    if (defined $file_content) {
        while ($file_content =~ /<dependency\s+([^>]+)>/g) {
            my $attrs = $1;
            my $name;
            my $rev;
            $name = $1 if $attrs =~ /\bname="([^"]+)"/;
            $rev = $1 if $attrs =~ /\brev="([^"]+)"/;

            if (defined $name && defined $rev) {
                if (!exists $max_direct_versions{$name} ||
                    version_compare($rev, $max_direct_versions{$name}) > 0) {
                    $max_direct_versions{$name} = $rev;
                }
            }
        }
    }

    open(my $fh, '<', $deps_file) or return;

    my @stack;
    my %pending_exclusions;

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

                    if (exists $always_exclude_orgs{$org}) {
                        $is_mismatched = 1;
                    }
                    elsif (exists $update_ref->{$name} && exists $surviving_deps_ref->{$name}) {
                        my $update_rev = $update_ref->{$name}->{rev};
                        my $parent_update_rev = $update_ref->{$root_parent}->{rev} if exists $update_ref->{$root_parent};
                        if (defined $update_rev && $update_rev ne $rev) {
                            my $cmp = version_compare($update_rev, $rev);
                            if ($cmp < 0) {
                                if (!defined $parent_update_rev || $parent_update_rev ne $update_rev) {
                                    $is_mismatched = 1;
                                }
                            }
                        }
                    }
                    elsif (exists $surviving_deps_ref->{$name}) {
                        my $max_direct = $max_direct_versions{$name};
                        if (defined $max_direct) {
                            my $cmp = version_compare($max_direct, $rev);
                            if ($cmp < 0) {
                                $is_mismatched = 1;
                            }
                        }
                        else {
                            $is_mismatched = 1;
                        }
                    }

                    if ($is_mismatched) {
                        if ($name ne $root_parent) {
                            $pending_exclusions{$root_parent}{$org}{$name} = $rev;
                        }
                    }
                }
            }
        }
    }
    close($fh);

    for my $root_parent (keys %pending_exclusions) {
        $exclusions_ref->{$root_parent} ||= [];

        for my $org (keys %{$pending_exclusions{$root_parent}}) {
            my $modules_ref = $pending_exclusions{$root_parent}{$org};
            my @modules = keys %$modules_ref;

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

    while ($xml_content =~ /<exclude\s+([^>]+)\/>/g) {
        my $attrs = $1;
        my $org = $1 if $attrs =~ /\borg="([^"]+)"/;
        my $module = $1 if $attrs =~ /\bmodule="([^"]+)"/;
        my $name = $1 if $attrs =~ /\bname="([^"]+)"/;

        my $target = $module || $name;

        if (defined $target) {
            $global_excludes{$target} = 1;
        }
        if (defined $org && !defined $target) {
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

    my $base_indent = '        ';
    if ($$file_content_ref =~ m{^(\s*)<dependency\s+}m) {
        $base_indent = $1;
    }

    for my $trigger_pkg_name (keys %$add_if_missing_ref) {
        my $trigger_deps = $add_if_missing_ref->{$trigger_pkg_name};
        next unless defined $trigger_deps && @$trigger_deps;

        my $trigger_dep_block_regex = qr{
            (
                \s+
                <dependency\s+
                (?:[^>]|"[^"]*")*?
                \bname="\Q$trigger_pkg_name\E"
                (?:[^>]|"[^"]*")*?
                (?:
                    \s*/>
                    |
                    >\s*.*?\s*</dependency>
                )
            )
        }xms;

        my $match_end_offset;
        my $trigger_indent = $base_indent;

        if ($$file_content_ref =~ m{(.*?)($trigger_dep_block_regex)}s) {
            # Parent tag exists: insert right after it
            $match_end_offset = length($1) + length($2);
            my $matched_trigger_block = $2;
            if ($matched_trigger_block =~ m{^(\s*)<dependency}) {
                $trigger_indent = $1;
            }
        }
        elsif ($$file_content_ref =~ m{(.*?)([ \t]*<exclude\b)}s) {
            # Fallback 1: Insert BEFORE the first <exclude> tag
            $match_end_offset = length($1);
        }
        elsif ($$file_content_ref =~ m{(.*?)([ \t]*</dependencies>)}s) {
            # Fallback 2: Insert before </dependencies> if no <exclude> tags exist
            $match_end_offset = length($1);
        }

        if (defined $match_end_offset) {
            my $xml_to_insert = '';

            for my $pkg (@$trigger_deps) {
                my $dep = $update_ref->{$pkg};
                next unless defined $dep;

                my $org = $dep->{org};
                my $name = $dep->{name} || $pkg;

                if ($$file_content_ref !~ m{<dependency\b[^>]*?\bname="\Q$name\E"}s) {
                    my $dep_exclusions = $exclusions_ref->{$name} || $exclusions_ref->{"$org,$name"};
                    my $exclusions_xml = generate_exclusion_xml($dep_exclusions, $trigger_indent . '    ');

                    my $conf = $dep->{conf} || 'runtime->default';
                    my $new_dep_xml;
                    if (length $exclusions_xml > 0) {
                        $new_dep_xml = qq!\n${trigger_indent}<dependency org="$org" name="$name" rev="$dep->{rev}" conf="$conf">$exclusions_xml\n${trigger_indent}</dependency>!;
                    }
                    else {
                        $new_dep_xml = qq!\n${trigger_indent}<dependency org="$org" name="$name" rev="$dep->{rev}" conf="$conf" />!;
                    }

                    log_info("Add missing dependency: $name ($dep->{rev})");
                    $xml_to_insert .= $new_dep_xml;
                }
            }

            if (length $xml_to_insert > 0) {
                push @insertions_to_apply, { pos => $match_end_offset, text => $xml_to_insert };
            }
        }
    }

    @insertions_to_apply = sort {$b->{pos} <=> $a->{pos}} @insertions_to_apply;

    foreach my $insertion (@insertions_to_apply) {
        substr($$file_content_ref, $insertion->{pos}, 0) = $insertion->{text};
    }
}

sub insert_missing_dependencies {
    my ($file_content_ref, $add_if_missing_ref, $update_ref, $exclusions_ref) = @_;

    if (defined $add_if_missing_ref && %$add_if_missing_ref) {
        process_parent_triggered_additions($file_content_ref, $add_if_missing_ref, $update_ref, $exclusions_ref);
    }

    my $indentation = '    ';
    while ($$file_content_ref =~ m{^(\s*)<dependency\s+}gm) {
        $indentation = $1 if defined $1;
    }
}

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

    my %mgic_classes;

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
                    push @file_imports, $imp unless $imp =~ /^(java|javax)\./;
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

    my %reachable_mgic_imports;

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

    my %provided_modules;

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

    if (defined $extra_lib_dir && -d $extra_lib_dir) {
        log_info("Including container library directory in audit: $extra_lib_dir");

        $provided_modules{'org.w3c.dom'} = 1;
        $provided_modules{'org.xml.sax'} = 1;

        find({
            wanted   => sub {
                return unless -f $_ && $_ =~ /\.jar$/i;
                my $jar_name = lc(basename($_));

                if ($jar_name =~ /mq|wmq/i) {
                    $provided_modules{'com.ibm.mq'} = 1;
                    $provided_modules{'com.ibm.msg'} = 1;
                }
                elsif ($jar_name =~ /servlet|jsp|el-api|catalina|tomcat/i) {
                    $provided_modules{'jakarta.servlet'} = 1;
                    $provided_modules{'org.apache.catalina'} = 1;
                }

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
            $line =~ s/\s*#.*$//;

            next if $line =~ /^\s*$/ || $line =~ /^key,/;

            if ($line =~ /=>/) {
                my ($old, $target_str) = split /\s*=>\s*/, $line;
                my %opts;
                my @parts = split /\s*,\s*/, $target_str;
                my $new = shift @parts;

                for my $part (@parts) {
                    my ($k, $v) = split /\s*=\s*/, $part, 2;
                    $opts{$k} = $v if defined $k && defined $v;
                }

                if (exists $hash->{$new}) {
                    $hash->{$old} = { %{$hash->{$new}} };
                    $hash->{$old}->{replace_from} = $old;
                    $hash->{$old}->{replace_to} = $new;
                    $hash->{$old}->{keep_both} = ($opts{keep} // 0);
                }
                else {
                    log_warning("missing key: $new");
                }
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
        $line =~ s/\s*#.*$//;
        next if $line =~ /^\s*$/;

        my ($jar_name, $paths_str) = split /\s+/, $line, 2;
        next unless defined $jar_name && defined $paths_str;

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

    find({
        wanted   => sub {
            return unless -f $_ && $_ =~ /\.java$/i;
            open(my $fh, '<', $_) or return;
            my $content = do {
                local $/;
                <$fh>
            };
            close($fh);

            while ($content =~ /\@(?:ComponentScan|EnableJpaRepositories|EntityScan|EnableElasticsearchRepositories|SpringBootApplication)\s*(?:\([^)]*?\b(?:basePackages|scanBasePackages)\s*=\s*\{([^}]+)\})?/g) {
                if (defined $1) {
                    my $packages_str = $1;
                    while ($packages_str =~ /"([a-zA-Z0-9_.]+)"/g) {
                        push @base_packages, $1;
                    }
                }
            }

            if ($content =~ /\@(?:ComponentScan|EnableJpaRepositories|EntityScan|EnableElasticsearchRepositories|SpringBootApplication)\s*\(\s*(?:basePackages|scanBasePackages)\s*=\s*"([^"]+)"\s*\)/) {
                push @base_packages, $1;
            }

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

    return 1 if !@$base_packages_ref;

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

    for my $dep (@required_deps) {
        $update_ref->{$dep} ||= {};
        $update_ref->{$dep}->{keep} = 1;
    }

    for my $dep_name (@required_deps) {
        if ($$file_content_ref !~ /<dependency\b[^>]*?\bname="\Q$dep_name\E"/s) {
            my $entry = $update_ref->{$dep_name} || {};
            my $org = $entry->{org} || ($dep_name eq 'angus-mail' ? 'org.eclipse.angus' : 'org.apache.logging.log4j');
            my $rev = $entry->{rev} || ($dep_name eq 'angus-mail' ? '2.0.3' : '2.26.1');
            my $conf = $entry->{conf} || 'runtime->default';

            my $indent = '        ';
            if ($$file_content_ref =~ m{^(\s*)<dependency\s+}m) {
                $indent = $1;
            }

            my $new_dep_xml = qq!${indent}<dependency org="$org" name="$dep_name" rev="$rev" conf="$conf" />\n!;

            if ($$file_content_ref =~ s{(^[ \t]*</dependencies>)}{${new_dep_xml}${1}}m) {
                log_success("Added missing SMTP dependency: $dep_name ($rev)");
                $$changes_made_ref++;
            }
        }
    }
}

sub enforce_dependency_conflicts {
    my ($conflicts_ref, $transitive_map_ref, $surviving_deps_ref, $file_content_ref, $exclusions_ref, $changes_made_ref) = @_;

    return unless defined $conflicts_ref && %$conflicts_ref;

    for my $primary_mod (keys %$conflicts_ref) {

        my $is_primary_present = exists $surviving_deps_ref->{$primary_mod};
        unless ($is_primary_present) {
            for my $parent (keys %$transitive_map_ref) {
                if (exists $transitive_map_ref->{$parent}{$primary_mod}) {
                    $is_primary_present = 1;
                    last;
                }
            }
        }

        next unless $is_primary_present;

        for my $rule (@{$conflicts_ref->{$primary_mod}}) {
            my $target_org = $rule->{org};
            my $target_module = $rule->{name};

            if (exists $surviving_deps_ref->{$target_module} || $$file_content_ref =~ /<dependency\b[^>]*?\bname="\Q$target_module\E"/s) {
                if (remove_dependency_tag($file_content_ref, $target_module)) {
                    delete $surviving_deps_ref->{$target_module};
                    log_warning("Conflict resolved: Removed direct dependency '$target_module' because '$primary_mod' is present.");
                    $$changes_made_ref++;
                }
            }

            for my $parent_dep (keys %$transitive_map_ref) {
                if (exists $transitive_map_ref->{$parent_dep}{$target_module}) {
                    next unless exists $surviving_deps_ref->{$parent_dep};

                    $exclusions_ref->{$parent_dep} ||= [];

                    my $already_exists = 0;
                    for my $ex (@{$exclusions_ref->{$parent_dep}}) {
                        if (($ex->{org} // '') eq $target_org && ($ex->{module} // '') eq $target_module) {
                            $already_exists = 1;
                            last;
                        }
                    }

                    unless ($already_exists) {
                        push @{$exclusions_ref->{$parent_dep}}, {
                            org  => $target_org,
                            name => $target_module
                        };
                        log_warning("Conflict safety: Queued inline <exclude org=\"$target_org\" name=\"$target_module\"/> under parent '$parent_dep'");
                        $$changes_made_ref++;
                    }
                }
            }
        }
    }
}

sub promote_snyk_transitives {
    my ($transitive_map_ref, $surviving_deps_ref, $update_ref, $file_content_ref, $changes_made_ref) = @_;

    return unless defined $transitive_map_ref && %$transitive_map_ref;
    return unless defined $update_ref && %$update_ref;

    my %transitive_parents;
    my %max_transitive_revs;

    for my $parent (keys %$transitive_map_ref) {
        next unless exists $surviving_deps_ref->{$parent};
        for my $child (keys %{$transitive_map_ref->{$parent}}) {
            push @{$transitive_parents{$child}}, $parent;

            my $child_trans_rev = $transitive_map_ref->{$parent}{$child};
            if (defined $child_trans_rev) {
                if (!exists $max_transitive_revs{$child} ||
                    version_compare($child_trans_rev, $max_transitive_revs{$child}) > 0) {
                    $max_transitive_revs{$child} = $child_trans_rev;
                }
            }
        }
    }

    my @insertions_to_apply;

    for my $dep_name (keys %transitive_parents) {
        next if exists $surviving_deps_ref->{$dep_name};

        my $entry = $update_ref->{$dep_name};
        if (defined $entry && exists $entry->{snyk} && defined $entry->{snyk}) {
            my $org = $entry->{org} // 'unknown.org';
            my $name = $entry->{name} // $dep_name;
            my $rev = $entry->{rev};
            my $conf = $entry->{conf} // 'runtime->default';
            my $snyk_id = $entry->{snyk};

            unless (defined $rev) {
                log_warning("Cannot promote Snyk transitive '$dep_name': missing 'rev' in revision-updates.txt");
                next;
            }

            my $transitive_rev = $max_transitive_revs{$dep_name};

            if (defined $transitive_rev) {
                my $cmp = version_compare($rev, $transitive_rev);
                if ($cmp <= 0) {
                    log_info("Skipping promotion for Snyk transitive '$name': requested $rev <= transitive $transitive_rev");
                    next;
                }
            }

            my $matched_parent;
            my $match_end_offset;
            my $parent_indent = '        ';

            for my $parent (@{$transitive_parents{$dep_name}}) {
                my $parent_regex = qr{
                    (
                        ^ [ \t]*
                        <dependency\b
                        (?:[^>"']|"[^"]*"|'[^']*')*?
                        \bname="\Q$parent\E"
                        (?:[^>"']|"[^"]*"|'[^']*')*?
                        (?:
                            />
                            |
                            >\s*.*?\s*</dependency>
                        )
                        \r?\n?
                    )
                }msx;

                if ($$file_content_ref =~ m/(.*?)($parent_regex)/s) {
                    $match_end_offset = length($1) + length($2);
                    $matched_parent = $parent;

                    if ($2 =~ /^(\s*)<dependency/m) {
                        $parent_indent = $1;
                    }
                    last;
                }
            }

            if (defined $matched_parent && defined $match_end_offset) {
                my $new_dep_xml = "${parent_indent}<!-- $snyk_id -->\n" . qq!${parent_indent}<dependency org="$org" name="$name" rev="$rev" conf="$conf" />\n!;

                push @insertions_to_apply, {
                    pos            => $match_end_offset,
                    text           => $new_dep_xml,
                    name           => $name,
                    rev            => $rev,
                    transitive_rev => $transitive_rev // 'unknown',
                    snyk           => $snyk_id,
                    parent         => $matched_parent,
                };
            }
        }
    }

    @insertions_to_apply = sort {$b->{pos} <=> $a->{pos}} @insertions_to_apply;

    for my $ins (@insertions_to_apply) {
        substr($$file_content_ref, $ins->{pos}, 0) = $ins->{text};
        $surviving_deps_ref->{$ins->{name}} = 1;
        log_success("Promoted transitive Snyk dependency to direct: $ins->{name} ($ins->{rev} > $ins->{transitive_rev}) [snyk=$ins->{snyk}] (inserted after parent '$ins->{parent}')");
        $$changes_made_ref++;
    }
}

sub enforce_snyk_comments {
    my ($file_content_ref, $update_ref, $changes_made_ref) = @_;

    return unless defined $update_ref && %$update_ref;

    for my $dep_name (keys %$update_ref) {
        my $entry = $update_ref->{$dep_name};
        next unless defined $entry && exists $entry->{snyk} && defined $entry->{snyk} && $entry->{snyk} ne '';

        my $snyk_id = $entry->{snyk};
        my $snyk_rev = $entry->{rev};

        $$file_content_ref =~ s{
            ^ ([ \t]*)
            (?: <!-- \s* (SNYK-[^>]+?) \s* --> \s* \r?\n [ \t]* )?
            (
                <dependency \b
                (?: [^>"'] | "[^"]*" | '[^']*' )*?
                \bname="\Q$dep_name\E"
                (?: [^>"'] | "[^"]*" | '[^']*' )*?
                (?: /> | > \s* .*? \s* </dependency> )
            )
        }{
            my $indent = $1 // '        ';
            my $existing_snyk = $2;
            my $dep_block = $3;

            my $current_rev;
            if ($dep_block =~ /\brev="([^"]*)"/) {
                $current_rev = $1;
            }

            my $is_newer = 0;
            if (defined $current_rev && defined $snyk_rev) {
                if (version_compare($current_rev, $snyk_rev) > 0) {
                    $is_newer = 1;
                }
            }

            if ($is_newer) {
                if (defined $existing_snyk) {
                    log_info("Removed Snyk comment for '$dep_name' ($current_rev > $snyk_rev)");
                    $$changes_made_ref++;
                }
                "${indent}${dep_block}";
            }
            else {
                if (defined $existing_snyk) {
                    if ($existing_snyk ne $snyk_id) {
                        log_info("Updated Snyk comment for '$dep_name': $existing_snyk -> $snyk_id");
                        $$changes_made_ref++;
                        "${indent}<!-- $snyk_id -->\n${indent}${dep_block}";
                    }
                    else {
                        "${indent}<!-- $snyk_id -->\n${indent}${dep_block}";
                    }
                }
                else {
                    log_info("Added Snyk comment for '$dep_name': $snyk_id");
                    $$changes_made_ref++;
                    "${indent}<!-- $snyk_id -->\n${indent}${dep_block}";
                }
            }
        }gmsxe;
    }
}

__END__