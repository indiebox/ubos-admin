# 
# Abstract superclass for device-specific installers. Device-specific parts are
# factored out in methods that can be overridden in subclasses.
# 

use strict;
use warnings;

package UBOS::Install::AbstractInstaller;

use fields qw( hostname
               target tempTarget
               repo
               channel
               basepackages devicepackages additionalpackages
               baseservices deviceservices additionalservices
               packagedbs );
# basepackages: always installed, regardless
# devicepackages: packages installed for this device class, but not necessarily all others
# additionalpackages: packages installed because added on the command-line

use Cwd;
use File::Spec;
use File::Temp;
use UBOS::Logging;
use UBOS::Utils;

##
# Constructor
sub new {
    my $self = shift;

    unless( ref $self ) {
        $self = fields::new( $self );
    }
    # set some defaults
    unless( $self->{hostname} ) {
        $self->{hostname} = 'ubos-device';
    }
    unless( $self->{channel} ) {
        $self->{channel} = 'green';
    }
    unless( $self->{basepackages} ) {
        $self->{basepackages} = [ qw( base openssh btrfs-progs ntp ubos-admin ubos-networking rng-tools ) ];
    }
    unless( $self->{baseservices} ) {
        $self->{baseservices} = [ qw( rngd ubos-admin ubos-networking ntpd sshd ) ];
    }
    unless( $self->{packagedbs} ) {
        $self->{packagedbs} = [ qw( os hl ) ];
    }

    return $self;
}

##
# Create a DiskLayout object that goes with this Installer.
# $argvp: remaining command-line arguments
sub createDiskLayout {
    my $self  = shift;
    my $argvp = shift;

    fatal( 'Must override:', ref( $self ));
}

##
# Set a different hostname
# $hostname: the new hostname
sub setHostname {
    my $self     = shift;
    my $hostname = shift;

    $self->{hostname} = $hostname;
}

##
# Set the target filesystem's mount point
# $target: the mount point, e.g. /mnt
sub setTarget {
    my $self   = shift;
    my $target = shift;

    $self->{target} = $target;
}

##
# Use a temporary target directory
sub useTempTarget {
    my $self = shift;

    $self->{tempTarget} = File::Temp->newdir( DIR => getcwd(), UNLINK => 1 );
    $self->{target}     = $self->{tempTarget}->dirname;
}

##
# Set the directory which contains the package databases
# $repo: the directory, so that $repo/<arch>/os/os.db exists
sub setRepo {
    my $self = shift;
    my $repo = shift;

    $self->{repo} = $repo;
}

##
# Set the channel
# $channel: the channel
sub setChannel {
    my $self    = shift;
    my $channel = shift;

    $self->{channel} = $channel;
}

##
# Set the packages that are to be installed in addition
# $packages: array of package names
sub setAdditionalPackages {
    my $self     = shift;
    my $packages = shift;

    $self->{additionalpackages} = $packages;
}

##
# Set the services that are to be enabled in addition
# $services: array of service names
sub setAdditionalServices {
    my $self     = shift;
    my $services = shift;

    $self->{additionalservices} = $services;
}

##
# Install UBOS
# $diskLayout: the disk layout to use
sub install {
    my $self       = shift;
    my $diskLayout = shift;

    debug( 'Installing UBOS with hostname', $self->{hostname} );

    $self->check( $diskLayout ); # will exit if not valid

    my $pacmanConfigInstall = $self->generatePacmanConfigTarget( [ qw( os hl tools ) ] );
            # only dbs available on all platforms; not virt
    my $errors = 0;

    $errors += $diskLayout->createDisks();
    $errors += $diskLayout->formatDisks();
    $errors += $diskLayout->mountDisks( $self->{target} );
    $errors += $self->mountSpecial();
    $errors += $self->installPackages( $pacmanConfigInstall->filename );
    $errors += $self->savePacmanConfigProduction( $self->{packagedbs} );
    $errors += $self->saveHostname();
    $errors += $self->saveChannel();
    $errors += $diskLayout->saveFstab( $self->{target} );
    $errors += $self->saveSecuretty();
    $errors += $self->saveOther();    
    $errors += $self->installBootLoader( $pacmanConfigInstall->filename, $diskLayout );
 
    my $chrootScript = <<S;
#!/bin/bash
# Script to be run in chroot
set -e
S
    $errors += $self->addEnableServicesToScript( \$chrootScript );

    my $out;
    my $err;
    if( UBOS::Utils::myexec( "sudo chroot '" . $self->{target} . "'", $chrootScript, \$out, \$err )) {
        error( "chroot script failed", $err );
        ++$errors;
    }

    $errors += $self->umountSpecial();
    $errors += $diskLayout->umountDisks( $self->{target} );

    unlink( $pacmanConfigInstall->filename );

    return $errors;
}

