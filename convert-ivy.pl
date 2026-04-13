#! /usr/bin/perl

use strict;
use warnings;
use Term::ANSIColor qw{:constants};
use version;    # provides version parsing and comparisons (not sure it is semver compatible)

my $ivy_file = "ivy.xml";
my $output_file = "ivy.xml.new";

my ($help,$hibernate5) = (0) x 2;

for my $arg (@ARGV) {
    my $key = lc($arg);
    $hibernate5 = 1 if $key eq "5";
}

my @remove_packages = (
    "commons-httpclient",
    "commons-logging",
    "commons-pool",
    "spring-asm",
    "spring-orm",
    "spring-core",
    "spring-data-commons",
    "hibernate-entitymanager",
    "hibernate-jpa-2.1-api",
    "httpmime",
    'jandex',
    "log4jdbc",
    "^powermock-",
    "easymock",
    "springfox-swagger2",
    "log4jdbc",
    "httpcore",
    "aopalliance",
    'jackson-.*-asl',
    'xml-api',
);

my $recommendations = {
    'esapi' => 'convert Query to use bind parameters and remove esapi dependency',
    'apereo' => 'convert to EmployeeFormBasedAuthForLDAP and remove apereo dependencies',
    'commons-lang' => 'convert all classes to use commons-lang3, try to remove commons-lang dependency',
};

my $springVersion = '6.2.17';
my $springSecurityVersion = '6.5.4';

my @keyOrder = ( "org", "module", "name" );

