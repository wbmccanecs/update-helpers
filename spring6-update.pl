#! /usr/bin/perl

use strict;
use warnings;
use File::Find;
use File::Basename;
use File::Spec;
use Getopt::Long;
use Term::ANSIColor qw{:constants};
use Cwd 'cwd', 'abs_path';

my $start_directory = '.';
my $remove_if_exists = {
    "EnvironmentHelper" => "remove",
    "FilterConfig" => "remove",
    "FilterConfigTest" => "remove",
    "AuthorizationDeniedController" => "remove",
    "AuthorizationDeniedControllerTest" => "remove",
    "LogoutController" => "remove",
    "LogoutControllerTest" => "remove",
};
my $java_patterns = {
    'org\.apache\.commons\.lang\.' => 'org.apache.commons.lang3.',
    'org\.apache\.commons\.collections\.' => 'org.apache.commons.collections4.',
    "org\\.apache\\.http\\." => 'org.apache.hc.client5.http.',
    'org\.apache\.commons\.httpclient\.' => 'org.apache.hc.core5.http.',
    '([\(\s])javax\.(?!cache|mail|management|naming|net|sql|xml)' => '$1jakarta.',
    "^import *com\\.ibm\\.mq\\.jms" => 'import com.ibm.mq.jakarta.jms',
    '^( *).*"MQ_QMGRNAME".*$' => '$1System.setProperty("MQCHLLIB", "W:/MQ/devtools/ccdt/");',
    "^( *).*MgicQueueConnectionFactory.setCluster.*" => '$1System.setProperty("MQCHLTAB", "INT.RQDM4TS.JSON");',
    "(?<!Service)\\.findOne\\(((?:[^()]+|\\((?1)\\))*?)\\)" => '.findById($1).orElse(null)',
    "requestMappingHandlerAdapter" => 'createRequestMappingHandlerAdapter',
    "com\\.mgic\\.system\\.Environment" => 'com.mgic.spring.Environment',
    "import .*\\.EnvironmentHelper" => 'import com.mgic.spring.Environment',
    '(?<!\w)Environment\.(get|is)' => 'environment.$1',
    "([Ee])nvironmentHelper" => '$1nvironment',
    'ConnectModuleDataSource' => 'CyberArkDatasource',
    'org\.mockito\.Matchers\.' => 'org.mockito.ArgumentMatchers.',
    '^\s*import org\.powermock\.modules\.junit4\.PowerMockRunner\s*;\s*$' => 'import org.mockito.junit.MockitoJUnitRunner;',
    '^\s*import\s+(static\s+)?org\.powermock\.(api|core)\..*$' => '',
    '^import static org.mockito.ArgumentMatchers.anyObject' => 'import static org.mockito.ArgumentMatchers.any',
    '^\s*\@PrepareForTest\(.*$' => '',
    '^\s*\@PowerMockIgnore\(.*$' => '',
    '^\s*\@RunWith\(PowerMockRunner' => '@RunWith(MockitoJUnitRunner',
    '^\s*PowerMockito\..*$' => '',
    'CyberArkDatasource' => 'CyberArkDataSource',
    'import +org.apache.log4j.Logger *;' => "import org.slf4j.Logger;\nimport org.slf4j.LoggerFactory;",
    'Logger\.getLogger\(' => 'LoggerFactory.getLogger(',
};
my $optional_java_patterns = {
    "new *(Long|Integer|Short|Byte|Float|Double|Boolean)\\(" => '$1.valueOf(',
    "new (\\w+)<\\w+>" => 'new $1<>',
    "new (\\w+)<\\w+, \\w+>" => 'new $1<>',
};
my $xml_patterns = {
    "org\\.jasig" => "org.apereo",
    "JDK_(?!21)" => "JDK_21",
    "http://java.sun.com/xml/ns/javaee" => "https://jakarta.ee/xml/ns/jakartaee",
    "/web-app_3_0.xsd" => "/web-app_6_0.xsd",
    ",nagios," => ",",
    ",nagios" => "",
    "nagios," => "",
};
my $jsp_patterns = {
    "(<form:form( .*)?) commandName=" => '$1 modelAttribute=',
    "http://java.sun.com/jsp/jstl/(.*)" => 'jakarta.tags.$1',
    "https?://www.owasp.org/index.php/OWASP_Java_Encoder_Project(#advanced)?" => "owasp.encoder.jakarta",
};
my $js_patterns = {
	'^(\s*)(.*\.(append|html)\()((?!sanitized)[_\w]+)(\);)\s*$' => q!$1var sanitizedHtml = DOMPurify.sanitize($4, { ADD_TAGS: ['script'] });!."\n".q!$1$2sanitizedHtml$5!,
};
my $properties_patterns = {
    "content.ts.mgicint.net" => "content.mgic.com",
    "(rd|qa).content.mgic.(com|net)" => "content.mgic.com",
    '\.dc01\.' => '.',
};
my $yaml_patterns = {
    "ci-core.yml" => "ci-core.java21.yml",
};

