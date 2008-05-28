package POE::Component::Client::Bayeux::Transport::LongPolling;

use strict;
use warnings;
use POE;
use Data::Dumper;
use HTTP::Request::Common;

use base qw(POE::Component::Client::Bayeux::Transport);

sub extra_states {
    # return an array of method names in this class that I want exposed
    return ( qw( openTunnelWith tunnelResponse ) );
}

sub check {
    my ($kernel, $heap, $types, $version, $xdomain) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
}

sub tunnelInit {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    # Allow parent class to do error checking
    #$class->SUPER::tunnelInit(@_);

    my %connect = (
        channel => '/meta/connect',
        clientId => $heap->{parent_heap}{clientId},
        connectionType => 'long-polling',
    );

    $kernel->yield('openTunnelWith', \%connect);
}

sub openTunnelWith {
    my ($kernel, $heap, @messages) = @_[KERNEL, HEAP, ARG0 .. $#_];
    my $pheap = $heap->{parent_heap};
    $pheap->{_polling} = 1;

    # Ensure clientId is defined
    foreach my $message (@messages) {
        $message->{clientId} = $pheap->{clientId};
    }

    print scalar(localtime()) . " >>> LongPolling tunnel >>>\n".Dumper(\@messages)
        if $pheap->{args}{Debug};

    # Create an HTTP POST request, encoding the messages into JSON
    my $request = POST $pheap->{remote_url},
        [ message => $pheap->{json}->encode(\@messages) ];

    # Create a UUID so I can collect meta info about this request
    my $uuid = $pheap->{uuid}->create_str();
    $heap->{_tunnelsOpen}{$uuid} = { opened => time() };

    # Use parent user agent to make request
    $kernel->post( $pheap->{ua}, 'request', 'tunnelResponse', $request, $uuid );

    # TODO: use $heap->{parent_heap}{advice}{timeout} as a timeout for this connect to reply
}

sub tunnelResponse {
    my ($kernel, $heap, $request_packet, $response_packet) = @_[KERNEL, HEAP, ARG0, ARG1];
    my $pheap = $heap->{parent_heap};
    $pheap->{_polling} = 0;

    my $request_object  = $request_packet->[0];
    my $request_tag     = $request_packet->[1]; # from the 'request' post
    my $response_object = $response_packet->[0];

    my $meta = delete $heap->{_tunnelsOpen}{$request_tag};

    my $json;
    eval {
        $json = $pheap->{json}->decode( $response_object->content );
    };
    if ($@) {
        # Ignore errors if shutting down
        return if $pheap->{_shutdown};
        die "Failed to JSON decode data (error $@).  Content:\n" . $response_object->content;
    }

    print scalar(localtime()) . " <<< LongPolling tunnel <<<\n".Dumper($json)
        if $pheap->{args}{Debug};

    foreach my $message (@$json) {
        $kernel->post( $heap->{parent}, 'deliver', $message );
    }

    $kernel->yield('tunnelCollapse');
}

sub tunnelCollapse {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $pheap = $heap->{parent_heap};

    if ($pheap->{advice} && $pheap->{advice}{reconnect} eq 'none') {
        die "Server asked us not to reconnect";
    }

    return if (! $pheap->{_initialized});

    if ($pheap->{_polling}) {
        print "tunnelCollapse: Wait for polling to end\n" if $pheap->{args}{Debug};
        return;
    }

    if ($pheap->{_connected}) {
        my %connect = (
            channel => '/meta/connect',
            clientId => $pheap->{clientId},
            connectionType => 'long-polling',
        );

        $kernel->yield('openTunnelWith', \%connect);
    }
}

sub sendMessages {
    my ($kernel, $heap, $messages) = @_[KERNEL, HEAP, ARG0];
    my $pheap = $heap->{parent_heap};

    foreach my $message (@$messages) {
        $message->{clientId} = $pheap->{clientId};
    }

    print scalar(localtime()) . " >>> LongPolling >>>\n".Dumper($messages)
        if $pheap->{args}{Debug};

    # Create an HTTP POST request, encoding the messages into JSON
    my $request = POST $pheap->{remote_url},
        [ message => $pheap->{json}->encode($messages) ];

    # Use parent user agent to make request
    $kernel->post( $pheap->{ua}, 'request', 'deliver', $request );
}

sub deliver {
    my ($kernel, $heap, $request_packet, $response_packet) = @_[KERNEL, HEAP, ARG0, ARG1];
    my $pheap = $heap->{parent_heap};

    my $request_object  = $request_packet->[0];
    my $request_tag     = $request_packet->[1]; # from the 'request' post
    my $response_object = $response_packet->[0];

    my $json;
    eval {
        $json = $pheap->{json}->decode( $response_object->content );
    };
    if ($@) {
        die "Failed to JSON decode data (error $@).  Content:\n" . $response_object->content;
    }

    print scalar(localtime()) . " <<< LongPolling <<<\n" . Dumper($json)
        if $pheap->{args}{Debug};

    foreach my $message (@$json) {
        $kernel->post( $heap->{parent}, 'deliver', $message );
    }
}

1;
