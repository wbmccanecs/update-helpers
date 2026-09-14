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
    # Old APIs
    'org\.apache\.commons\.lang\.'                                                                                                                                   => "commons-lang",
    'org\.apache\.commons\.collections\.'                                                                                                                            => "commons-collections",
    'com\.ibm\.mq\.jms'                                                                                                                                              => "IBM MQ JMS",
    'import *javax\.(?!cache|crypto|mail|management|naming|net|sql|xml\.(?>XMLConstants|catalog|datatype|namespace|parsers|stream|transform|validation|xpath))(\w+)' => 'javax.$1',
    'org\.apache\.http\.client'                                                                                                                                      => "httpcomponents",
    "org\.apache\.commons\.httpclient"                                                                                                                               => "httpcomponents",
    "springfox"                                                                                                                                                      => "upgrade springfox to springdoc",
    'import +org\.apache\.log4j\.Logger'                                                                                                                             => 'replace log4j with slf4j',
    'import +org\.apache\.commons\.logging'                                                                                                                          => 'replace commons-logging with slf4j',

    # SSOE replacement
    'org\.\apereo\.'                                                                                                                                                 => "remove Apereo CAS",
    'ExtranetAuthorizationFilter'                                                                                                                                    => "replace with EmployeeFormBasedAuthFilterForLDAP",
    'isAuthorizedUser'                                                                                                                                               => "replace with manageAuthorizedUser",
    'EmployeeLdapHelper[^V]'                                                                                                                                         => "remove EmployeeLdapHelper",
    '(ticketValidation|authentication)Filter'                                                                                                                        => "remove ticketValidation and authentication filters",

    '\b(?!SpringWebConfig\b)\w+\s+(implements\s+WebMvcConfigurer)'                                                                                                   => 'remove $1',
    'extends +(WebMvcConfigurerAdapter|WebMvcConfigurationSupport)'                                                                                                  => "implement WebMvcConfigurer",
    'HandlerInterceptorAdapter'                                                                                                                                      => "HandlerInterceptorAdapter",
    'DefaultHttpRequestRetryStrategy'                                                                                                                                => "retry strategies",
    'getPatternsCondition'                                                                                                                                           => "test-harness",
    "(MQ_QMGRNAME|MgicQueueConnectionFactory.setCluster)"                                                                                                            => "MQCLUSTER",
    "(?<!Service)\\.findOne\\(\\w+\\)"                                                                                                                               => "refactor to use findById()",
    '\.setApplicationId\(\D[_\w]+\)'                                                                                                                                 => "convert from setApplicationId() to setUrl()",
    "\@DependsOn"                                                                                                                                                    => "replace \@DependsOn with DI",
    'com\.mgic\.(spring|system)\.Environment'                                                                                                                        => "refactor to use environment properties",
    'import +[\w\.]+\.EnvironmentHelper'                                                                                                                             => "import mgic.com.spring.Environment",
    'EnvironmentHelper'                                                                                                                                              => "refactor to use Environment component",
    'ConnectModuleDataSource'                                                                                                                                        => 'refactor to CyberArkDatasource',
    '\.getConnectInfo\W'                                                                                                                                             => 'replace with getConnectInfoForURL',
    'import +org.powermock'                                                                                                                                          => 'remove powermock',
    'import +org.easymock'                                                                                                                                           => 'remove easymock',
    'new +(Integer|Short|Long|Byte)[^\w]'                                                                                                                            => 'fix $1 boxing',
    '@EnableMBeanExport'                                                                                                                                             => 'remove @EnableMBeanExport',
    '(CommonsMultipartResolver)'                                                                                                                                     => 'replace $1 with StandardServletMultipartResolver',
    '(\w*JdbcTemplate)'                                                                                                                                              => '$1',
    'filter\.PageFilter'                                                                                                                                             => 'replace PageFilter with SiteMeshFilter',
    'com\.mgic\.business\.aims\.'                                                                                                                                    => 'use aimservice-client.jar',
    'org\.hibernate\.annotations\.Named'                                                                                                                             => 'use JPA NamedNativeQuery',

    '(@Value.*Integer\.MAX_VALUE)'                                                                                                                                   => 'update SpEL $1',

    # FQCN Declarations
    '^(?:[^/]|/(?!/))*?(?:private|public|protected)?\s+(?:final\s+)?(?:static\s+)?((?:[a-z][a-zA-Z0-9_]*\.){2,}[A-Z][a-zA-Z0-9_]*)\s+\w+(?:\s*[=;,])'                => 'FQCN member declaration: $1',
    '^(?:[^/]|/(?!/))*?\bnew\s+((?:[a-z][a-zA-Z0-9_]*\.){2,}[A-Z][a-zA-Z0-9_]*)\s*\('                                                                                => 'FQCN construction: $1',
    '(JMSC\.MQJMS_(\w+))'                                                                                                                                            => 'replace $1 with WMQConstants.WMQ_$2',
};

