# $Id$
##############################################################################
#
#     70_INDEGO.pm
#     An FHEM Perl module for controlling a Bosch Indego.
#
#     Copyright by Ulf von Mersewsky
#     e-mail: umersewsky at gmail.com
#
#     This file is part of fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
#
# Version: 0.3.0
#
##############################################################################

package FHEM::INDEGO;

use strict;
use warnings;
use POSIX;

# wird für den Import der FHEM Funktionen aus der fhem.pl benötigt
use GPUtils qw(:all);

use Time::HiRes qw(gettimeofday);
use JSON qw(decode_json encode_json);
use Encode qw(encode_utf8);
use MIME::Base64;

require HttpUtils;

## Import der FHEM Funktionen
BEGIN {
    GP_Import(
        qw(
          AttrVal
          CommandAttr
          createUniqueId
          fhemTzOffset
          FmtDateTime
          FmtDateTimeRFC1123
          getKeyValue
          getUniqueId
          InternalTimer
          InternalVal
          Log3
          readingFnAttributes
          ReadingsAge
          readingsBeginUpdate
          readingsBulkUpdate
          readingsBulkUpdateIfChanged
          readingsDelete
          readingsEndUpdate
          ReadingsNum
          readingsSingleUpdate
          ReadingsVal
          RemoveInternalTimer
          setKeyValue
          time_str2num
          trim
          )
    );
}

GP_Export(
    qw(
      Initialize
      )
);

my $useDigestMD5 = 0;
if ( eval { require Digest::MD5; 1 } ) {
    $useDigestMD5 = 1;
    Digest::MD5->import();
}

###################################
sub Initialize {
    my ($hash) = @_;

    Log3($hash, 5, "INDEGO_Initialize: Entering");

    $hash->{GetFn}    = \&Get;
    $hash->{SetFn}    = \&Set;
    $hash->{DefFn}    = \&Define;
    $hash->{UndefFn}  = \&Undefine;
    $hash->{DeleteFn} = \&Delete;

    $hash->{AttrList} =
        "disable:0,1 "
      . "actionInterval "
      . $readingFnAttributes;

    return;
}

###################################
sub Define {
    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );
    my $name = $hash->{NAME};

    Log3( $name, 5, "INDEGO $name: called function Define()" );

    if ( int(@a) < 3 ) {
        my $msg =
          "Wrong syntax: define <name> INDEGO <email> [<poll-interval>]";
        Log3( $name, 4, $msg );
        return $msg;
    }

    $hash->{TYPE} = "INDEGO";

    my $email = $a[2];
    $hash->{helper}{EMAIL} = $email;

    # use interval of 300 sec if not defined
    my $interval = 300;

    if (defined($a[3])) {
      if ($a[3] =~ /^[0-9]+$/xms && !defined($a[4])) {
        $interval = $a[3];
      } else {
        StorePassword($hash, $a[3]);
        $interval = $a[4] if (defined($a[4]));
      }
    }
    $hash->{INTERVAL} = $interval;

    CommandAttr( $hash, "$name webCmd mow:pause:returnToDock" )
      if ( AttrVal( $name, 'webCmd', 'none' ) eq 'none' );

    # start the status update timer
    RemoveInternalTimer($hash);
    InternalTimer( gettimeofday() + 2, \&GetStatus, $hash, 1 );

    AddExtension($name, \&GetMap, "INDEGO/$name/map");

    return;
}

###################################
sub Undefine {
    my ( $hash, $arg ) = @_;
    my $name = $hash->{NAME};

    Log3( $name, 5, "INDEGO $name: called function Undefine()" );

    # De-Authenticate
    SendCommand($hash, "deauthenticate");

    # Stop the internal GetStatus-Loop and exit
    RemoveInternalTimer($hash);

    RemoveExtension("INDEGO/$name/map");

    return;
}

###################################
sub Delete {
    my ( $hash, $arg ) = @_;
    my $name = $hash->{NAME};

    Log3( $name, 5, "INDEGO $name: called function Delete()" );

    my $index = $hash->{TYPE} . "_" . $name . "_passwd";
    setKeyValue( $index, undef );

    return;
}
#####################################
sub GetStatus {
    my ( $hash, $update ) = @_;
    my $name     = $hash->{NAME};
    my $interval = $hash->{INTERVAL};

    Log3( $name, 5, "INDEGO $name: called function GetStatus()" );

    # use actionInterval if state is busy, paused, or returning
    $interval = AttrVal($name, "actionInterval", $interval) if (ReadingsVal($name, "state_id", "0") =~ /^[57]\d\d$/xms);

    RemoveInternalTimer($hash);
    InternalTimer( gettimeofday() + $interval, \&GetStatus, $hash, 0 );

    return if ( AttrVal($name, "disable", 0) == 1 );

    # check device availability
    if (!$update) {
      SendCommand( $hash, "state" );
    }

    # cleanup
    readingsDelete( $hash, "cal" );
    readingsDelete( $hash, "fc_cal" );

    return;
}

