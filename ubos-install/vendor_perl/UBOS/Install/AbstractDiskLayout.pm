#
# Abstract superclass for disk layouts for an installation.
#
# Copyright (C) 2014 and later, Indie Computing Corp. All rights reserved. License: see package.
#

use strict;
use warnings;

package UBOS::Install::AbstractDiskLayout;

use fields qw( devicetable );

use Cwd 'abs_path';
use UBOS::Logging;
use UBOS::Utils;

my $_pathFacts = {}; # cache of facts about particular paths, hash of <string,hash>
my $_lsBlk     = undef; # cache of lsblk output

##
# Constructor for subclasses only
# $devicetable: information about the layout
sub new {
    my $self        = shift;
    my $devicetable = shift;

    unless( ref( $self )) {
        $self = fields::new( $self );
    }

    $self->{devicetable} = $devicetable;

    trace( 'Using disk layout', ref( $self ));

    return $self;
}

##
# Format the configured disks.
sub createDisks {
    my $self = shift;

    # no op, may be overridden
    return 0;
}

##
# Format the configured disks.
sub formatDisks {
    my $self = shift;

    my $errors = 0;

    trace( 'Checking that none of the devices are currently mounted' );

    my $lsblk;
    my %mounted;
    UBOS::Utils::myexec( 'lsblk -P', undef, \$lsblk );
    foreach my $line ( split /\n/, $lsblk ) {
        if( $line =~ m!NAME="([^"]+)".*MOUNTPOINT="([^"]+)"! ) {
            $mounted{"/dev/$1"} = $2;
        }
    }
    foreach my $mountPath ( keys %{$self->{devicetable}} ) {
        my $data = $self->{devicetable}->{$mountPath};
        foreach my $dev ( @{$data->{devices}} ) {
            if( $mounted{$dev} ) {
                fatal( 'Cannot install to mounted device:', $dev );
            }
        }
    }

    trace( 'Formatting file systems' );

    foreach my $mountPath ( keys %{$self->{devicetable}} ) {
        my $data = $self->{devicetable}->{$mountPath};
        my $fs   = $data->{fs};

        if( !$fs ) {
            # do not format
            next;
        }

        debugAndSuspend( 'Format file system', $mountPath, 'with', $fs );
        if( 'btrfs' eq $fs ) {
            my $cmd = 'mkfs.btrfs -f';
            if( @{$data->{devices}} > 1 ) {
                $cmd .= ' -m raid1 -d raid1';
            }
            if( exists( $data->{mkfsflags} )) {
                $cmd .= ' ' . $data->{mkfsflags};
            }
            if( exists( $data->{label} )) {
                $cmd .= " --label '" . $data->{label} . "'";
            }
            $cmd .= ' ' . join( ' ', @{$data->{devices}} );

            my $out;
            my $err;
            if( UBOS::Utils::myexec( $cmd, undef, \$out, \$err )) {
                error( "$cmd error:", $err );
                ++$errors;
            }

        } elsif( 'swap' eq $fs ) {
            foreach my $dev ( @{$data->{devices}} ) {
                my $out;
                my $err;
                my $cmd = "mkswap '$dev'";

                if( exists( $data->{label} )) {
                    $cmd .= " --label '" . $data->{label} . "'";
                }

                if( UBOS::Utils::myexec( $cmd, undef, \$out, \$err )) {
                    error( "$cmd error:", $err );
                    ++$errors;
                }
            }

        } else {
            foreach my $device ( @{$data->{devices}} ) {
                my $cmd = "mkfs.$fs";
                if( exists( $data->{mkfsflags} )) {
                    $cmd .= ' ' . $data->{mkfsflags};
                }
                if( exists( $data->{label} )) {
                    if( $fs eq 'vfat' ) {
                        $cmd .= " -n '" . $data->{label} . "'";
                    } elsif( $fs eq 'ext4' ) {
                        $cmd .= " -L '" . $data->{label} . "'";
                    } else {
                        warning( "Don't know how to label filesystem of type:", $fs );
                    }
                }
                $cmd .= " '$device'";

                my $out;
                my $err;
                if( UBOS::Utils::myexec( $cmd, undef, \$out, \$err )) {
                    error( "$cmd error:", $err );
                    ++$errors;
                }
            }
        }
    }
    $errors += resetDiskCaches();

    return $errors;
}

