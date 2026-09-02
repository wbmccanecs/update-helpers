#! /usr/bin/perl

use strict;
use warnings;
use File::Find;
use File::Basename;
use File::Spec;
use Getopt::Long;
use Term::ANSIColor qw{:constants};
use Cwd 'cwd', 'abs_path';

use FindBin;
use lib "$FindBin::RealBin";

use MyLogger qw(
    log_info
    log_warning
    log_error
    log_success
);

my $start_directory = '.';
my $remove_if_exists = {
    "EnvironmentHelper" => "remove",
    "FilterConfig"      => "remove",
};
my $java_patterns = {
    "org\\.apache\\.commons\\.lang\\."                                                                                                                               => "commons-lang",
    "org\\.apache\\.commons\\.collections\\."                                                                                                                        => "commons-collections",
    "com\\.ibm\\.mq\\.jms"                                                                                                                                           => "IBM MQ JMS",
    "WebMvcConfigurerAdapter"                                                                                                                                        => "WebMvcConfigurerAdapter",
    "MappingJacksonJsonView *get"                                                                                                                                    => "MappingJacksonJsonView",
    'import *javax\.(?!cache|crypto|mail|management|naming|net|sql|xml\.(?>XMLConstants|catalog|datatype|namespace|parsers|stream|transform|validation|xpath))(\w+)' => 'javax.$1',
    "RequestMappingHandlerAdapter *request"                                                                                                                          => "rename to createRequestMappingHandlerAdapter",
    "HandlerInterceptorAdapter"                                                                                                                                      => "HandlerInterceptorAdapter",
    "org.apache.http.client"                                                                                                                                         => "httpcomponents",
    "org.apache.commons.httpclient"                                                                                                                                  => "httpcomponents",
    "DefaultHttpRequestRetryStrategy"                                                                                                                                => "retry strategies",
    "getPatternsCondition"                                                                                                                                           => "test-harness",
    "swagger"                                                                                                                                                        => "swagger",
    "\@Api"                                                                                                                                                          => "swagger",
    "springfox"                                                                                                                                                      => "springfox",
    "(MQ_QMGRNAME|MgicQueueConnectionFactory.setCluster)"                                                                                                            => "MQCLUSTER",
    "(?<!Service)\\.findOne\\(\\w+\\)"                                                                                                                               => "refactor to use findById()",
    "org\\.\\apereo\\."                                                                                                                                              => "remove Apereo CAS",
    "ExtranetAuthorizationFilter"                                                                                                                                    => "replace with EmployeeFormBasedAuthFilterForLDAP",
    "isAuthorizedUser"                                                                                                                                               => "replace with manageAuthorizedUser",
    "EmployeeLdapHelper[^V]"                                                                                                                                         => "remove EmployeeLdapHelper",
    "(ticketValidation|authentication)Filter"                                                                                                                        => "remove ticketValidation and authentication filters",
    '\.setApplicationId\(\D[_\w]+\)'                                                                                                                                 => "convert from setApplicationId() to setUrl()",
    "\@DependsOn"                                                                                                                                                    => "replace \@DependsOn with DI",
    "com.mgic.(spring|system).Environment"                                                                                                                           => "refactor to use environment properties",
    "import [\\w\\.]+\.EnvironmentHelper"                                                                                                                            => "import mgic.com.spring.Environment",
    "EnvironmentHelper"                                                                                                                                              => "refactor to use Environment component",
    'ConnectModuleDataSource'                                                                                                                                        => 'refactor to CyberArkDatasource',
    '@EnableWebMvc'                                                                                                                                                  => 'remove EnableWebMvc annotation',
    '\.getConnectInfo\W'                                                                                                                                             => 'replace with getConnectInfoForURL',
    'import org.powermock'                                                                                                                                           => 'remove powermock',
    'import +org.apache.log4j.Logger'                                                                                                                                => 'remove old log4j',
    'import +org.apache.commons.logging'                                                                                                                             => 'remove commons-logging',
    'new (Integer|Short|Long|Byte)[^\w]'                                                                                                                             => 'fix $1 boxing',
    '\.(setRemovedAbandoned)\('                                                                                                                                      => 'replace $1 with setRemoveAbandonedOnMaintenance',
    '\.(setTimeBetweenEvictionRunsMillis)\('                                                                                                                         => 'replace $1 with setDurationBetweenEvictionRuns',
    '\.(setRemoveAbandonedTimeout)\((\d+)'                                                                                                                           => 'replace $1($2) with $1(Duration)',
    '\.(setMaxWait)\((\d+)'                                                                                                                                          => 'replace $1($) with $1(Duration)',
    '@EnableMBeanExport'                                                                                                                                             => 'remove @EnableMBeanExport',
    '(CommonsMultipartResolver)'                                                                                                                                     => 'replace $1 with StandardServletMultipartResolver',
    '(\w*JdbcTemplate)'                                                                                                                                              => '$1',
    'BigDecimal.*getResult'                                                                                                                                          => 'query returns BigDecimal',
    'filter\.PageFilter'                                                                                                                                             => 'replace PageFilter with SiteMeshFilter',
    'com\.mgic\.business\.aims\.'                                                                                                                                    => 'use aimservice-client.jar',
    'org\.hibernate\.annotations\.Named'                                                                                                                             => 'use JPA NamedNativeQuery',
    '^(?:[^/]|/(?!/))*?(?:private|public|protected)?\s+(?:final\s+)?(?:static\s+)?((?:[a-z][a-zA-Z0-9_]*\.){2,}[A-Z][a-zA-Z0-9_]*)\s+\w+(?:\s*[=;,])'                => 'FQCN member declaration: $1',
    '^(?:[^/]|/(?!/))*?\bnew\s+((?:[a-z][a-zA-Z0-9_]*\.){2,}[A-Z][a-zA-Z0-9_]*)\s*\('                                                                                => 'FQCN construction: $1',
    '(JMSC\.MQJMS_(\w+))'                                                                                                                                            => 'replace $1 with WMQConstants.WMQ_$2',
};
my $xml_patterns = {
    "org\\.jasig"                                     => "jasig CAS",
    "org\\.apereo\\.cas"                              => "remove apereo CAS",
    "<buildFile[^>]* />"                              => "missing add-opens",
    "<bean"                                           => "move beans to java config",
    "JDK_(?!21)"                                      => "JDK",
    "http://java.sun.com/xml/ns/javaee"               => "upgrade to jakarta 6.0",
    "Extranet(Authentication|TicketValidation)Filter" => "remove extranet filters",
    "(ticketValidation|authentication)Filter"         => "remove ticketValidation and authentication filters",
    "nagios"                                          => "remove nagios from security groups",
    'mgic.entity.revision=\d+'                        => "check mgic.entity.revision",
};
my $iml_patterns = {
    '"MQ"'                 => 'use tomcat10 library',
    'jdkName="(?!21)(.*)"' => "JDK",
};
my $jsp_patterns = {
    "javax\\.servlet\\.jsp"                           => "javax JSP API",
    "(http://java.sun.com/jsp|https://www.owasp.org)" => "old taglibs",
    "<enc:forJavaScriptBlockvalue"                    => "enc:forJavaScriptBlockvalue",
    "<form:form.*commandName="                        => "commandName",
};
my $js_patterns = {
    '^(\s*)(.*\.(append|html)\()((?!sanitized)[_\w]+)(\);)\s*$' => 'not sanitized $3',
};
my $properties_patterns = {
    "content.ts.mgicint.net"         => "static content",
    "(rd|qa).content.mgic.(com|net)" => "static content",
    "ojdbc8.jat"                     => "move ojdbc8 driver to ivy.xml",
};
my $yaml_patterns = {
    "core.yml"       => "upgrade for java21",
    "BUILD\\.DEPLOY" => "upgrade for java21",
};
my $sh_patterns = {
    "umask *022" => "update setenv.sh",
    "/jre/"      => "fix cacerts folder",
};
my $file_patterns = {
    '.gitignore' => {
        '\.idea.*/libraries' => 'fix libraries exclusion',
        'test-automation'    => 'remove test-automation from .gitignore',
    },
};

