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
};
my $java_patterns = {
    "org\\.apache\\.commons\\.lang\\." => "commons-lang",
    "org\\.apache\\.commons\\.collections\\." => "commons-collections",
    "com\\.ibm\\.mq\\.jms" => "IBM MQ JMS",
    "WebMvcConfigurerAdapter" => "WebMvcConfigurerAdapter",
    "MappingJacksonJsonView *get" => "MappingJacksonJsonView",
    'import *javax\.(?!cache|crypto|mail|management|naming|net|sql|xml\.(?>XMLConstants|catalog|datatype|namespace|parsers|stream|transform|validation|xpath))(\w+)' => 'javax.$1',
    "RequestMappingHandlerAdapter *request" => "rename to createRequestMappingHandlerAdapter",
    "HandlerInterceptorAdapter" => "HandlerInterceptorAdapter",
    "org.apache.http.client" => "httpcomponents",
    "org.apache.commons.httpclient" => "httpcomponents",
    "DefaultHttpRequestRetryStrategy" => "retry strategies",
    "getPatternsCondition" => "test-harness",
    "swagger" => "swagger",
    "\@Api" => "swagger",
    "springfox" => "springfox",
    "(MQ_QMGRNAME|MgicQueueConnectionFactory.setCluster)" => "MQCLUSTER",
    "(?<!Service)\\.findOne\\(\\w+\\)" => "refactor to use findById()",
    "org\\.\\apereo\\." => "remove Apereo CAS",
    "ExtranetAuthorizationFilter" => "replace with EmployeeFormBasedAuthFilterForLDAP",
    "isAuthorizedUser" => "replace with manageAuthorizedUser",
    "EmployeeLdapHelper[^V]" => "remove EmployeeLdapHelper",
    "(ticketValidation|authentication)Filter" => "remove ticketValidation and authentication filters",
    "\\.setApplicationId\\([_\\w]+\\)" => "convert from setApplicationId() to setUrl()",
    "\@DependsOn" => "replace \@DependsOn with DI",
    "com.mgic.(spring|system).Environment" => "refactor to use environment properties",
    "import [\\w\\.]+\.EnvironmentHelper" => "import mgic.com.spring.Environment",
    "EnvironmentHelper" => "refactor to use Environment component",
    'ConnectModuleDataSource' => 'refactor to CyberArkDatasource',
    '@EnableWebMvc' => 'remove EnableWebMvc annotation',
    '\.getConnectInfo\W' => 'replace with getConnectInfoForURL',
    'import org.powermock' => 'remove powermock',
    'import +org.apache.log4j.Logger' => 'remove old log4j',
    'new (Integer|Short|Long|Byte)[^\w]' => 'fix $1 boxing',
    '\.(setRemovedAbandoned)\(' => 'replace $1 with setRemoveAbandonedOnMaintenance',
    '\.(setTimeBetweenEvictionRunsMillis)\(' => 'replace $1 with setDurationBetweenEvictionRuns',
    '\.(setRemoveAbandonedTimeout)\((\d+)' => 'replace $1($2) with $1(Duration)',
    '\.(setMaxWait)\((\d+)' => 'replace $1($) with $1(Duration)',
    '@EnableMBeanExport' => 'remove @EnableMBeanExport',
    '(CommonsMultipartResolver)' => 'replace $1 with StandardServletMultipartResolver',
    '(\w*JdbcTemplate)' => '$1',
    'BigDecimal.*getResult' => 'query returns BigDecimal',
    'filter\.PageFilter' => 'replace PageFilter with SiteMeshFilter',
};
my $xml_patterns = {
    "org\\.jasig" => "jasig CAS",
    "org\\.apereo\\.cas" => "remove apereo CAS",
    "<buildFile[^>]* />" => "missing add-opens",
    "<bean" => "move beans to java config",
    "JDK_(?!21)" => "JDK",
    "http://java.sun.com/xml/ns/javaee" => "upgrade to jakarta 6.0",
    "Extranet(Authentication|TicketValidation)Filter" => "remove extranet filters",
    "(ticketValidation|authentication)Filter" => "remove ticketValidation and authentication filters",
    "nagios" => "remove nagios from security groups",
    'mgic.entity.revision=\d+' => "check mgic.entity.revision",
};
my $iml_patterns = {
    '"MQ"' => 'use tomcat10 library',
    'jdkName="(?!21)(.*)"' => "JDK",
};
my $jsp_patterns = {
    "javax\\.servlet\\.jsp" => "javax JSP API",
    "(http://java.sun.com/jsp|https://www.owasp.org)" => "old taglibs",
    "<enc:forJavaScriptBlockvalue" => "enc:forJavaScriptBlockvalue",
    "<form:form.*commandName=" => "commandName",
};
my $js_patterns = {
    '^(\s*)(.*\.(append|html)\()((?!sanitized)[_\w]+)(\);)\s*$' => 'unsanitized $3',
};
my $properties_patterns = {
    "content.ts.mgicint.net" => "static content",
    "(rd|qa).content.mgic.(com|net)" => "static content",
    "ojdbc8.jat" => "move ojdbc8 driver to ivy.xml",
};
my $yaml_patterns = {
    "core.yml" => "upgrade for java21",
    "BUILD\\.DEPLOY" => "upgrade for java21",
};
my $sh_patterns = {
    "umask *022" => "update setenv.sh",
    "/jre/" => "fix cacerts folder",
};

