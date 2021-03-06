#!/usr/bin/perl
#
# The secure-copy data transfer protocol.
#
# Copyright (C) 2014 and later, Indie Computing Corp. All rights reserved. License: see package.
#

use strict;
use warnings;

package UBOS::DataTransferProtocols::Scp;

use base qw( UBOS::AbstractDataTransferProtocol );
use fields;

use Getopt::Long qw( GetOptionsFromArray );
use UBOS::Logging;
use UBOS::Utils;
use URI;

##
# Factory method.
# If successful, return instance. If not, return undef.
# $location: the location to parse
# $dataTransferConfig: data transfer configuration options
# $argsP: array of remaining command-line arguments
# return: instance or undef
sub parseLocation {
    my $self               = shift;
    my $location           = shift;
    my $dataTransferConfig = shift;
    my $argsP              = shift;

    my $uri = URI->new( $location );
    if( !$uri->scheme() || $uri->scheme() ne protocol() ) {
        return undef;
    }
    my $authority = $uri->authority();

    # does not have userinfo() on uri as the scheme is not known
    if( $authority !~ m!\S+\@\S+! ) {
        fatal( 'Need to provide user info in the URL, e.g. scp://joe@example.com/destination' );
    } elsif( $authority =~ m!:.+\@! ) {
        fatal( 'Do not specify password in the URL' );
    }

    my $idfile     = undef;
    my $sshOptions = undef;
    my $limit      = undef;

    my $parseOk = GetOptionsFromArray(
            $argsP,
            'idfile|i=s'   => \$idfile,
            'sshoptions=s' => \$sshOptions,
            'limit=s'      => \$limit );
    if( !$parseOk || @$argsP ) {
        return undef;
    }

    if( $idfile ) {
        unless( -r $idfile ) {
            fatal( 'File cannot be read:', $idfile );
        }
        $dataTransferConfig->setValue( 'scp', $authority, 'idfile', $idfile );
    }
    if( $sshOptions ) {
        UBOS::AbstractDataTransferProtocol::validiateSshOptions( $sshOptions );
        $dataTransferConfig->setValue( 'scp', $authority, 'sshoptions', $sshOptions );
    }
    if( $limit ) {
        unless( $limit =~ m!^\d+$! ) {
            fatal( 'Limit must be a positive integer:', $limit );
        }
        $dataTransferConfig->setValue( 'scp', $authority, 'limit', $limit );
    }

    unless( ref( $self )) {
        $self = fields::new( $self );
    }
    $self->SUPER::new( $location, $authority, protocol() );

    return $self;
}

##
# Is this a local destination?
# return: true or false
sub isLocal {
    my $self = shift;

    return 0;
}

##
# Is this a valid destination?
# $toFile: the candidate destination
# return: true or false
sub isValidToFile {
    my $self   = shift;
    my $toFile = shift;

    return 1;
}

##
# Send a local file to location via this protocol.
# $localFile: the local file
# $toFile: the ultimate destination as a file URL
# $dataTransferConfig: data transfer configuration options
# return: success or fail
sub send {
    my $self               = shift;
    my $localFile          = shift;
    my $toFile             = shift;
    my $dataTransferConfig = shift;

    my $uri = URI->new( $toFile ); # scp://user@host/path -> user@host:path

    my $idfile = $dataTransferConfig->getValue( 'scp', $self->{authority}, 'idfile' );
    my $limit  = $dataTransferConfig->getValue( 'scp', $self->{authority}, 'limit' );

    my $cmd = 'scp';
    # Run in interactive, not batch mode, so the first connection attempt to
    # a new host (not in ~/.ss/known_hosts) won't fail
    $cmd .= ' -C'; # compression
    $cmd .= ' -p'; # preserve timestamps etc
    $cmd .= ' -q'; # quiet mode

    if( $idfile ) {
        $cmd .= " -i '$idfile'"; # private key
    }
    if( $limit ) {
        $cmd .= " -l '$limit'"; # $data transfer limit
    }

    my $sshOptions = $dataTransferConfig->getValue( 'scp', $self->{authority}, 'sshoptions' );
    if( $sshOptions ) {
        $cmd .= " $sshOptions";
    }

    $cmd .=  " '$localFile'";

    my $dest     = $uri->authority();
    my $destPath = $uri->path();
    $destPath =~ s!^/!!; # absolute paths need double slashes

    $dest .= ":$destPath";

    info( 'Uploading to', $dest );

    $cmd .= " '$dest'";

    my $err;
    if( UBOS::Utils::myexec( $cmd, undef, undef, \$err )) {
        $@ = "Upload failed to: $toFile : $err";
        return 0;
    }
    return 1;
}

##
# The supported protocol.
# return: the protocol
sub protocol {
    return 'scp';
}

##
# Description of this data transfer protocol, to be shown to the user.
# return: description
sub description {
    return <<TXT;
The scp protocol. Options:
    --limit <limit>        : limits the used bandwidth, specified in Kbit/s.
    --idfile <idfile>      : selects the file from which the identity (private key)
                             for public key authentication is read.
    --sshoptions <options> : any addition SSH options; will be appended to the SSH
                             command-line
TXT
}

1;
