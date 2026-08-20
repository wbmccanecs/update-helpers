package MyLogger;

use strict;
use warnings;
use Term::ANSIColor qw{:constants};

use Exporter 'import';
our @EXPORT_OK = qw(
    log_info
    log_warning
    log_error
    log_success
);

sub log_info {
    my ($message, $color) = @_;
    $color ||= CYAN;
    print BOLD $color . "[INFO] $message" . RESET . "\n";
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

1;