my $java_multiline_patterns = {
    # Potential CVE vulnerabilities
    '@(?:NativeQuery|Query\s*\(\s*value[^,]+,\s*nativeQuery\s*=\s*true\s*\)|Query\s*\(\s*nativeQuery\s*=\s*true\s*\))[^;]*?(?:Pageable|Sort)\s+\w+' => 'Potential SQL Injection vulnerability (SNYK-JAVA-ORGSPRINGFRAMEWORKDATA-19267482)',
    '\b(AutoPopulatingList|LazyList)\b'                                                                                                             => 'Potential DoS (SNYK-JAVA-ORGSPRINGFRAMEWORK-19267072): self-populating list ($1) usage detected',

    # Return types and parameters
    'BigDecimal[^;{}]*?getResult'                                                                                                                   => 'query returns BigDecimal',
    'MappingJacksonJsonView\s+get'                                                                                                                  => 'MappingJacksonJsonView',
    'RequestMappingHandlerAdapter\s+request'                                                                                                        => 'rename to createRequestMappingHandlerAdapter',

    # Chained methods (DBCP2 / Commons Pool upgrades)
    '\s*\.\s*(setRemovedAbandoned)\s*\('                                                                                                            => 'replace $1 with setRemoveAbandonedOnMaintenance',
    '\s*\.\s*(setTimeBetweenEvictionRunsMillis)\s*\('                                                                                               => 'replace $1 with setDurationBetweenEvictionRuns',
    '\s*\.\s*(setRemoveAbandonedTimeout)\s*\(\s*(\d+)'                                                                                              => 'replace $1($2) with $1(Duration)',
    '\s*\.\s*(setMaxWait)\s*\(\s*(\d+)'                                                                                                             => 'replace $1($) with $1(Duration)',

    # Annotations
    '@EnableWebMvc(?!.*\bWebMvcConfigurer\b)'                                                                                                       => 'remove EnableWebMvc annotation',
    '(?s)\A(?!.*@EnableWebMvc).*\bWebMvcConfigurer\b'                                                                                               => 'add missing EnableWebMvc annotation',
};

my $xml_patterns = {
    'org\.jasig'                                      => "jasig CAS",
    'org\.apereo\.cas'                                => "remove apereo CAS",
    '<bean'                                           => "move beans to java config",
    'JDK_(?!21)'                                      => "JDK",
    'http://java.sun.com/xml/ns/javaee'               => "upgrade to jakarta 6.0",
    'Extranet(Authentication|TicketValidation)Filter' => "remove extranet filters",
    "(ticketValidation|authentication)Filter"         => "remove ticketValidation and authentication filters",
    "nagios"                                          => "remove nagios from security groups",
    'mgic.entity.revision=\d+'                        => "check mgic.entity.revision",
    'smoke-status.htm'                                => 'remove smoke-status.htm',
};

my $xml_multiline_patterns = {
    '<buildFile[^>]*/>' => 'missing add-opens',
};

my $iml_patterns = {
    '"MQ"'                       => 'use tomcat10 library',
    'jdkName="(?!(jdk)?21)(.*)"' => "JDK",
};

my $jsp_patterns = {
    'javax\.servlet\.jsp'                             => "javax JSP API",
    '(http://java.sun.com/jsp|https://www.owasp.org)' => "old taglibs",
    '<enc:forJavaScriptBlockvalue'                    => "enc:forJavaScriptBlockvalue",
};