###################################
sub Get {
    my ( $hash, @a ) = @_;
    my $name = $hash->{NAME};
    my $what;

    Log3( $name, 5, "INDEGO $name: called function Get()" );

    return "argument is missing" if ( int(@a) < 2 );

    $what = $a[1];

    if ( $what =~ /^(mapsvgcache)$/xms ) {
        my $value = ReadingsVal($name, $what, "");
        if ($value eq "") {
          $value = ReadingsVal($name, ".$what", "");
          eval { require Compress::Zlib; };
          unless($@) {
            $value = Compress::Zlib::uncompress($value);
          }
        }
        if ( $value ne "" ) {
            return $value;
        } else {
            return "no such reading: $what";
        }
    } else {
        return "Unknown argument $what, choose one of mapsvgcache:noArg";
    }
}

###################################
sub Set {
    my ( $hash, @a ) = @_;
    my $name  = $hash->{NAME};

    Log3( $name, 5, "INDEGO $name: called function Set()" );

    return "No Argument given" if ( !defined( $a[1] ) );

    my $usage = "Unknown argument " . $a[1];
    $usage .= ", choose one of password renewContext:noArg mow:noArg operatingData:noArg pause:noArg returnToDock:noArg reloadMap:noArg smartMode:on,off";
    $usage .= " deleteAlert:noArg" if (ReadingsVal($name, "alert_id", "-") ne "-");
    $usage .= " calendar:0,1,2,3,4,5";

    # mow
    if ( $a[1] eq "mow" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] );

        SendCommand( $hash, "state", "mow" );
        readingsSingleUpdate($hash, "state", "Set_Mowing", 1);
    }

    # pause
    elsif ( $a[1] eq "pause" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] );

        SendCommand( $hash, "state", "pause" );
        readingsSingleUpdate($hash, "state", "Set_Paused", 1);
    }

    # returnToDock
    elsif ( $a[1] eq "returnToDock" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] );

        SendCommand( $hash, "state", "returnToDock" );
        readingsSingleUpdate($hash, "state", "Set_Returning", 1);
    }

    # reloadMap
    elsif ( $a[1] eq "reloadMap" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] );

        SendCommand( $hash, "map" );
    }

    # renewContext
    elsif ( $a[1] eq "renewContext" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] );

        SendCommand( $hash, "authenticate" );
    }

    # deleteAlert
    elsif ( $a[1] eq "deleteAlert" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] );

        SendCommand( $hash, "deleteAlert" );
    }

    # selectCalendar
    elsif ( $a[1] eq "calendar" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] . " " . $a[2] );

        return "No argument given" if ( !defined( $a[2] ) );

        SendCommand( $hash, "setCalendar", $a[2] );
    }

    # smartMode
    elsif ( $a[1] eq "smartMode" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] . " " . $a[2] );

        return "No argument given" if ( !defined( $a[2] ) );

        SendCommand( $hash, "smartMode", $a[2] );
    }

    #operatingData
    elsif ( $a[1] eq "operatingData" ) {
        Log3( $name, 2, "INDEGO set $name " . $a[1] );

        SendCommand( $hash, "operatingData" );
    }

    # password
    elsif ( $a[1] eq "password") {
        Log3( $name, 2, "INDEGO set $name " . $a[1] );

        return "No password given" if ( !defined( $a[2] ) );

        StorePassword( $hash, $a[2] );
    }

    # return usage hint
    else {
        return $usage;
    }

    return;
}

############################################################################################################
#
#   Begin of helper functions
#
############################################################################################################

#########################
sub AddExtension {
    my ( $name, $func, $link ) = @_;

    my $url = "/$link";
    Log3( $name, 2, "Registering INDEGO $name for URL $url..." );
    $::data{FWEXT}{$url}{deviceName} = $name;
    $::data{FWEXT}{$url}{FUNC}       = $func;
    $::data{FWEXT}{$url}{LINK}       = $link;

    return;
}

#########################
sub RemoveExtension {
    my ($link) = @_;

    my $url  = "/$link";
    my $name = $::data{FWEXT}{$url}{deviceName};
    Log3( $name, 2, "Unregistering INDEGO $name for URL $url..." );
    delete $::data{FWEXT}{$url};

    return;
}