my $update = {
    # <!-- Spring -->
    "spring-beans"                             => { org => "org.springframework", name => "spring-beans", rev => $springVersion },
    "spring-context"                           => { org => "org.springframework", name => "spring-context", rev => $springVersion },
    "spring-context-support"                   => { org => "org.springframework", name => "spring-context-support", rev => $springVersion },
    "spring-expression"                        => { org => "org.springframework", name => "spring-expression", rev => $springVersion },
    "spring-jms"                               => { org => "org.springframework", name => "spring-jms", rev => $springVersion },
    "spring-messaging"                         => { org => "org.springframework", name => "spring-messaging", rev => $springVersion },
    "spring-test"                              => { org => "org.springframework", name => "spring-test", rev => $springVersion },
    "spring-tx"                                => { org => "org.springframework", name => "spring-tx", rev => $springVersion },
    "spring-jdbc"                              => { org => "org.springframework", name => "spring-jdbc", rev => $springVersion },
    "spring-data-jpa"                          => { org => "org.springframework.data", name => "spring-data-jpa", rev => "3.5.4" },
    "spring-web"                               => { org => "org.springframework", name => "spring-web", rev => $springVersion },
    "spring-webmvc"                            => { org => "org.springframework", name => "spring-webmvc", rev => $springVersion },
    "spring-websocket"                         => { org => "org.springframework", name => "spring-websocket", rev => $springVersion },
    "spring-aop"                               => { org => "org.springframework", name => "spring-aop", rev => $springVersion },
    "spring-security-core"                     => { org => "org.springframework.security", name => "spring-security-core", rev => "6.5.4" },
    "spring-security-crypto"                   => { org => "org.springframework.security", name => "spring-security-crypto", rev => $springSecurityVersion },
    "spring-security-web"                      => { org => "org.springframework.security", name => "spring-security-web", rev => $springSecurityVersion },
    "spring-security-config"                   => { org => "org.springframework.security", name => "spring-security-config", rev => $springSecurityVersion },
    "spring-security-oauth2-resource-server"   => { org => "org.springframework.security", name => "spring-security-oauth2-resource-server", rev => $springSecurityVersion },
    "spring-security-test"                     => { org => "org.springframework.security", name => "spring-security-test", rev => $springSecurityVersion },
    "spring-security-oauth2-jose"              => { org => "org.springframework.security", name => "spring-security-oauth2-jose", rev => $springSecurityVersion },
    # <!-- Miscellaneous -->
    "jcc"                                      => { org => "com.ibm.db2", name => "jcc", rev => "11.5.9.0" },
    "ojdbc8"                                   => { org => "com.oracle.database.jdbc", name => "ojdbc8", rev => "23.26.0.0.0" },
    "displaytag"                               => { org => "com.github.hazendaz", name => "displaytag", rev => "3.6.0" },
    "fop"                                      => { org => "org.apache.xmlgraphics", name => "fop", rev => "2.10" },
    "commons-collections4"                     => { org => "org.apache.commons", name => "commons-collections4", rev => "4.5.0" },
    "commons-lang3"                            => { org => "org.apache.commons", name => "commons-lang3", rev => "3.20.0" },
    "commons-beanutils"                        => { org => "commons-beanutils", name => "commons-beanutils", rev => "1.11.0" },
    "commons-dbcp2"                             => { org => "org.apache.commons", name => "commons-dbcp2", rev => "2.14.0" },
    "commons-io"                               => { org => "commons-io", name => "commons-io", rev => "2.20.0" },
    "javax.mail-api"                           => { org => "javax.mail", name => "javax.mail-api", rev => "1.5.5" },
    "javax.mail"                               => { org => "com.sun.mail", name => "javax.mail", rev => "1.5.5" },
    "joda-time"                                => { org => "joda-time", name => "joda-time", rev => "2.9.2" },
    "jaxen"                                    => { org => "jaxen", name => "jaxen", rev => "2.0.0" },
    # <!-- Logging -->
    "log4j-api"                                => { org => "org.apache.logging.log4j", name => "log4j-api", rev => "2.25.3" },
    "log4j-core"                               => { org => "org.apache.logging.log4j", name => "log4j-core", rev => "2.25.3" },
    "log4j-slf4j2-impl"                        => { org => "org.apache.logging.log4j", name => "log4j-slf4j2-impl", rev => "2.25.3" },
    "jcl-over-slf4j"                           => { org => "org.slf4j", name => "jcl-over-slf4j", rev => "2.0.17" },
    "slf4j-api"                                => { org => "org.slf4j", name => "slf4j-api", rev => "2.0.17" },
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
    "javax.activation"                         => { org => "com.sun.activation", name => "javax.activation", rev => "1.2.0" },
    "jaxb-api"                                 => { org => "javax.xml.bind", name => "jaxb-api", rev => "2.3.0" },
    "jaxb-core"                                => { org => "com.sun.xml.bind", name => "jaxb-core", rev => "2.3.0" },
    "jaxb-impl"                                => { org => "com.sun.xml.bind", name => "jaxb-impl", rev => "2.3.0" },
    "lombok"                                   => { org => "org.projectlombok", name => "lombok", rev => "1.18.38" },
    "javax.annotation-api"                     => { org => "javax.annotation", name => "javax.annotation-api", rev => "1.3.2" },
    "jakarta.annotation-api"                   => { org => "jakarta.annotation", name => "jakarta.annotation-api", rev=> "3.0.0" },
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
    "nimbus-jose-jwt"                          => { org => "com.nimbusds", name => "nimbus-jose-jwt", rev => "10.0.2" },
    # <!-- Other -->
    "poi"                                      => { org => "org.apache.poi", name => "poi", rev => "5.4.1" },
    "poi-ooxml"                                => { org => "org.apache.poi", name => "poi-ooxml", rev => "5.4.1" },
    "tika-core"                                => { org => "org.apache.tika", name => "tika-core", rev => "3.2.3" },
    "tika-parsers-standard-package"            => { org => "org.apache.tika", name => "tika-parsers-standard-package", rev => "3.2.3" },
    "tika-parser-sqlite3-package"              => { org => "org.apache.tika", name => "tika-parser-sqlite3-package", rev => "3.2.3" },

    # OTHER OTHER
    "jackson-annotations"                      => { org => "com.fasterxml.jackson.core", name => "jackson-annotations", rev => "2.21" },
    "jackson-core"                             => { org => "com.fasterxml.jackson.core", name => "jackson-core", rev => "2.21.2" },
    "jackson-databind"                         => { org => "com.fasterxml.jackson.core", name => "jackson-databind", rev => "2.21.2" },
    "jackson-datatype-jsr310"                  => { org => "com.fasterxml.jackson.datatype", name => "jackson-datatype-jsr310", rev => "2.21.2" },
    "jackson-datatype-json-org"                => { org => "com.fasterxml.jackson.datatype", name => "jackson-datatype-json-org", rev => "2.21.2" },
    "itextpdf"                                 => { org => "com.itextpdf", name => "itextpdf", rev => "5.5.13.3" },
    "commons-codec"                            => { org => "commons-codec", name => "commons-codec", rev => "1.14" },
    "jakarta.xml.soap-api"                     => { org => "jakarta.xml.soap", name => "jakarta.xml.soap-api", rev => "2.0.1" },
    "jaxws-api"                                => { org => "javax.xml.ws", name => "jaxws-api", rev => "2.3.0" },
    "commons-fileupload2-jakarta-servlet"      => { org => "org.apache.commons", name => "commons-fileupload2-jakarta-servlet", rev => "2.0.0-M4" },
    "httpmime"                                 => { org => "org.apache.httpcomponents", name => "httpmime", rev => "4.5.13" },
    "httpclient5"                              => { org => "org.apache.httpcomponents.client5", name => "httpclient5", rev => "5.5.1" },
    "httpclient5-cache"                        => { org => "org.apache.httpcomponents.client5", name => "httpclient5-cache", rev => "5.5.1" },
    "xmlbeans"                                 => { org => "org.apache.xmlbeans", name => "xmlbeans", rev => "3.0.0" },
    "hibernate-commons-annotations"            => { org => "org.hibernate.common", name => "hibernate-commons-annotations", rev => "5.1.1.Final" },
    "encoder"                                  => { org => "org.owasp.encoder", name => "encoder", rev => "1.3.1" },
    "slf4j-log4j12"                            => { org => "org.slf4j", name => "slf4j-log4j12", rev => "1.7.34" },
    "slf4j-reload4j"                           => { org => "org.slf4j", name => "slf4j-reload4j", rev => "2.0.1" },
    "jakarta.validation-api"                   => { org => "jakarta.validation", name => "jakarta.validation-api", rev => "3.0.2" },
    "esapi"                                    => { org => "org.owasp.esapi", name => "esapi", rev => "2.7.0.0" },

    # current versions just to help convert old build.xml projects to ivy.xml
    "jta"                                      => { org => "javax.transaction", name => "jta", rev => "1.1" },
    "jsch"                                     => { org => "com.jcraft", name => "jsch", rev => "0.1.54" },
    
    # ehcache
    "cache-api"                                => { org => "javax.cache", name => "cache-api", rev => "1.1.1" },
    "ehcache"                                  => { org => "org.ehcache", name => "ehcache", rev => "3.11.1" },
    "jaxb-runtime"                             => { org => "org.glassfish.jaxb", name => "jaxb-runtime", rev => "4.0.5" },
};

