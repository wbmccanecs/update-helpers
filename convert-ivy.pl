#! /usr/bin/perl

use strict;
use warnings;
use File::stat;
use File::Find;
use File::Basename;
use Cwd 'abs_path';
use Term::ANSIColor qw{:constants};
use version;

my ($help, $hibernate5, $no_ui, $audit_deps) = (0) x 4;

for my $arg (@ARGV) {
    my $key = lc($arg);
    $help = 1 if $key eq "-h" || $key eq "--help";
    $hibernate5 = 1 if $key eq "5" || $key eq "--hibernate5";
    $no_ui = 1 if $key eq "noui" || $key eq "headless" || $key eq "--no-ui";
    $audit_deps = 1 if $key eq "audit" || $key eq "--audit-deps";
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

    my $libdir = (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';

    my @src_dirs = ('src', 'test');
    if (-e "$libdir/mgic-business.jar") {
        log_file_check("$libdir/mgic-business.jar");
        push @src_dirs, "../mgic_business/src";
    }
    if (-e "$libdir/mgic-common.jar") {
        log_file_check("$libdir/mgic-common.jar");
        push @src_dirs, "../mgic_common/src";
    }
    if (-e "$libdir/mgic-entity-custom.jar" || -e "$libdir/mgic-entity-master.jar") {
        log_file_check("$libdir/mgic-entity-custom.jar") if -e "$libdir/mgic-entity-custom.jar";
        log_file_check("$libdir/mgic-entity-master.jar") if -e "$libdir/mgic-entity-master.jar";
        log_error("Both mgic-entity-custom.jar and mgic-entity-master.jar exist. Please remove one of them.")
            if -e "$libdir/mgic-entity-custom.jar" && -e "$libdir/mgic-entity-master.jar";
        push @src_dirs, "../mgic_entity/src";
    }
    if (-e "$libdir/mgic-mux.jar") {
        log_file_check("$libdir/mgic-mux.jar");
        push @src_dirs, "../mgic_mux/src";
    }
    if (-e "$libdir/mgic-persistence.jar") {
        log_file_check("$libdir/mgic-persistence.jar");
        push @src_dirs, "../mgic_persistence/src";
    }

    my %used_deps_to_keep = extract_all_referenced_packages(\@src_dirs, (-d 'war' ? 'war' : undef));

    if ($audit_deps) {
        log_file_check($libdir);

        my ($unused_ref, $used_ref) = audit_dependencies(\@src_dirs, $libdir);
        %unused_deps_to_drop = %$unused_ref;
    }

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
        # Override revisions for Hibernate 5.x dependencies
        $update->{"hibernate-core-jakarta"} = { org => "org.hibernate", name => "hibernate-core-jakarta", rev => "5.6.15.Final" };
        $update->{"hibernate-jpamodelgen"} = { org => "org.hibernate", name => "hibernate-jpamodelgen", rev => "5.6.15.Final" };

        # cleanup and replace
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

    my $file_content;
    open(my $in, "<", $ivy_file)
        or die "Error: could not open '$ivy_file': $!";
    {
        local $/;
        $file_content = <$in>;
    }

    # Detect parents that currently have bouncycastle jdk15on module-specific excludes
    my %parents_with_bc_excludes = detect_parents_with_bouncycastle_excludes($file_content);

    # Strip auto-generated exclusions BEFORE regenerating .deps so show-deps sees the full transitive tree
    my $stripped_content = strip_auto_generated_exclusions($file_content, $update);

    # Temporarily write stripped version to disk so show-deps sees full tree without exclusions
    my $backup_needed = ($stripped_content ne $file_content);
    open(my $temp_fh, ">", "$ivy_file-clean")
        or die "Error: could not write temporary '$ivy_file-clean': $!";
    print $temp_fh $stripped_content;
    close $temp_fh;

    update_deps_file($ivy_file);

    # Dynamically generate the transitive version map from the fresh .deps tree
    my $remove_redundant_transitives_versioned = generate_transitive_map_from_deps('.deps');

    my %global_excludes = extract_global_exclusions($file_content);

    # Pre-scan ivy.xml to track all currently present direct dependencies
    my %present_deps;
    while ($file_content =~ /<dependency\s+(?:[^>]*?\s+)?name="([^"]+)"/g) {
        $present_deps{$1} = 1;
    }

    # Compute exact set of direct dependencies that will SURVIVE this run
    my %surviving_deps;
    for my $dep (keys %present_deps) {
        if ($update->{$dep} && $update->{$dep}->{keep}) {
            $surviving_deps{$dep} = 1;
            next;
        }

        next if $unused_deps_to_drop{$dep};
        next if grep {$dep =~ $_} @remove_packages;

        $surviving_deps{$dep} = 1;
    }

    # Second Pass: Prune dependencies whose parents actually survived
    for my $dep (keys %surviving_deps) {
        my ($current_rev) = $file_content =~ /<dependency\s+[^>]*name="\Q$dep\E"[^>]*rev="([^"]+)"/;

        if (should_remove_transitive($dep, $current_rev, $update, \%used_deps_to_keep, \%surviving_deps, $remove_redundant_transitives_versioned)) {
            delete $surviving_deps{$dep};
        }
    }

    # Generate dynamic exclusions ONLY for surviving deps that aren't globally excluded
    generate_dynamic_exclusions_from_deps('.deps', \%surviving_deps, $exclusions, \%global_excludes, $update, $add_if_missing, \%globally_add_deps);

    # Ensure all parents that had old-style bouncycastle module excludes now get org-level exclusions
    for my $parent (keys %parents_with_bc_excludes) {
        if (exists $surviving_deps{$parent}) {
            $exclusions->{$parent} ||= [];
            my $already_has_org_bc = 0;
            for my $rule (@{$exclusions->{$parent}}) {
                if ((defined $rule->{org} && $rule->{org} eq 'org.bouncycastle') &&
                    !defined $rule->{module}) {
                    $already_has_org_bc = 1;
                    last;
                }
            }
            if (!$already_has_org_bc) {
                push @{$exclusions->{$parent}}, { org => 'org.bouncycastle' };
                log_info("Generated org.bouncycastle exclusion on parent '$parent' (had old-style bouncycastle module excludes)");
            }
        }
    }

    # Process and rewrite ivy.xml content
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
        elsif (should_remove_transitive($dep_name, $current_rev, $update, \%used_deps_to_keep, \%surviving_deps, $remove_redundant_transitives_versioned)) {
            if ($audit_deps && $used_deps_to_keep{$dep_name}) {
                $replacement_str = $leading_whitespace . $dependency_block;
            }
            else {
                log_info("Remove redundant transitive $dep_name (rev '$current_rev' is <= required override version)");
            }
        }
        elsif (grep {$dep_name =~ $_} @remove_packages && !($update->{$dep_name} && $update->{$dep_name}->{keep})) {
            log_info("Remove $dep_name");
        }
        elsif ($unused_deps_to_drop{$dep_name} && !($update->{$dep_name} && $update->{$dep_name}->{keep})) {
            log_info("Remove unused dependency $dep_name (no active imports in src/)");
        }
        elsif (grep {$dep_name eq $_} @packages) {
            log_warning("Remove duplicate dependency $dep_name");
        }
        else {
            push @packages, $dep_name; # keep list of dependencies we have found

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
                        next if $key eq "keep";
                        my $new_val = $update_entry_ref->{$key};
                        $new_val = $current_rev if $key eq 'rev' && $should_keep_rev;

                        if ($modified_dependency_block =~ s/\b$key="([^"]*)"/$key="$new_val"/i) {
                            log_success("Update $dep_name:$key to $new_val") unless $1 eq $new_val;
                        }
                        else {
                            log_warning("$dep_org,$dep_name attempting to add missing $key attribute");
                            if ($modified_dependency_block =~ s# /># $key="$new_val" />#) {
                                # Attribute was added
                            }
                            else {
                                log_error("unable to add $key attribute");
                            }
                        }
                    }
                }

                if (exists $recommendations->{$dep_name}) {
                    log_info($recommendations->{$dep_name});
                }
            }

            # ------------------------------------------------------------------
            # CLEAN RECONSTRUCTION OF DEPENDENCY BLOCK
            # ------------------------------------------------------------------
            # 1. Extract pure opening attributes (handles conf="runtime->default" cleanly)
            my $clean_attrs = '';
            if ($modified_dependency_block =~ m{^<dependency\s+((?:[^"'>]|"[^"]*"|'[^']*')+?)\s*(?:/>|>)}s) {
                $clean_attrs = $1;
                $clean_attrs =~ s/\s+/ /g; # Normalize spaces
                $clean_attrs =~ s/\s+$//;  # Trim trailing whitespace
            }

            # 2. Check for dynamic exclusions generated for this dep
            my $dep_exclusions = $exclusions->{$dep_name} || $exclusions->{"$dep_org,$dep_name"};

            if (defined $dep_exclusions && @$dep_exclusions > 0) {
                my $current_dep_tag_indent = '';
                if ($leading_whitespace =~ m/^(\s*)/s) {
                    my @lines = split /\r?\n/, $leading_whitespace;
                    $current_dep_tag_indent = $lines[-1];
                }
                my $exclusion_indent = $current_dep_tag_indent . '    ';

                my $new_exclusions = generate_exclusion_xml($dep_exclusions, $exclusion_indent, $dep_name);

                if (length $new_exclusions > 0) {
                    $modified_dependency_block = "<dependency $clean_attrs>$new_exclusions\n$current_dep_tag_indent</dependency>";
                }
                else {
                    $modified_dependency_block = "<dependency $clean_attrs />";
                }
            }
            else {
                # 3. NO EXCLUSIONS: Collapse multi-line container tag to single self-closing tag
                $modified_dependency_block = "<dependency $clean_attrs />";
            }

            $replacement_str = $leading_whitespace . $modified_dependency_block;
        }

        $replacement_str;
    }mxseg;

    my $dependencies_close_tag_indent = '    ';
    if ($file_content =~ m!^(\s*)</dependencies>!ms) {
        $dependencies_close_tag_indent = $1;
    }

    insert_missing_dependencies(\$file_content, $add_if_missing, $update, $exclusions);

    open(my $out, ">", $output_file)
        or die "Error: could not open '$output_file': $!";
    print $out $file_content;
    close $out;
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

sub is_dep_used {
    my ($dep_name, $update_ref, $used_deps_ref) = @_;
    return 0 unless defined $dep_name && defined $used_deps_ref && %$used_deps_ref;

    return 1 if exists $used_deps_ref->{$dep_name};

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

sub should_remove_transitive {
    my ($dep_name, $current_rev, $update_ref, $used_deps_ref, $surviving_deps_ref, $remove_redundant_transitives_versioned) = @_;
    return 0 unless defined $current_rev;
    return 0 unless defined $remove_redundant_transitives_versioned
        && ref($remove_redundant_transitives_versioned) eq 'HASH';

    # 1. Guardrail: Keep if 'keep' flag is set in update hash
    if ($update_ref && exists $update_ref->{$dep_name} && $update_ref->{$dep_name}->{keep}) {
        return 0;
    }

    # 2. Direct code usage in src/, test/, or ../mgic_*/src -> KEEP
    if ($used_deps_ref && is_dep_used($dep_name, $update_ref, $used_deps_ref)) {
        return 0;
    }

    my $has_exact_match_parent = 0;

    # 3. Scan ALL surviving parents
    for my $parent_pkg (keys %$remove_redundant_transitives_versioned) {
        if ($surviving_deps_ref && exists $surviving_deps_ref->{$parent_pkg}) {
            my $targets = $remove_redundant_transitives_versioned->{$parent_pkg};

            if (exists $targets->{$dep_name}) {
                my $transitive_rev = $targets->{$dep_name};

                my $target_rev = $update_ref->{$dep_name}->{rev} if defined $update_ref && exists $update_ref->{$dep_name};
                my $effective_rev = $target_rev || $current_rev;

                my $cmp = version_compare($effective_rev, $transitive_rev);

                # IF ANY SURVIVING PARENT brings in a mismatched/older version (e.g. ignite-log4j2 brings 2.25.3),
                # WE MUST KEEP THE DIRECT DEPENDENCY IN PLACE to force version alignment!
                if ($cmp != 0) {
                    log_success("Keeping direct dependency $dep_name ($effective_rev != $transitive_rev via parent '$parent_pkg')");
                    return 0;
                }
                else {
                    $has_exact_match_parent = 1;
                }
            }
        }
    }

    # Only drop if AT LEAST ONE parent matched exactly AND NO parents had version mismatches
    if ($has_exact_match_parent) {
        log_info("Dropping redundant direct dependency $dep_name (Fully satisfied by surviving parents at $current_rev)");
        return 1;
    }

    return 0;
}

sub update_deps_file {
    my ($ivy_file) = @_;
    my $deps_file = '.deps';
    $ivy_file ||= 'ivy.xml';
    my $ant_cmd = "/c/ant/bin/ant -f my-build.xml show-deps -Divy.file=$ivy_file-clean";
    my $deps_mtime = (-e $deps_file) ? (stat($deps_file))->mtime : 0;
    my $ivy_mtime = (-e $ivy_file) ? (stat($ivy_file))->mtime : 0;

    if ($deps_mtime > 0 && $deps_mtime > $ivy_mtime) {
        log_info("$deps_file is up to date relative to $ivy_file. Skipping ant execution.\n");
        return;
    }

    log_info("INFO: Generating $deps_file from Ant show-deps target...");

    open(my $ant_fh, "$ant_cmd 2>&1 |") or die "Failed to execute Ant command: $!\n";

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
                # Match lines with branch connectors (+- or \-)
                if ($content =~ /^(.*?)(?:[\+\\]\-)(.*)$/) {
                    # Keep the whole tree so we can map deep transitives
                    push @filtered_lines, $content . "\n";
                }
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
    my ($src_dirs_ref, $webapp_dir) = @_;
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
        log_info("Scanning external mgic directories (" . join(', ', @mgic_dirs) . ") for reachability...");

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

        log_info("Reachable mgic classes: " . (scalar keys %reachable_level1) . " (Direct local), " . (scalar keys %reachable_level2) . " (1-hop indirect)");
    }

    log_success("Extracted " . (scalar keys %referenced_packages) . " active package/class references.");
    return %referenced_packages;
}

sub audit_dependencies {
    my ($src_dirs, $libdir) = @_;
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

    my @stack; # Tracks the current dependency at each tree depth

    while (my $line = <$fh>) {
        chomp $line;

        # Match the visual tree: (prefix)(connector)(org#name;version)
        if ($line =~ /^(.*?)(?:[\+\\]\-)\s*(.*?)$/) {
            my $prefix = $1;
            my $payload = $2;

            # Every 3 characters of prefix (like "|  " or "   ") equals 1 level of depth
            my $depth = length($prefix) / 3;

            # Parse Ivy's default format: org#name;version
            # Safely handles trailing eviction notices like "1.0 (evicted by 2.0)"
            if ($payload =~ /([^#]+)#([^;]+);([^\s]+)/) {
                my $name = $2;
                my $rev = $3;

                # Update the stack at the current depth
                $stack[$depth] = $name;

                # If we are deeper than the root, map this transitive to the top-level parent
                if ($depth > 0 && defined $stack[0]) {
                    my $root_parent = $stack[0];

                    # keep LOWEST version so version mismatch is detected if older versions exist in tree
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
    my ($deps_file, $surviving_deps_ref, $exclusions_ref, $global_excludes_ref, $update_ref, $add_if_missing_ref, $globally_add_deps_ref) = @_;

    return unless -e $deps_file;

    open(my $fh, '<', $deps_file) or return;

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

                    # RULE 1: Direct dependency exists in ivy.xml
                    if (exists $surviving_deps_ref->{$name}) {
                        if (exists $update_ref->{$name}) {
                            my $update_entry = $update_ref->{$name};
                            my $update_rev = $update_entry->{rev};

                            if (defined $update_rev && $update_rev ne $rev) {
                                $exclusions_ref->{$root_parent} ||= [];
                                my $already_excluded = 0;
                                for my $rule (@{$exclusions_ref->{$root_parent}}) {
                                    if ((defined $rule->{module} && $rule->{module} eq $name) ||
                                        (defined $rule->{name} && $rule->{name} eq $name)) {
                                        $already_excluded = 1;
                                        last;
                                    }
                                }
                                # ONLY LOG IF NEWLY ADDED
                                if (!$already_excluded) {
                                    push @{$exclusions_ref->{$root_parent}}, { module => $name };
                                    log_info("Generated exclusion for transitive '$name' ($rev) under parent '$root_parent'");
                                }
                            }
                        }
                    }
                    # RULE 2: Promote to add_if_missing only if not direct
                    elsif (exists $update_ref->{$name} && exists $surviving_deps_ref->{$root_parent}) {
                        my $update_entry = $update_ref->{$name};
                        my $update_rev = $update_entry->{rev};

                        if (defined $update_rev && $update_rev ne $rev) {
                            if (defined $globally_add_deps_ref && !exists $globally_add_deps_ref->{$name}) {
                                $globally_add_deps_ref->{$name} = 1;
                                if (defined $add_if_missing_ref) {
                                    if (!exists $add_if_missing_ref->{$root_parent}) {
                                        $add_if_missing_ref->{$root_parent} = [ $name ];
                                    }
                                    elsif (!grep {$_ eq $name} @{$add_if_missing_ref->{$root_parent}}) {
                                        push @{$add_if_missing_ref->{$root_parent}}, $name;
                                    }
                                }
                            }

                            $exclusions_ref->{$root_parent} ||= [];
                            my $already_excluded = 0;
                            for my $rule (@{$exclusions_ref->{$root_parent}}) {
                                if ((defined $rule->{module} && $rule->{module} eq $name) ||
                                    (defined $rule->{name} && $rule->{name} eq $name)) {
                                    $already_excluded = 1;
                                    last;
                                }
                            }
                            # ONLY LOG IF NEWLY ADDED
                            if (!$already_excluded) {
                                push @{$exclusions_ref->{$root_parent}}, { module => $name };
                                log_info("Generated exclusion for versioned transitive '$name' on parent '$root_parent'");
                            }
                        }
                    }

                    # RULE 3: BouncyCastle org-level exclusions
                    if ($org eq 'org.bouncycastle' && $name =~ /jdk15on/ && exists $surviving_deps_ref->{$root_parent}) {
                        $exclusions_ref->{$root_parent} ||= [];
                        my $already_excluded_bc = 0;
                        for my $rule (@{$exclusions_ref->{$root_parent}}) {
                            if ((defined $rule->{org} && $rule->{org} eq 'org.bouncycastle') &&
                                !defined $rule->{module}) {
                                $already_excluded_bc = 1;
                                last;
                            }
                        }
                        # ONLY LOG IF NEWLY ADDED
                        if (!$already_excluded_bc) {
                            push @{$exclusions_ref->{$root_parent}}, { org => 'org.bouncycastle' };
                            log_info("Generated org.bouncycastle exclusion on parent '$root_parent'");
                        }
                    }
                }
            }
        }
    }
    close($fh);
}

sub detect_parents_with_bouncycastle_excludes {
    my ($xml_content) = @_;
    my %parents;

    # Find all dependency blocks that contain bouncycastle module-specific excludes
    while ($xml_content =~ /<dependency\s+([^>]*?)(?:>|\/\s*>)((?:(?!<\/dependency>).)*?)<\/dependency>/gms) {
        my $dep_attrs = $1;
        my $dep_content = $2;

        my $parent_name;
        if ($dep_attrs =~ /\bname="([^"]+)"/) {
            $parent_name = $1;
        }

        # Check if this dependency block has any bouncycastle jdk15on module excludes
        if (defined $parent_name && $dep_content =~ /<exclude\s+[^>]*org="org\.bouncycastle"[^>]*module="[^"]*jdk15on[^"]*"\s*\/>/i) {
            $parents{$parent_name} = 1;
        }
    }

    return %parents;
}

sub strip_auto_generated_exclusions {
    my ($xml_content, $update_ref) = @_;

    # Strip org-level bouncycastle excludes (auto-generated for jdk15on variants)
    $xml_content =~ s{\s*<exclude\s+org="org\.bouncycastle"\s*/>}{}gms;

    # Strip module-level excludes for dependencies with version overrides in update data
    # (these are auto-generated for version mismatches)
    if (defined $update_ref && %$update_ref) {
        foreach my $dep_name (keys %$update_ref) {
            # Escape special characters for regex
            my $escaped_name = quotemeta($dep_name);
            $xml_content =~ s{\s*<exclude\s+[^>]*module="$escaped_name"\s*/>}{}gms;
        }
    }

    return $xml_content;
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
                    log_info("Scanning file: $file");

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

sub load_update_data {
    my $script_dir = dirname(abs_path($0));
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

__END__