###################################
sub SendCommand {
    my ( $hash, $service, $type, @successor ) = @_;
    my $name        = $hash->{NAME};
    my $email       = $hash->{helper}{EMAIL};
    my $password    = ReadPassword($hash);
    my $timestamp   = gettimeofday();
    my $timeout     = 30;
    my $header;
    my $data;
    my $method      = "GET";

    Log3( $name, 5, "INDEGO $name: called function SendCommand()" );

    my $URL = "https://api.indego.iot.bosch-si.com/api/v1/";
    
    if ($service ne "authenticate") {
      return if CheckContext($hash, $service, $type, @successor);
    }

    Log3( $name, 4, "INDEGO $name: REQ $service" );
    LogSuccessors( $hash, @successor );

    if ($service eq "authenticate") {
      $URL .= $service;
      $header = "Content-Type: application/json";
      $header .= "\r\nAuthorization: Basic ";
      $header .= encode_base64("$email:$password","");
      $data = "{\"device\":\"\", \"os_type\":\"Android\", \"os_version\":\"4.0\", \"dvc_manuf\":\"unknown\", \"dvc_type\":\"unknown\"}";
      $method = "POST";

    } elsif ($service eq "deauthenticate") {
      $URL .= $service;
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");
      $method = "DELETE";

    } elsif ($service eq "alerts") {
      $URL .= $service;
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");

    } elsif ($service eq "deleteAlert") {
      my $id = ReadingsVal($name, "alert_id", "-");
      return if ($id eq "-");

      $URL .= "alerts/$id";
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");
      $method = "DELETE";

    } elsif ($service eq "state") {
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "");
      $URL .= "/$service";
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");
      if (defined($type)) {
        $header .= "\r\nContent-Type: application/json";
        $data = "{\"state\":\"".$type."\"}";
        $method = "PUT";
      }

    } elsif ($service eq "longpollState") {
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "0");
      $URL .= "/state?longpoll=true&timeout=3600&last=";
      $URL .= ReadingsVal($name, "state_id", "0");
      
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");
      $timeout = 3600;
      
      $hash->{LONGPOLL} = time();

    } elsif ($service eq "setCalendar") {
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "");
      $URL .= "/calendar";
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");
      $header .= "\r\nContent-Type: application/json";
      $data = BuildCalendar($hash, $type);
      $method = "PUT";

    } elsif ($service eq "firmware") {
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "");
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");

    } elsif ($service eq "smartMode") {
      my $smartMode = (defined($type) && $type eq "on") ? "true" : "false";
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "");
      $URL .= "/predictive";
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");
      $header .= "\r\nContent-Type: application/json";
      $data  = "{\"enabled\":".$smartMode."}";
      $method = "PUT";

    } else {
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "");
      $URL .= "/$service";
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");

    }

    # send request via HTTP method
    Log3( $name, 5, "INDEGO $name: $method $URL (" . ::urlDecode($data) . ")" )
      if ( defined($data) );
    Log3( $name, 5, "INDEGO $name: $method $URL" )
      if ( !defined($data) );
    Log3( $name, 5, "INDEGO $name: header $header" )
      if ( defined($header) );

    if ( defined($type) && $type eq "blocking" ) {
      my ($err, $return_data) = ::HttpUtils_BlockingGet(
          {
              url         => $URL,
              timeout     => 15,
              noshutdown  => 1,
              header      => $header,
              data        => $data,
              method      => $method,
              hash        => $hash,
              service     => $service,
              timestamp   => $timestamp,
          }
      );
      return $return_data;
    } else {
      ::HttpUtils_NonblockingGet(
          {
              url         => $URL,
              timeout     => $timeout,
              noshutdown  => 1,
              header      => $header,
              data        => $data,
              method      => $method,
              hash        => $hash,
              service     => $service,
              cmd         => $type,
              successor   => \@successor,
              timestamp   => $timestamp,
              callback    => \&ReceiveCommand,
          }
      );
    }

    return;
}