my $jsp_multiline_patterns = {
    '<form:form.*?commandName=' => 'commandName',
};

my $js_patterns = {}; # JS checks handled by analyze_javascript_file()

my $properties_patterns = {
    "content.ts.mgicint.net"         => "static content",
    "(rd|qa).content.mgic.(com|net)" => "static content",
    "ojdbc8.jat"                     => "move ojdbc8 driver to ivy.xml",
    'sb\.application\.servers'       => "remove sb.application.servers",
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
safety_check($start_directory, 'java', $java_patterns, $java_multiline_patterns) if $checks->{java} || $checkAll;
if ($checks->{jsp} || $checkAll) {
    safety_check($start_directory, 'jsp', $jsp_patterns, $jsp_multiline_patterns);
    check_unused_tagdefs($start_directory);
    check_xml_well_formedness($start_directory, [ 'jsp', 'jspf', 'htm', 'html', 'tld', 'tag' ]);
}
safety_check($start_directory, 'js', $js_patterns) if $checks->{js} || $checkAll;
safety_check($start_directory, 'properties', $properties_patterns) if $checks->{properties} || $checkAll;
if ($checks->{xml} || $checkAll) {
    safety_check($start_directory, 'xml', $xml_patterns, $xml_multiline_patterns);
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
    my ($current_dir, $file_extension, $patterns_ref, $multiline_patterns_ref) = @_;

    my $lc_target_extension_with_dot = "." . lc $file_extension;

    my %compiled_patterns;
    foreach my $p (keys %$patterns_ref) {
        eval {$compiled_patterns{$p} = qr/$p/;};
        if ($@) {
            log_error("Error: Invalid regular expression pattern '$p': $@");
            exit 1;
        }
    }

    # Compile Multiline Patterns if provided
    my %compiled_multiline_patterns;
    if (defined $multiline_patterns_ref) {
        foreach my $p (keys %$multiline_patterns_ref) {
            eval {$compiled_multiline_patterns{$p} = qr/$p/sm;};
            if ($@) {
                log_error("Error: Invalid multiline pattern '$p': $@");
                exit 1;
            }
        }
    }

    log_info("\nRunning Safety Check for *.$file_extension files");
    log_info("-" x 50);

    my $file_count = 0;

    my $wanted_sub = sub {
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
                    $full_path_relative =~ '.*/war/web/scripts/jquery' ||
                    $full_path_relative =~ '.*/.settings'
            ) {
                $File::Find::prune = 1;
                return;
            }
        }

        return unless -f $_;

        my $file_path = $File::Find::name;
        my ($filename, $dirs, $suffix) = fileparse($file_path, qr/\.[^.]*$/);

        # Only run JS analysis when safety_check is specifically scanning .js files
        if (lc($file_extension) eq 'js') {
            if (lc($suffix) eq '.js') {
                analyze_javascript_file($_, $file_path);
                $file_count++;
            }
            return;
        }

        my $validated = check_single_file($_, $file_path, $lc_target_extension_with_dot, \%compiled_patterns, $patterns_ref, \%compiled_multiline_patterns, $java_multiline_patterns);
        $file_count++ if $validated;
    };

    find($wanted_sub, $current_dir);
    log_info("  Validated files: $file_count");
    log_info("-" x 50);
}