##
# Check that provided parameters are correct. Exit if not.
sub check {
    my $self       = shift;
    my $diskLayout = shift;

    unless( $self->{hostname} ) {
        fatal( 'Hostname must not be empty' );
    }

    unless( $self->{target} ) {
        fatal( 'No target given' );
    }
    if( $self->{target} =~ m!/$! ) {
        fatal( 'Target must not have a trailing slash:', $self->{target} );
    }
    unless( -d $self->{target} ) {
        fatal( 'Target is not a directory:', $self->{target} );
    }

    if( $self->{repo} ) {
        # if not given, use default depot.ubos.net
        unless( -d $self->{repo} ) {
            fatal( 'Repo must be an existing directory, is not:', $self->{repo} );
        }
        my $archRepo = $self->{repo} . '/' . $self->arch;
        my $osDb     = $archRepo . '/os/os.db';
        unless( -l $osDb ) {
            fatal( 'Not a valid repo, cannot find:', $osDb );
        }
    }

    unless( $self->{channel} ) {
        fatal( 'No channel given' );
    }
    if( $self->{channel} ne 'dev' && $self->{channel} ne 'red' && $self->{channel} ne 'yellow' && $self->{channel} ne 'green' ) {
        fatal( 'Invalid channel:', $self->{channel} );
    }

    # Would be nice to check that packages actually exist, but that's hard if
    # they are remote
}

##
# Mount special devices in target dir, so packages can install correctly
sub mountSpecial {
    my $self = shift;

    debug( "Executing mountSpecial" );

    my $target = $self->{target};
    my $errors = 0;

    my $s = <<END;
sudo mkdir -m 0755 -p $target/var/{cache/pacman/pkg,lib/pacman,log} $target/{dev,run,etc}
sudo mkdir -m 1777 -p $target/tmp
sudo mkdir -m 0555 -p $target/{sys,proc}

sudo mount proc   $target/proc    -t proc     -o nosuid,noexec,nodev
sudo mount sys    $target/sys     -t sysfs    -o nosuid,noexec,nodev,ro
sudo mount udev   $target/dev     -t devtmpfs -o mode=0755,nosuid
sudo mount devpts $target/dev/pts -t devpts   -o mode=0620,gid=5,nosuid,noexec
sudo mount shm    $target/dev/shm -t tmpfs    -o mode=1777,nosuid,nodev
sudo mount run    $target/run     -t tmpfs    -o nosuid,nodev,mode=0755
sudo mount tmp    $target/tmp     -t tmpfs    -o mode=1777,strictatime,nodev,nosuid
END

    if( UBOS::Utils::myexec( $s )) {
        ++$errors;
    }
    return $errors;
}

##
# Unmount special devices from target dir
sub umountSpecial {
    my $self = shift;

    debug( "Executing unmountSpecial" );

    my $target = $self->{target};
    my $errors = 0;

    my $s = <<END;
sudo umount $target/tmp
sudo umount $target/run
sudo umount $target/dev/shm
sudo umount $target/dev/pts
sudo umount $target/dev
sudo umount $target/sys
sudo umount $target/proc
END
    if( UBOS::Utils::myexec( $s )) {
        ++$errors;
    }
    return $errors;
}

##
# Generate pacman config file for installation into target
# $dbs: array of package database names
# return: File object of the generated temp file
sub generatePacmanConfigTarget {
    my $self = shift;
    my $dbs  = shift;

    debug( "Executing generatePacmanConfigTarget" );

    my $repo = $self->{repo};
    my $arch = $self->arch;
    my $dbRoot;
    if( $repo ) {
        $dbRoot = "file://$repo/$arch";
    } else {
        my $channel = $self->{channel};
        $dbRoot = "http://depot.ubos.net/$channel/$arch";
    }

    # Generate pacman config file for creating the image
    my $file = File::Temp->new( UNLINK => 1 );
    print $file <<'END';
#
# Pacman config file for installing packages
#

[options]
SigLevel           = Required TrustedOnly
LocalFileSigLevel  = Required TrustedOnly
RemoteFileSigLevel = Required TrustedOnly
END

    foreach my $db ( @$dbs ) {
        print $file <<END;

[$db]
Server = $dbRoot/$db
END
    }
    close $file;
    return $file;
}

