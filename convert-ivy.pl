#! /usr/bin/perl

use strict;
use warnings;
use File::stat;
use File::Find;
use Term::ANSIColor qw{:constants};
use version;

my $ivy_file = "ivy.xml";
my $output_file = "ivy.xml.new";

my ($help, $hibernate5, $no_ui, $audit_deps) = (0) x 4;

for my $arg (@ARGV) {
    my $key = lc($arg);
    $hibernate5 = 1 if $key eq "5" || $key eq "--hibernate5";
    $no_ui = 1 if $key eq "noui" || $key eq "headless" || $key eq "--no-ui";
    $audit_deps = 1 if $key eq "audit" || $key eq "--audit-deps";
}

my %unused_deps_to_drop;
my %used_deps_to_keep;

if ($audit_deps) {
    my $libdir = (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';
    log_file_check($libdir);

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
        push @src_dirs, "../mgic_entity/src"
    }
    if (-e "$libdir/mgic-mux.jar") {
        log_file_check("$libdir/mgic-mux.jar");
        push @src_dirs, "../mgic_mux/src";
    }
    if (-e "$libdir/mgic-persistence.jar") {
        log_file_check("$libdir/mgic-persistence.jar");
        push @src_dirs, "../mgic_persistence/src";
    }

    my ($unused_ref, $used_ref) = audit_dependencies(\@src_dirs, $libdir);
    %unused_deps_to_drop = %$unused_ref;
    %used_deps_to_keep = %{filter_dependencies($used_ref, \%used_deps_to_keep)};
}