my ($help,$checkJava,$checkJsp,$checkJs,$checkProperties,$checkXml,$checkYml) = (0) x 7;

my %checkMap = (
    'java' => \$checkJava,
    'jsp' => \$checkJsp,
    'js' => \$checkJs,
    'prop' => \$checkProperties,
    'properties' => \$checkProperties,
    'xml' => \$checkXml,
    'yml' => \$checkYml,
    'yaml' => \$checkYml,
);

GetOptions(
    "dir|d=s"         => \$start_directory,
    "help|h"          => \$help,
) or usage();

for my $arg (@ARGV) {
    my $key = lc($arg);

    ${$checkMap{$key}} = 1 if exists $checkMap{$key};
}

my $checkAll = (scalar @ARGV == 0 ) & !($checkJava + $checkJsp + $checkJs + $checkProperties + $checkXml + $checkYml);

my $abs_start_directory_resolved = abs_path($start_directory);
if (!defined $abs_start_directory_resolved) {
    die BOLD RED "Error: Starting directory '$start_directory' does not exist or is inaccessible.\n" . RESET;
    exit 1;
}
print BOLD MAGENTA "DEBUG (Top-Level): File::Find will start from absolute path: '$abs_start_directory_resolved'\n" . RESET;

print BOLD GREEN "--- Starting All Spring 6 Upgrades ---\n" . RESET;
upgrade_to_spring6($start_directory, 'java', $java_patterns, $optional_java_patterns) if $checkJava || $checkAll;
upgrade_to_spring6($start_directory, 'jsp', $jsp_patterns) if $checkJsp || $checkAll;
upgrade_to_spring6($start_directory, 'js', $js_patterns) if $checkJs || $checkAll;
upgrade_to_spring6($start_directory, 'properties', $properties_patterns) if $checkProperties || $checkAll;
upgrade_to_spring6($start_directory, 'xml', $xml_patterns) if $checkXml || $checkAll;
upgrade_to_spring6($start_directory, 'yml', $yaml_patterns) if $checkYml || $checkAll;
print BOLD GREEN "--- All Spring 6 Upgrades Complete ---\n" . RESET;
exit 0;

