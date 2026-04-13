#! /usr/bin/perl

use strict;
use warnings;
use version;	# provides version parsing and comparisons (not sure it is semver compatible)

my $ivy_file = "ivy.xml";
my $output_file = "ivy.xml.new";

my @remove_packages = (
    "commons-logging",
    "hibernate-entitymanager",
    "hibernate-jpa-2.1-api",
    "log4jdbc",
    "^powermock-",
    "spring-orm",
);

my $springVersion = '6.2.8';

my @keyOrder = ( "org", "module", "name", "rev", "conf" );

my $update = {
    "byte-buddy"                               => { org => "net.bytebuddy", name => "byte-buddy", rev => "1.8.22" },
    "cas-client-core"                          => { org => "org.apereo.cas.client", name => "cas-client-core", rev => "4.0.4" },
    "commons-beanutils"                        => { org => "commons-beanutils", name => "commons-beanutils", rev => "1.11.0" },
    "commons-codec"                            => { org => "commons-codec", name => "commons-codec", rev => "1.14" },
    "commons-collections4"                     => { org => "org.apache.commons", name => "commons-collections4", rev => "4.5.0" },
    "commons-dbcp"                             => { org => "commons-dbcp", name => "commons-dbcp", rev => "1.4" },
    "commons-fileupload2-jakarta-servlet6"     => { org => "org.apache.commons", name => "commons-fileupload2-jakarta-servlet6", rev => "2.0.0-M4" },
    "commons-io"                               => { org => "commons-io", name => "commons-io", rev => "2.18.0" },
    "commons-lang"                             => { org => "commons-lang", name => "commons-lang", rev => "2.6" },
    "commons-pool"                             => { org => "commons-pool", name => "commons-pool", rev => "1.6" },
    "displaytag"                               => { org => "com.github.hazendaz", name => "displaytag", rev => "3.0.3" },
    "dom4j"                                    => { org => "org.dom4j", name => "dom4j", rev => "2.1.4" },
    "encoder"                                  => { org => "org.owasp.encoder", name => "encoder", rev => "1.3.1" },
    "encoder-jakarta-jsp"                      => { org => "org.owasp.encoder", name => "encoder-jakarta-jsp", rev => "1.3.1" },
    "hibernate-commons-annotations"            => { org => "org.hibernate.common", name => "hibernate-commons-annotations", rev => "5.1.1.Final" },
    "hibernate-core-jakarta"                   => { org => "org.hibernate", name => "hibernate-core-jakarta", rev => "5.6.15.Final" },
    "hibernate-jpamodelgen"                    => { org => "org.hibernate", name => "hibernate-jpamodelgen", rev => "5.6.15.Final" },
    "hibernate-validator"                      => { org => "org.hibernate", name => "hibernate-validator", rev => "8.0.0.Final" },
    "hibernate-validator-annotation-processor" => { org => "org.hibernate", name => "hibernate-validator-annotation-processor", rev => "5.4.3.Final" },
    "httpclient5"			       => { org => "org.apache.httpcomponents.client5", name => "httpclient5", rev => "5.4.3" },
    "httpmime"                                 => { org => "org.apache.httpcomponents", name => "httpmime", rev => "4.5.13" },
    "itextpdf"                                 => { org => "com.itextpdf", name => "itextpdf", rev => "5.5.12" },
    "jackson-core"                             => { org => "com.fasterxml.jackson.core", name => "jackson-core", rev => "2.18.1" },
    "jackson-databind"                         => { org => "com.fasterxml.jackson.core", name => "jackson-databind", rev => "2.18.1" },
    "jakarta.persistence-api"                  => { org => "jakarta.persistence", name => "jakarta.persistence-api", rev => "3.2.0" },
    "jakarta.servlet.jsp.jstl"                 => { org => "org.glassfish.web", name => "jakarta.servlet.jsp.jstl", rev => "3.0.1", conf => "compile->default" },
    "jakarta.servlet.jsp.jstl-api"             => { org => "jakarta.servlet.jsp.jstl", name => "jakarta.servlet.jsp.jstl-api", rev => "3.0.2" },
    "jakarta.servlet.jsp-api"                  => { org => "jakarta.servlet.jsp", name => "jakarta.servlet.jsp-api", rev => "4.0.0", conf => 'compile->default' },
    "jakarta.servlet-api"                      => { org => "jakarta.servlet", name => "jakarta.servlet-api", rev => "6.0.0", conf => 'compile->default' },
    "jakarta.transaction-api"                  => { org => "jakarta.transaction", name => "jakarta.transaction-api", rev => "2.0.1" },
    "jakarta.xml.soap-api"                     => { org => "jakarta.xml.soap", name => "jakarta.xml.soap-api", rev => "2.0.1" },
    "javax.activation"                         => { org => "com.sun.activation", name => "javax.activation", rev => "1.2.0" },
    "javax.annotation-api"                     => { org => "javax.annotation", name => "javax.annotation-api", rev => "1.3.2" },
    "javax.mail"                               => { org => "com.sun.mail", name => "javax.mail", rev => "1.5.5" },
    "javax.mail-api"                           => { org => "javax.mail", name => "javax.mail-api", rev => "1.5.5" },
    "jaxb-api"                                 => { org => "javax.xml.bind", name => "jaxb-api", rev => "2.3.0" },
    "jaxb-core"                                => { org => "com.sun.xml.bind", name => "jaxb-core", rev => "2.3.0" },
    "jaxb-impl"                                => { org => "com.sun.xml.bind", name => "jaxb-impl", rev => "2.3.0" },
    "jaxen"                                    => { org => "jaxen", name => "jaxen", rev => "2.0.0" },
    "jcl-over-slf4j"                           => { org => "org.slf4j", name => "jcl-over-slf4j", rev => "2.0.16" },
    "joda-time"                                => { org => "joda-time", name => "joda-time", rev => "2.9.2" },
    "junit"                                    => { org => "junit", name => "junit", rev => "4.13.2" },
    "log4j-api"                                => { org => "org.apache.logging.log4j", name => "log4j-api", rev => "2.17.1" },
    "log4j-core"                               => { org => "org.apache.logging.log4j", name => "log4j-core", rev => "2.17.1" },
    "log4j-slf4j2-impl"                        => { org => "org.apache.logging.log4j", name => "log4j-slf4j2-impl", rev => "2.24.3" },
    "lombok"                                   => { org => "org.projectlombok", name => "lombok", rev => "1.18.30" },
    "mockito-core"                             => { org => "org.mockito", name => "mockito-core", rev => "2.23.0" },
    "ojdbc8"                                   => { org => "com.oracle.database.jdbc", name => "ojdbc8", rev => "23.3.0.23.09" },
    "poi"                                      => { org => "org.apache.poi", name => "poi", rev => "3.17" },
    "sitemesh"                                 => { org => "opensymphony", name => "sitemesh", rev => "2.7.0-M1" },
    "slf4j-api"                                => { org => "org.slf4j", name => "slf4j-api", rev => "2.0.16" },
    "slf4j-log4j12"                            => { org => "org.slf4j", name => "slf4j-log4j12", rev => "1.7.34" },
    "slf4j-reload4j"                           => { org => "org.slf4j", name => "slf4j-reload4j", rev => "2.0.1" },
    "spring-aop"                               => { org => "org.springframework", name => "spring-aop", rev => $springVersion },
    "spring-beans"                             => { org => "org.springframework", name => "spring-beans", rev => $springVersion },
    "spring-context"                           => { org => "org.springframework", name => "spring-context", rev => $springVersion },
    "spring-context-support"                   => { org => "org.springframework", name => "spring-context-support", rev => $springVersion },
    "spring-data-jpa"                          => { org => "org.springframework.data", name => "spring-data-jpa", rev => "3.4.1" },
    "spring-expression"                        => { org => "org.springframework", name => "spring-expression", rev => $springVersion },
    "spring-jdbc"                              => { org => "org.springframework", name => "spring-jdbc", rev => $springVersion },
    "spring-jms"                               => { org => "org.springframework", name => "spring-jms", rev => $springVersion },
    "spring-messaging"                         => { org => "org.springframework", name => "spring-messaging", rev => $springVersion },
    "spring-test"                              => { org => "org.springframework", name => "spring-test", rev => $springVersion },
    "spring-tx"                                => { org => "org.springframework", name => "spring-tx", rev => $springVersion },
    "spring-web"                               => { org => "org.springframework", name => "spring-web", rev => $springVersion },
    "spring-webmvc"                            => { org => "org.springframework", name => "spring-webmvc", rev => $springVersion },
    "spring-websocket"                         => { org => "org.springframework", name => "spring-websocket", rev => $springVersion },
    "xmlbeans"                                 => { org => "org.apache.xmlbeans", name => "xmlbeans", rev => "3.0.0" },


};

