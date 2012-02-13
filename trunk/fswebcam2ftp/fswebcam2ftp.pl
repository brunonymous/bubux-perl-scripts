#!/usr/bin/perl
# @author Bruno Ethvignot <bruno at tlk.biz>
# @created 2012-02-04
# @date 2012-02-13
# http://code.google.com/p/bubux-perl-scripts/
#
# copyright (c) 2012 TLK Games all rights reserved
# $Id$
#
# fswebcam2ftp.pl is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# fswebcam2ftp.pl is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301, USA.
use strict;
use FindBin qw ( $Bin $Script );
use Config::General;
use Data::Dumper;
use Net::FTP;
use Getopt::Std;
use Net::SMTP::TLS;
use Sys::Syslog;
use Sys::Hostname;
use Time::HiRes qw ( gettimeofday tv_interval );
use vars qw($VERSION);
$Getopt::Std::STANDARD_HELP_VERSION = 1;
$VERSION                            = '0.8.2';
my $isVerbose       = 0;
my $isDebug         = 0;
my $isTest          = 0;
my $loopMax         = 0;
my $putSuccessCount = 0;
my $putTryCount     = 5;
my $configFileName  = 'fswebcam2ftp.conf';
my $actionSelected;
my $ftp;
my $ftp_ref;
my $fswebcam_ref;
my $smtp_ref;
my $sysLog_ref;
my %action = (
    'fswebcam2ftpProcess' => \&fswebcam2ftpProcess,
    'sendMailProcess'     => \&sendMailProcess,
    'listProcess'         => \&listProcess

);

eval {
    init();
    run();
};
if ($@) {
    my $error = $@;
    sayError($error);
    sayError("(!) fswebcam2ftp.pl failed!");
    sendMail( "The $Bin script crashed", "message: $error" );
    die $error;
}

## @method void END()
sub END {
    if ( defined $ftp ) {
        sayDebug( 'Send the QUIT command to the remote FTP server'
                . ' and close the socket connection' );

        $ftp->quit();
        undef($ftp);
    }
    sayDebug("Sys::Syslog::closelog");
    Sys::Syslog::closelog();
}

## @method void run();
sub run {
    my $actionSub = $action{$actionSelected};
    $actionSub->();
}

## @method void fswebcam2ftpProcess()
sub fswebcam2ftpProcess {
    $fswebcam_ref->{'image-counter'} = 0;
    if ( !-d $fswebcam_ref->{'pathname'} ) {
        die sayError("mkdir($fswebcam_ref->{'pathname'}): $!")
            if !mkdir( $fswebcam_ref->{'pathname'} );
    }
    ftpLogin();
    my $count = 0;
    while (1) {
        $count++;
        sayDebug("Loop $count");
        my $t0 = [gettimeofday];
        my ( $pathname, $filenameTmp, $filename ) = fswebcam();
        if ( !$isTest ) {
            eval {
                $ftp->put($pathname)
                    or die sayError(
                    'put($pathname) was failed: ' . $ftp->message() );
                sayInfo("put $pathname successful");
                $ftp->rename( $filenameTmp, $filename );
                sayInfo("rename to $filename successful");
                $putSuccessCount++;
                $putTryCount = 5;
            };
            if ($@) {
                my $error = $@;
                sayError($error);
                sayInfo("We try $putTryCount more times.");
                $putSuccessCount = 0;
                sendMail(
                    'FTP transfer error: ' . $putTryCount,
                    'An FTP error occurred:  ' . $error
                );
                if ( $putTryCount <= 1 ) {
                    die $error;
                }
                ftpLogin();
                $putTryCount--;
            }
            my $elapsed = tv_interval($t0);
            sayInfo(  'Time of capture and upload has lasted ' 
                    . $elapsed
                    . ' seconds' );
        }
        last if $loopMax > 0 and $count >= $loopMax;
    }
    sayInfo("The script is completed successfully.");
}

## @method void listProcess()
sub listProcess {
    ftpLogin(1);
}

## @method void sendMailProcess()
sub sendMailProcess {
    sendMail(
        'This is a simple test message.',
        "Just a quick message that validates the operation of sending e-mails."
    );

}