sub upgrade_to_spring6 {
    my ($current_dir, $file_extension, $patterns_ref, $optional_patterns_ref) = @_;

    my $lc_target_extension_with_dot = "." . lc $file_extension;

    my %compiled_patterns;
    foreach my $p (keys %$patterns_ref) {
        eval {
            $compiled_patterns{$p} = qr/$p/m;
        };
        if ($@) {
            print BOLD RED "Error: Invalid regular expression pattern '$p': $@\n" . RESET;
            exit 1;
        }
    }
    my %optional_compiled_patterns;
    if ($optional_patterns_ref) {
        foreach my $p (keys %$optional_patterns_ref) {
            eval {
                $optional_compiled_patterns{$p} = qr/$p/m;
            };
            if ($@) {
                print BOLD RED "Error: Invalid regular expression pattern '$p': $@\n" . RESET;
                exit 1;
            }
        }
    }

    print BOLD BLUE "\n---Running Spring 6 upgrade for *.$file_extension files ---\n" . RESET;
    print BOLD BLUE "  Starting directory: " . $current_dir . "\n" . RESET;
    print "-" x 50 . "\n\n";

    my $file_count = 0;
    my $file_changes = 0;

    my $wanted_sub = sub {
        # Skip common development/build directories
        if (-d $_) {
            (my $full_path_relative = $File::Find::name) =~ s!\\!/!g;

            if (
                $full_path_relative eq './.git' ||
                $full_path_relative eq './target' ||
                $full_path_relative eq './build' ||
                $full_path_relative eq './node_modules' ||
                $full_path_relative eq './bin' ||
                $full_path_relative eq './out' ||
                $full_path_relative eq './deploy' ||
                $full_path_relative eq './reports' ||
                $full_path_relative eq './test-automation' ||
                $full_path_relative eq './test-bin' ||
                $full_path_relative eq './war/META-INF' ||
                $full_path_relative eq './war/WEB-INF/classes' ||
                $full_path_relative eq './war/WEB-INF/lib' ||
                $full_path_relative eq './.settings' # Eclipse project files
            ) {
                $File::Find::prune = 1; # Don't traverse into this directory
                return;
            }
        }

        # only process regular files
        return unless -f $_;

        my $file_path_raw = $File::Find::name;
        my ($filename, $dirs, $suffix) = fileparse($file_path_raw, qr/\.[^.]*$/);

        return unless lc $suffix eq $lc_target_extension_with_dot;

	# remove unwanted classes
	if ($remove_if_exists->{$filename}) {
            warn BOLD YELLOW "Removing unwanted class $dirs$filename$suffix" . RESET . "\n";
	    unlink $_;
	    die "$!" if $!;
	    return;
	}

        open my $fh, "<", $_ or do {
            warn BOLD YELLOW "Warning: could not open $file_path_raw: $!" . RESET . "\n";
            return;
        };
        my $slurp;
        {
            local $/ = undef;
            $slurp = <$fh>;
        }
        close $fh;

        ++$file_count;

        my $file_has_match = 0;
        my $original_slurp = $slurp;

        if ($slurp) {
            $slurp = perform_substitutions($file_path_raw, $slurp, \%compiled_patterns, $patterns_ref);
            if ($slurp ne $original_slurp && $optional_patterns_ref) {
                $slurp = perform_substitutions($file_path_raw, $slurp, \%optional_compiled_patterns, $optional_patterns_ref);
            }
        }

        if ($slurp ne $original_slurp) {
            $file_has_match = 1;
            ++ $file_changes;
            print BOLD CYAN "  Saving changes\n" . RESET;

            open my $out_fh, ">", $_ or do {
                die BOLD RED "Error: could not write to $file_path_raw\n" . RESET;
            };
            print $out_fh $slurp;
            close $out_fh;
        }
    };

    find($wanted_sub, $current_dir);
    print BOLD BLUE "  Checked files: " . $file_count . "\n" . RESET;
    print BOLD BLUE "  Updated files: " . $file_changes . "\n" . RESET;
    print "-" x 50 . "\n\n";
}

sub perform_substitutions {
    my ($file_path_raw, $slurp, $compiled_patterns, $patterns_ref) = @_;

    for my $pattern_regex_key (keys %$compiled_patterns) {
        my $replacement = $patterns_ref->{$pattern_regex_key};
        if ($replacement =~ m/\$\d/) {
            if ($slurp =~ m/\$[1-9]/) {
                warn BOLD RED "$file_path_raw contains string that looks like matching group so cannot be updated" . RESET . "\n";
		last;
            } else {
                while ($slurp =~ s/$compiled_patterns->{$pattern_regex_key}/$patterns_ref->{$pattern_regex_key}/xs) {
                    my @matches = (0, $1, $2, $3, $4, $5, $6, $7, $8, $9);
		    $slurp =~ s/\$([1-9])/$matches[$1]/ge;
		    #		    $slurp =~ s/\\n/\n/g;
		    my $output_string = $patterns_ref->{$pattern_regex_key};
		    $output_string =~ s/\$([1-9])/$matches[$1]/ge;
		    $output_string =~ s/\\n/\n/g;
                    print BOLD YELLOW "$file_path_raw " . $output_string . "\n" . RESET;
                }
            }
        } else {
	    my $output_string = $patterns_ref->{$pattern_regex_key};
            if ($slurp =~ s/$compiled_patterns->{$pattern_regex_key}/$output_string/xsg) {
                print BOLD YELLOW "$file_path_raw " . ($output_string || $pattern_regex_key) . "\n" . RESET;
            }
        }
    }

    $slurp;
}