# replaced packages
$update->{"commons-collections"} = $update->{"commons-collections4"};
$update->{"commons-fileupload"} = $update->{"commons-fileupload2-jakarta-servlet6"};
$update->{"hibernate-core"} = $update->{"hibernate-core-jakarta"};
$update->{"httpclient"} = $update->{"httpclient5"};
$update->{"javax.servlet-api"} = $update->{"jakarta.servlet-api"};
$update->{"jsp-api"} = $update->{"jakarta.servlet.jsp-api"};
$update->{"mockito-all"} = $update->{"mockito-core"};
$update->{"log4j-slf4j-impl"} = $update->{"log4j-slf4j2-impl"};
$update->{"mail"} = $update->{"javax.mail-api"};
$update->{"display-portlet"} = $update->{"displaytag"};
$update->{"javax.xml.soap-api"} = $update->{"jakarta.xml.soap-api"};

my $add_if_missing = {
    "hibernate-core-jakarta" => [
	"dom4j",
	"byte-buddy",
        "jakarta.persistence-api",
        "jakarta.transaction-api",
	"ojdbc8",
    ],
    "javax.servlet.jsp" => [
        "jakarta.servlet.jsp-api",
    ],
    "jakarta.servlet.jsp-api" => [
        "jakarta.servlet.jsp.jstl",
    ],
};