###################################
sub ReceiveCommand {
    my ( $param, $err, $data ) = @_;
    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};
    my $service = $param->{service};
    my $cmd     = $param->{cmd};
    my @successor  = @{ $param->{successor} };

    my $rc = ( $param->{buf} ) ? $param->{buf} : $param;
    my $return;
    
    Log3( $name, 5, "INDEGO $name: called function ReceiveCommand() rc: $rc err: $err data: $data " );

    readingsBeginUpdate($hash);

    # device not reachable
    if ($err) {

        if ( !defined($cmd) || $cmd eq "" ) {
            Log3( $name, 4, "INDEGO $name:$service RCV $err" );
        } else {
            Log3( $name, 4, "INDEGO $name:$service/$cmd RCV $err" );
        }

        # keep last error state
        readingsBulkUpdate($hash, "last_error", $err);
        readingsEndUpdate( $hash, 1 );
    }

    # data received
    elsif ($data) {
      
        if ( !defined($cmd) ) {
            Log3( $name, 4, "INDEGO $name: RCV $service" );
        } else {
            Log3( $name, 4, "INDEGO $name: RCV $service/$cmd" );
        }

        if ( $data ne "" ) {
            if ( $data =~ /^{/xms || $data =~ /^\[/xms ) {
                if ( !defined($cmd) || $cmd eq "" ) {
                    Log3( $name, 4, "INDEGO $name: RES $service - $data" );
                } else {
                    Log3( $name, 4, "INDEGO $name: RES $service/$cmd - $data" );
                }
                $return = decode_json( encode_utf8($data) );
            } elsif ( $service = "map" ) {
                if ( !defined($cmd) || $cmd eq "" ) {
                    Log3( $name, 4, "INDEGO $name: RES $service - $data" );
                } else {
                    Log3( $name, 4, "INDEGO $name: RES $service/$cmd - $data" );
                }
                $return = $data;
            } else {
                Log3( $name, 3, "INDEGO $name: RES ERROR $service\n" . $data );
                if ( !defined($cmd) || $cmd eq "" ) {
                    Log3( $name, 5, "INDEGO $name: RES ERROR $service\n$data" );
                } else {
                    Log3( $name, 5, "INDEGO $name: RES ERROR $service/$cmd\n$data" );
                }
                return;
            }
        }

        # state
        if ( $service eq "state" || $service eq "longpollState") {
          if ( ref($return) eq "HASH" && !defined($cmd)) {
            readingsBulkUpdateIfChanged($hash, "state",          BuildState($hash, $return->{state})) if (defined($return->{state}));
            readingsBulkUpdateIfChanged($hash, "state_id",       $return->{state}) if (defined($return->{state}));
            readingsBulkUpdateIfChanged($hash, "mowed",          $return->{mowed}) if (defined($return->{mowed}));
            readingsBulkUpdateIfChanged($hash, "mowed_ts",       FmtDateTime(int($return->{mowed_ts}/1000))) if (defined($return->{mowed_ts}));
            if ( ref($return->{runtime}) eq "HASH" ) {
              my $runtime = $return->{runtime};
              if ( ref($runtime->{total}) eq "HASH" ) {
                my $total = $runtime->{total};
                my $operate = $total->{operate};
                my $charge = $total->{charge};
                readingsBulkUpdateIfChanged($hash, "totalOperate", GetDuration($hash, $operate));
                readingsBulkUpdateIfChanged($hash, "totalCharge",  GetDuration($hash, $charge));
              }
              if ( ref($runtime->{session}) eq "HASH" ) {
                my $session = $runtime->{session};
                my $operate = $session->{operate};
                my $charge = $session->{charge};
                readingsBulkUpdateIfChanged($hash, "sessionOperate", GetDuration($hash, $operate));
                readingsBulkUpdateIfChanged($hash, "sessionCharge",  GetDuration($hash, $charge));
              }
            }
            readingsEndUpdate( $hash, 1 );

            if (
                (
                       $service eq "state"
                    && AttrVal( $name, "disable", 0 ) == 0
                    && (  !defined( $hash->{LONGPOLL} )
                        || time() - $hash->{LONGPOLL} > 3600 )
                )
                || $service eq "longpollState"
              )
            {
                Log3( $name, 4, "INDEGO $name: Request GET state (longPoll)" );
                # call longpoll outside of command stack
                SendCommand( $hash, "longpollState" );
            }

            push( @successor, [ "alerts", undef ] );
            push( @successor, [ "location", undef ] );
            push( @successor, [ "predictive", undef ] );
            push( @successor, [ "predictive/nextcutting", undef ] );
            push( @successor, [ "predictive/useradjustment", undef ] );
            push( @successor, [ "predictive/useradjustment?withProposal=true", undef ] );
            push( @successor, [ "map", undef ] ) if ($return->{map_update_available});
          }
        }
    
        # firmware
        elsif ( $service eq "firmware" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "alm_name",             $return->{alm_name});
            readingsBulkUpdateIfChanged($hash, "service_counter",      $return->{service_counter});
            readingsBulkUpdateIfChanged($hash, "bareToolnumber",       $return->{bareToolnumber});
            readingsBulkUpdateIfChanged($hash, "alm_firmware_version", $return->{alm_firmware_version});
            readingsBulkUpdateIfChanged($hash, "model",                GetModel($hash, $return->{bareToolnumber}))
                if (defined($return->{bareToolnumber}));

            readingsEndUpdate( $hash, 1 );
          }
        }

        # alerts
        elsif ( $service eq "alerts" ) {
          if ( ref($return) eq "ARRAY" and scalar(@{$return}) > 0) {
            my $date;
            foreach my $alert (@{$return}) {
              my $current_date = time_str2num(substr($alert->{date}, 0, 19));
              if (!defined($date) || $date < $current_date) {
                $date = $current_date;
                readingsBulkUpdateIfChanged($hash, "alert_number",   scalar(@{$return}));
                readingsBulkUpdateIfChanged($hash, "alert_id",       $alert->{alert_id});
                readingsBulkUpdateIfChanged($hash, "alert_headline", $alert->{headline});
                readingsBulkUpdateIfChanged($hash, "alert_date",     FmtDateTime($current_date + fhemTzOffset($current_date)));
                readingsBulkUpdateIfChanged($hash, "alert_message",  $alert->{message});
                readingsBulkUpdateIfChanged($hash, "alert_flag",     $alert->{flag});
                readingsBulkUpdateIfChanged($hash, "alert_status",   $alert->{read_status});
              }
            }
          }
          readingsEndUpdate( $hash, 1 );
        }

        # updates
        elsif ( $service eq "updates" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "updates", $return->{available} ? "available" : "unavailable");

            readingsEndUpdate( $hash, 1 );
          }
        }

        # security
        elsif ( $service eq "security" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "security", $return->{enabled} ? "enabled" : "disabled");
            readingsBulkUpdateIfChanged($hash, "autolock", $return->{autolock} ? "true" : "false");

            readingsEndUpdate( $hash, 1 );
          }
        }

        # automaticUpdate
        elsif ( $service eq "automaticUpdate" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "allow_automatic_update", $return->{allow_automatic_update} ? "true" : "false");

            readingsEndUpdate( $hash, 1 );
          }
        }

        # location
        elsif ( $service eq "location" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "latitude",  $return->{latitude});
            readingsBulkUpdateIfChanged($hash, "longitude", $return->{longitude});

            readingsEndUpdate( $hash, 1 );
          }
        }

        # predictive/nextcutting
        elsif ( $service eq "predictive" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "fc_enabled",  $return->{enabled});

            readingsEndUpdate( $hash, 1 );
          }
        }

        # predictive/location
        elsif ( $service eq "predictive/location" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "fc_loc_latitude",  $return->{latitude});
            readingsBulkUpdateIfChanged($hash, "fc_loc_longitude", $return->{longitude});
            readingsBulkUpdateIfChanged($hash, "fc_loc_timezone",  $return->{timezone});

            readingsEndUpdate( $hash, 1 );
          }
        }

        # predictive/nextcutting
        elsif ( $service eq "predictive/nextcutting" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "mow_next",  $return->{mow_next});

            readingsEndUpdate( $hash, 1 );
          }
        }

        # predictive/useradjustment
        elsif ( $service eq "predictive/useradjustment" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "user_adjustment",  $return->{user_adjustment});

            readingsEndUpdate( $hash, 1 );
          }
        }

        # predictive/useradjustment?withProposal=true
        elsif ( $service eq "predictive/useradjustment?withProposal=true" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "user_adjustment_proposed",  $return->{user_adjustment});

            readingsEndUpdate( $hash, 1 );
          }
        }

        # calendar
        elsif ( $service eq "calendar" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "calendar", $return->{sel_cal});

            my %currentCals;
            foreach ( keys %{ $hash->{READINGS} } ) {
              $currentCals{$_} = 1 if ( $_ =~ /^cal\d_.*/xms );
            }

            if ( ref($return->{cals}) eq "ARRAY" ) {
              my @cals = @{$return->{cals}};
              foreach my $cal (@cals) {
                my @days = @{$cal->{days}};
                for my $day (@days) {
                  my $schedule;
                  my @slots = @{$day->{slots}};
                  for my $slot (@slots) {
                    if ($slot->{En}) {
                      my $slotStr = GetSlotFormatted($hash, $slot);
                      if (defined($schedule)) {
                        $schedule .= " ".$slotStr;
                      } else {
                        $schedule = $slotStr;
                      }
                    }
                  }
                  if (defined($schedule)) {
                    my $reading = "cal".$cal->{cal}."_".$day->{day}."_".GetDay($hash, $day->{day});
                    readingsBulkUpdateIfChanged($hash, $reading, $schedule) ;
                    delete $currentCals{$reading};
                  }
                }
              }
            }

            #remove outdated calendar information
            foreach ( keys %currentCals ) {
              delete( $hash->{READINGS}{$_} );
            }

            readingsEndUpdate( $hash, 1 );
          }
        }

        # predictive/calendar
        elsif ( $service eq "predictive/calendar" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "fc_calendar", $return->{sel_cal});

            my %currentCals;
            foreach ( keys %{ $hash->{READINGS} } ) {
              $currentCals{$_} = 1 if ( $_ =~ /^fc_cal\d_.*/xms );
            }

            if ( ref($return->{cals}) eq "ARRAY" ) {
              my @cals = @{$return->{cals}};
              foreach my $cal (@cals) {
                my @days = @{$cal->{days}};
                for my $day (@days) {
                  my $schedule;
                  my @slots = @{$day->{slots}};
                  for my $slot (@slots) {
                    if ($slot->{En}) {
                      my $slotStr = GetSlotFormatted($hash, $slot);
                      if (defined($schedule)) {
                        $schedule .= " ".$slotStr;
                      } else {
                        $schedule = $slotStr;
                      }
                    }
                  }
                  if (defined($schedule)) {
                    my $reading = "fc_cal".$cal->{cal}."_".$day->{day}."_".GetDay($hash, $day->{day});
                    readingsBulkUpdateIfChanged($hash, $reading, $schedule) ;
                    delete $currentCals{$reading};
                  }
                }
              }
            }

            #remove outdated calendar information
            foreach ( keys %currentCals ) {
              delete( $hash->{READINGS}{$_} );
            }

            readingsEndUpdate( $hash, 1 );
          }
        }

        # predictive/weather
        elsif ( $service eq "predictive/weather" ) {
          if ( ref($return) eq "HASH") {
            if ( ref($return->{LocationWeather}) eq "HASH" ) {
              my $weather = $return->{LocationWeather};
              if ( ref($weather->{location}) eq "HASH" ) {
                my $location = $weather->{location};
                readingsBulkUpdateIfChanged($hash, "fc_loc_name",    $location->{name});
                readingsBulkUpdateIfChanged($hash, "fc_loc_country", $location->{country});
                readingsBulkUpdateIfChanged($hash, "fc_loc_dtz",     $location->{dtz});
              }
            }

            readingsEndUpdate( $hash, 1 );
          }
        }

        # operatingData
        elsif ( $service eq "operatingData" ) {
          if ( ref($return) eq "HASH") {
            if ( ref($return->{battery}) eq "HASH" ) {
              my $battery = $return->{battery};
              readingsBulkUpdateIfChanged($hash, "battery",         $battery->{percent});
              readingsBulkUpdateIfChanged($hash, "battery_temp",    $battery->{battery_temp});
              readingsBulkUpdateIfChanged($hash, "battery_voltage", $battery->{voltage});
            }
            if ( ref($return->{garden}) eq "HASH" ) {
              my $garden = $return->{garden};
              readingsBulkUpdateIfChanged($hash, "garden_size",     $garden->{size});
            }

            readingsEndUpdate( $hash, 1 );
          }
        }

        # map
        elsif ( $service eq "map" ) {
          if ( defined($return) && !ref($return)) {
            my $map = $return;
            eval { require Compress::Zlib; };
            unless($@) {
              $map = Compress::Zlib::compress($map);
            }
            readingsBulkUpdateIfChanged($hash, ".mapsvgcache", $map );
  
            readingsEndUpdate( $hash, 1 );
          }
        }

        # authenticate
        elsif ( $service eq "authenticate" ) {
          if ( ref($return) eq "HASH") {
            readingsBulkUpdateIfChanged($hash, "contextId", $return->{contextId});
            readingsBulkUpdateIfChanged($hash, "userId",    $return->{userId});
            readingsBulkUpdateIfChanged($hash, "alm_sn",    $return->{alm_sn});

            readingsEndUpdate( $hash, 1 );
            
            # new context received - reload state
            push( @successor, [ "state", undef ] );
            push( @successor, [ "firmware", undef ] );
            push( @successor, [ "automaticUpdate", undef ] );
            push( @successor, [ "calendar", undef ] );
            push( @successor, [ "updates", undef ] );
            push( @successor, [ "security", undef ] );
            push( @successor, [ "predictive/calendar", undef ] );
            push( @successor, [ "predictive/location", undef ] );
            push( @successor, [ "predictive/weather", undef ] );
            push( @successor, [ "map", undef ] );
          }
        }
    
        # all other command results
        else {
            Log3( $name, 2, "INDEGO $name: ERROR: method to handle response of $service not implemented" );
        }

    } else {
        if ($rc =~ /401/xms) {
            Log3( $name, 4, "INDEGO $name: authentication context invalidated" ); 
            readingsSingleUpdate($hash, "contextId", "", 1);
            $hash->{LONGPOLL} = 0 if ($service eq "longpollState");

            if ( $service =~ /deleteAlert|setCalendar/xms) {
                CheckContext($hash, $service, undef, @successor);
                return;
            }
            if ($service eq "state" and defined($cmd)) {
                CheckContext($hash, $service, $cmd, @successor);
                return;
            }
        }

        # no alerts
        elsif ( $service eq "alerts" and $rc =~ /204 User found but no alerts were found/) {
            readingsBulkUpdateIfChanged($hash, "alert_number", 0);
            readingsBulkUpdateIfChanged($hash, "alert_id",       "-");
            readingsBulkUpdateIfChanged($hash, "alert_headline", "-");
            readingsBulkUpdateIfChanged($hash, "alert_date",     "-");
            readingsBulkUpdateIfChanged($hash, "alert_message",  "-");
            readingsBulkUpdateIfChanged($hash, "alert_flag",     "-");
            readingsBulkUpdateIfChanged($hash, "alert_status",   "-");
        }

        # deleteAlert
        elsif ( $service eq "deleteAlert" ) {
            push( @successor, [ "alerts", undef ] );
        }

        # setCalendar
        elsif ( $service eq "setCalendar" ) {
            push( @successor, [ "calendar", undef ] );
        }

        # smartMode
        elsif ( $service eq "smartMode" ) {
            readingsBulkUpdateIfChanged($hash, "fc_enabled", ($rc->{cmd} eq "on") ? 1 : 0)
                if ($rc->{httpheader} =~ /HTTP\/1.\d\s200/xms);

            readingsEndUpdate( $hash, 1 );
        }
    }

    if (@successor) {
        my @nextCmd    = @{ shift(@successor) };
        my $cmdLength  = @nextCmd;
        my $cmdService = $nextCmd[0];
        my $cmdType;
        $cmdType       = $nextCmd[1] if ( $cmdLength > 1 );

        SendCommand( $hash, $cmdService, $cmdType, @successor )
          if ( ( $service ne $cmdService )
            or ( defined($cmd) && defined($cmdType) && $cmd ne $cmdType ) );
    }

    return;
}