my @required_files = (
    'pom.xml',
    'build.xml',
    'ivy.xml',
    'build-standard.xml',
    'build.properties',
    '.gitignore',
);

my @unwanted = (
    'test-automation',
    '.gradle',
);

my %HTML_VOID_TAGS = map {$_ => 1} qw(
    area base br col embed hr img input link meta param source track wbr
);

my $checks;
my ($help, $verbose);

GetOptions(
    "dir|d=s"   => \$start_directory,
    "verbose|v" => \$verbose,
    "help|h"    => \$help,
) or usage();

if ($help) {
    usage();
    exit 0;
}

for my $arg (@ARGV) {
    my $key = lc($arg);
    $checks->{$key} = 1;
}

my $checkAll = scalar keys %$checks == 0;

my $abs_start_directory_resolved = abs_path($start_directory);
if (!defined $abs_start_directory_resolved) {
    log_error("Error: Starting directory '$start_directory' does not exist or is inaccessible.");
    exit 1;
}
log_info("DEBUG (Top-Level): File::Find will start from absolute path: '$abs_start_directory_resolved'", MAGENTA);

log_success("--- Starting All Safety Checks ---");
safety_check($start_directory, 'java', $java_patterns) if $checks->{java} || $checkAll;
if ($checks->{jsp} || $checkAll) {
    safety_check($start_directory, 'jsp', $jsp_patterns);
    check_unused_tagdefs($start_directory);
    check_xml_well_formedness($start_directory, [ 'jsp', 'jspf', 'htm', 'html', 'tld', 'tag' ]);
}
safety_check($start_directory, 'js', $js_patterns) if $checks->{js} || $checkAll;
safety_check($start_directory, 'properties', $properties_patterns) if $checks->{properties} || $checkAll;
if ($checks->{xml} || $checkAll) {
    safety_check($start_directory, 'xml', $xml_patterns);
    check_xml_well_formedness($start_directory, 'xml');
}
safety_check($start_directory, 'iml', $iml_patterns) if $checks->{iml} || $checkAll;
safety_check($start_directory, 'yml', $yaml_patterns) if $checks->{yml} || $checkAll;
safety_check($start_directory, 'sh', $sh_patterns) if $checks->{sh} || $checkAll;
file_pattern_safety_checks($start_directory, $file_patterns) if $checks->{files} || $checks->{file_patterns} || $checkAll;
misc_checks($start_directory) if $checks->{misc} || $checkAll;
if ($checkAll) {
    for my $m (@unwanted) {
        if (-e $m) {
            log_error("remove " . $m);
        }
    }
}