sub check_single_file {
    my ($file_to_open, $file_path_display, $lc_target_extension_with_dot, $compiled_patterns, $patterns_ref, $compiled_multiline_patterns, $multiline_patterns_ref) = @_;

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

    if (defined $compiled_multiline_patterns && keys %$compiled_multiline_patterns > 0) {
        my $full_text = join("", @lines);

        for my $pattern_regex_key (keys %$compiled_multiline_patterns) {
            while ($full_text =~ /$compiled_multiline_patterns->{$pattern_regex_key}/g) {
                my @matches = ($1, $2, $3, $4, $5, $6, $7, $8, $9);
                my $match_pos = $-[0];
                my $exact_line = () = substr($full_text, 0, $match_pos) =~ /\n/g;
                $exact_line++;

                my $output_string = $multiline_patterns_ref->{$pattern_regex_key};
                $output_string =~ s{\$(\d+)}{$matches[$1 - 1] // ''}ge;

                if (defined $lc_target_extension_with_dot && $lc_target_extension_with_dot eq ".java") {
                    (my $fpd = $file_path_display) =~ s#^./(src|test)/##;
                    $fpd =~ s#/#.#g;
                    $fpd =~ s/$lc_target_extension_with_dot//;
                    log_warning("$fpd.($filename:$exact_line) - " . $output_string);
                }
                else {
                    log_warning("$file_path_display line $exact_line: " . $output_string);
                }
            }
        }
    }

    my %imports;
    for my $line (@lines) {
        if ($line =~ /^\s*import\s+(?:static\s+)?((?:[a-z][a-zA-Z0-9_]*\.)+([A-Z][a-zA-Z0-9_]*))\s*;\s*$/) {
            $imports{$2} = $1;
        }
    }

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

                $output_string =~ s{\$(\d+)}{$matches[$1 - 1] // ''}ge;

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
                last;
            }
        }
        last if $found_count == $patterns_count;
    }

    return 1;
}