my $exclusions = {
    "cas-client-core"               => [
        { org => "org.bouncycastle", name => "bcprov-jdk15on" }
    ],
    "mockito-core"                  => [
        { org => "net.bytebuddy" }
    ],
    "poi"                           => [
        { module => "log4j" },
        { module => "log4j-api" },
        { org => "org.slf4j" },
    ],
    "poi-ooxml"                     => [
        { module => "log4j" },
        { module => "log4j-api" },
        { org => "org.slf4j" },
    ],
    "tika-core"                     => [
        { org => "org.gagravarr" },
        { module => "log4j" },
        { module => "log4j-api" },
        { org => "org.slf4j" },
    ],
    "tika-parsers-standard-package" => [
        { org => "org.gagravarr" },
        { module => "log4j" },
        { module => "log4j-api" },
        { org => "org.slf4j" },
    ],
    "tika-parser-sqlite3-package"   => [
        { org => "org.gagravarr" },
        { module => "log4j" },
        { module => "log4j-api" },
        { org => "org.slf4j" },
    ],
};

my $file_content;
open(my $in, "<", $ivy_file)
    or die "Error: could not open '$ivy_file': $!";
{
    local $/;
    $file_content = <$in>;
}

$file_content =~ s{
    (\s*)
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
    elsif (grep { $dep_name =~ $_ } @remove_packages) {
        $replacement_str = "";
    }
    else {
        my $modified_dependency_block = $dependency_block;

        my $update_entry_ref = $update->{$dep_name};
        if (defined $update_entry_ref) {
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
		warn "Could not parse version for $dep_org:$dep_name. Current='$current_v_norm', Proposed='$new_v_norm'";
		$should_keep_rev = 1;
	    }

	    my $is_package_name_changing = ($update_entry_ref->{org} ne $dep_org || $update_entry_ref->{name} ne $dep_name);
	    if (defined $current_rev && !$is_package_name_changing && !$should_keep_rev) {
		if ($current_v gt $new_v) {
		    warn "Keeping current rev for $dep_org:$dep_name: $current_rev";
		    $should_keep_rev = 1;
		}
	    }

            foreach my $key (keys %$update_entry_ref) {
                my $new_val = $update_entry_ref->{$key};
		$new_val = $current_rev if $key eq 'rev' && $should_keep_rev;

		if ($modified_dependency_block =~ s/\b$key="[^"]*"/$key="$new_val"/i) {
		    # Attribute was updated
		}
		else {
		    warn "$dep_org,$dep_name missing $key attribute";
		}
            }
        }

        my $dep_exclusions = $exclusions->{$dep_name} || $exclusions->{"$dep_org,$dep_name"};
        if (defined $dep_exclusions) {
            # remove existing exclusions
            $modified_dependency_block =~ s{\s*<exclude\s+(?:[^>]*?)\s*/>}{}gsi;              # Self-closing
            $modified_dependency_block =~ s{\s*<exclude\s+(?:[^>]*?)>(?:.*?)</exclude>}{}gsi; # Opening/closing tags

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
                    warn "Warning: Could not find suitable place to insert exclusions for $dep_org,$dep_name";
                    $modified_dependency_block .= "\n" . $new_exclusions;
                }
            }
        }
        $replacement_str = $leading_whitespace . $modified_dependency_block;
    }

    $replacement_str;
}xseg;

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
            my $name = $dep->{name};

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

    $ver_str =~ s/([.-])([A-Za-z][\w+]*)/_\L$2/g;
    # remove syntactic sugar and hope for the best
    $ver_str =~ s/_\w+$//;
    # add missing 'v' at front of version string
    $ver_str = "v".$ver_str unless $ver_str =~ m/^v/;

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