##
# Create any needed loop devices. By default, this does nothing.
# return: number of errors
sub createLoopDevices {
    my $self = shift;

    return 0;
}

##
# Delete any created loop devices. By default, this does nothing.
# return: number of errors
sub deleteLoopDevices {
    my $self = shift;

    return 0;
}

##
# Mount this disk layout at the specified target directory
# $target: the target directory
# return: number of errors
sub mountDisks {
    my $self   = shift;
    my $target = shift;

    trace( 'Mounting disks' );

    my $errors = 0;
    # shortest first
    foreach my $mountPoint ( sort { length( $a ) <=> length( $b ) } keys %{$self->{devicetable}} ) {
        my $entry   = $self->{devicetable}->{$mountPoint};
        my $fs      = $entry->{fs};
        my @devices = @{$entry->{devices}};

        unless( $fs ) {
            # no need to mount
            next;
        }
        unless( @devices ) {
            error( 'No device known for', $mountPoint );
            ++$errors;
            next;
        }

        # don't swapon swap devices during install
        if( $mountPoint =~ m!^/! ) { # don't mount devices that don't start with /

            unless( -d "$target$mountPoint" ) {
                UBOS::Utils::mkdir( "$target$mountPoint" );
            }

            my $firstDevice = $devices[0];

            debugAndSuspend( 'Mount device', $firstDevice, 'at', "$target$mountPoint", 'with', $fs );
            if( UBOS::Utils::myexec( "mount -t $fs '$firstDevice' '$target$mountPoint'" )) {
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

    trace( 'Unmounting disks' );

    my $errors = 0;
    # longest first
    foreach my $mountPoint ( sort { length( $b ) <=> length( $a ) } keys %{$self->{devicetable}} ) {
        my $entry  = $self->{devicetable}->{$mountPoint};
        my $fs     = $entry->{fs};

        unless( $fs ) {
            next;
        }

        if( $mountPoint =~ m!^/! ) { # don't umount devices that don't start with /
            debugAndSuspend( 'Umount ', $mountPoint );
            if( UBOS::Utils::myexec( "umount '$target$mountPoint'" )) {
                ++$errors;
            }
        }
    }
    return $errors;
}

##
# Create btrfs subvolumes if needed
# $target: the path where the bootimage has been mounted
# return: number of errors
sub createSubvols {
    my $self   = shift;
    my $target = shift;

    my $errors = 0;

    my $deviceTable = $self->{devicetable}->{'/'};
    if( defined( $deviceTable->{fs} ) && 'btrfs' eq $deviceTable->{fs} ) {
        # create separate subvol for /var/log, so snapper does not roll back the logs
        unless( -d "$target/var" ) {
            UBOS::Utils::mkdirDashP( "$target/var" );

        }

        debugAndSuspend( 'Create subvol ', "$target/var/log" );
        my $out;
        if( UBOS::Utils::myexec( "btrfs subvol create '$target/var/log'", undef, \$out, \$out )) {
            error( "Failed to create btrfs subvol for '$target/var/log':", $out );
            ++$errors;
        }
    } else {
        UBOS::Utils::mkdirDashP( "$target/var/log" );
    }

    return $errors;
}

##
# Generate and save /etc/fstab
# $@mountPathSequence: the sequence of paths to mount
# %$partitions: map of paths to devices
# $target: the path where the bootimage has been mounted
# return: number of errors
sub saveFstab {
    my $self   = shift;
    my $target = shift;

    my $fsTab = <<FSTAB;
#
# /etc/fstab: static file system information
#
# <file system> <dir>   <type>  <options>   <dump>  <pass>

FSTAB

    if( defined( $self->{devicetable} )) {
        my $i=0;

        # shortest first
        foreach my $mountPoint ( sort { length( $a ) <=> length( $b ) } keys %{$self->{devicetable}} ) {
            my $deviceTable = $self->{devicetable}->{$mountPoint};
            my $fs          = $deviceTable->{fs};

            unless( $fs ) {
                next;
            }

            if( 'btrfs' eq $fs ) {
                my @devices = @{$deviceTable->{devices}};

                # Take blkid from first device
                my $uuid;
                UBOS::Utils::myexec( "blkid -s UUID -o value '" . $devices[0] . "'", undef, \$uuid );
                $uuid =~ s!^\s+!!g;
                $uuid =~ s!\s+$!!g;

                trace( 'uuid of btrfs device', $devices[0], 'to be mounted at', $mountPoint, 'is', $uuid );

                my $passno = ( $mountPoint eq '/' ) ? 1 : 2;

                $fsTab .= "UUID=$uuid $mountPoint btrfs rw,relatime";
                # This may not be needed, if 'btrfs device scan' is done during boot
                # and if it is needed, this won't work, because @devices contains /dev/mapper/loopXpY or such
                # $fsTab .= join( '', map { ",device=$_" } @devices );
                $fsTab .= " $i $passno\n";

            } elsif( 'swap' eq $fs ) {
                my @devices = @{$deviceTable->{devices}};

                foreach my $device ( @devices ) {
                    my $uuid;
                    UBOS::Utils::myexec( "blkid -s UUID -o value '" . $device . "'", undef, \$uuid );
                    $uuid =~ s!^\s+!!g;
                    $uuid =~ s!\s+$!!g;

                    trace( 'uuid of swap device', $device, 'is', $uuid );

                    $fsTab .= "UUID=$uuid none swap defaults 0 0\n";
                }

            } else {
                my $device = $deviceTable->{devices}->[0];

                my $uuid;
                UBOS::Utils::myexec( "blkid -s UUID -o value '$device'", undef, \$uuid );
                $uuid =~ s!^\s+!!g;
                $uuid =~ s!\s+$!!g;

                trace( 'uuid of other device', $device, 'to be mounted at', $mountPoint, 'is', $uuid );

                my $passno = ( $mountPoint eq '/' ) ? 1 : 2;

                $fsTab .= "UUID=$uuid $mountPoint $fs rw,relatime $i $passno\n";
            }
            ++$i;
        }
    }
    debugAndSuspend( 'Saving ', "$target/etc/fstab", ":\n$fsTab" );

    UBOS::Utils::saveFile( "$target/etc/fstab", $fsTab, 0644, 'root', 'root' );

    return 0;
}

##
# Obtain the btrfs device mount points that snapper should manage.
# return: list of mount points
sub snapperBtrfsMountPoints {
    my $self = shift;

    my @ret;
    if( defined( $self->{devicetable} )) {
        foreach my $mountPoint ( keys %{$self->{devicetable}} ) {
            my $deviceTable = $self->{devicetable}->{$mountPoint};
            my $fs          = $deviceTable->{fs};

            if( defined( $fs ) && 'btrfs' eq $fs ) {
                push @ret, $mountPoint;
            }
        }
    }
    return @ret;
}

##
# Helper method to determine the names of the root device
# return: the device name(s)
sub getRootDeviceNames {
    my $self = shift;

    my @ret = @{$self->{devicetable}->{'/'}->{devices}};
    return @ret;
}

##
# Determine the boot loader device for this DiskLayout
sub determineBootLoaderDevice {
    my $self = shift;

    # no op, may be overridden
    return 0;
}

# -- statics from here

##
# Reset caches related to information about disks.
# return: number of errors
sub resetDiskCaches {

    my $ret = 0;
    if( UBOS::Utils::myexec( 'partprobe' )) {
        ++$ret;
    }
    $_pathFacts = {};
    $_lsBlk     = undef;
    return $ret;
}

##
# Helper method to determine some facts about a given path, such as whether it is a file,
# a disk, or a partition
# $path: the path
# $fact: the fact to determine
sub _determineDeviceFact {
    my $path = shift;
    my $fact = shift;

    my $facts;
    if( exists( $_pathFacts->{$path} )) {
        $facts = $_pathFacts->{$path};

    } else {
        if( -e $path ) {
            my $absPath = abs_path( $path );

            if( -f $absPath ) {
                $facts = {
                    'devicetype' => 'file'
                };

            } elsif( -d $absPath ) {
                $facts = {
                    'devicetype' => 'directory'
                };

            } elsif( -b $absPath ) {

                unless( $_lsBlk ) {
                    my $out;
                    if( UBOS::Utils::myexec( "lsblk -o NAME,TYPE,PARTUUID,MOUNTPOINT --json -n", undef, \$out )) {
                        fatal( 'lsblk of device failed:', $absPath );
                    }

                    $_lsBlk = UBOS::Utils::readJsonFromString( $out );
                }

                foreach my $deviceEntry ( @{$_lsBlk->{blockdevices}} ) {
                    my $deviceName = $deviceEntry->{name};
                    my $deviceFacts = {
                        'devicetype' => $deviceEntry->{type},
                        'partuuid'   => $deviceEntry->{partuuid},
                        'mountpoint' => $deviceEntry->{mountpoint}
                    };
                    $_pathFacts->{ "/dev/$deviceName" } = $deviceFacts;


                    if( exists( $deviceEntry->{children} )) {
                        # flatten this
                        foreach my $child ( @{$deviceEntry->{children}} ) {
                            my $childName = $child->{name};
                            my $childFacts = {
                                'devicetype' => $child->{type},
                                'partuuid'   => $child->{partuuid},
                                'mountpoint' => $child->{mountpoint}
                            };
                            $_pathFacts->{ "/dev/$childName" } = $childFacts;
                        }
                    }
                }
                if( exists( $_pathFacts->{$absPath} )) {
                    $facts = $_pathFacts->{$absPath};
                }
            } else {
                warning( 'Cannot determine type of path:', $path );
                $facts = {
                    'devicetype' => 'unknown'
                };
            }
        } else {
            $facts = {
                'devicetype' => 'missing'
            };
        }
        $_pathFacts->{$path} = $facts;
    }
    if( $facts && exists( $facts->{$fact} )) {
        return $facts->{$fact};
    } else {
        return undef;
    }
}

##
# Helper method to determine whether a given path points to a file
# $path: the path
sub isFile {
    my $path = shift;

    my $type = _determineDeviceFact( $path, 'devicetype' );
    return $type eq 'file';
}

##
# Helper method to determine whether a given path points to a disk
# $path: the path
sub isDisk {
    my $path = shift;

    my $type = _determineDeviceFact( $path, 'devicetype' );
    return $type eq 'disk';
}

##
# Helper method to determine whether a given path points to a partition
# $path: the path
sub isPartition {
    my $path = shift;

    my $type = _determineDeviceFact( $path, 'devicetype' );
    return $type eq 'part';
}

##
# Helper method to determine whether a given path points to a block device
# $path: the path
sub isBlockDevice {
    my $path = shift;

    my $type = _determineDeviceFact( $path, 'devicetype' );
    return $type eq 'disk' || $type eq 'part';
}

##
# Helper method to determine whether a given path points to a loop device
# $path: the path
sub isLoopDevice {
    my $path = shift;

    my $type = _determineDeviceFact( $path, 'devicetype' );
    return $type eq 'loop';
}

##
# Helper method to determine the PARTUUID of a given device, assuming it has one
# $path: the file's name
sub determinePartUuid {
    my $path = shift;

    my $uuid = _determineDeviceFact( $path, 'partuuid' );
    return $uuid;
}

##
# Helper method to determine the MOUNTPOINT of a given device, or return undef if
# not mounted.
# $path: the file's name
sub determineMountPoint {
    my $path = shift;

    my $mountPoint = _determineDeviceFact( $path, 'mountpoint' );
    if( $mountPoint ) {
        return $mountPoint;
    } else {
        return undef;
    }
}

##
# Helper method to determine whether or not a given device, or a child device
# is mounted. E.g. for /dev/sda, it will return 0 only if neither /dev/sda nor
# any of the /dev/sda1 ... /dev/sdaX are mounted; 1 otherwise
# $path: the block device's
# return: true or false
sub isMountedOrChildMounted {
    my $path = shift;

    if( determineMountPoint( $path )) {
        return 1;
    }

    foreach my $childPath ( keys %$_pathFacts ) {
        if( $childPath =~ m!^$path! ) {
            if( determineMountPoint( $childPath )) {
                return 1;
            }
        }
    }
    return 0;
}

1;