if ($hibernate5) {
    $update->{"hibernate-core-jakarta"}                   = { org => "org.hibernate", name => "hibernate-core-jakarta", rev => "5.6.15.Final" };
    $update->{"hibernate-jpamodelgen"}                    = { org => "org.hibernate", name => "hibernate-jpamodelgen", rev => "5.6.15.Final" };
    push @remove_packages, "hibernate-community-dialects";
} else {
    $update->{"hibernate-core"}                           = { org => "org.hibernate.orm", name => "hibernate-core", rev => "6.6.36.Final" };
    $update->{"hibernate-jpamodelgen"}                    = { org => "org.hibernate.orm", name => "hibernate-jpamodelgen", rev => "6.6.36.Final" };
    $update->{"hibernate-community-dialects"}             = { org => "org.hibernate.orm", name => "hibernate-community-dialects", rev => "6.6.45.Final" };
}

# replaced packages
$update->{"commons-lang"} = $update->{"commons-lang3"};
$update->{"commons-dbcp"} = $update->{"commons-dbcp2"};
$update->{"commons-collections"} = $update->{"commons-collections4"};
$update->{"commons-fileupload"} = $update->{"commons-fileupload2-jakarta-servlet"};
$update->{"encoder-jsp"} = $update->{"encoder-jakarta-jsp"};
if ($hibernate5) {
    $update->{"hibernate-core"} = $update->{"hibernate-core-jakarta"};
} else {
    $update->{"hibernate-core-jakarta"} = $update->{"hibernate-core"};
}
$update->{"httpclient"} = $update->{"httpclient5"};
$update->{"httpclient-cache"} = $update->{"httpclient5-cache"};
$update->{"javax.servlet-api"} = $update->{"jakarta.servlet-api"};
$update->{"javax.servlet.jsp-api"} = $update->{"jakarta.servlet.jsp-api"};
$update->{"jsp-api"} = $update->{"jakarta.servlet.jsp-api"};
$update->{"mockito-all"} = $update->{"mockito-core"};
$update->{"log4j"} = $update->{"log4j-core"};
$update->{"log4j-slf4j-impl"} = $update->{"log4j-slf4j2-impl"};
$update->{"mail"} = $update->{"javax.mail-api"};
$update->{"displaytag-portlet"} = $update->{"displaytag"};
$update->{"javax.xml.soap-api"} = $update->{"jakarta.xml.soap-api"};
$update->{"validation-api"} = $update->{"jakarta.validation-api"};
$update->{"jstl"} = $update->{"jakarta.servlet.jsp.jstl"};
$update->{"db2jcc"} = $update->{"jcc"};
$update->{"db2jcc4"} = $update->{"jcc"};

my $add_if_missing = {
    "javax.servlet.jsp" => [
        "jakarta.servlet.jsp-api",
    ],
    "jakarta.servlet.jsp-api" => [
        "jakarta.servlet.jsp.jstl",
    ],
    "jstl" => [
        "jakarta.servlet.jsp.jstl-api",
    ],
    "jakarta.servlet.jsp.jstl" => [
        "jakarta.servlet.jsp.jstl-api",
    ],
    "jaxb-api" => [
        "jaxb-core",
        "jaxb-impl",
    ],
    "cas-client-core" => [
        "nimbus-jose-jwt",
    ],
    "mockito-all" => [
        "byte-buddy-agent",
    ],
    "mockito-core" => [
        "byte-buddy-agent",
    ],
    "ehcache" => [
        "jaxb-runtime",
    ],
};