sub analyze_javascript_file {
    my ($file_to_open, $file_path_display) = @_;

    open my $fh, "<", $file_to_open or do {
        log_warning("Warning: could not open $file_path_display: $!");
        return;
    };

    my @lines = <$fh>;
    close $fh;

    my %sanitized_vars;
    my %tainted_vars;
    my %callback_funcs;
    my %ajax_requests;
    my $line_num = 0;

    # Pre-pass: detect inline network callbacks and named-function registrations to mark taint origins by origination
    my $source = join('', @lines);

    # Robustly find $.post/.get/.getJSON occurrences and extract callback function parameters even when args contain parentheses
    my $slen = length($source);
    my $pos = 0;
    while (1) {
        my $pidx = index($source, '$.', $pos);
        last if $pidx < 0;
        # peek method name after '$.'
        if (substr($source, $pidx, 6) =~ /^\$\.(post|get|getJSON)/) {
            my ($method) = ($1 // undef);
            # find first '(' after method
            my $after = index($source, '(', $pidx);
            if ($after > $pidx) {
                # extract balanced parentheses content
                my $depth = 0;
                my $in_q = '';
                my $content = '';
                for (my $i = $after + 1; $i < $slen; $i++) {
                    my $c = substr($source, $i, 1);
                    if ($in_q) {
                        if ($c eq $in_q && substr($source, $i - 1, 1) ne '\\\\') {$in_q = '';}
                    }
                    else {
                        if ($c eq '"' || $c eq "'" || $c eq '`') {$in_q = $c;}
                        elsif ($c eq '(') {$depth++;}
                        elsif ($c eq ')') {
                            if ($depth == 0) {last}
                            $depth--;
                        }
                    }
                    $content .= $c;
                }
                # look for callback function inside content
                while ($content =~ /function\s*\(\s*([^\)]*)\)/g) {
                    my $params = $1;
                    my $prior_src = substr($source, 0, $pidx);
                    for my $p (split /\s*,\s*/, $params) {
                        $p =~ s/^\s+|\s+$//g;
                        next unless length $p;
                        # getJSON -> JSON response -> don't taint
                        if (defined $method && lc($method) eq 'getjson') {next}
                        # If there is an earlier variable with same name assigned from .serialize() before this invocation, skip tainting (naming collision)
                        if ($prior_src =~ /(?:var|let|const)\s+\Q$p\E\s*=\s*[^;]*\.serialize\s*\(/s) {next}
                        $tainted_vars{$p} = 1;
                    }
                }
            }
            $pos = $pidx + 2;
        }
        else {$pos = $pidx + 2}
    }

    # Handle $.ajax calls assigned to a request variable: var req = $.ajax({ ... })
    while ($source =~ /(?:var|let|const)\s+([a-zA-Z0-9_\$]+)\s*=\s*\$\.ajax\s*\(\s*\{(.*?)\}\s*\)/gs) {
        my ($reqVar, $obj) = ($1, $2);
        my $dataType = '';
        if ($obj =~ /dataType\s*:\s*['"]([^'"]+)['"]/i) {
            $dataType = lc $1;
        }
        $ajax_requests{$reqVar} = ($dataType eq 'json') ? 1 : 0;
        # If not json, mark inline success handlers as tainted
        if ($dataType ne 'json') {
            while ($obj =~ /\b(success|done|then)\s*:\s*function\s*\(\s*([^\)]*)\)/g) {
                my $params = $2;
                for my $p (split /\s*,\s*/, $params) {
                    $p =~ s/^\s+|\s+$//g;
                    $tainted_vars{$p} = 1 if length $p;
                }
            }
            while ($obj =~ /\b(success|done|then)\s*:\s*([a-zA-Z0-9_\$]+)/g) {
                $callback_funcs{$2} = 1;
            }
        }
        else {
            while ($obj =~ /\b(success|done|then)\s*:\s*([a-zA-Z0-9_\$]+)/g) {
                $callback_funcs{$2} = 1;
            }
        }
    }

    # Inline $.ajax(...) calls without assignment (e.g., $.ajax({...}).done(...))
    while ($source =~ /\$\.ajax\s*\(\s*\{(.*?)\}\s*\)/gs) {
        my $obj = $1;
        my $dataType = '';
        if ($obj =~ /dataType\s*:\s*['"]([^'"]+)['"]/i) {
            $dataType = lc $1;
        }
        if ($dataType ne 'json') {
            while ($obj =~ /\b(success|done|then)\s*:\s*function\s*\(\s*([^\)]*)\)/g) {
                my $params = $2;
                for my $p (split /\s*,\s*/, $params) {
                    $p =~ s/^\s+|\s+$//g;
                    $tainted_vars{$p} = 1 if length $p;
                }
            }
            while ($obj =~ /\b(success|done|then)\s*:\s*([a-zA-Z0-9_\$]+)/g) {
                $callback_funcs{$2} = 1;
            }
        }
        else {
            while ($obj =~ /\b(success|done|then)\s*:\s*([a-zA-Z0-9_\$]+)/g) {
                $callback_funcs{$2} = 1;
            }
        }
    }

    # Detect $.post(..., function(...) { ... }) even with multiple preceding args and scan the callback body for unsafe DOM insertion
    while ($source =~ /\$\.post\s*\([^\)]*function\s*\(\s*([^\)]*)\)\s*\{(.*?)\}\s*\)/gs) {
        my ($params, $body) = ($1, $2);
        my $match_start = $-[0];
        for my $p (split /\s*,\s*/, $params) {
            $p =~ s/^\s+|\s+$//g;
            next unless length $p;
            # If there is an earlier variable with same name assigned from .serialize() before this $.post, skip tainting (common naming collision)
            my $prior_src = substr($source, 0, $match_start);
            if ($prior_src =~ /(?:var|let|const)\s+\Q$p\E\s*=\s*[^;]*\.serialize\s*\(/s) {
                next;
            }
            $tainted_vars{$p} = 1;
            # If callback body inserts the param into DOM via append/html/prepend, warn with line
            while ($body =~ /\.(append|html|prepend)\s*\(\s*([^\)]*\b\Q$p\E\b[^\)]*)\)/gs) {
                my $arg = $2;
                # skip if the tainted variable is being sanitized (DOMPurify, escapeUtils.escapeHtml, or escapeHtml(...))
                if ($arg =~ /(?:DOMPurify\.sanitize|escapeUtils\.escapeHtml|\bescapeHtml\s*)\s*\(/) {next;}
                # compute approximate line number by counting newlines before the match position
                my $match_pos = $-[0] + (pos($source) - length($body));
                my $line_num = () = substr($source, 0, $match_pos) =~ /\n/g;
                $line_num++;
                my $clean_arg = $arg;
                $clean_arg =~ s/\s+/ /g;
                log_warning("$file_path_display line $line_num: unsanitized DOM input (from $.post callback param $p): $clean_arg");
            }
        }
    }

    # Inline $.getJSON(url, function(data){}) and $.get/post with callback
    # Match $.get/.post/.getJSON with any args before a callback function: e.g. $.post(url, data, function(resp){})
    while ($source =~ /\$\.((?:getJSON|get|post))\s*\([^)]*?\bfunction\s*\(\s*([^\)]*)\)/gs) {
        my ($method, $params) = ($1, $2);
        my $match_start = $-[0];
        my $prior_src = substr($source, 0, $match_start);
        for my $p (split /\s*,\s*/, $params) {
            $p =~ s/^\s+|\s+$//g;
            next unless length $p;
            if (lc($method) eq 'getjson') {
                next; # getJSON -> JSON response, don't taint
            }
            # Skip tainting if an earlier variable with same name was assigned from .serialize()
            if ($prior_src =~ /(?:var|let|const)\s+\Q$p\E\s*=\s*[^;]*\.serialize\s*\(/s) {next;}
            $tainted_vars{$p} = 1;
        }
    }

    # fetch(...).then(function(resp){}) chains
    while ($source =~ /fetch\s*\([^\)]*\)\s*\.\s*then\s*\(\s*function\s*\(\s*([^\)]*)\)/gs) {
        my $params = $1;
        for my $p (split /\s*,\s*/, $params) {
            $p =~ s/^\s+|\s+$//g;
            $tainted_vars{$p} = 1 if length $p;
        }
    }

    # Handle requestVar.done(function(...)) only if requestVar was a $.ajax call without dataType:'json'
    while ($source =~ /([a-zA-Z0-9_\$]+)\s*\.\s*done\s*\(\s*function\s*\(\s*([^\)]*)\)/gs) {
        my ($reqVar, $params) = ($1, $2);
        if (exists $ajax_requests{$reqVar} && $ajax_requests{$reqVar} == 0) {
            for my $p (split /\s*,\s*/, $params) {
                $p =~ s/^\s+|\s+$//g;
                $tainted_vars{$p} = 1 if length $p;
            }
        }
    }

    # Registrations of named handlers: $(document).ajaxError(handler), .on('ajaxError', handler), jQuery.ajax({ error: handlerName })
    while ($source =~ /\.(?:ajaxError)\s*\(\s*([a-zA-Z0-9_\$]+)/gs) {
        $callback_funcs{$1} = 1;
    }
    while ($source =~ /\.on\s*\(\s*['"]ajaxError['"]\s*,\s*([a-zA-Z0-9_\$]+)/gs) {
        $callback_funcs{$1} = 1;
    }
    while ($source =~ /\$\.ajax\s*\(\s*\{(.*?)\}\s*\)/gs) {
        my $obj = $1;
        while ($obj =~ /\berror\s*:\s*([a-zA-Z0-9_\$]+)/g) {
            $callback_funcs{$1} = 1;
        }
    }

    # If a named callback function was registered, find its definition and mark its params tainted
    while ($source =~ /function\s+([a-zA-Z0-9_\$]+)\s*\(\s*([^\)]*)\)/gs) {
        my ($fname, $params) = ($1, $2);
        if ($callback_funcs{$fname}) {
            for my $p (split /\s*,\s*/, $params) {
                $p =~ s/^\s+|\s+$//g;
                $tainted_vars{$p} = 1 if length $p;
            }
        }
    }

    # Additional heuristic: scan entire file for insertions that reference any tainted param identifier
    for my $t (keys %tainted_vars) {
        while ($source =~ /\.(?:append|html|prepend)\s*\(\s*([^\)]*\b\Q$t\E\b[^\)]*)\)/gs) {
            my $arg = $1;
            # skip if the tainted variable is being sanitized (DOMPurify, escapeUtils.escapeHtml, or escapeHtml(...)) in the insertion
            if ($arg =~ /(?:DOMPurify\.sanitize|escapeUtils\.escapeHtml|\bescapeHtml\s*)\s*\(/) {next;}
            my $match_pos = $-[0];
            my $line_num = () = substr($source, 0, $match_pos) =~ /\n/g;
            $line_num++;
            my $clean_arg = $arg;
            $clean_arg =~ s/\s+/ /g;
            log_warning("$file_path_display line $line_num: unsanitized DOM input (from $t): $clean_arg");
        }
    }

    # Also propagate taint through simple assignments: var x = taintedVar; x = taintedVar; const/let/var
    # We'll do this later while scanning lines to capture order-based propagation

    for my $line (@lines) {
        $line_num++;

        # Track variables assigned via DOMPurify.sanitize(...)
        while ($line =~ /(?:var|let|const|\s|^)\s*([a-zA-Z0-9_\$]+)\s*=\s*DOMPurify\.sanitize\b/g) {
            $sanitized_vars{$1} = $line_num;
        }

        # Propagate taint through simple assignments encountered in order
        while ($line =~ /(?:var|let|const)\s+([a-zA-Z0-9_\$]+)\s*=\s*([^;]+)/g) {
            my ($lhs, $rhs) = ($1, $2);
            for my $t (keys %tainted_vars) {
                if ($rhs =~ /\b\Q$t\E\b/) {
                    $tainted_vars{$lhs} = $line_num;
                    last;
                }
            }
        }
        while ($line =~ /([a-zA-Z0-9_\$]+)\s*=\s*([^;]+)/g) {
            my ($lhs, $rhs) = ($1, $2);
            for my $t (keys %tainted_vars) {
                if ($rhs =~ /\b\Q$t\E\b/) {
                    $tainted_vars{$lhs} = $line_num;
                    last;
                }
            }
        }

        while ($line =~ /\.(append|html|prepend)\s*\(/g) {
            my $start_pos = pos($line);
            my $depth = 1;
            my $pos = $start_pos;
            my $len = length($line);
            my $in_quote = '';
            my $arg = '';

            while ($pos < $len && $depth > 0) {
                my $char = substr($line, $pos, 1);

                if ($in_quote) {
                    if ($char eq $in_quote && substr($line, $pos - 1, 1) ne '\\') {
                        $in_quote = '';
                    }
                }
                else {
                    if ($char eq '"' || $char eq "'" || $char eq "`") {
                        $in_quote = $char;
                    }
                    elsif ($char eq '(') {
                        $depth++;
                    }
                    elsif ($char eq ')') {
                        $depth--;
                    }
                }

                if ($depth > 0) {
                    $arg .= $char;
                }
                $pos++;
            }

            $arg =~ s/^\s+|\s+$//g;
            next unless length $arg;

            # Skip if argument is a single static string literal (single/double/backtick)
            if ($arg =~ /^\s*(['"`]).*\1\s*$/s) {
                next;
            }

            # Rule A: Inline sanitizer calls (DOMPurify, escapeUtils.escapeHtml, or escapeHtml(...))
            next if $arg =~ /(?:DOMPurify\.sanitize|escapeUtils\.escapeHtml|\bescapeHtml\s*\()/;

            # Rule B: Parameter is a variable sanitized earlier in this file
            if ($arg =~ /^([a-zA-Z0-9_\$]+)$/) {
                my $var_name = $1;
                next if exists $sanitized_vars{$var_name};
            }

            # Rule C: jQuery-created DOM nodes (e.g. $('<input>').attr(...)) or document.createElement(...)
            # These create elements and set attributes rather than injecting HTML strings, so consider them non-tainted
            if ($arg =~ /\$\s*\(\s*['"]\s*<\s*\w+/s || $arg =~ /document\.createElement\s*\(/) {
                next;
            }

            # Rule D: jQuery .val() results or direct element.value access are considered non-tainted by SNYK
            # e.g., $(this).val() or document.getElementById(...).value
            if ($arg =~ /\$\([^)]*\)\s*\.\s*val\s*\(/s || $arg =~ /\b\.value\b/) {
                next;
            }

            # Rule F: Only warn when the argument contains a tainted identifier (data from service calls)
            my $is_tainted = 0;
            for my $t (keys %tainted_vars) {
                if ($arg =~ /\b\Q$t\E\b/) {
                    $is_tainted = 1;
                    last;
                }
            }

            # Rule E: Concatenation of string literal(s) and identifiers (e.g. 'text' + var) — treat as non-tainted (matches SNYK heuristics)
            # Only apply this safe-concatenation heuristic when no tainted identifier is present
            if (!$is_tainted && $arg =~ /(['"`]).*?\1/s) {
                my $rest = $arg;
                $rest =~ s/(['"`]).*?\1//gs; # remove string literals
                $rest =~ s/\s+//g;           # remove whitespace
                $rest =~ s/\+//g;            # remove concatenation operators
                # if remaining chars are only identifiers, dots, brackets or dollar signs, consider safe
                if ($rest =~ /^[a-zA-Z0-9_\$\.\[\]]*$/) {
                    next;
                }
            }

            next unless $is_tainted;

            my $clean_arg = $arg;
            $clean_arg =~ s/\s+/ /g;
            log_warning("$file_path_display line $line_num: unsanitized DOM input: $clean_arg");
        }
    }
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
    log_info("-" x 50);

    my $file_count = 0;

    my $wanted_sub = sub {
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
                    $full_path_relative =~ '.*/.settings'
            ) {
                $File::Find::prune = 1;
                return;
            }
        }

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

    find(sub {
        return unless -f $_ && $_ eq 'tagdefs.jsp';
        $tagdefs_path = $File::Find::name;
    }, $current_dir);

    unless ($tagdefs_path && -f $tagdefs_path) {
        return;
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

    find(sub {
        if (-d $_) {
            my $full_path = $File::Find::name;
            if ($full_path =~ m#/(?:\.git|target|build|node_modules|bin|out|deploy|reports|test-automation|test-bin|war/META-INF|war/WEB-INF/classes|war/WEB-INF/lib|\.settings)$#) {
                $File::Find::prune = 1;
                return;
            }
        }

        return unless -f $_ && $_ =~ /\.(jsp|jspf|tag)$/i;
        return if $File::Find::name eq $tagdefs_path;

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

    $content =~ s/(<%--.*?--%>)/blank_keep_newlines($1)/gse;
    $content =~ s/(<%[@=!]?.*?%>)/blank_keep_newlines($1)/gse;
    $content =~ s/(\$\{[^}]*\})/blank_keep_newlines($1)/gse;
    $content =~ s/(<!--.*?-->)/blank_keep_newlines($1)/gse;
    $content =~ s/(<!\[CDATA\[.*?\]\]>)/blank_keep_newlines($1)/gse;
    $content =~ s/(<\?.*?\?>)/blank_keep_newlines($1)/gse;
    $content =~ s/(<!DOCTYPE.*?>)/blank_keep_newlines($1)/gse;

    # Blank taglib-style custom tags (e.g., <mux:.../>) BEFORE handling <script> / <style>
    my $taglib_regex = qr{
        </?
        [a-zA-Z0-9_\-\.]+:[a-zA-Z0-9_\-\.]+
        (?:\s+(?:[^"'>]|"[^"]*"|'[^']*')*)?
        /?>
    }xms;
    $content =~ s/($taglib_regex)/blank_keep_newlines($1)/gse;

    $content =~ s{(<script\b[^>]*>)(.*?)(</script>)}{$1 . blank_keep_newlines($2) . $3}gse;
    $content =~ s{(<style\b[^>]*>)(.*?)(</style>)}{$1 . blank_keep_newlines($2) . $3}gse;

    my @tag_stack;
    my $root_element_count = 0;

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

    while ($content =~ m{($tag_regex|[^<]+|<)}gs) {
        my $chunk = $1;
        my $chunk_pos = pos($content) - length($chunk);
        my $line_num = (substr($content, 0, $chunk_pos) =~ tr/\n//) + 1;

        if ($chunk eq '<') {
            return "Line $line_num: Malformed XML: Unclosed or orphaned '<' found";
        }
        elsif ($chunk =~ /^</) {
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

            if ($chunk =~ /^<\s*([a-zA-Z0-9_\-\.\:]+)([\s\S]*)?>$/s) {
                my $open_tag = $1;
                my $raw_body = $2 // '';
                my $lc_tag = lc($open_tag);

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

    return undef;
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