log_success("--- All Safety Checks Complete ---");
exit 0;

sub safety_check {
    my ($current_dir, $file_extension, $patterns_ref) = @_;

    my $lc_target_extension_with_dot = "." . lc $file_extension;

    my %compiled_patterns;
    foreach my $p (keys %$patterns_ref) {
        eval {
            $compiled_patterns{$p} = qr/$p/;
        };
        if ($@) {
            log_error("Error: Invalid regular expression pattern '$p': $@");
            exit 1;
        }
    }

    log_info("\nRunning Safety Check for *.$file_extension files");
    if ($verbose) {
        log_info("  Target files with extension: $file_extension");
        log_info("  Searching for patterns:");
        foreach my $p_regex (sort keys %$patterns_ref) {
            log_info("    - '$p_regex' (Identified as: " . $patterns_ref->{$p_regex} . ")");
        }
    }
    log_info("  Starting directory: $current_dir") if $verbose && $current_dir ne ".";
    log_info("-" x 50);

    my $file_count = 0;

    my $wanted_sub = sub {
        # Skip common development/build directories
        if (-d $_) {
            (my $full_path_relative = $File::Find::name) =~ s#\\#/#g;

            if (
                $full_path_relative =~ '.*/.git' ||
                    $full_path_relative =~ '.*/target' ||
                    $full_path_relative =~ '.*/build' ||
                    $full_path_relative =~ '.*/node_modules' ||
                    $full_path_relative =~ '.*/bin' ||
                    $full_path_relative =~ '.*/out' ||
                    $full_path_relative =~ '.*/deploy' ||
                    $full_path_relative =~ '.*/reports' ||
                    $full_path_relative =~ '.*/test-automation' ||
                    $full_path_relative =~ '.*/test-bin' ||
                    $full_path_relative =~ '.*/war/META-INF' ||
                    $full_path_relative =~ '.*/war/WEB-INF/classes' ||
                    $full_path_relative =~ '.*/war/WEB-INF/lib' ||
                    $full_path_relative =~ '.*/.settings' # Eclipse project files
            ) {
                $File::Find::prune = 1; # Don't traverse into this directory
                return;
            }
        }

        # only process regular files
        return unless -f $_;

        my $validated = check_single_file($_, $File::Find::name, $lc_target_extension_with_dot, \%compiled_patterns, $patterns_ref);
        $file_count++ if $validated;
    };

    find($wanted_sub, $current_dir);
    log_info("  Validated files: $file_count");
    log_info("-" x 50);
}

