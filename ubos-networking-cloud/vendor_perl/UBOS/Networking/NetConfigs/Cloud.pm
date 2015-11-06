#!/usr/bin/perl
#
# A network configuration for a virtual cloud server, currently for EC2
# only.
#
# This file is part of ubos-networking.
# (C) 2012-2015 Indie Computing Corp.
#
# ubos-networking is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ubos-networking is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with ubos-networking.  If not, see <http://www.gnu.org/licenses/>.
#

use strict;
use warnings;

package UBOS::Networking::NetConfigs::Cloud;

use JSON;
use UBOS::Networking::NetConfigUtils;

my $name = 'cloud';

##
# Determine whether this network configuration could currently be activated.
# This return false, if, for example, this network configuration requires two
# ethernet interfaces, but the device has only one ethernet interface attached.
# This will also return true if this configuration is currently active.
# return: 1 or 0
sub isPossible {
    my $allNics = UBOS::Host::nics();
    
    return ( keys %$allNics ) > 0;
}

##
# Activate this network configuration.
# $initOnly: if true, enable services but do not start them (e.g. during ubos-install)
sub activate {
    my $initOnly = shift;

    my $allNics = UBOS::Host::nics();

    my $conf    = UBOS::Networking::NetConfigUtils::readNetconfigConfFileFor( $name );
    my $error   = 0;
    my $updated = 0;

    unless( $conf ) {
        $conf  = {};
        $error = 1;
    }
    foreach my $nic ( keys %$allNics ) {
        unless( exists( $conf->{$nic} )) {
            $conf->{$nic} = {};
        }
        unless( exists( $conf->{$nic}->{dhcp} )) {
            $conf->{$nic}->{dhcp} = JSON::true;
            $updated = 1;
        }
        unless( exists( $conf->{$nic}->{ports} )) {
            $conf->{$nic}->{ports} = JSON::true;
            $updated = 1;
        }
        unless( exists( $conf->{$nic}->{ssh} )) {
            $conf->{$nic}->{ssh} = JSON::true;
            $updated = 1;
        }
        unless( exists( $conf->{$nic}->{'cloud-init'} )) {
            $conf->{$nic}->{'cloud-init'} = JSON::true;
            $updated = 1;
        }
    }
    my $ret = UBOS::Networking::NetConfigUtils::configure( $name, $conf, $initOnly );

    if( $updated && !$error ) {
        UBOS::Networking::NetConfigUtils::saveNetconfigConfFileFor( $name, $conf );
    }
    return $ret;
}

##
# Return help text for this network configuration
# return: help text
sub help {
    return 'Configure networking appropriate for a cloud server using cloud-init.';
}

1;