sub CheckContext {
  my ($hash, $service, $type, @successor) = @_;
  my $name = $hash->{NAME};
  my $contextId = ReadingsVal($name, "contextId", "");
  my $contextAge = ReadingsAge($name, "contextId", 0);

  if ($contextId eq "" or $contextAge > 7200) {
    unshift( @successor, [ $service, $type ] );

    my @succ_item;
    my $msg = " successor:";
    for ( my $i = 0 ; $i < @successor ; $i++ ) {
        @succ_item = @{ $successor[$i] };
        $msg .= " $i: ";
        $msg .= join( ",", map { defined($_) ? $_ : '' } @succ_item );
    }
    Log3( $name, 4, "INDEGO created" . $msg );

    SendCommand($hash, "authenticate", undef, @successor);

    return 1;
  }
  
  return;
}

sub GetSlotFormatted {
  my ($hash,$slot) = @_;
  
  return sprintf("%02d:%02d-%02d:%02d", $slot->{StHr}, $slot->{StMin}, $slot->{EnHr}, $slot->{EnMin});  
}

sub GetDuration {
  my ($hash,$duration) = @_;
  
  return sprintf("%d:%02d", int($duration/60), $duration-int($duration/60)*60);  
}

sub GetDay {
    my ($hash,$day) = @_;
    my $days = {
        '0' => "Mon",
        '1' => "Tue",
        '2' => "Wed",
        '3' => "Thu",
        '4' => "Fri",
        '5' => "Sat",
        '6' => "Sun",
    };

    return $days->{$day};
}