my @remove_packages = (
    "commons-httpclient",
    "commons-logging",
    "commons-pool",
    # "httpmime",
    'jandex',
    # "jaxb-core",
    # "jaxb-impl",
    "log4jdbc",
    "^powermock-",
    "easymock",
    "httpcore",
    # "aopalliance",
    # 'jackson-.*-asl',
    # 'xml-api',
    'taglibs-standard-impl',
    # "javax.jms-api",
    # "jakarta.jms-api",
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

my $springVersion = '6.2.19';
my $springSecurityVersion = '6.5.4';

my @keyOrder = ("org", "module", "name");

my $update = {
    # <!-- Spring -->
    "spring-core"                              => { org => "org.springframework", name => "spring-core", rev => $springVersion },
    "spring-beans"                             => { org => "org.springframework", name => "spring-beans", rev => $springVersion },
    "spring-context"                           => { org => "org.springframework", name => "spring-context", rev => $springVersion },
    "spring-context-support"                   => { org => "org.springframework", name => "spring-context-support", rev => $springVersion },
    "spring-expression"                        => { org => "org.springframework", name => "spring-expression", rev => $springVersion },
    "spring-jms"                               => { org => "org.springframework", name => "spring-jms", rev => $springVersion },
    "spring-messaging"                         => { org => "org.springframework", name => "spring-messaging", rev => $springVersion },
    "spring-test"                              => { org => "org.springframework", name => "spring-test", rev => $springVersion },
    "spring-tx"                                => { org => "org.springframework", name => "spring-tx", rev => $springVersion },
    "spring-data-jpa"                          => { org => "org.springframework.data", name => "spring-data-jpa", rev => "3.5.12" },
    "spring-web"                               => { org => "org.springframework", name => "spring-web", rev => $springVersion },
    "spring-webmvc"                            => { org => "org.springframework", name => "spring-webmvc", rev => $springVersion },
    "spring-websocket"                         => { org => "org.springframework", name => "spring-websocket", rev => $springVersion },
    "spring-aop"                               => { org => "org.springframework", name => "spring-aop", rev => $springVersion },
    "spring-aspects"                           => { org => "org.springframework", name => "spring-aspects", rev => $springVersion },
    "spring-security-core"                     => { org => "org.springframework.security", name => "spring-security-core", rev => "6.5.4" },
    "spring-security-crypto"                   => { org => "org.springframework.security", name => "spring-security-crypto", rev => $springSecurityVersion },
    "spring-security-web"                      => { org => "org.springframework.security", name => "spring-security-web", rev => $springSecurityVersion },
    "spring-security-config"                   => { org => "org.springframework.security", name => "spring-security-config", rev => $springSecurityVersion },
    "spring-security-oauth2-resource-server"   => { org => "org.springframework.security", name => "spring-security-oauth2-resource-server", rev => $springSecurityVersion },
    "spring-security-test"                     => { org => "org.springframework.security", name => "spring-security-test", rev => $springSecurityVersion },
    "spring-security-oauth2-jose"              => { org => "org.springframework.security", name => "spring-security-oauth2-jose", rev => $springSecurityVersion },
    "spring-boot-autoconfigure"                => { org => "org.springframework.boot", name => "spring-boot-autoconfigure", rev => "3.5.14" },
    # <!-- Miscellaneous -->
    "jcc"                                      => { org => "com.ibm.db2", name => "jcc", rev => "11.5.9.0" },
    "ojdbc8"                                   => { org => "com.oracle.database.jdbc", name => "ojdbc8", rev => "23.26.2.0.0" },
    "displaytag"                               => { org => "com.github.hazendaz", name => "displaytag", rev => "3.8.0" },
    "fop"                                      => { org => "org.apache.xmlgraphics", name => "fop", rev => "2.10" },
    "commons-collections4"                     => { org => "org.apache.commons", name => "commons-collections4", rev => "4.5.0" },
    "commons-lang3"                            => { org => "org.apache.commons", name => "commons-lang3", rev => "3.20.0" },
    "commons-text"                             => { org => "org.apache.commons", name => "commons-text", rev => "1.15.0" },
    "commons-beanutils"                        => { org => "commons-beanutils", name => "commons-beanutils", rev => "1.11.0" },
    "commons-dbcp2"                            => { org => "org.apache.commons", name => "commons-dbcp2", rev => "2.14.0" },
    "commons-io"                               => { org => "commons-io", name => "commons-io", rev => "2.22.0" },
    "angus-mail"                               => { org => "org.eclipse.angus", name => "angus-mail", rev => "2.1.0-M1" },
    "joda-time"                                => { org => "joda-time", name => "joda-time", rev => "2.14.2" },
    "jaxen"                                    => { org => "jaxen", name => "jaxen", rev => "2.0.6" },
    # <!-- Logging -->
    "log4j-api"                                => { org => "org.apache.logging.log4j", name => "log4j-api", rev => "2.26.1" },
    "log4j-core"                               => { org => "org.apache.logging.log4j", name => "log4j-core", rev => "2.26.1" },
    "log4j-slf4j2-impl"                        => { org => "org.apache.logging.log4j", name => "log4j-slf4j2-impl", rev => "2.26.1" },
    "log4j-jakarta-smtp"                       => { org => "org.apache.logging.log4j", name => "log4j-jakarta-smtp", rev => "2.26.1" },
    "jcl-over-slf4j"                           => { org => "org.slf4j", name => "jcl-over-slf4j", rev => "2.0.18" },
    "slf4j-api"                                => { org => "org.slf4j", name => "slf4j-api", rev => "2.0.18" },
    # <!-- UNIT TESTS -->
    "junit"                                    => { org => "junit", name => "junit", rev => "4.13.2", conf => "compile->default" },
    "easymock"                                 => { org => "org.easymock", name => "easymock", rev => "5.6.0", conf => "compile->default" },
    "mockito-core"                             => { org => "org.mockito", name => "mockito-core", rev => "5.23.0", conf => "compile->default" },
    # <!-- WEB RUNTIME -->
    "encoder-jakarta-jsp"                      => { org => "org.owasp.encoder", name => "encoder-jakarta-jsp", rev => "1.4.0" },
    "sitemesh"                                 => { org => "opensymphony", name => "sitemesh", rev => "2.7.0-M1" },
    # <!-- WEB COMPILE -->
    "jakarta.servlet-api"                      => { org => "jakarta.servlet", name => "jakarta.servlet-api", rev => "6.0.0", conf => 'compile->default' },
    "jakarta.servlet.jsp-api"                  => { org => "jakarta.servlet.jsp", name => "jakarta.servlet.jsp-api", rev => "4.0.0", conf => 'compile->default' },
    "jakarta.servlet.jsp.jstl"                 => { org => "org.glassfish.web", name => "jakarta.servlet.jsp.jstl", rev => "3.0.1" },
    "jakarta.servlet.jsp.jstl-api"             => { org => "jakarta.servlet.jsp.jstl", name => "jakarta.servlet.jsp.jstl-api", rev => "3.0.2" },
    "lombok"                                   => { org => "org.projectlombok", name => "lombok", rev => "1.18.46" },
    "jakarta.annotation-api"                   => { org => "jakarta.annotation", name => "jakarta.annotation-api", rev => "3.0.0" },
    "byte-buddy-agent"                         => { org => "net.bytebuddy", name => "byte-buddy-agent", rev => "1.17.7", conf => "compile->default" },
    # <!-- Hibernate -->
    "hibernate-validator"                      => { org => "org.hibernate.validator", name => "hibernate-validator", rev => "8.0.0.Final" },
    "hibernate-validator-annotation-processor" => { org => "org.hibernate.validator", name => "hibernate-validator-annotation-processor", rev => "8.0.0.Final" },
    "dom4j"                                    => { org => "org.dom4j", name => "dom4j", rev => "2.2.0" },
    "byte-buddy"                               => { org => "net.bytebuddy", name => "byte-buddy", rev => "1.17.7" },
    "jakarta.persistence-api"                  => { org => "jakarta.persistence", name => "jakarta.persistence-api", rev => "3.2.0" },
    "jakarta.transaction-api"                  => { org => "jakarta.transaction", name => "jakarta.transaction-api", rev => "2.0.1" },
    # <!-- CAS for SSO - ONLY FOR ATLAS APPS -->
    "cas-client-core"                          => { org => "org.apereo.cas.client", name => "cas-client-core", rev => "4.0.4" },
    "nimbus-jose-jwt"                          => { org => "com.nimbusds", name => "nimbus-jose-jwt", rev => "10.9.1" },
    # <!-- Other -->
    "poi"                                      => { org => "org.apache.poi", name => "poi", rev => "5.4.1" },
    "poi-ooxml"                                => { org => "org.apache.poi", name => "poi-ooxml", rev => "5.4.1" },
    "tika-core"                                => { org => "org.apache.tika", name => "tika-core", rev => "3.3.1" },
    "tika-parsers-standard-package"            => { org => "org.apache.tika", name => "tika-parsers-standard-package", rev => "3.3.1" },
    "tika-parser-sqlite3-package"              => { org => "org.apache.tika", name => "tika-parser-sqlite3-package", rev => "3.3.1" },

    # OTHER OTHER
    "jackson-annotations"                      => { org => "com.fasterxml.jackson.core", name => "jackson-annotations", rev => "2.22" },
    "jackson-core"                             => { org => "com.fasterxml.jackson.core", name => "jackson-core", rev => "2.22.1" },
    "jackson-databind"                         => { org => "com.fasterxml.jackson.core", name => "jackson-databind", rev => "2.22.1" },
    "jackson-datatype-jsr310"                  => { org => "com.fasterxml.jackson.datatype", name => "jackson-datatype-jsr310", rev => "2.22.1" },
    "jackson-datatype-json-org"                => { org => "com.fasterxml.jackson.datatype", name => "jackson-datatype-json-org", rev => "2.22.1" },
    "itextpdf"                                 => { org => "com.itextpdf", name => "itextpdf", rev => "5.5.13.5" },
    "itext-pdfa"                               => { org => "com.itextpdf", name => "itext-pdfa", rev => "5.5.13.5" },
    "itext-xtra"                               => { org => "com.itextpdf", name => "itext-xtra", rev => "5.5.13.5" },
    "commons-codec"                            => { org => "commons-codec", name => "commons-codec", rev => "1.22.0" },
    "jakarta.xml.soap-api"                     => { org => "jakarta.xml.soap", name => "jakarta.xml.soap-api", rev => "3.0.2" },
    "jakarta.xml.ws-api"                       => { org => "jakarta.xml.ws", name => "jakarta.xml.ws-api", rev => "4.0.3" },
    "jakarta.xml.bind-api"                     => { org => "jakarta.xml.bind", name => "jakarta.xml.bind-api", rev => "4.0.5" },
    "commons-fileupload2-jakarta-servlet6"     => { org => "org.apache.commons", name => "commons-fileupload2-jakarta-servlet6", rev => "2.0.0-M5" },
    "httpclient5"                              => { org => "org.apache.httpcomponents.client5", name => "httpclient5", rev => "5.6.2" },
    "httpclient5-cache"                        => { org => "org.apache.httpcomponents.client5", name => "httpclient5-cache", rev => "5.6" },
    "xmlbeans"                                 => { org => "org.apache.xmlbeans", name => "xmlbeans", rev => "3.0.0" },
    "hibernate-commons-annotations"            => { org => "org.hibernate.common", name => "hibernate-commons-annotations", rev => "5.1.1.Final" },
    "encoder"                                  => { org => "org.owasp.encoder", name => "encoder", rev => "1.3.1" },
    "slf4j-log4j12"                            => { org => "org.slf4j", name => "slf4j-log4j12", rev => "1.7.34" },
    "slf4j-reload4j"                           => { org => "org.slf4j", name => "slf4j-reload4j", rev => "2.0.1" },
    "jakarta.validation-api"                   => { org => "jakarta.validation", name => "jakarta.validation-api", rev => "3.1.1" },
    "esapi"                                    => { org => "org.owasp.esapi", name => "esapi", rev => "2.7.0.0" },

    # current versions just to help convert old build.xml projects to ivy.xml
    "jsch"                                     => { org => "com.jcraft", name => "jsch", rev => "0.1.54" },

    # ehcache
    "cache-api"                                => { org => "javax.cache", name => "cache-api", rev => "1.1.1" },
    "ehcache"                                  => { org => "org.ehcache", name => "ehcache", rev => "3.12.0" },
    "jaxb-runtime"                             => { org => "org.glassfish.jaxb", name => "jaxb-runtime", rev => "4.0.9" },

    "ignite-core"                              => { org => "org.apache.ignite", name => "ignite-core", rev => "2.18.0" },
    "ignite-spring"                            => { org => "org.apache.ignite", name => "ignite-spring", rev => "2.18.0" },
    "ignite-indexing"                          => { org => "org.apache.ignite", name => "ignite-indexing", rev => "2.18.0" },
    "ignite-log4j2"                            => { org => "org.apache.ignite", name => "ignite-log4j2", rev => "2.18.0" },
    "ignite-slf4j"                             => { org => "org.apache.ignite", name => "ignite-slf4j", rev => "2.18.0" },
};

if ($hibernate5) {
    $update->{"hibernate-core-jakarta"} = { org => "org.hibernate", name => "hibernate-core-jakarta", rev => "5.6.15.Final" };
    $update->{"hibernate-jpamodelgen"} = { org => "org.hibernate", name => "hibernate-jpamodelgen", rev => "5.6.15.Final" };
    push @remove_packages, "hibernate-community-dialects";
}
else {
    $update->{"hibernate-core"} = { org => "org.hibernate.orm", name => "hibernate-core", rev => "6.6.54.Final" };
    $update->{"hibernate-jpamodelgen"} = { org => "org.hibernate.orm", name => "hibernate-jpamodelgen", rev => "6.6.54.Final" };
    $update->{"hibernate-community-dialects"} = { org => "org.hibernate.orm", name => "hibernate-community-dialects", rev => "6.6.54.Final" };
}

# replaced packages
$update->{"commons-lang"} = $update->{"commons-lang3"};
$update->{"commons-dbcp"} = $update->{"commons-dbcp2"};
$update->{"commons-collections"} = $update->{"commons-collections4"};
$update->{"commons-fileupload"} = $update->{"commons-fileupload2-jakarta-servlet6"};
$update->{"encoder-jsp"} = $update->{"encoder-jakarta-jsp"};
if ($hibernate5) {
    $update->{"hibernate-core"} = $update->{"hibernate-core-jakarta"};
}
else {
    $update->{"hibernate-core-jakarta"} = $update->{"hibernate-core"};
}
$update->{"httpclient"} = $update->{"httpclient5"};
$update->{"httpclient-cache"} = $update->{"httpclient5-cache"};
$update->{"javax.annotation-api"} = $update->{"jakarta.annotation-api"};
$update->{"javax.servlet-api"} = $update->{"jakarta.servlet-api"};
$update->{"javax.servlet.jsp-api"} = $update->{"jakarta.servlet.jsp-api"};
$update->{"jsp-api"} = $update->{"jakarta.servlet.jsp-api"};
$update->{"mockito-all"} = $update->{"mockito-core"};
$update->{"log4j"} = $update->{"log4j-core"};
$update->{"log4j-slf4j-impl"} = $update->{"log4j-slf4j2-impl"};
$update->{"mail"} = $update->{"angus-mail"};
$update->{"javax.mail-api"} = $update->{"angus-mail"};
$update->{"jakarta.mail-api"} = $update->{"angus-mail"};
$update->{"javax.mail"} = $update->{"angus-mail"};
$update->{"displaytag-portlet"} = $update->{"displaytag"};
$update->{"javax.xml.soap-api"} = $update->{"jakarta.xml.soap-api"};
$update->{"validation-api"} = $update->{"jakarta.validation-api"};
$update->{"jstl"} = $update->{"jakarta.servlet.jsp.jstl"};
$update->{"db2jcc"} = $update->{"jcc"};
$update->{"db2jcc4"} = $update->{"jcc"};
$update->{"jta"} = $update->{"jakarta.transaction-api"};
$update->{"jaxws-api"} = $update->{"jakarta.xml.ws-api"};
$update->{"jaxb-api"} = $update->{"jakarta.xml.bind-api"};

my $add_if_missing = {};

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

update_deps_file();

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
    # Skip if flagged for removal by audit or package filters
    next if $audit_deps && $unused_deps_to_drop{$dep};
    next if grep {$dep =~ $_} @remove_packages;

    # Mark as surviving candidate for initial pass
    $surviving_deps{$dep} = 1;
}

