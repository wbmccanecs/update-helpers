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

if ($audit_deps) {
    my $libdir = (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';
    my @src_dirs = ('src', 'test');
    push @src_dirs, "../mgic_business/src" if -e "$libdir/mgic-business.jar";
    push @src_dirs, "../mgic_common/src" if -e "$libdir/mgic-common.jar";
    push @src_dirs, "../mgic_entity/src" if -e "$libdir/mgic-entity-custom.jar" || -e "$libdir/mgic-entity-master.jar";
    push @src_dirs, "../mgic_persistence/src" if -e "$libdir/mgic-persistence.jar";

    %unused_deps_to_drop = get_unused_direct_dependencies(\@src_dirs, $libdir);
}

my @remove_packages = (
    "commons-httpclient",
    "commons-logging",
    "commons-pool",
    "spring-asm",
    "spring-orm",
    "spring-data-commons",
    "hibernate-entitymanager",
    "hibernate-jpa-2.1-api",
    "httpmime",
    'jandex',
    "jaxb-core",
    "jaxb-impl",
    "log4jdbc",
    "^powermock-",
    "easymock",
    "springfox-swagger2",
    "httpcore",
    "aopalliance",
    'jackson-.*-asl',
    'xml-api',
    'taglibs-standard-impl',
    "javax.jms-api",
    "jakarta.jms-api",
    "hibernate-annotations",
    "javax.activation",
    "spring-jdbc",
);

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
    "ojdbc8"                                   => { org => "com.oracle.database.jdbc", name => "ojdbc8", rev => "23.26.0.0.0" },
    "displaytag"                               => { org => "com.github.hazendaz", name => "displaytag", rev => "3.6.0" },
    "fop"                                      => { org => "org.apache.xmlgraphics", name => "fop", rev => "2.10" },
    "commons-collections4"                     => { org => "org.apache.commons", name => "commons-collections4", rev => "4.5.0" },
    "commons-lang3"                            => { org => "org.apache.commons", name => "commons-lang3", rev => "3.20.0" },
    "commons-text"                             => { org => "org.apache.commons", name => "commons-text", rev => "1.15.0" },
    "commons-beanutils"                        => { org => "commons-beanutils", name => "commons-beanutils", rev => "1.11.0" },
    "commons-dbcp2"                            => { org => "org.apache.commons", name => "commons-dbcp2", rev => "2.14.0" },
    "commons-io"                               => { org => "commons-io", name => "commons-io", rev => "2.22.0" },
    "angus-mail"                               => { org => "org.eclipse.angus", name => "angus-mail", rev => "2.1.0-M1" },
    "joda-time"                                => { org => "joda-time", name => "joda-time", rev => "2.14.0" },
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
    "mockito-core"                             => { org => "org.mockito", name => "mockito-core", rev => "5.19.0", conf => "compile->default" },
    # <!-- WEB RUNTIME -->
    "encoder-jakarta-jsp"                      => { org => "org.owasp.encoder", name => "encoder-jakarta-jsp", rev => "1.3.1" },
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
    "nimbus-jose-jwt"                          => { org => "com.nimbusds", name => "nimbus-jose-jwt", rev => "10.9" },
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
    "itextpdf"                                 => { org => "com.itextpdf", name => "itextpdf", rev => "5.5.13.4" },
    "itext-pdfa"                               => { org => "com.itextpdf", name => "itext-pdfa", rev => "5.5.13.4" },
    "itext-xtra"                               => { org => "com.itextpdf", name => "itext-xtra", rev => "5.5.13.4" },
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
    "jakarta.validation-api"                   => { org => "jakarta.validation", name => "jakarta.validation-api", rev => "3.0.2" },
    "esapi"                                    => { org => "org.owasp.esapi", name => "esapi", rev => "2.7.0.0" },

    # current versions just to help convert old build.xml projects to ivy.xml
    "jsch"                                     => { org => "com.jcraft", name => "jsch", rev => "0.1.54" },

    # ehcache
    "cache-api"                                => { org => "javax.cache", name => "cache-api", rev => "1.1.1" },
    "ehcache"                                  => { org => "org.ehcache", name => "ehcache", rev => "3.12.0" },
    "jaxb-runtime"                             => { org => "org.glassfish.jaxb", name => "jaxb-runtime", rev => "4.0.5" },

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

my $add_if_missing = {
    "javax.servlet.jsp"        => [
        "jakarta.servlet.jsp-api",
    ],
    "jakarta.servlet.jsp-api"  => [
        "jakarta.servlet.jsp.jstl",
    ],
    "jstl"                     => [
        "jakarta.servlet.jsp.jstl-api",
    ],
    "jakarta.servlet.jsp.jstl" => [
        "jakarta.servlet.jsp.jstl-api",
    ],
    "cas-client-core"          => [
        "nimbus-jose-jwt",
    ],
    "mockito-all"              => [
        "byte-buddy-agent",
    ],
    "mockito-core"             => [
        "byte-buddy-agent",
    ],
    "ehcache"                  => [
        "jaxb-runtime",
    ],
    "angus-mail"               => [
        "log4j-jakarta-smtp",
    ],
};

my $keep_if_exists = {
    "commons-lang" => "commons-lang3",
    "httpclient"   => "httpclient5",
    "httpcore"     => "httpclient5",
};

my $exclusions = {
    "cas-client-core"               => [
        { org => "org.bouncycastle", name => "bcprov-jdk15on" },
        { org => "com.nimbusds" },
    ],
    "mockito-core"                  => [
        { org => "net.bytebuddy" },
    ],
    "poi"                           => [
        { module => "log4j-api" },
    ],
    "poi-ooxml"                     => [
        { module => "log4j-api" },
    ],
    "tika-core"                     => [
        { org => "org.slf4j" },
    ],
    "tika-parsers-standard-package" => [
        { org => "org.gagravarr" },
        { org => "org.slf4j" },
        { org => "com.github.junrar" },
    ],
    "tika-parser-sqlite3-package"   => [],
    "ignite-indexing"               => [
        { org => "com.h2database", }
    ],
};

my $remove_redundant_transitives_versioned = {
    'angus-mail'             => {
        'jakarta.mail-api'     => '2.2.0-M1',
        'angus.activation-api' => '2.2.0-M1',
    },
    'hibernate-core'         => {
        'byte-buddy'              => '1.17.5',
        'jakarta.persistence-api' => '3.1.0',
        'jakarta.transaction-api' => '2.0.1',
        'jakarta.xml.bind-api'    => '4.0.2',
        'jaxb-runtime'            => '4.0.5',
        'antlr'                   => '4.13.0',
    },
    'hibernate-core-jakarta' => {
        'antlr'                   => '2.7.7',
        'byte-buddy'              => '1.12.18',
        'jakarta.persistence-api' => '3.0.0',
        'jakarta.transaction-api' => '2.0.0',
    },
};

my @packages;

my $file_content;
open(my $in, "<", $ivy_file)
    or die "Error: could not open '$ivy_file': $!";
{
    local $/;
    $file_content = <$in>;
}

update_deps_file();

# Pre-scan file to track top-level dependencies
my %present_deps;
while ($file_content =~ /<dependency\s+(?:[^>]*?\s+)?name="([^"]+)"/g) {
    $present_deps{$1} = 1;
}