sub GetModel {
    my ($hash,$baretool) = @_;
    my $models = {
        "3600HA2300" => "1000",
        "3600HA2301" => "1200",
        "3600HA2302" => "1100",
        "3600HA2303" => "13C",
        "3600HA2304" => "10C",
        "3600HB0100" => "350",
        "3600HB0101" => "400",
        "3600HB0102" => "S+ 350",
        "3600HB0103" => "S+ 400"
    };
    
    if (defined( $models->{$baretool})) {
        return $models->{$baretool};
    } else {
        return $baretool;
    }
}

sub BuildState {
    my ($hash,$state) = @_;
    my $states = {
           '0' => "Reading status",
         '257' => "Charging",
         '258' => "Docked",
         '259' => "Docked - Software update",
         '260' => "Docked - Charging",
         '261' => "Docked",
         '262' => "Docked - Loading map",
         '263' => "Docked - Saving map",
         '512' => "Leaving dock",
         '513' => "Mowing",
         '514' => "Relocalising",
         '515' => "Loading map",
         '516' => "Learning lawn",
         '517' => "Paused",
         '518' => "Border cut",
         '519' => "Idle in lawn",
         '520' => "Learning lawn",
         '768' => "Returning to dock",
         '769' => "Returning to dock",
         '770' => "Returning to dock",
         '771' => "Returning to dock - Battery low",
         '772' => "Returning to dock - Calendar timeslot ended",
         '773' => "Returning to dock - Battery temp range",
         '774' => "Returning to dock",
         '775' => "Returning to dock - Lawn complete",
         '776' => "Returning to dock - Relocalising",
        '1025' => "Diagnostic mode",
        '1026' => "End of live",
        '1281' => "Software update",
        '1537' => "Low power mode - Check PIN request on display",
       '64513' => "Docked - Waking up"
    };

    if (defined( $states->{$state})) {
        return $states->{$state};
    } else {
        return $state;
    }
}