# Second Pass: Prune dependencies whose parents actually survived
for my $dep (keys %surviving_deps) {
    my ($current_rev) = $file_content =~ /<dependency\s+[^>]*name="\Q$dep\E"[^>]*rev="([^"]+)"/;

    if (should_remove_transitive($dep, $current_rev, \%present_deps, $update, \%used_deps_to_keep, \%surviving_deps)) {
        delete $surviving_deps{$dep};
    }
}

# Generate dynamic exclusions ONLY for surviving deps that aren't globally excluded
generate_dynamic_exclusions_from_deps('.deps', \%surviving_deps, $exclusions, \%global_excludes, $update);

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
    elsif (should_remove_transitive($dep_name, $current_rev, \%present_deps, $update, \%used_deps_to_keep)) {
        if ($audit_deps && $used_deps_to_keep{$dep_name}) {
            log_warning("Keep direct dependency $dep_name (Transitive, but direct usage detected in code)");
            $replacement_str = $leading_whitespace . $dependency_block;
        }
        else {
            log_info("Remove redundant transitive $dep_name (rev '$current_rev' is <= required override version)");
        }
    }
    elsif (grep {$dep_name =~ $_} @remove_packages) {
        log_info("Remove $dep_name");
    }
    elsif ($audit_deps && $unused_deps_to_drop{$dep_name}) {
        log_info("Remove unused dependency $dep_name (no active imports in src/)");
        # Format the comment to match current indentation
        #        my $indent = $leading_whitespace;
        #        $indent =~ s/.*\n//s; # Keep only the trailing spaces on the last line
        #        $replacement_str = "\n" . $indent . "<!-- [AUDIT] Removed '$dep_name': No active Java imports found in src/ -->";
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
                    my $new_val = $update_entry_ref->{$key};
                    $new_val = $current_rev if $key eq 'rev' && $should_keep_rev;

                    if ($modified_dependency_block =~ s/\b$key="([^"]*)"/$key="$new_val"/i) {
                        # Attribute was updated
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

        # 1. Always strip existing inner <exclude> tags from the dependency block
        $modified_dependency_block =~ s{\s*<exclude\s+(?:[^>]*?)\s*/>}{}gsi;              # Self-closing
        $modified_dependency_block =~ s{\s*<exclude\s+(?:[^>]*?)>(?:.*?)</exclude>}{}gsi; # Opening/closing

        # 2. Convert multi-line container back to self-closing if it became empty
        if ($modified_dependency_block =~ m{^\s*<dependency\b([^>]*)>\s*</dependency>\s*$}s) {
            my $attrs = $1;
            $attrs =~ s/\s+$//;
            $modified_dependency_block = "<dependency$attrs />";
        }

        # 3. Only attach new exclusions if explicit exclusion rules actually exist for this dep
        my $dep_exclusions = $exclusions->{$dep_name} || $exclusions->{"$dep_org,$dep_name"};
        if (defined $dep_exclusions && @$dep_exclusions > 0) {

            my $current_dep_tag_indent = '';
            if ($leading_whitespace =~ m/^(\s*)/s) {
                my @lines = split /\r?\n/, $leading_whitespace;
                $current_dep_tag_indent = $lines[-1];
            }
            my $exclusion_indent = $current_dep_tag_indent . '    ';

            my $new_exclusions = generate_exclusion_xml($dep_exclusions, $exclusion_indent);

            if (length $new_exclusions > 0) {
                if ($modified_dependency_block =~ m{/>$}) {
                    $modified_dependency_block =~ s{/>$}{>$new_exclusions\n$current_dep_tag_indent</dependency>};
                }
                elsif ($modified_dependency_block =~ m{((?:\s*)</dependency>)$}s) {
                    $modified_dependency_block =~ s{((?:\s*)</dependency>)$}{$new_exclusions$1}s;
                }
            }
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

exit 0;

sub generate_exclusion_xml {
    my ($rules_ref, $base_indent) = @_;
    my $exclusions_xml = '';

    if (defined $rules_ref && @$rules_ref > 0) {
        foreach my $rule (@$rules_ref) {
            $exclusions_xml .= qq!\n$base_indent<exclude!;
            for my $attribute (@keyOrder) {
                if (defined $rule->{$attribute}) {
                    log_info("Adding exclusion: " . $attribute . "=" . $rule->{$attribute});
                    # Use quotemeta to escape attribute values in case they contain regex metacharacters
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

sub should_remove_transitive {
    my ($dep_name, $current_rev, $present_deps_ref, $update_ref, $used_deps_ref, $surviving_deps_ref) = @_;
    return 0 unless defined $current_rev;
    return 0 unless defined $remove_redundant_transitives_versioned
        && ref($remove_redundant_transitives_versioned) eq 'HASH';

    # 1. Direct code usage in src/ -> KEEP
    if ($used_deps_ref && exists $used_deps_ref->{$dep_name}) {
        log_info("Keep direct dependency $dep_name (Direct usage detected in src/)");
        return 0;
    }

    for my $parent_pkg (keys %$remove_redundant_transitives_versioned) {
        if (exists $surviving_deps_ref->{$parent_pkg}) {
            my $targets = $remove_redundant_transitives_versioned->{$parent_pkg};

            if (exists $targets->{$dep_name}) {
                my $transitive_rev = $targets->{$dep_name};

                my $target_rev = $update_ref->{$dep_name}->{rev} if defined $update_ref && exists $update_ref->{$dep_name};
                my $effective_rev = $target_rev || $current_rev;

                # Compare versions numerically: 10.9 vs 9.1
                my $cmp = version_compare($effective_rev, $transitive_rev);

                if ($cmp > 0) {
                    # Direct version (e.g. 10.9) is STRICTLY NEWER than transitive (e.g. 9.1) -> KEEP
                    log_success("Keeping direct dependency $dep_name ($effective_rev > $transitive_rev - explicit version override)");
                    return 0;
                }
                else {
                    # Transitive is >= direct version (e.g. 9.1 >= 9.1 or 10.9 >= 10.9) -> DROP direct dependency
                    log_info("Dropping direct dependency $dep_name (Transitively supplied by surviving parent '$parent_pkg' at $transitive_rev)");
                    return 1;
                }
            }
        }
    }

    return 0;
}

sub update_deps_file {
    my $deps_file = '.deps';
    my $ivy_file = 'ivy.xml';
    my $ant_cmd = '/c/ant/bin/ant -f my-build.xml show-deps';

    my $deps_mtime = (-e $deps_file) ? (stat($deps_file))->mtime : 0;
    my $ivy_mtime = (-e $ivy_file) ? (stat($ivy_file))->mtime : 0;

    if ($deps_mtime > 0 && $deps_mtime > $ivy_mtime) {
        print "INFO: $deps_file is up to date relative to $ivy_file. Skipping ant execution.\n";
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

    log_info("Scanning source directories (" . join(', ', @src_dirs) . ") and webapp...");

    my $register = sub {
        my ($raw) = @_;
        return unless defined $raw;
        $raw =~ s#[\r\n\s]+##g;

        # Strict check: MUST be a dot-separated Java FQCN/package with at least 2 dots
        # e.g., 'com.ibm.db2' or 'org.hibernate.dialect.DB2Dialect'
        return unless $raw =~ /^[a-zA-Z][a-zA-Z0-9_]*\.[a-zA-Z0-9_]+\.[a-zA-Z0-9_\.]+/;

        # Filter out common false-positive non-Java patterns
        return if $raw =~ /^(http|https|ftp|mailto|www|com\.sun|org\.w3c\.dom)/i;
        return if $raw =~ /\.(xsd|xml|html|jsp|properties|png|jpg|gif|css|js)$/i;

        # 1. Register full raw reference
        $referenced_packages{$raw} = 1;

        # 2. Extract parent package if a capitalized ClassName is at the end
        # e.g., 'com.ibm.db2.jcc.DB2Driver' -> 'com.ibm.db2.jcc'
        my $pkg = $raw;
        if ($pkg =~ s#\.[A-Z][a-zA-Z0-9_]*$##) {
            $referenced_packages{$pkg} = 1;
        }
    };

    # 1. Scan ALL provided source directories
    if (@src_dirs) {
        find({
            wanted   => sub {
                my $file = $File::Find::name;
                return unless -f $file && $file =~ /\.(java|xml|properties|factories)$/i;
                open(my $fh, '<', $file) or return;
                while (my $line = <$fh>) {
                    # Standard & Static Java Imports
                    if ($line =~ /^\s*import\s+(?:static\s+)?([a-zA-Z0-9_\.\*]+)\s*;\s*$/) {
                        my $imp = $1;
                        if ($imp =~ /\*$/) {
                            $imp =~ s#\.\*$##;
                            $register->($imp);
                        }
                        else {
                            $register->($imp);
                        }
                    }

                    # 1. Reflection Calls: Class.forName("..."), loadClass("...")
                    while ($line =~ /(?:Class\.forName|loadClass)\s*\(\s*"([a-zA-Z0-9_\.]+)"\s*\)/g) {
                        $register->($1);
                    }

                    # 1.5 Class Literals (e.g., com.ibm.db2.jcc.DB2Driver.class or .class.getName())
                    while ($line =~ /([a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+)\.class\b/g) {
                        $register->($1);
                    }

                    # 2. Specific Class/Driver XML attributes (EXCLUDING generic name="")
                    while ($line =~ /(?:driverClassName|dialect|class|type|factory-method)="([a-zA-Z0-9_\.]+)"/g) {
                        $register->($1);
                    }

                    # 3. Log4j <Logger name="org.hibernate..."> specifically
                    while ($line =~ /<Logger\s+[^>]*?name="([a-zA-Z0-9_\.]+)"/g) {
                        $register->($1);
                    }

                    # 4. Quoted FQCN Literals in Java code, XML values, or properties
                    # Must contain at least TWO dots to avoid matching single package/bean names
                    while ($line =~ /"([a-zA-Z][a-zA-Z0-9_]*\.[a-zA-Z0-9_]+\.[a-zA-Z0-9_\.]+)"/g) {
                        $register->($1);
                    }
                }
                close($fh);
            },
            no_chdir => 1
        }, @src_dirs);
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
                        $register->($1);
                    }
                    if ($line =~ /%@\s*page\s+.*?import="([^"]+)"/) {
                        for my $imp (split /\s*,\s*/, $1) {
                            $imp =~ s#\.\*$##;
                            $register->($imp);
                        }
                    }
                }
                close($fh);
            },
            no_chdir => 1
        }, $webapp_dir);
    }

    log_success("Extracted " . (scalar keys %referenced_packages) . " unique package/class references.");
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
                next; # Skip standard libraries
            }

            if ($class =~ m{^\.\./}) {
                $unused_deps{$import} = 1;
            }
            else {
                $used_deps{$import} = 1;
            }
        }
    }

    return ($dependencies, {}); # Replace with actual return values
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

                    # If it appears multiple times, keep the highest version
                    if (!exists $dynamic_transitives{$root_parent}{$name} ||
                        version->parse(normalize_version($rev)) > version->parse(normalize_version($dynamic_transitives{$root_parent}{$name}))) {

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
    my ($deps_file, $surviving_deps_ref, $exclusions_ref, $global_excludes_ref, $update_ref) = @_;

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

                $stack[$depth] = $name;

                if ($depth > 0 && defined $stack[0]) {
                    my $root_parent = $stack[0];

                    next if exists $global_excludes_ref->{$name};
                    next if exists $global_excludes_ref->{"org:$org"};

                    # Check if this transitive dependency is overridden directly
                    if (exists $surviving_deps_ref->{$name} && $name ne $root_parent) {

                        # ------------------------------------------------------------------
                        # RULE: Only insert an <exclude> if the artifact/group name CHANGED!
                        # ------------------------------------------------------------------
                        my $needs_exclude = 0;

                        if (exists $update_ref->{$name}) {
                            my $update_entry = $update_ref->{$name};
                            my $new_org = $update_entry->{org} || $org;
                            my $new_name = $update_entry->{name} || $name;

                            # If Org or Module Name shifted (e.g. javax -> jakarta or commons-lang -> commons-lang3),
                            # Ivy won't evict it automatically, so an EXCLUDE is REQUIRED.
                            if ($new_org ne $org || $new_name ne $name) {
                                $needs_exclude = 1;
                            }
                        }

                        # If it's just a normal version bump for the same org & name,
                        # Ivy's latest-revision resolver evicts it automatically -> SKIP EXCLUDE!
                        next unless $needs_exclude;

                        $exclusions_ref->{$root_parent} ||= [];

                        my $already_excluded = 0;
                        for my $rule (@{$exclusions_ref->{$root_parent}}) {
                            if ((defined $rule->{module} && $rule->{module} eq $name) ||
                                (defined $rule->{name} && $rule->{name} eq $name)) {
                                $already_excluded = 1;
                                last;
                            }
                        }

                        if (!$already_excluded) {
                            push @{$exclusions_ref->{$root_parent}}, { module => $name };
                            log_info("Generated necessary exclusion for renamed artifact '$name' under '$root_parent'");
                        }
                    }
                }
            }
        }
    }
    close($fh);
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

                    my $exclusions_xml = generate_exclusion_xml($dep_exclusions, $current_dep_tag_indent . '    ');

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

    # 3. Ensure global exclusion for Bouncy Castle jdk15on is present at the end of <dependencies>
    if ($$file_content_ref !~ /<exclude\s+.*bouncycastle.*jdk15on"/) {
        my $exclude_xml = "${indentation}<exclude org=\"org.bouncycastle\" module=\".*-jdk15on\" matcher=\"regexp\" />";
        $$file_content_ref =~ s{(\s*</dependencies>)}{\n$exclude_xml$1};
        log_info("[GLOBAL EXCLUDE] Added exclusion for org.bouncycastle#*-jdk15on");
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

__END__