my @required_files = (
    'pom.xml',
    'build.xml',
    'ivy.xml',
    'build-standard.xml',
    'build.properties',
    '.gitignore',
);


my $checks;
my ($help);

GetOptions(
    "dir|d=s"        => \$start_directory,
    "help|h"        => \$help,
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
    die BOLD RED "Error: Starting directory '$start_directory' does not exist or is inaccessible.\n" . RESET;
    exit 1;
}
print BOLD MAGENTA "DEBUG (Top-Level): File::Find will start from absolute path: '$abs_start_directory_resolved'\n" . RESET;

print BOLD GREEN "--- Starting All Safety Checks ---\n" . RESET;
safety_check($start_directory, 'java', $java_patterns) if $checks->{java} || $checkAll;
safety_check($start_directory, 'jsp', $jsp_patterns) if $checks->{jsp} || $checkAll;
safety_check($start_directory, 'js', $js_patterns) if $checks->{js} || $checkAll;
safety_check($start_directory, 'properties', $properties_patterns) if $checks->{properties} || $checkAll;
safety_check($start_directory, 'xml', $xml_patterns) if $checks->{xml} || $checkAll;
safety_check($start_directory, 'iml', $iml_patterns) if $checks->{iml} || $checkAll;
safety_check($start_directory, 'yml', $yaml_patterns) if $checks->{yml} || $checkAll;
safety_check($start_directory, 'sh', $sh_patterns) if $checks->{sh} || $checkAll;
misc_checks($start_directory) if $checks->{misc} || $checkAll;
print BOLD GREEN "--- All Safety Checks Complete ---\n" . RESET;
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
        print BOLD RED "Error: Invalid regular expression pattern '$p': $@\n" . RESET;
        exit 1;
    }
    }

    print BOLD BLUE "\n---Running Safety Check for *.$file_extension files ---\n" . RESET;
    print BOLD BLUE "  Target files with extension: " . $file_extension . "\n" . RESET;
    print BOLD BLUE "  Searching for patterns:\n" . RESET;
    foreach my $p_regex (sort keys %$patterns_ref) {
    print BOLD BLUE "    - '$p_regex' (Identified as: " . $patterns_ref->{$p_regex} . ")\n" . RESET;
    }
    print BOLD BLUE "  Starting directory: " . $current_dir . "\n" . RESET;
    print "-" x 50 . "\n\n";

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

    my $file_path_raw = $File::Find::name;
    my ($filename, $dirs, $suffix) = fileparse($file_path_raw, qr/\.[^.]*$/);

    return unless lc $suffix eq $lc_target_extension_with_dot;

    # remove unwanted files
    if ($remove_if_exists->{$filename}) {
        print BOLD YELLOW "$file_path_raw " . $remove_if_exists->{$filename} . "\n" . RESET;
        return;
    }

    open my $fh, "<", $_ or do {
        warn BOLD YELLOW "Warning: could not open $file_path_raw: $!" . RESET . "\n";
        return;
    };

    ++$file_count;

    my $line_num = 0;
    my $file_has_match = 0;

    while (my $line = <$fh>) {
        $line_num ++;
        for my $pattern_regex_key (keys %compiled_patterns) {
        if ($line =~ $compiled_patterns{$pattern_regex_key}) {
            $file_has_match = 1;
            my $output_string = $patterns_ref->{$pattern_regex_key};
            my @matches = ($1, $2, $3, $4, $5, $6, $7, $8, $9);
            $output_string =~ s/\$(\d+)/$matches[$1-1]/ge;
            print BOLD YELLOW "$file_path_raw " . $output_string . "\n" . RESET;
        }
        }
        last if $file_has_match;
    }
    close $fh;
    };

    find($wanted_sub, $current_dir);
    print BOLD BLUE "  Validated files: " . $file_count . "\n" . RESET;
    print "-" x 50 . "\n\n";
}

sub misc_checks {
    my ($current_dir) = @_;

    for my $file (@required_files) {
        check_for_file($file);
    }
}

sub check_for_file {
    my ($file) = @_;

    if (! -f $file) {
        print BOLD YELLOW $file . " missing\n" . RESET;
    } else {
        my $x=`git ls-files --error-unmatch $file`;
        print BOLD YELLOW $file . " is not in repository\n" . RESET if $?;
    }
}