sub BuildCalendar {
    my ($hash,$selected) = @_;
    my $name = $hash->{NAME};

    # create calendar object
    my @cals;
    for (my $i=1; $i<=5; $i++) {
      my @days;
      for (my $j=0; $j<=6; $j++) {
        my @slots;
        for (my $k=0; $k<2; $k++) {
          my %slot = (
            "En"    => \0,
            "StHr"  => 0,
            "StMin" => 0,
            "EnHr"  => 0,
            "EnMin" => 0
          );
          push(@slots, \%slot);
        }
        my %day = (
          "day"   => $j,
          "slots" => \@slots
        );
        push(@days, \%day);
      }
      my %cal = (
        "cal"  => $i,
        "days" => \@days
      );
      push(@cals, \%cal);
    }

    my $hours       = '([0-2]\d)';
    my $minutes     = '([0-5]\d)';
    my $timestamp   = qq/$hours:$minutes/;
    my $slot        = qq/$timestamp-$timestamp/;
    my $single_slot = qr/$slot/xms;
    my $double_slot = qr/$slot\s$slot/xms;

    # set current data
    foreach ( keys %{ $hash->{READINGS} } ) {
      if ( $_ =~ /^cal(\d)_(\d)_.*/xms ) {
        my $calnr = $1;
        $calnr--; # array starts with 0
        my $daynr = $2;
        my $value = ReadingsVal($name, $_, "");
        if ($value =~ $double_slot) {
          my $slot1 = $cals[$calnr]->{days}[$daynr]->{slots}[0];
          $slot1->{En}    = \1;
          $slot1->{StHr}  = int($1);
          $slot1->{StMin} = int($2);
          $slot1->{EnHr}  = int($3);
          $slot1->{EnMin} = int($4);
          my $slot2 = $cals[$calnr]->{days}[$daynr]->{slots}[1];
          $slot2->{En}    = \1;
          $slot2->{StHr}  = int($5);
          $slot2->{StMin} = int($6);
          $slot2->{EnHr}  = int($7);
          $slot2->{EnMin} = int($8);
        } elsif ($value =~ $single_slot) {
          my $slot1 = $cals[$calnr]->{days}[$daynr]->{slots}[0];
          $slot1->{En}    = \1;
          $slot1->{StHr}  = int($1);
          $slot1->{StMin} = int($2);
          $slot1->{EnHr}  = int($3);
          $slot1->{EnMin} = int($4);
        }
      }
    }
    
    my %calendar = (
      "sel_cal" => int($selected),
      "cals"    => \@cals
    );
    return encode_json(\%calendar);
}