## @method void ftpLogin($showList)
# @brief
# @param boolean $showList
sub ftpLogin {
    my ($showList) = @_;
    $showList = 0 if !defined $showList;
    $ftp->quit() if defined $ftp;
    undef($ftp);
    sayDebug("Tries to access the $ftp_ref->{'hostname'} server");
    $ftp = Net::FTP->new(
        $ftp_ref->{'hostname'},
        'Passive' => $ftp_ref->{'passive'},
        'Timeout' => $ftp_ref->{'timeout'},
        'Debug'   => $isDebug
        )
        or die sayError(
        'Cannot connect to ' . $ftp_ref->{'hostname'} . ': ' . $@ );
    $ftp->login( $ftp_ref->{'username'}, $ftp_ref->{'password'} )
        or die sayError( 'Login failed for '
            . $ftp_ref->{'username'}
            . ' user: '
            . $ftp->message() );
    sayInfo( 'Successful login. Hostname: ' . $ftp_ref->{'hostname'} );
    $ftp->cwd( $ftp_ref->{'pathname'} )
        or die sayError( 'Can\'t cwd to ' . $ftp_ref->{'pathname'} );
    my @files = $ftp->ls();
    $ftp->binary();

    foreach my $filename (@files) {
        if ($showList) {
            print STDOUT "- $filename\n";
        }
        else {
            sayDebug($filename);
        }
    }
}

## @method string fswebcam()
#@brief Capture images from webcam
#@return string
sub fswebcam {
    my $filename = sprintf(
        $fswebcam_ref->{'filename'},
        $fswebcam_ref->{'image-counter'}
    );
    my $filenameTmp = $Script . '_tempo_' . $filename;
    my $pathname    = $fswebcam_ref->{'pathname'} . '/' . $filenameTmp;

    my $cmd = $fswebcam_ref->{'fswebcam'} . ' -r '
        . $fswebcam_ref->{'resolution'};
    $cmd .= ' -q ' if !$isDebug;

    my $lineColours_ref = $fswebcam_ref->{'line-coulours'};
    $fswebcam_ref->{'line-coulours-index'} = 0
        if $fswebcam_ref->{'line-coulours-index'}
            >= scalar(@$lineColours_ref);
    my $lineColour
        = $lineColours_ref->[ $fswebcam_ref->{'line-coulours-index'} ];
    $fswebcam_ref->{'line-coulours-index'}++;
    my $info = $fswebcam_ref->{'info'};
    $info .= ' ' . $filename if $isDebug;

    $cmd
        .= ' --title "'
        . $fswebcam_ref->{'title'} . '"'
        . ' --subtitle "'
        . $fswebcam_ref->{'subtitle'} . '"'
        . ' --info "'
        . $info . '"'
        . ' --log syslog '
        . ' --line-colour '
        . $lineColour . ' '
        . $pathname;

    sayDebug("$cmd");
    my $res = `$cmd`;
    sayDebug($res);
    die sayError("$cmd return $res") if $? > 0;

    die sayError("$pathname was not found") if !-f $pathname;

    $fswebcam_ref->{'image-counter'}++;
    $fswebcam_ref->{'image-counter'} = 0
        if $fswebcam_ref->{'image-counter'}
            >= $fswebcam_ref->{'image-counter-max'};

    return ( $pathname, $filenameTmp, $filename );

}

##@method void sendMail($subject, $body)
#@brief Send an e-mail
#@param string $subject The subject of the message
#@param string $body The body of the email
sub sendMail {
    my ( $subject, $body ) = @_;
    if ( !defined $smtp_ref or !$smtp_ref->{'enable'} ) {
        sayInfo("Sending email is disabled");
        return;
    }
    $subject = '' if !defined $subject;
    $body = 'Empty message' if !defined $body;

    $subject = hostname() . ' ' . $Script . ': ' . $subject;
    my @params = (
        $smtp_ref->{'host'},
        'Hello'    => $smtp_ref->{'hello'},
        'Port'     => $smtp_ref->{'port'},
        'User'     => $smtp_ref->{'user'},
        'Password' => $smtp_ref->{'password'},
        'Debug'    => $isDebug
    );
    my $smtp = new Net::SMTP::TLS(@params);
    $smtp->mail( $smtp_ref->{'from'} );
    $smtp->to( $smtp_ref->{'to'} );
    $smtp->data();
    $smtp->datasend(
        'From: ' . $smtp_ref->{'name'} . ' <' . $smtp_ref->{'from'} . ">\n" );
    $smtp->datasend( 'Reply-to: ' . $smtp_ref->{'from'} . "\n" );
    $smtp->datasend( 'To: ' . $smtp_ref->{'to'} . "\n" );
    $smtp->datasend( 'Subject: ' . $subject . "\n" );
    $smtp->datasend("\n");
    $smtp->datasend( $body . "\n" );
    $smtp->dataend();
    $smtp->quit();
    sayDebug("The email has been sent to $smtp_ref->{'to'}");
}

