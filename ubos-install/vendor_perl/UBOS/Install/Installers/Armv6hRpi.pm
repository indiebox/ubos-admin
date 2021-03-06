#
# Install UBOS on an SD Card for a Raspberry Pi.
#
# Copyright (C) 2014 and later, Indie Computing Corp. All rights reserved. License: see package.
#

use strict;
use warnings;

package UBOS::Install::Installers::Armv6hRpi;

use UBOS::Install::AbstractVolumeLayout;
use UBOS::Logging;
use UBOS::Utils;

use base qw( UBOS::Install::AbstractRpiInstaller );
use fields;

## Constructor inherited from superclass

##
# Check that the provided parameters are correct, and complete incomplete items from
# default except for the disk layout.
# return: number of errors.
sub checkCompleteParameters {
    my $self = shift;

    # override some defaults

    unless( $self->{hostname} ) {
        $self->{hostname}      = 'ubos-raspberry-pi';
    }

    unless( $self->{kernelPackage} ) {
        $self->{kernelPackage} = 'linux-raspberrypi';
    }

    my $errors = $self->SUPER::checkCompleteParameters();

    push @{$self->{devicePackages}}, 'ubos-deviceclass-rpi';

    return $errors;
}

##
# Install the bootloader
# $pacmanConfigFile: the Pacman config file to be used to install packages
# return: number of errors
sub installBootLoader {
    my $self             = shift;
    my $pacmanConfigFile = shift;

    info( 'Installing boot loader' );

    # Copied from the ArchLinuxARM Raspberry Pi image

    my $kernelPars = $self->getAllKernelParameters();

    my $rootDevice;
    if( $self->{rootDevice} ) {
        $rootDevice = $self->{rootDevice};

    } else {
        $rootDevice = 'PARTUUID=' . UBOS::Install::AbstractVolumeLayout::determinePartUuid(
                $self->{volumeLayout}->getRootVolume()->getDeviceNames() );
    }

    my $cmdline = <<CONTENT;
root=$rootDevice rw rootwait rootfstype=btrfs console=ttyAMA0,115200 console=tty1 kgdboc=ttyAMA0,115200 selinux=0 plymouth.enable=0 smsc95xx.turbo_mode=N dwc_otg.lpm_enable=0 elevator=noop $kernelPars
CONTENT

    UBOS::Utils::saveFile( $self->{target} . '/boot/cmdline.txt', $cmdline, 0644, 'root', 'root' );

    UBOS::Utils::saveFile( $self->{target} . '/boot/config.txt', <<CONTENT, 0644, 'root', 'root' );
# uncomment if you get no picture on HDMI for a default "safe" mode
#hdmi_safe=1

# uncomment this if your display has a black border of unused pixels visible
# and your display can output without overscan
#disable_overscan=1

# uncomment the following to adjust overscan. Use positive numbers if console
# goes off screen, and negative if there is too much border
#overscan_left=16
#overscan_right=16
#overscan_top=16
#overscan_bottom=16

# uncomment to force a console size. By default it will be display's size minus
# overscan.
#framebuffer_width=1280
#framebuffer_height=720

# uncomment if hdmi display is not detected and composite is being output
#hdmi_force_hotplug=1

# uncomment to force a specific HDMI mode (this will force VGA)
#hdmi_group=1
#hdmi_mode=1

# uncomment to force a HDMI mode rather than DVI. This can make audio work in
# DMT (computer monitor) modes
#hdmi_drive=2

# uncomment to increase signal to HDMI, if you have interference, blanking, or
# no display
#config_hdmi_boost=4

# uncomment for composite PAL
#sdtv_mode=2

#uncomment to overclock the arm. 700 MHz is the default.
#arm_freq=800

# for more options see http://elinux.org/RPi_config.txt

## Some over clocking settings, governor already set to ondemand

##None
#arm_freq=700
#core_freq=250
#sdram_freq=400
#over_voltage=0

##Modest
#arm_freq=800
#core_freq=300
#sdram_freq=400
#over_voltage=0

##Medium
#arm_freq=900
#core_freq=333
#sdram_freq=450
#over_voltage=2

##High
#arm_freq=950
#core_freq=450
#sdram_freq=450
#over_voltage=6

##Turbo
#arm_freq=1000
#core_freq=500
#sdram_freq=500
#over_voltage=6

gpu_mem_512=64
gpu_mem_256=64

# hardware clock of the Desktop Pi
# device_tree_overlay=i2c-rtc,pcf8563

CONTENT

    return 0;
}

##
# Returns the arch for this device.
# return: the arch
sub arch {
    return 'armv6h';
}

##
# Returns the device class
sub deviceClass {
    return 'rpi';
}

##
# Help text
sub help {
    return 'SD card for Raspberry Pi 1 or Zero';
}

1;