sub StorePassword {
    my ($hash, $password) = @_;
    my $index = $hash->{TYPE}."_".$hash->{NAME}."_passwd";
    my $key = getUniqueId().$index;
    my $enc_pwd = "";

    if ($useDigestMD5) {
      $key = Digest::MD5::md5_hex(unpack "H*", $key);
      $key .= Digest::MD5::md5_hex($key);
    }
    
    for my $char (split //, $password) {
      my $encode=chop($key);
      $enc_pwd.=sprintf("%.2x",ord($char)^ord($encode));
      $key=$encode.$key;
    }
    
    my $err = setKeyValue($index, $enc_pwd);
    return "error while saving the password - $err" if(defined($err));

    return "password successfully saved";
}

sub ReadPassword {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $index = $hash->{TYPE}."_".$hash->{NAME}."_passwd";
    my $key = getUniqueId().$index;
    my ($password, $err);
    
    Log3( $name, 4, "INDEGO $name: Read password from file" );
    
    ($err, $password) = getKeyValue($index);

    if ( defined($err) ) {
      Log3( $name, 3, "INDEGO $name: unable to read password from file: $err" );
      return; 
    }
    
    if ( defined($password) ) {
      if ($useDigestMD5) {
        $key = Digest::MD5::md5_hex(unpack "H*", $key);
        $key .= Digest::MD5::md5_hex($key);
      }
      my $dec_pwd = '';
      for my $char (map { pack('C', hex($_)) } ($password =~ /(..)/gxms)) {
        my $decode=chop($key);
        $dec_pwd.=chr(ord($char)^ord($decode));
        $key=$decode.$key;
      }
      return $dec_pwd;
    } else {
      Log3( $name, 3, "INDEGO $name: No password in file" );
      return;
    }
}

sub LogSuccessors {
    my ( $hash, @successor ) = @_;
    my $name = $hash->{NAME};

    my $msg = "INDEGO $name: successors";
    my @succ_item;
    for ( my $i = 0 ; $i < @successor ; $i++ ) {
        @succ_item = @{ $successor[$i] };
        $msg .= " $i: ";
        $msg .= join( ",", map { defined($_) ? $_ : '' } @succ_item );
    }
    Log3( $name, 4, $msg ) if ( @successor > 0 );

    return;
}

sub ShowMap {
    my ($name,$width,$height) = @_;
    my $hash = $::defs{$name};
    my $compress = 0;

    eval { require Compress::Zlib; };
    unless($@) {
      $compress = 1;
    } 

    my $map = ReadingsVal($name, ".mapsvgcache", "");
    my $data = $map;

    $width  = 800 if (!defined($width));

    if ($map eq "") {
      $map = SendCommand($hash, "map", "blocking");
      $data = $map;
      $map = Compress::Zlib::compress($map) if ($compress);
      readingsSingleUpdate($hash, ".mapsvgcache", $map, 1);
    } else {
      $data = Compress::Zlib::uncompress($data) if ($compress);
    }

    if (defined($data) && $data ne "") {
      if (!defined($height) && $data =~ /viewBox="0\s0\s(\d+)\s(\d+)"/xms) {
        my $factor = $1/$width;
        $height = int($2/$factor);
      }
      my $html;
      $html = '<svg style="width:'.$width.'px; height:'.$height.'px;"' if (defined($height));
      $html .= substr($data, 4);
   
      return $html;
    }
    
    return 'Map currently not available';
}

sub GetMap {
    my ($request) = @_;
    
    if ($request =~ /^\/INDEGO\/(\w+)\/map(\/(\d+)(\/(\d+))?)?/xms) {
      my $name   = $1;
      my $width  = $3;
      my $height = $5;
      
      return ("text/html; charset=utf-8", ShowMap($name, $width, $height));
    }

    return ("text/plain; charset=utf-8", "No INDEGO device for webhook $request");
    
}

1;
=pod
=begin html

<a name="INDEGO"></a>
<h3>INDEGO</h3>
<ul>
  This module controls a Bosch Indego.
  <br><br>
  <b>Define</b>
</ul>

=end html
=begin html_DE

<a name="INDEGO"></a>
<h3>INDEGO</h3>
<ul>
  Diese Module dient zur Steuerung eines Bosch Indego
  <br><br>
  <b>Define</b>
</ul>

=end html_DE
=cut