## @method void init()
sub init {
    getOptions();
    print STDOUT 'fswebcam2ftp.pl $Revision$' . "\n"
        if $isVerbose;
    readConfig();
    if ( defined $sysLog_ref ) {
        Sys::Syslog::setlogsock( $sysLog_ref->{'sock_type'} );
        my $ident = $main::0;
        $ident =~ s,^.*/([^/]*)$,$1,;
        Sys::Syslog::openlog(
            $ident,
            "ndelay,$sysLog_ref->{'logopt'}",
            $sysLog_ref->{'facility'}
        );
    }
    $actionSelected = 'fswebcam2ftpProcess' if !defined $actionSelected;
    die sayError("$actionSelected action was not found")
        if !exists $action{$actionSelected};
}

## @method void readConfig()
sub readConfig {
    my $confFound = 0;
    foreach my $pathname ( $ENV{'HOME'} . '/.fswebcam2ftp', '/etc', $Bin ) {
        my $filename = $pathname . '/' . $configFileName;
        print STDOUT "Tries to read the file $filename\n" if $isDebug;
        next                                              if !-e $filename;
        print STDOUT "The file $filename was found\n"     if $isDebug;
        $confFound = 1;
        my %config = Config::General->new($filename)->getall();

        # Reads FTP configuration
        $ftp_ref = getHash( \%config, 'ftp' );
        foreach my $name ( 'username', 'password', 'hostname', 'pathname' ) {
            isString( $ftp_ref, $name );
        }
        isInt( $ftp_ref, 'passive' );
        isInt( $ftp_ref, 'timeout' );

        # Reads fswebcam configuration
        $fswebcam_ref = getHash( \%config, 'fswebcam' );
        foreach my $name (
            'pathname', 'resolution', 'filename', 'title',
            'subtitle', 'info',       'line-colours'
            )
        {
            isString( $fswebcam_ref, $name );
        }
        isExe( $fswebcam_ref, 'fswebcam' );
        isInt( $fswebcam_ref, 'image-counter-max' );
        die "bad image dimension ($fswebcam_ref->{'resolution'} ) "
            if $fswebcam_ref->{'resolution'} !~ m{^\d+x\d+$};
        uc( $fswebcam_ref->{'line-coulours'} );
        my @lineColours = split( /,/, $fswebcam_ref->{'line-colours'} );
        foreach my $colour (@lineColours) {
            die "'$colour' is not a hexa value" if $colour !~ m{^[A-F0-9]+$};
        }
        $fswebcam_ref->{'line-coulours'}       = \@lineColours;
        $fswebcam_ref->{'line-coulours-index'} = 0;

        # Reads SMTP configuration
        $smtp_ref = getHash( \%config, 'smtp' );
        isBool( $smtp_ref, 'enable' );
        if ( $smtp_ref->{'enable'} ) {
            isBool( $smtp_ref, 'tls' );
            foreach
                my $name ( 'host', 'hello', 'user', 'password', 'from', 'to',
                'name' )
            {
                isString( $smtp_ref, $name );
            }
            isInt( $smtp_ref, 'port' );
        }

        # Reads Syslog Configuration
        $sysLog_ref = $config{'syslog'};
        isBool( $sysLog_ref, 'enable' );
        if ( $sysLog_ref->{'enable'} ) {
            foreach my $name ( 'logopt', 'facility', 'sock_type' ) {
                isString( $sysLog_ref, $name );
            }
        }
        last;
    }
    die "(!) readConfig(): no configuration file has been found!"
        if !$confFound;
}

