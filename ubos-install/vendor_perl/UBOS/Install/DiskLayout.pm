# 
# Captures the disk layout for an installation.
#
# Supported modes:
# 1. Single image file; everything goes on it
# 2. One or more block devices.
# Can't mix and match.
# These are implemented as subclasses in the same file.
#

use strict;
use warnings;

package UBOS::Install::DiskLayout;

use fields qw( bootfs bootsize
               rootfs rootsize
               varfs  varsize
               mountpointToDevice );

use UBOS::Logging;
use UBOS::Utils;

##
# Constructor -- instantiates subclasses, which also check for validity
sub new {
    my $self             = shift;
    my $rootpartitions   = shift;
    my $varpartitions    = shift;
    my $bootpartition    = shift;
    my $bootloaderdevice = shift;

    if( @$rootpartitions == 0 ) {
        fatal( 'No root partition(s) given' );
    }
    if( @$rootpartitions == 1 ) {
        # could be ::DiskImage or ::BlockDevices
        if( ! -e $rootpartitions->[0] ) {
            fatal( 'Does not exist:', $rootpartitions->[0] );
        }
        if( -f $rootpartitions->[0] ) {
            $self = UBOS::Install::DiskLayout::DiskImage->new( $rootpartitions, $varpartitions, $bootpartition, $bootloaderdevice );
        } else {
            $self = UBOS::Install::DiskLayout::BlockDevices->new( $rootpartitions, $varpartitions, $bootpartition, $bootloaderdevice );
        }

    } else {
        # must be ::BlockDevices
        $self = UBOS::Install::DiskLayout::BlockDevices->new( $rootpartitions, $varpartitions, $bootpartition, $bootloaderdevice );
    }

    return $self;
}

##
# Parameterize this disk layout's boot partition
# $fs: the filesystem to use
# $size: the size to use
sub setBootParameters {
    my $self = shift;
    my $fs   = shift;
    my $size = shift;

    $self->{bootfs}   = $fs;
    $self->{bootsize} = $size;
}

##
# Parameterize this disk layout's root partition
# $fs: the filesystem to use
# $size: the size to use
sub setRootParameters {
    my $self = shift;
    my $fs   = shift;
    my $size = shift;

    $self->{rootfs}   = $fs;
    $self->{rootsize} = $size;
}

##
# Parameterize this disk layout's var partition
# $fs: the filesystem to use
# $size: the size to use
sub setVarParameters {
    my $self = shift;
    my $fs   = shift;
    my $size = shift;

    $self->{varfs}   = $fs;
    $self->{varsize} = $size;
}

##
# Format the configured disks.
sub formatDisks {
    my $self = shift;

    fatal( 'Must override:', ref( $self ));
}

##
# Mount this disk layout at the specified target directory
# $target: the target directory
sub mountDisks {
    my $self   = shift;
    my $target = shift;

    my $errors = 0;
    if( defined( $self->{mountpointToDevice} )) {
        # shortest first
        foreach my $dir ( sort { length( $a ) <=> length( $b ) } keys %{$self->{mountpointToDevice}} ) {
            my( $device, $fs ) = @{$self->{mountpointToDevice}->{$dir}};

            unless( -d "$target$dir" ) {
                UBOS::Utils::mkdir( "$target$dir" );
            }
            if( UBOS::Utils::myexec( "mount -t $fs '$device' '$target$dir'" )) {
                ++$errors;
            }
        }
    }
    return $errors;
}

##
# Unmount the previous mounts
# $target: the target directory
sub umountDisks {
    my $self   = shift;
    my $target = shift;

    my $errors = 0;
    if( defined( $self->{mountpointToDevice} )) {
        # longest first
        foreach my $dir ( sort { length( $b ) <=> length( $a ) } keys %{$self->{mountpointToDevice}} ) {
            if( UBOS::Utils::myexec( "umount '$target$dir'" )) {
                ++$errors;
            }
        }
    }
    return $errors;
}

##
# Create an fdisk script fragment to change a partition type
# $fs: desired file system type
# $i: partition number
sub appendFdiskChangePartitionType {
    my $self = shift;
    my $fs   = shift;
    my $i    = shift;

    my $script = '';
    if( $fs && $i ) {
        # This may have to be extended

        # Only specify $i if $i > 1; we generate partitions in sequence, and fdisk does not
        # ask which partition if number == 1
        if( 'vfat' eq $fs ) {
            if( $i > 1 ) {
                $script .= <<END;
t
$i
c
END
            } else {
                $script .= <<END;
t
c
END
            }
        }
    }
    return $script;
}