$add_if_missing->{$hibernate5 ? "hibernate-core-jakarta" : "hibernate-core" } = [
            "dom4j",
            "byte-buddy",
            "jakarta.persistence-api",
            "jakarta.transaction-api",
        ];

my $keep_if_exists = {
    "commons-lang" => "commons-lang3",
    "httpclient" => "httpclient5",
    "httpcore" => "httpclient5",
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
    "ehcache"                       => [
        { org => "org.glassfish.jaxb" },
    ],
};

my @packages;

my $file_content;
open(my $in, "<", $ivy_file)
    or die "Error: could not open '$ivy_file': $!";
{
    local $/;
    $file_content = <$in>;
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
    elsif (exists $keep_if_exists->{$dep_name} && grep { $keep_if_exists->{$dep_name} eq $_ } @packages) {
        warn BOLD YELLOW "Keep $dep_name" . RESET . "\n";
        $replacement_str = $leading_whitespace . $dependency_block;
    }
    elsif (grep { $dep_name =~ $_ } @remove_packages) {
        warn BOLD CYAN "Remove $dep_name" . RESET . "\n";
    }
    elsif (grep { $dep_name eq $_ } @packages) {
        warn BOLD YELLOW "Remove duplicate dependency $dep_name" . RESET . "\n";
    }
    else {
        push @packages, $dep_name;                # keep list of dependencies we have found

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
                warn BOLD RED "Could not parse version for $dep_org:$dep_name. Current='$current_v_norm', Proposed='$new_v_norm'" .
                                RESET . "\n";
                $should_keep_rev = 1;
            }

            my $update_dep_name = $update_entry_ref->{name} || $dep_name;
            my $is_package_name_changing = ($update_entry_ref->{org} ne $dep_org || $update_dep_name ne $dep_name);
            if (defined $current_rev && !$is_package_name_changing && !$should_keep_rev) {
                if ($current_v gt $new_v) {
                    warn BOLD YELLOW "Keep current rev for $dep_org:$dep_name: $current_rev" . RESET . "\n";
                    $should_keep_rev = 1;
                }
            }

            if (!$should_keep_rev) {
                foreach my $key (keys %$update_entry_ref) {
                    my $new_val = $update_entry_ref->{$key};
                    $new_val = $current_rev if $key eq 'rev' && $should_keep_rev;

                    if ($modified_dependency_block =~ s/\b$key="([^"]*)"/$key="$new_val"/i) {
                        # Attribute was updated
                        warn BOLD GREEN "Update $dep_name:$key to $new_val" . RESET . "\n" unless $1 eq $new_val;
                    }
                    else {
                        warn BOLD YELLOW "$dep_org,$dep_name attempting to add missing $key attribute" . RESET . "\n";
                        if ($modified_dependency_block =~ s# /># $key="$new_val" />#) {
                            # Attribute was added
                        } else {
                            warn BOLD RED "unable to add $key attribute" . RESET ."\n";
                        }
                    }
                }
            }

            if (exists $recommendations->{$dep_name}) {
                warn BOLD MAGENTA $recommendations->{$dep_name} . RESET . "\n"
            }
        }

        my $dep_exclusions = $exclusions->{$dep_name} || $exclusions->{"$dep_org,$dep_name"};
        if (defined $dep_exclusions) {
            # remove existing exclusions
            warn BOLD YELLOW "Removed old exclusions for $dep_name" . RESET . "\n"
                if ($modified_dependency_block =~ s{\s*<exclude\s+(?:[^>]*?)\s*/>}{}gsi);              # Self-closing
            warn BOLD YELLOW "Removed old exclusions for $dep_name" . RESET . "\n"
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
                    warn BOLD RED "Warning: Could not find suitable place to insert exclusions for $dep_org,$dep_name" . RESET . "\n";
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

                warn BOLD MAGENTA "Add missing $trigger_pkg_name dependency $name" . RESET . "\n";
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
                    warn BOLD BLUE "Adding exclusion: " . $attribute."=".$rule->{$attribute}.RESET."\n";
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
    my $ver_str= shift;

    if ($ver_str) {
        $ver_str =~ s/([.-])([A-Za-z][\w+]*)/_\L$2/g;
        # remove syntactic sugar and hope for the best
        $ver_str =~ s/_\w+$//;
        # add missing 'v' at front of version string
        $ver_str = "v".$ver_str unless $ver_str =~ m/^v/;
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

__END__