## @method isInt($conf_ref, $name)
sub isInt {
    my ( $conf_ref, $name ) = @_;
    die "'$name' integer was not found"
        if !exists $conf_ref->{$name}
            or $conf_ref->{$name} !~ m{^\d+$};
}

## @method isString($conf_ref, $name)
# @brief Check if hash key is defined as a string
sub isString {
    my ( $conf_ref, $name ) = @_;
    die "'$name' string was not found" if !exists $conf_ref->{$name};
}

## @method hash_ref getHash($conf_ref, $name)
sub getHash {
    my ( $conf_ref, $name ) = @_;
    die "'$name' section was not found" if !exists $conf_ref->{$name};
    die "'$name' section is not a hashtable"
        if ref( $conf_ref->{$name} ) ne 'HASH';
    return $conf_ref->{$name};
}

## @method boolean isBool($hash_ref, $name)
# @brief Check if hash key is defined as a boolean
# @param hashref $hash_ref A hash
# @param string $name A key of this hash
sub isBool {
    my ( $hash_ref, $name ) = @_;
    die sayError("'$name' boolean not found or wrong")
        if !exists( $hash_ref->{$name} )
            or ref( $hash_ref->{$name} )
            or $hash_ref->{$name} !~ m{^(0|1|true|false)$};
    if ( $hash_ref->{$name} eq 'false' ) {
        $hash_ref->{$name} = 0;
    }
    elsif ( $hash_ref->{$name} eq 'true' ) {
        $hash_ref->{$name} = 1;
    }
}

## @method boolean isExe($hash_ref, $name)
#@brief Check if hash key is defined as a string and executable file
sub isExe {
    my ( $hash_ref, $name ) = @_;
    isString( $hash_ref, $name );
    my $exe = $hash_ref->{$name};
    die sayError("'$exe' executable not found or wrong")
        unless -r $exe
            and -x $exe
            and ( -s $exe > 0 );
}

## @method void sayError($message)
# @param message Error message
sub sayError {
    my ($message) = @_;
    $message =~ s{(\n|\r)}{}g;
    setlog( 'info', $message );
    print STDERR $message . "\n"
        if $isVerbose;
}

## @method void sayInfo($message)
# @param message Info message
sub sayInfo {
    my ($message) = @_;
    $message =~ s{(\n|\r)}{}g;
    setlog( 'info', $message );
    print STDOUT $message . "\n"
        if $isVerbose;
}

## @method void sayDebug($message)
# @param message Debug message
sub sayDebug {
    return if !$isDebug;
    my ($message) = @_;
    $message =~ s{(\n|\r)}{}g;
    setlog( 'info', $message );
    print STDOUT $message . "\n"
        if $isVerbose;
}

## @method void setlog($priorite, $message)
# @param priorite Level: 'info', 'error', 'debug' or 'warning'
sub setlog {
    my ( $priorite, $message ) = @_;
    return if !defined $sysLog_ref;
    Sys::Syslog::syslog( $priorite, '%s', $message );
}

## @method void getOptions()
sub getOptions {
    my %opt;
    getopts( 'lsidvnm:', \%opt ) || HELP_MESSAGE();
    $isVerbose = 1 if exists $opt{'v'};
    $isTest    = 1 if exists $opt{'n'};
    $isDebug   = 1 if exists $opt{'d'};
    $loopMax = $opt{'m'} if exists $opt{'m'} and defined $opt{'m'};
    if ( exists $opt{'l'} ) {
        $actionSelected = 'listProcess';
    }
    if ( exists $opt{'s'} ) {
        $actionSelected = 'sendMailProcess';
    }
    print STDOUT "isTest = $isTest\n" if $isTest;
}

## @method void HELP_MESSAGE()
# Display help message
sub HELP_MESSAGE {
    print <<ENDTXT;
Usage: 
 fswebcam2ftp.pl [-l -d -v -n -m maxLoop] 
  -l         List the FTP files and quit
  -v         Verbose mode
  -d         Debug mode
  -n         Perform a trial run with no changes made 
  -m maxLoop
ENDTXT
    exit 0;
}

## @method void VERSION_MESSAGE()
sub VERSION_MESSAGE {
    print STDOUT <<ENDTXT;
    $Script $VERSION (2012-02-13) 
    Copyright (C) 2012 TLK Games 
    Written by Bruno Ethvignot. 
ENDTXT
}