##
# Generate and save /etc/fstab
# $@mountPathSequence: the sequence of paths to mount
# %$partitions: map of paths to devices
# $targetDir: the path where the bootimage has been mounted
# return: number of errors
sub saveFstab {
    my $self   = shift;
    my $target = shift;
    
    my $fsTab = <<FSTAB;
#
# /etc/fstab: static file system information
#
# <file system> <dir>	<type>	<options>	<dump>	<pass>

FSTAB

    if( defined( $self->{mountpointToDevice} )) {
        my $i=0;

        # shortest first
        foreach my $dir ( sort { length( $a ) <=> length( $b ) } keys %{$self->{mountpointToDevice}} ) {
            my( $device, $fs ) = @{$self->{mountpointToDevice}->{$dir}};

            my $uuid;
            UBOS::Utils::myexec( "sudo blkid -s UUID -o value '$device'", undef, \$uuid );
            $uuid =~ s!^\s+!!g;
            $uuid =~ s!\s+$!!g;

            my $passno = ( $dir eq '/' ) ? 1 : 2;

            $fsTab .= <<FSTAB;
UUID=$uuid $dir $fs rw,relatime $i $passno
FSTAB
            ++$i;
        }
    }

    UBOS::Utils::saveFile( "$target/etc/fstab", $fsTab, 0644, 'root', 'root' );

    return 0;
}

##
# Determine the boot device for this DiskLayout
sub determineBootDevice {
    my $self = shift;

    fatal( 'Must override:', ref( $self ));
}


############

package UBOS::Install::DiskLayout::DiskImage;

use base qw( UBOS::Install::DiskLayout );
use fields qw( rootpartition );

use UBOS::Logging;

##
# Constructor
sub new {
    my $self             = shift;
    my $rootpartitions   = shift;
    my $varpartitions    = shift;
    my $bootpartition    = shift;
    my $bootloaderdevice = shift;

    unless( @$rootpartitions == 1 ) {
        fatal( 'Must have single rootpartition file for UBOS::Install::DiskLayout::DiskImage' );
    }
    unless( -f $rootpartitions->[0] ) {
        fatal( 'Single rootpartition for UBOS::Install::DiskLayout::DiskImage must be a file' );
    }
    if( $varpartitions && @$varpartitions ) {
        fatal( 'Cannot provide separate varpartition(s) for UBOS::Install::DiskLayout::DiskImage. All must be in same image.' );
    }
    if( $bootpartition ) {
        fatal( 'Cannot provide separate bootpartition for UBOS::Install::DiskLayout::DiskImage. All must be in same image.' );
    }
    if( $bootloaderdevice ) {
        fatal( 'Cannot provide separate bootloaderdevice for UBOS::Install::DiskLayout::DiskImage. All must be in same image.' );
    }

    unless( ref( $self )) {
        $self = fields::new( $self );
    }
    $self->{rootpartition} = $rootpartitions->[0];

    return $self;
}