##
# Install the packages that need to be installed
# $pacmanConfig: pacman config file to use
#
sub installPackages {
    my $self         = shift;
    my $pacmanConfig = shift;

    debug( "Executing installPackages" );

    my $target = $self->{target};
    my $errors = 0;

    my @allPackages = ( @{$self->{basepackages}} );
    if( defined( $self->{devicepackages} )) {
        push @allPackages, @{$self->{devicepackages}};
    }
    if( defined( $self->{additionalpackages} )) {
        push @allPackages, @{$self->{additionalpackages}};
    }

    my $cmd = "sudo pacman"
            . " -r '$target'"
            . " -Sy"
            . " '--config=$pacmanConfig'"
            . " --cachedir '$target/var/cache/pacman/pkg'"
            . " --noconfirm"
            . ' ' . join( ' ', @allPackages );

    my $out;
    my $err;
    if( UBOS::Utils::myexec( $cmd, undef, \$out, \$err )) {
        error( "pacman failed:", $err, "\nconfiguration was:\n", UBOS::Utils::slurpFile( $pacmanConfig ) );
        ++$errors;
    }

    return $errors;
}

##
# Generate and save the pacman config file for production
sub savePacmanConfigProduction {
    my $self = shift;
    my $dbs  = shift;

    debug( "Executing savePacmanConfigProduction" );

    my $arch    = $self->arch;
    my $channel = $self->{channel};

    my $pacmanConfigProduction = <<END;
#
# Pacman config file for UBOS
#

[options]
Architecture = $arch
CheckSpace

SigLevel           = Required TrustedOnly
LocalFileSigLevel  = Required TrustedOnly
RemoteFileSigLevel = Required TrustedOnly

END
    foreach my $db ( @$dbs ) {
        $pacmanConfigProduction .= <<END; # Note what is and isn't escaped here

[$db]
Server = http://depot.ubos.net/$channel/\$arch/$db
END
    }
    if( UBOS::Utils::saveFile( $self->{target} . '/etc/pacman.conf', $pacmanConfigProduction, 0644, 'root', 'root' )) {
        return 0;
    } else {
        return 1;
    }
}

##
# Generate and save the /etc/hostname file
sub saveHostname {
    my $self = shift;

    debug( "Executing saveHostname" );

    # hostname
    if( UBOS::Utils::saveFile(
            $self->{target}   . '/etc/hostname',
            $self->{hostname} . "\n",
            0644, 'root', 'root' )) {

        return 0;

    } else {
        return 1;
    }
}

##
# Generate and save the /etc/ubos/channel file
sub saveChannel {
    my $self = shift;
    
    debug( "Executing saveChannel" );

    # hostname
    if( UBOS::Utils::saveFile(
            $self->{target}   . '/etc/ubos/channel',
            $self->{channel} . "\n",
            0644, 'root', 'root' )) {

        return 0;

    } else {
        return 1;
    }
}

##
# Generate and save a different /etc/securetty if needed
# return: number of errors
sub saveSecuretty {
    my $self  = shift;

    # do nothing by default

    return 0;
}

##
# Generate and save different other files if needed
# return: number of errors
sub saveOther {
    my $self = shift;

    # do nothing by default

    return 0;
}

##
# Install the bootloader
# $pacmanConfigFile: the Pacman config file to be used to install packages
# $bootLoaderDevice: device to install the bootloader on
# return: number of errors
sub installBootLoader {
    my $self             = shift;
    my $pacmanConfigFile = shift;
    my $bootLoaderDevice = shift;

    error( 'Method installBootLoader() must be overridden for', ref( $self ));

    return 1;
}

##
# Add commands to the provided script, to be run in a chroot, that enable services
# $chrootScriptP: pointer to script
sub addEnableServicesToScript {
    my $self          = shift;
    my $chrootScriptP = shift;

    debug( "Executing addEnableServicesToScript" );

    my @allServices = ();
    
    if( defined( $self->{baseservices} )) {
        push @allServices, @{$self->{baseservices}};
    }
    if( defined( $self->{deviceservices} )) {
        push @allServices, @{$self->{deviceservices}};
    }
    if( defined( $self->{additionalservices} )) {
        push @allServices, @{$self->{additionalservices}};
    }
    if( @allServices ) {
        $$chrootScriptP .= 'systemctl enable ' . join( ' ', @allServices ) . "\n\n";
    }
    return 0;
}

##
# Returns the arch for this device.
# return: the arch
sub arch {
    my $self = shift;

    fatal( 'Method arch() must be overridden in', ref( $self ));
}

1;