sub check_single_file {
    my ($file_to_open, $file_path_display, $lc_target_extension_with_dot, $compiled_patterns, $patterns_ref) = @_;

    my ($filename, $dirs, $suffix) = fileparse($file_path_display, qr/\.[^.]*$/);

    if (defined $lc_target_extension_with_dot && $lc_target_extension_with_dot ne '') {
        return 0 unless lc $suffix eq $lc_target_extension_with_dot;
    }

    if ($remove_if_exists->{$filename}) {
        log_warning("remove " . $filename);
        return 0;
    }

    open my $fh, "<", $file_to_open or do {
        log_warning("Warning: could not open $file_path_display: $!");
        return 0;
    };

    my @lines = <$fh>;
    close $fh;

    # 1. Collect explicit imports: e.g. 'Date' => 'java.util.Date'
    my %imports;
    for my $line (@lines) {
        if ($line =~ /^\s*import\s+(?:static\s+)?((?:[a-z][a-zA-Z0-9_]*\.)+([A-Z][a-zA-Z0-9_]*))\s*;\s*$/) {
            $imports{$2} = $1;
        }
    }

    # 2. Validate line-by-line against compiled patterns
    my $line_num = 0;
    my %pattern_found;
    my $patterns_count = scalar keys %$compiled_patterns;
    my $found_count = 0;

    for my $line (@lines) {
        $line_num++;
        for my $pattern_regex_key (keys %$compiled_patterns) {
            next if $pattern_found{$pattern_regex_key};

            if ($line =~ $compiled_patterns->{$pattern_regex_key}) {
                my @matches = ($1, $2, $3, $4, $5, $6, $7, $8, $9);
                my $output_string = $patterns_ref->{$pattern_regex_key};

                # Braces s{}{} allow using '//' defined-or safely inside replacement block
                $output_string =~ s{\$(\d+)}{$matches[$1 - 1] // ''}ge;

                # 3. Detect conflicts between matched FQCN and imported class
                my $extra_info = "";
                if ($output_string =~ /FQCN/ && defined $matches[0] && $matches[0] =~ /^(.*)\.([A-Z][a-zA-Z0-9_]*)$/) {
                    my ($fqcn, $simple_class) = ($matches[0], $2);
                    if (exists $imports{$simple_class} && $imports{$simple_class} ne $fqcn) {
                        next;
                    }
                }

                $pattern_found{$pattern_regex_key} = 1;
                $found_count++;
                if (defined $lc_target_extension_with_dot && $lc_target_extension_with_dot eq ".java") {
                    (my $fpd = $file_path_display) =~ s#^./(src|test)/##;
                    $fpd =~ s#/#.#g;
                    $fpd =~ s/$lc_target_extension_with_dot//;
                    log_warning("$fpd.($filename:$line_num) - " . $output_string . $extra_info);
                }
                else {
                    log_warning("$file_path_display line $line_num: " . $output_string . $extra_info);
                }
            }
        }
        last if $found_count == $patterns_count;
    }

    return 1;
}

sub file_pattern_safety_checks {
    my ($current_dir, $file_patterns_ref) = @_;

    my %compiled_wildcards;
    my %compiled_patterns_by_wildcard;

    foreach my $wildcard (keys %$file_patterns_ref) {
        my $regex_str = quotemeta($wildcard);
        $regex_str =~ s/\\\*/.*/g;
        $regex_str =~ s/\\\?/./g;
        eval {
            if ($wildcard =~ m#/#) {
                $compiled_wildcards{$wildcard} = qr/(?:^|\/)$regex_str$/;
            }
            else {
                $compiled_wildcards{$wildcard} = qr/^$regex_str$/;
            }
        };
        if ($@) {
            log_error("Error: Invalid wildcard pattern '$wildcard': $@");
            exit 1;
        }

        my $patterns_ref = $file_patterns_ref->{$wildcard};
        my %compiled_patterns;
        foreach my $p (keys %$patterns_ref) {
            eval {
                $compiled_patterns{$p} = qr/$p/;
            };
            if ($@) {
                log_error("Error: Invalid regular expression pattern '$p' under wildcard '$wildcard': $@");
                exit 1;
            }
        }
        $compiled_patterns_by_wildcard{$wildcard} = \%compiled_patterns;
    }

    log_info("\n---Running Safety Check for Wildcard File Patterns ---");
    log_info("  Target wildcards: " . join(", ", sort keys %$file_patterns_ref));
    log_info("  Starting directory: " . $current_dir);
    log_info("-" x 50);

    my $file_count = 0;

    my $wanted_sub = sub {
        # Skip common development/build directories
        if (-d $_) {
            (my $full_path_relative = $File::Find::name) =~ s#\\#/#g;

            if (
                $full_path_relative =~ '.*/.git' ||
                    $full_path_relative =~ '.*/target' ||
                    $full_path_relative =~ '.*/build' ||
                    $full_path_relative =~ '.*/node_modules' ||
                    $full_path_relative =~ '.*/bin' ||
                    $full_path_relative =~ '.*/out' ||
                    $full_path_relative =~ '.*/deploy' ||
                    $full_path_relative =~ '.*/reports' ||
                    $full_path_relative =~ '.*/test-automation' ||
                    $full_path_relative =~ '.*/test-bin' ||
                    $full_path_relative =~ '.*/war/META-INF' ||
                    $full_path_relative =~ '.*/war/WEB-INF/classes' ||
                    $full_path_relative =~ '.*/war/WEB-INF/lib' ||
                    $full_path_relative =~ '.*/.settings' # Eclipse project files
            ) {
                $File::Find::prune = 1; # Don't traverse into this directory
                return;
            }
        }

        # only process regular files
        return unless -f $_;

        my $filename_to_match = $_;
        (my $path_to_match = $File::Find::name) =~ s#\\#/#g;

        foreach my $wildcard (keys %compiled_wildcards) {
            my $matches_wildcard = 0;
            if ($wildcard =~ m#/#) {
                $matches_wildcard = ($path_to_match =~ $compiled_wildcards{$wildcard});
            }
            else {
                $matches_wildcard = ($filename_to_match =~ $compiled_wildcards{$wildcard});
            }

            if ($matches_wildcard) {
                my $validated = check_single_file(
                    $_,
                    $File::Find::name,
                    undef,
                    $compiled_patterns_by_wildcard{$wildcard},
                    $file_patterns_ref->{$wildcard}
                );
                $file_count++ if $validated;
            }
        }
    };

    find($wanted_sub, $current_dir);
    log_info("-" x 50);
    log_info("  Validated files: $file_count");
    log_info("-" x 50);
}

sub misc_checks {
    my ($current_dir) = @_;

    for my $file (@required_files) {
        check_for_file($file);
    }
}

sub check_for_file {
    my ($file) = @_;

    if (!-f $file) {
        log_warning("$file missing");
    }
    else {
        my $x = `git ls-files --error-unmatch $file`;
        log_warning("$file is not in repository") if $?;
    }
}

sub check_unused_tagdefs {
    my ($current_dir) = @_;

    my $tagdefs_path;
    my %declared_prefixes;
    my %used_prefixes;

    # 1. Locate tagdefs.jsp and parse declared taglibs
    find(sub {
        return unless -f $_ && $_ eq 'tagdefs.jsp';
        $tagdefs_path = $File::Find::name;
    }, $current_dir);

    unless ($tagdefs_path && -f $tagdefs_path) {
        return; # Silent skip if project doesn't utilize a tagdefs.jsp
    }

    open my $fh, "<", $tagdefs_path or return;
    my $line_num = 0;
    while (my $line = <$fh>) {
        $line_num++;
        if ($line =~ /<%@\s*taglib\s+[^>]*prefix=["']([^"']+)["']/) {
            $declared_prefixes{$1} = $line_num;
        }
    }
    close $fh;

    return unless %declared_prefixes;

    # 2. Scan all JSP/JSPF/TAG files to record prefix occurrences
    find(sub {
        if (-d $_) {
            my $full_path = $File::Find::name;
            if ($full_path =~ m#/(?:\.git|target|build|node_modules|bin|out|deploy|reports|test-automation|test-bin|war/META-INF|war/WEB-INF/classes|war/WEB-INF/lib|\.settings)$#) {
                $File::Find::prune = 1;
                return;
            }
        }

        return unless -f $_ && $_ =~ /\.(jsp|jspf|tag)$/i;
        return if $File::Find::name eq $tagdefs_path; # Ignore self

        open my $jsp_fh, "<", $_ or return;
        while (my $line = <$jsp_fh>) {
            while ($line =~ /<([a-zA-Z0-9_-]+):/g) {
                $used_prefixes{$1} = 1;
            }

            while ($line =~ /\$\{?\s*([a-zA-Z0-9_-]+):[a-zA-Z0-9_-]+\s*\(/g) {
                $used_prefixes{$1} = 1;
            }
        }
        close $jsp_fh;
    }, $current_dir);

    # 3. Output warnings for any unused declared taglibs
    log_info("\nChecking tagdefs.jsp for Unused Taglib Declarations");
    log_info("-" x 50);

    my $unused_count = 0;
    for my $prefix (sort keys %declared_prefixes) {
        unless ($used_prefixes{$prefix}) {
            my $decl_line = $declared_prefixes{$prefix};
            log_warning("$tagdefs_path line $decl_line: unused taglib prefix '$prefix' in tagdefs.jsp - consider removing");
            $unused_count++;
        }
    }

    if ($unused_count == 0) {
        log_info("  All declared taglib prefixes in tagdefs.jsp are actively used.");
    }
    log_info("-" x 50);
}

sub blank_keep_newlines {
    my ($str) = @_;
    $str =~ s/[^\n]/ /g;
    return $str;
}

sub validate_attributes {
    my ($tag_name, $attrs, $line_num) = @_;
    return undef unless defined $attrs && $attrs =~ /\S/;

    # Validate attribute quote closure
    while ($attrs =~ m{([a-zA-Z0-9_\-\.\:]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))}g) {
        my ($attr_name, $val_dbl, $val_sgl, $unquoted) = ($1, $2, $3, $4);
        if (defined $unquoted) {
            return "Line $line_num: Unquoted attribute value in tag <$tag_name>: $attr_name=$unquoted";
        }
    }
    return undef;
}

sub validate_xml_content_pure_perl {
    my ($content) = @_;

    # 1. Pre-process: Preserve newlines while blanking out non-XML text blocks
    $content =~ s/(<%--.*?--%>)/blank_keep_newlines($1)/gse;   # JSP comments
    $content =~ s/(<%[@=!]?.*?%>)/blank_keep_newlines($1)/gse; # JSP directives and scriptlets
    $content =~ s/(\$\{[^}]*\})/blank_keep_newlines($1)/gse;   # JSP EL expressions (${...})
    $content =~ s/(<!--.*?-->)/blank_keep_newlines($1)/gse;    # XML comments
    $content =~ s/(<!\[CDATA\[.*?\]\]>)/blank_keep_newlines($1)/gse;
    $content =~ s/(<\?.*?\?>)/blank_keep_newlines($1)/gse;
    $content =~ s/(<!DOCTYPE.*?>)/blank_keep_newlines($1)/gse;

    # FIX: Blank out inner content of <script> and <style> tags to ignore JS/CSS ampersands (&&, &)
    $content =~ s{(<script\b[^>]*>)(.*?)(</script>)}{$1 . blank_keep_newlines($2) . $3}gse;
    $content =~ s{(<style\b[^>]*>)(.*?)(</style>)}{$1 . blank_keep_newlines($2) . $3}gse;

    # Blank out custom JSP/JSTL taglib tags (e.g., <c:if ...>, </c:if>, <fmt:...>, <mux:...>)
    my $taglib_regex = qr{
        </?
        [a-zA-Z0-9_\-\.]+:[a-zA-Z0-9_\-\.]+
        (?:\s+(?:[^"'>]|"[^"]*"|'[^']*')*)?
        /?>
    }xms;
    $content =~ s/($taglib_regex)/blank_keep_newlines($1)/gse;

    my @tag_stack; # Stores tuples: [ $tag_name, $line_num ]
    my $root_element_count = 0;

    # Tag regex: Matches < ... > while allowing < and > inside single or double quotes
    my $tag_regex = qr{
        <
        (?:
            [^"'>]
            |
            "[^"]*"
            |
            '[^']*'
        )*
        >
    }xms;

    # 2. Tokenize by tags (respecting quoted < and >), stray '<', or text content
    while ($content =~ m{($tag_regex|[^<]+|<)}gs) {
        my $chunk = $1;
        my $chunk_pos = pos($content) - length($chunk);
        my $line_num = (substr($content, 0, $chunk_pos) =~ tr/\n//) + 1;

        if ($chunk eq '<') {
            return "Line $line_num: Malformed XML: Unclosed or orphaned '<' found";
        }
        elsif ($chunk =~ /^</) {
            # Closing tag: </foo>
            if ($chunk =~ /^<\/\s*([a-zA-Z0-9_\-\.\:]+)\s*>$/s) {
                my $close_tag = $1;
                unless (@tag_stack) {
                    return "Line $line_num: Unexpected closing tag </$close_tag> with empty tag stack";
                }
                my $open_entry = pop @tag_stack;
                my ($open_tag, $open_line) = @$open_entry;
                if (lc($open_tag) ne lc($close_tag)) {
                    return "Line $line_num: Mismatched tag: expected </$open_tag> (opened at line $open_line), but found </$close_tag>";
                }
                next;
            }

            # Opening or self-closing tag
            if ($chunk =~ /^<\s*([a-zA-Z0-9_\-\.\:]+)([\s\S]*)?>$/s) {
                my $open_tag = $1;
                my $raw_body = $2 // '';
                my $lc_tag = lc($open_tag);

                # Determine if self-closing or an HTML void element (e.g. <link>, <img>, <meta>)
                my $is_self_closing = ($chunk =~ /\/>$/s) || $HTML_VOID_TAGS{$lc_tag};

                my $attrs = $raw_body;
                $attrs =~ s/\/?\s*>$//;

                if (my $err = validate_attributes($open_tag, $attrs, $line_num)) {
                    return $err;
                }

                unless ($is_self_closing) {
                    $root_element_count++ if scalar(@tag_stack) == 0;
                    push @tag_stack, [ $open_tag, $line_num ];
                }
            }
            else {
                return "Line $line_num: Invalid tag structure: $chunk";
            }
        }
        else {
            # Text content: Verify entity escaping
            if ($chunk =~ /&(?!([a-zA-Z][a-zA-Z0-9]*|#\d+|#x[0-9a-fA-F]+);)/) {
                my $entity_offset = $-[0];
                my $exact_line = $line_num + (substr($chunk, 0, $entity_offset) =~ tr/\n//);
                return "Line $exact_line: Unescaped '&' symbol found in text content";
            }
        }
    }

    if (@tag_stack) {
        my @unclosed_msgs = map {"<$_->[0]> (line $_->[1])"} @tag_stack;
        return "Unclosed tag(s) remaining: " . join(", ", @unclosed_msgs);
    }

    return undef; # Success
}

sub check_xml_well_formedness {
    my ($search_dirs_ref, $extensions) = @_;
    my $ext_re = ref($extensions) eq 'ARRAY' ? join "|", @$extensions : ($extensions || 'foo');
    my @dirs = ref($search_dirs_ref) eq 'ARRAY' ? @$search_dirs_ref : ($search_dirs_ref || '.');
    @dirs = grep {-d $_} @dirs;

    log_info("Auditing XML well-formedness across directories: " . join(", ", @dirs) . " for " . $ext_re);

    my $total_checked = 0;
    my $failed_count = 0;

    find({
        wanted   => sub {
            my $file = $File::Find::name;
            return unless -f $file;
            return unless $file =~ /\.($ext_re)$/i;

            $total_checked++;

            open(my $fh, '<', $file) or do {
                log_warning("Could not open $file: $!");
                return;
            };
            my $content = do {
                local $/;
                <$fh>
            };
            close($fh);

            my $parse_error = validate_xml_content_pure_perl($content);

            if ($parse_error) {
                $failed_count++;
                log_error("INVALID XML [$file]: $parse_error");
            }
            elsif ($verbose) {
                log_success("VALID XML [$file]");
            }
        },
        no_chdir => 1
    }, @dirs);

    if ($failed_count > 0) {
        log_error("XML Check Failed: Found $failed_count invalid file(s) out of $total_checked checked.");
    }
    else {
        log_success("XML Check Passed: All $total_checked file(s) are well-formed XML.");
    }

    return $failed_count;
}

__END__