##
# Format the configured disks.
sub formatDisks {
    my $self = shift;

    my $errors      = 0;
    my $fdiskScript = '';
    my %mkfsTable   = ();

    $fdiskScript .= <<END; # first clear out everything
o
END

    my $i=1;
    if( $self->{bootfs} && $self->{bootsize} ) {
        my $size = $self->{bootsize};
        $fdiskScript .= <<END;
n
p
$i

+$size
a
END
        $fdiskScript .= $self->appendFdiskChangePartitionType( $self->{bootfs}, $i );
        $mkfsTable{$i} = [ $self->{bootfs}, '/boot' ];
        ++$i;
    }
    if( $self->{varfs} && $self->{varsize} ) {
        my $size = $self->{rootsize};
        $fdiskScript .= <<END;
n
p
$i

+$size
END
        $fdiskScript .= $self->appendFdiskChangePartitionType( $self->{rootfs}, $i );
        $mkfsTable{$i} = [ $self->{rootfs}, '/' ];
        ++$i;
        
        # take the rest for var
        $fdiskScript .= <<END;
n
p
$i


END
        $fdiskScript .= $self->appendFdiskChangePartitionType( $self->{varfs}, $i );
        $mkfsTable{$i} = [ $self->{varfs}, '/var' ];
        ++$i;
        
    } else {
        # take the rest for root
        $fdiskScript .= <<END;
n
p
$i


END
        $fdiskScript .= $self->appendFdiskChangePartitionType( $self->{rootfs}, $i );
        $mkfsTable{$i} = [ $self->{rootfs}, '/' ];
        ++$i;
    }
    $fdiskScript .= <<END;
w
END

    my $out;
    my $err;

    if( UBOS::Utils::myexec( "fdisk '" . $self->{rootpartition} . "'", $fdiskScript, \$out, \$err )) {
        error( 'fdisk failed', $out, $err );
        ++$errors;
    }

    # Reread partition table
    UBOS::Utils::myexec( "partprobe '" . $self->{rootpartition} . "'" ); 
        
    # Create loopback devices and figure out what they are
    debug( "Creating loop devices" );

    # -s: wait until created
    if( UBOS::Utils::myexec( "kpartx -a -s -v '" . $self->{rootpartition} . "'", undef, \$out, \$err )) {
        error( "kpartx error:", $err );
        ++$errors;
    }
    $out =~ m!/dev/(loop\d+)\s+!; # matches once for each partition, but that's okay
    my $partitionLoopDeviceRoot = "/dev/mapper/$1";

    # Add file systems
    debug( 'Formatting file systems' );

    foreach my $i ( keys %mkfsTable ) {
        my $device = $partitionLoopDeviceRoot . 'p' . $i;
        my $fs     = $mkfsTable{$i}->[0];

        my $cmd = "mkfs.$fs '$device'";
        if( 'btrfs' eq $fs ) {
            # overwrite if exists already: but only mkfs.btrfs knows about that
            $cmd .= ' -f';
        }
        if( UBOS::Utils::myexec( $cmd, undef, \$out, \$err )) {
            error( "$cmd error:", $err );
            ++$errors;
        }
        $self->{mountpointToDevice}->{$mkfsTable{$i}->[1]} = [ $device, $fs ];
    }
    return $errors;
}

##
# Unmount the previous mounts. Override because we need to take care of the
# loopback devices.
# $target: the target directory
sub umountDisks {
    my $self   = shift;
    my $target = shift;

    my $errors = $self->SUPER::umountDisks( $target );

    my $err;
    if( UBOS::Utils::myexec( "kpartx -d '" . $self->{rootpartition} . "'", undef, undef, \$err )) {
        error( "kpartx error:", $err );
        ++$errors;
    }
    
    return $errors;
}

##
# Determine the boot device for this DiskLayout
sub determineBootDevice {
    my $self = shift;

    return $self->{rootpartition};
}

############

package UBOS::Install::DiskLayout::BlockDevices;

use base qw( UBOS::Install::DiskLayout );
use fields qw( rootpartitions varpartitions bootpartition bootloaderdevice );

use UBOS::Logging;

##
# Constructor
sub new {
    my $self             = shift;
    my $rootpartitions   = shift;
    my $varpartitions    = shift;
    my $bootpartition    = shift;
    my $bootloaderdevice = shift;

    my %haveAlready = ();
    foreach my $part ( @$rootpartitions ) {
        unless( -b $part ) {
            fatal( 'In RAID mode, all rootpartitions must be block devices, is not:', $part );
        }
        if( $haveAlready{$part} ) {
            fatal( 'Do not specify more than once:', $part );
        }
        $haveAlready{$part} = 1;
    }
    if( @$varpartitions ) {
        foreach my $part ( @$varpartitions ) {
            unless( -b $part ) {
                fatal( 'All varpartitions must be block devices, is not:', $part );
            }
            if( $haveAlready{$part} ) {
                fatal( 'Do not specify more than once:', $part );
            }
            $haveAlready{$part} = 1;
        }
    }
    if( $bootpartition ) {
        unless( -b $bootpartition ) {
            fatal( 'Bootpartition must be block device, is not:', $bootpartition );
        }
    }
    if( $bootloaderdevice ) {
        unless( -b $bootloaderdevice ) {
            fatal( 'Bootloaderdevice must be block device, is not:', $bootloaderdevice );
        }
    }
    
    unless( ref( $self )) {
        $self = fields::new( $self );
    }

    $self->{rootpartitions}   = $rootpartitions;
    $self->{varpartitions}    = $varpartitions;
    $self->{bootpartition}    = $bootpartition;
    $self->{bootloaderdevice} = $bootloaderdevice;

    return $self;
}

##
# Determine the boot device for this DiskLayout
sub determineBootDevice {
    my $self = shift;

    if( defined( $self->{bootloaderdevice} )) {
        return $self->{bootloaderdevice};
    }
    return $self->{rootpartitions}->[0]; 
}

1;