# get rid of sources configuration
$file_content =~ s#;sources->sources##g;

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
        print BOLD YELLOW "Keep $dep_name" . RESET . "\n";
        $replacement_str = $leading_whitespace . $dependency_block;
    }
    elsif (should_remove_transitive($dep_name, $current_rev, \%present_deps)) {
        print BOLD CYAN "Remove redundant transitive $dep_name (rev '$current_rev' is <= required override version)" . RESET . "\n";
    }
    elsif (grep {$dep_name =~ $_} @remove_packages) {
        print BOLD CYAN "Remove $dep_name" . RESET . "\n";
    }
    elsif ($audit_deps && $unused_deps_to_drop{$dep_name}) {
        print BOLD CYAN "Remove unused dependency $dep_name (no active imports in src/)" . RESET . "\n";
        # Format the comment to match current indentation
        #        my $indent = $leading_whitespace;
        #        $indent =~ s/.*\n//s; # Keep only the trailing spaces on the last line
        #        $replacement_str = "\n" . $indent . "<!-- [AUDIT] Removed '$dep_name': No active Java imports found in src/ -->";
    }
    elsif (grep {$dep_name eq $_} @packages) {
        print BOLD YELLOW "Remove duplicate dependency $dep_name" . RESET . "\n";
    }
    else {
        push @packages, $dep_name; # keep list of dependencies we have found

        my $modified_dependency_block = $dependency_block;

        my $update_entry_ref = $update->{$dep_name};
        if (defined $update_entry_ref) {
            $update_entry_ref->{"conf"} = 'runtime->default' unless $update_entry_ref->{"conf"};
            my $should_keep_rev = 0;
            my $new_rev_candidate = $update_entry_ref->{rev};

            my ($current_v, $new_v);
            my $current_v_norm = normalize_version($current_rev);
            my $new_v_norm = normalize_version($new_rev_candidate);
            eval {
                $current_v = version->parse($current_v_norm);
                $new_v = version->parse($new_v_norm);
            };
            if ($@) {
                print BOLD RED "Could not parse version for $dep_org:$dep_name. Current='$current_v_norm', Proposed='$new_v_norm'" .
                    RESET . "\n";
                $should_keep_rev = 1;
            }

            my $update_dep_name = $update_entry_ref->{name} || $dep_name;
            my $is_package_name_changing = ($update_entry_ref->{org} ne $dep_org || $update_dep_name ne $dep_name);
            if (defined $current_rev && !$is_package_name_changing && !$should_keep_rev) {
                if ($current_v gt $new_v) {
                    print BOLD YELLOW "Keep current rev for $dep_org:$dep_name: $current_rev" . RESET . "\n";
                    $should_keep_rev = 1;
                }
            }

            if (!$should_keep_rev) {
                foreach my $key (keys %$update_entry_ref) {
                    my $new_val = $update_entry_ref->{$key};
                    $new_val = $current_rev if $key eq 'rev' && $should_keep_rev;

                    if ($modified_dependency_block =~ s/\b$key="([^"]*)"/$key="$new_val"/i) {
                        # Attribute was updated
                        print BOLD GREEN "Update $dep_name:$key to $new_val" . RESET . "\n" unless $1 eq $new_val;
                    }
                    else {
                        print BOLD YELLOW "$dep_org,$dep_name attempting to add missing $key attribute" . RESET . "\n";
                        if ($modified_dependency_block =~ s# /># $key="$new_val" />#) {
                            # Attribute was added
                        }
                        else {
                            print BOLD RED "unable to add $key attribute" . RESET . "\n";
                        }
                    }
                }
            }

            if (exists $recommendations->{$dep_name}) {
                print BOLD MAGENTA $recommendations->{$dep_name} . RESET . "\n"
            }
        }

        my $dep_exclusions = $exclusions->{$dep_name} || $exclusions->{"$dep_org,$dep_name"};
        if (defined $dep_exclusions) {
            # remove existing exclusions
            print BOLD YELLOW "Removed old exclusions for $dep_name" . RESET . "\n"
                if ($modified_dependency_block =~ s{\s*<exclude\s+(?:[^>]*?)\s*/>}{}gsi); # Self-closing
            print BOLD YELLOW "Removed old exclusions for $dep_name" . RESET . "\n"
                if ($modified_dependency_block =~ s{\s*<exclude\s+(?:[^>]*?)>(?:.*?)</exclude>}{}gsi); # Opening/closing tags

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
                else {
                    print BOLD RED "Warning: Could not find suitable place to insert exclusions for $dep_org,$dep_name" . RESET . "\n";
                    $modified_dependency_block .= "\n" . $new_exclusions;
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

my @insertions_to_apply = ();
for my $trigger_pkg_name (keys %$add_if_missing) {
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

    if ($file_content =~ m/(.*?)($trigger_dep_block_regex)/s) {
        my $match_end_offset = length($1) + length($2);
        my $matched_trigger_block = $2;

        my $trigger_base_indent = '';
        if ($matched_trigger_block =~ s{^(\s*)}{ $trigger_base_indent = $1;
            ''}se) {
            my @lines = split(/\r?\n/, $trigger_base_indent);
            if (@lines > 0) {
                if ($lines[-1] =~ /^(\s*)/) {
                    $trigger_base_indent = $1;
                }
            }
        }

        my $trigger_deps = $add_if_missing->{$trigger_pkg_name};
        my $xml_to_insert = '';

        for my $pkg (@$trigger_deps) {
            my $dep = $update->{$pkg};

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

            if ($file_content !~ $exists_regex) {
                my $current_dep_tag_indent = $trigger_base_indent;
                my $dep_exclusions = $exclusions->{$name} || $exclusions->{"$org,$name"};

                my $exclusions_xml = generate_exclusion_xml($dep_exclusions, $current_dep_tag_indent . '    ');

                my $new_dep_xml;
                my $conf = $dep->{conf} || 'runtime->default';
                if (length $exclusions_xml > 0) {
                    $new_dep_xml = qq!\n$current_dep_tag_indent<dependency org="$org" name="$name" rev="$dep->{rev}" conf="$conf">$exclusions_xml$current_dep_tag_indent</dependency>!;
                }
                else {
                    $new_dep_xml = qq!\n$current_dep_tag_indent<dependency org="$org" name="$name" rev="$dep->{rev}" conf="$conf" />!;
                }

                print BOLD MAGENTA "Add missing $trigger_pkg_name dependency $name" . RESET . "\n";
                $xml_to_insert .= $new_dep_xml;
            }
        }

        if (length $xml_to_insert > 0) {
            push @insertions_to_apply, { pos => $match_end_offset, text => $xml_to_insert };
        }
    }
}

# have to apply in reverse order to preserve positional integrity
@insertions_to_apply = sort {$b->{pos} <=> $a->{pos}} @insertions_to_apply;

foreach my $insertion (@insertions_to_apply) {
    substr($file_content, $insertion->{pos}, 0) = $insertion->{text};
}

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
                    print BOLD BLUE "Adding exclusion: " . $attribute . "=" . $rule->{$attribute} . RESET . "\n";
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

sub should_remove_transitive {
    my ($dep_name, $current_rev, $present_deps_ref) = @_;
    return 0 unless defined $current_rev;

    for my $parent_pkg (keys %$remove_redundant_transitives_versioned) {
        # Only check if the parent dependency (e.g., hibernate-core) is present in the file
        if (exists $present_deps_ref->{$parent_pkg}) {
            my $targets = $remove_redundant_transitives_versioned->{$parent_pkg};

            if (exists $targets->{$dep_name}) {
                my $max_version_str = $targets->{$dep_name};

                my ($curr_v, $max_v);
                eval {
                    $curr_v = version->parse(normalize_version($current_rev));
                    $max_v = version->parse(normalize_version($max_version_str));
                };

                if ($@) {
                    print BOLD RED "Version parse error comparing $dep_name ($current_rev vs $max_version_str)" . RESET . "\n";
                    return 0; # On error, safely keep the dependency
                }

                # If current version is less than or equal to threshold, mark for removal
                if ($curr_v <= $max_v) {
                    return 1;
                }
                else {
                    print BOLD GREEN "Keeping direct dependency $dep_name ($current_rev > $max_version_str) assumed Snyk override" . RESET . "\n";
                    return 0;
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

    print BOLD CYAN "INFO: Generating $deps_file from Ant show-deps target..." . RESET . "\n";

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
                my $leading_prefix = $1; # Everything BEFORE the '+-' or '\-'

                # Direct dependencies have 0 leading characters before '+-' / '\-'
                # 1st-Gen Transitives have 1 to 3 leading characters (e.g. '|  ', '   ', '\  ')
                # 2nd-Gen+ Transitives have 4 or more leading characters (e.g. '|  |  ')

                if (length($leading_prefix) <= 3) {
                    # Retain raw line with its native Ivy indentation
                    push @filtered_lines, $content . "\n";
                }
            }
        }
        elsif ($line =~ /Target "show-deps" does not exist/) {
            print BOLD RED "update my-build.xml" . RESET . "\n";
            return;
        }
    }
    close($ant_fh);

    open(my $deps_out, '>', $deps_file) or die "Could not write to $deps_file: $!\n";
    print $deps_out @filtered_lines;
    close($deps_out);

    if (!(stat($deps_file))->size) {
        print BOLD RED "FAILURE: could not generate " . $deps_file . RESET . "\n";
    }
    else {
        print BOLD GREEN "SUCCESS: Updated $deps_file with direct and 1st-generation dependencies." . RESET . "\n";
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

    print BOLD CYAN "Scanning source directories (" . join(', ', @src_dirs) . ") and webapp..." . RESET . "\n";

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

    print BOLD GREEN "Extracted " . (scalar keys %referenced_packages) . " unique package/class references." . RESET . "\n";
    return %referenced_packages;
}

sub get_unused_direct_dependencies {
    my ($src_dirs_ref, $lib_dir, $webapp_dir, $ivy_file) = @_;
    $lib_dir ||= (-e 'war/WEB-INF/lib') ? 'war/WEB-INF/lib' : 'lib';
    $webapp_dir ||= "war";
    $ivy_file ||= "ivy.xml";

    # 1. Normalize source directories to an array and filter existing ones
    my @src_dirs = ref($src_dirs_ref) eq 'ARRAY' ? @{$src_dirs_ref} : ($src_dirs_ref);
    @src_dirs = grep {defined $_ && -d $_} @src_dirs;

    my %unused_map;
    print BOLD CYAN "--- AUDITING DIRECT DEPENDENCIES ---" . RESET . "\n";

    # Ensure we have at least one valid source directory and a valid lib directory
    unless (@src_dirs && -d $lib_dir) {
        print BOLD RED "Error: No valid source or library directories found." . RESET . "\n";
        return %unused_map;
    }

    # 2. Collect only the dependency names declared in ivy.xml
    my %declared_deps = get_declared_ivy_dependencies($ivy_file);

    # 3. Extract package references across all valid source directories & webapp
    my %used_packages = extract_all_referenced_packages(\@src_dirs, $webapp_dir);
    my @jars = glob("$lib_dir/*.jar");

    for my $jar_file (@jars) {
        my ($filename) = $jar_file =~ m{([^/]+)\.jar$};

        # Derive dependency name from jar file name (e.g., spring-context-6.2.19 -> spring-context)
        my $dep_name = $filename;
        $dep_name =~ s/-\d+.*$//;

        # OPTIMIZATION: Skip jar tf unless directly declared in ivy.xml
        next unless exists $declared_deps{$dep_name};

        my %jar_packages;
        open(my $jar_fh, "jar tf \"$jar_file\" 2>&1 |") or next;
        while (my $entry = <$jar_fh>) {
            $entry =~ s#[\r\n]+##g;
            next unless $entry =~ /\.class$/ && $entry !~ /^META-INF/;

            my $fqcn = $entry;
            $fqcn =~ s#\.class$##;
            $fqcn =~ s#/#.#g;
            $fqcn =~ s#\$.*$##; # Strip inner class designations ($1, etc.)

            $jar_packages{$fqcn} = 1;

            my $pkg = $fqcn;
            if ($pkg =~ s#\.[A-Z][a-zA-Z0-9_]*$##) {
                $jar_packages{$pkg} = 1;
            }
        }
        close($jar_fh);

        # Cross-reference JAR classes against all captured project packages
        my $is_used = 0;
        FOR_ITEM:
        for my $jar_pkg (keys %jar_packages) {
            if (exists $used_packages{$jar_pkg}) {
                $is_used = 1;
                last FOR_ITEM;
            }
            for my $ref_pkg (keys %used_packages) {
                if ($ref_pkg eq $jar_pkg || $ref_pkg =~ /^\Q$jar_pkg\E\./ || $jar_pkg =~ /^\Q$ref_pkg\E\./) {
                    $is_used = 1;
                    last FOR_ITEM;
                }
            }
        }

        if (!$is_used) {
            $unused_map{$dep_name} = 1;
        }
    }

    my $count = scalar keys %unused_map;
    print BOLD GREEN "SUCCESS: Audit complete. Found $count candidate direct dependencies to prune." . RESET . "\n";

    return %unused_map;
}

__END__
