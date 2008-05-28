package POE::Component::Server::Bayeux;

=head1 NAME

POE::Component::Server::Bayeux - Bayeux/cometd server implementation in POE

=head1 SYNOPSIS

  use POE qw(Component::Server::Bayeux);

  # Create the server, listening on port 8080
  my $server = POE::Component::Server::Bayeux->spawn(
      Port  => 8080,
      Alias => 'bayeux_server',
  );

  # Create a local client, a reply-bot
  POE::Session->create(
      inline_states => {
          _start => sub {
              my ($kernel, $heap) = @_[KERNEL, HEAP];
              $kernel->alias_set('test_local_client');

              # Subscribe to /chat/demo, assigning a state for events
              $kernel->post('bayeux_server', 'subscribe', {
                  channel => '/chat/demo',
                  client_id => $heap->{client_id},
                  args => {
                      state => 'subscribe_response',
                  },
              });
          },
          subscribe_response => sub {
              my ($kernel, $heap, $message) = @_[KERNEL, HEAP, ARG0];

              # Don't auto-reply to my own messages
              return if $message->{clientId} eq $heap->{client_id};

              # Auto-reply to every message posted
              $kernel->post('bayeux_server', 'publish', {
                  channel => $message->{channel},
                  client_id => $heap->{client_id},
                  data => {
                      user => 'Autobot',
                      chat => "I got your message, ".($message->{data}{user} || 'anon'),
                  },
              });
          },
      },
      heap => {
          client_id => 'test_local_client',
      },
  );

  $poe_kernel->run();

=head1 DESCRIPTION

This module implements the Bayeux Protocol (1.0draft1) from the Dojo Foundation.
Also called cometd, Bayeux is a low-latency routing protocol for JSON encoded
events between clients and servers in a publish-subscribe model.

This is the server implementation.  There is also a client found at
L<POE::Component::Client::Bayeux>.  With this server, you can roll out a cometd
server and basic HTTP server with POE communication capabilities.  It comes bundled
with test code that you can run in your browser to test the functionality for a
basic chat program.

B<Please note>: This is the first release of this code.  Not much testing has been
done, so please keep that in mind if you plan on using this for production.  It was
developed for a production environment that is still being built, so future versions
of this code will be released over the next month that will be more feature complete
and less prone to errors.

=cut

use strict;
use warnings;

use POE qw(
    Component::Server::HTTP
    Component::Server::Bayeux::Client
    Component::Server::Bayeux::Request
);
use HTTP::Status; # for RC_OK
use Params::Validate qw(CODEREF validate);
use FindBin;
use Data::Dumper;
use POE::Component::Server::Bayeux::Utilities qw(:all);

# Logger modules
use base qw(Class::Accessor);
__PACKAGE__->mk_accessors(qw(logger session));
use Log::Log4perl qw(get_logger :levels);
use Log::Log4perl::Appender;
use Log::Log4perl::Layout;

# Basic HTTP server modules
use URI;

## Class globals ###

our $VERSION = '0.01';
our $protocol_version = '1.0';
our $supported_connection_types = [ 'long-polling' ];

## Class locals ###

our %file_types = (
    'application/javascript' => [ qr/\.js$/i ],
    'text/html'              => [ qr/\.html?$/i ],
    'text/css'               => [ qr/\.css$/i ],
    'image/png'              => [ qr/\.png$/i ],
    'image/jpeg'             => [ qr/\.jpe?g$/i ],
    'image/gif'              => [ qr/\.gif$/i ],
);

## Class methods ###

=head1 USAGE

=head2 spawn (...)

=over 4

Create a new Bayeux server.  Arguments to this method:

=over 4

=item I<Port> (default: 80)

Bind an HTTP server to this port.

=item I<Alias> (default: 'bayeux')

The POE session alias for local clients to post to.

=item I<AnonPublish> (default: 0)

Allow HTTP-connected clients to publish without handshake.

=item I<ConnectTimeout> (default: 120)

Seconds before an HTTP-connected client is timed out and forced to rehandshake.
Clients must not go this long between having a connect open.

=item I<Debug> (default: 0)

Either 0 or 1, indicates level of logging.

=item I<LogFile> (default: undef)

If present, opens the file path indicated for logging output.

=item I<DocumentRoot> (default: '../htdocs')

Document root of generic HTTP server for file serving.

=item I<DirectoryIndex> (default: [ 'index.html' ])

Index file (think Apache config).

=item I<TypeExpires> (default: {})

Provide a hashref of MIME types and their associated expiry time.  Similar to
mod_expires 'ExpiresByType $key "access plus $value seconds"'.

=item I<Services> (default: {})

Each key of this hash represents a service channel that will be available.  The
name of the channel will be '/service/$key', and the handling is dependent on
the $value.

If $value is a coderef, the code will be called with a single arg of the message
being acted upon.  The return value(s) of the coderef will be considered response(s)
to be sent back to the client, so return an empty array if you don't want this to
happen (if you've added responses by $message->request->add_response()).

=item I<MessageACL> (defaults: sub {})

Coderef to perform authorization checks on messages.  Code block is passed two args,
the Client, and the Message.  If the message should be rejected, the code should set
is_error() on the message.

One could use this to perform authentication on the 'handshake' message:

  sub {
      my ($client, $message) = @_;

      return unless $message->isa('POE::Component::Server::Bayeux::Message::Meta');
      return unless $message->type eq 'handshake';

      my $error;

      while (1) {
          if (! $message->ext ||
              ! (defined $message->ext->{username} && defined $message->ext->{password})) {
              $error = "Must pass username and password in ext to handshake";
              last;
          }

          my $authenticated = $message->ext->{username} eq 'admin'
              && $message->ext->{password} eq 'password' ? 1 : 0;

          if (! $authenticated) {
              $error = "Invalid username or password";
              last;
          }

          $client->flags->{is_authenticated} = 1;
          last;
      }

      if ($error) {
          $message->is_error($error);
      }
  }

=back

Returns a class object with methods of interest:

=over 4

=item I<logger>

Returns the L<Log::Log4perl> object used by the server.  Use this for unified logging output.

=item I<session>

The L<POE::Session> object returned from an internal create() call.

=back

=back

=cut

sub spawn {
    my $class = shift;
    my %args = validate(@_, {
        Port           => { default => '80' },
        Alias          => { default => 'bayeux' },
        AnonPublish    => { default => 0 },
        Debug          => { default => 0 },
        LogFile        => { default => '' },
        # Client must not go 2 minutes without having an outstanding connect
        ConnectTimeout => { default => 2 * 60 },
        DocumentRoot   => { default => $FindBin::Bin . '/../htdocs' },
        DirectoryIndex => { default => [ 'index.html' ] },
        TypeExpires    => { default => {} },
        Services       => { default => {} },
        MessageACL     => { default => sub {}, type => CODEREF },
    });

    # Setup logger
    my $logger = Log::Log4perl->get_logger('bayeux_server');
    {
        my $logger_layout = Log::Log4perl::Layout::PatternLayout->new("[\%d] \%p: \%m\%n");
        $logger->level($args{Debug} ? $DEBUG : $INFO);

        my $stdout_appender = Log::Log4perl::Appender->new(
            'Log::Log4perl::Appender::Screen',
            name => 'screenlog',
            stderr => 0,
        );
        $stdout_appender->layout($logger_layout);

        $logger->add_appender($stdout_appender);

        if ($args{LogFile}) {
            my $file_appender = Log::Log4perl::Appender->new(
                'Log::Log4perl::Appender::File',
                name => 'filelog',
                filename => $args{LogFile},
            );
            $file_appender->layout( $logger_layout );

            $logger->add_appender($file_appender);
        }
    }

    # Create HTTP server
    my $http_aliases = POE::Component::Server::HTTP->new(
        Port => $args{Port},
        ContentHandler => {
            '/cometd' => sub {
                $poe_kernel->call( $args{Alias}, 'handle_cometd', @_ );
            },
            '/' => sub {
                $poe_kernel->call( $args{Alias}, 'handle_generic', @_ );
            },
        },
    );

    # Create manager session
    my $session = POE::Session->create(
        inline_states => {
            _start => \&manager_start,
            _stop  => \&manager_stop,
            shutdown => \&manager_shutdown,

            handle_cometd    => \&handle_cometd,
            handle_generic   => \&http_server_generic,
            delay_request    => \&delay_request,
            complete_request => \&complete_request,
            
            subscribe        => \&subscribe,
            unsubscribe      => \&unsubscribe,
            publish          => \&publish,
        },
        heap => {
            args => \%args,
            manager => $args{Alias},
            clients => {
            #   example_client_id => {
            #       subscriptions => {
            #           '/chat/demo/not_real' => 1,
            #       },
            #   },
            },
            requests => {
            #   example_request_id => 1,
            },
            logger => $logger,
            http_aliases => $http_aliases,
        },
        options => {
            trace => 0,
            debug => 0,
        },
    );

    my $self = bless { %args, logger => $logger, session => $session }, $class;
    return $self;
}

###### POE States ######################

=head1 POE STATES

Most of the server code is regarding interaction with HTTP-connected clients.
For this, see L<POE::Component::Server::Bayeux::Client>.  It supports locally
connected POE sessions, and for this, makes the following states available.

These same states are called internally to handle the basic PubSub behavior of
the server for all clients, local and HTTP.

=cut

sub manager_start {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    $kernel->alias_set( $heap->{manager} );

    $heap->{logger}->info("Bayeux server started.  Connect to port $$heap{args}{Port}");
}

sub manager_stop {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
}

sub manager_shutdown {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    $heap->{logger}->info("Shutting down");

    while (my $request = values %{ $heap->{requests} }) {
        $request->complete();
    }

    $kernel->call( $heap->{http_session}{httpd}, 'shutdown' );
    $kernel->alarm_remove_all();
}

sub http_server_generic {
    my ($kernel, $heap, $request, $response) = @_[KERNEL, HEAP, ARG0, ARG1];

    my $uri = URI->new($request->uri);
    my $path = $heap->{args}{DocumentRoot} . '/' . $uri->path;

    # Attempt to find a directory index
    if (-d $path) {
        $path .= '/' unless $path =~ m{/$};
        foreach my $index_name (@{ $heap->{args}{DirectoryIndex} }) {
            next unless -f $path . $index_name;
            $path .= $index_name;
            last;
        }

    }
    if (-d $path) {
        $response->code(RC_OK);
        $response->content("Directory listing denied");
    }
    elsif (-f $path) {
        $response->code(RC_OK);
        open my $in, '<', $path;
        if (! $in) {
            $response->content("Unable to open '$path': $!");
            return RC_OK;
        }

        # Find a file type
        my $type;
        foreach my $possible_type (keys %file_types) {
            next unless grep { $path =~ $_ } @{ $file_types{$possible_type} };
            $type = $possible_type;
            last;
        }
        $type ||= 'text/plain';
        $response->content_type($type);

        if (my $whence = $heap->{args}{TypeExpires}{$type}) {
            $response->expires( time() + $whence );
        }

        my $content;
        {
            local $/ = undef;
            $content = <$in>;
        }
        close $in;
        $response->content($content);

        $heap->{logger}->info(sprintf 'Serving %s %s %s', $request->{connection}{remote_ip}, $uri->path, $response->content_type);
    }
    else {
        $response->code(RC_NOT_FOUND);
        $response->content("Path '".$uri->path."' not found");
    }

    return RC_OK;
}

## Remote clients, long-polling ###

sub handle_cometd {
    my ($kernel, $heap, $request, $response) = @_[KERNEL, HEAP, ARG0, ARG1];

    $heap->{logger}->debug("Handling new cometd request");

    my $bayeux_request = POE::Component::Server::Bayeux::Request->new(
        request => $request,
        response => $response,
        server_heap => $heap,
    );
    $bayeux_request->handle();

    if ($bayeux_request->is_complete) {
        $heap->{logger}->debug("Immediate remote response:\n" . Dumper($bayeux_request->json_response));
        return RC_OK;
    }
    else {
        $heap->{requests}{ $bayeux_request->id } = $bayeux_request;
        return RC_WAIT;
    }
}

sub delay_request {
    my ($kernel, $heap, $request_id, $delay) = @_[KERNEL, HEAP, ARG0, ARG1];

    $heap->{logger}->debug("Delaying $delay to process $request_id");
    $kernel->delay('complete_request', $delay, $request_id);
}

sub complete_request {
    my ($kernel, $heap, $request_id) = @_[KERNEL, HEAP, ARG0];

    $heap->{logger}->debug("complete_request($request_id)");

    return unless defined $heap->{requests}{$request_id};
    my $request = delete $heap->{requests}{$request_id};

    eval {
        $request->complete();
    };
    if ($@) {
        $heap->{logger}->error("Couldn't complete request $request_id - mayhap the client went away?");
    }
    else {
        $heap->{logger}->debug("Delayed remote response:\n" . Dumper($request->json_response));
    }
}

## Client agnostic, no auth performed ###

=head2 subscribe ({...})

=over 4

Required keys 'channel', 'client_id'.  Optional key 'args' (hashref).

Subscribes client_id to the channel indicated.  If subscribe() is called by
another session, it's treated as a non-HTTP request and will not perform
authentication on the subscription.  Local clients need not handshake or
connect.

Events published to the subscribed channel are sent to the calling session's
method named 'deliver', which can be overrided by the args hashref key 'state'.
For example:

  $kernel->post('bayeux_server', 'subscribe', {
      channel => '/chat/demo',
      client_id => 'local_client',
      args => {
          state => 'subscribe_events',
      },
  });

=back

=cut

sub subscribe {
    my ($kernel, $heap, $args) = @_[KERNEL, HEAP, ARG0];

    my @args = %$args;
    my %args;
    eval {
        %args = validate(@args, {
            channel => 1,
            client_id => 1,
            args => { default => {} },
        });
    };
    if ($@) {
        $heap->{logger}->error("subscribe() invalid call: $@");
        return;
    }

    # If subscribe() was called by another POE session
    if ($_[SESSION] != $_[SENDER]) {
        # Create a client, thereby storing the session in the client heap
        my $client = POE::Component::Server::Bayeux::Client->new(
            id => $args{client_id},
            session => $_[SENDER],
            server_heap => $heap,
        );
    }

    $args{args}{subscribed} = time;
    $heap->{clients}{ $args->{client_id} }{subscriptions}{ $args->{channel} } = $args{args}
}

=head2 unsubscribe ({...})

=over 4

Required keys 'channel', 'client_id'.

Unsubscribes client_id from the channel indicated.

=back

=cut

sub unsubscribe {
    my ($kernel, $heap, $sender, $args) = @_[KERNEL, HEAP, SENDER, ARG0];

    my @args = %$args;
    my %args;
    eval {
        %args = validate(@args, {
            channel => 1,
            client_id => 1,
        });
    };
    if ($@) {
        $heap->{logger}->error("unsubscribe() invalid call: $@");
        return;
    }

    my $client_heap = $heap->{clients}{ $args->{client_id} };
    return unless $client_heap;
    return unless $client_heap->{subscriptions}{ $args->{channel} };
    delete $client_heap->{subscriptions}{ $args->{channel} };
}

=head2 publish ({...})

=over 4

Required keys 'channel' and 'data'.  Optional keys 'client_id', 'id', and 'ext'.

Publishes a message to the channel specified.  The keys 'client_id', 'id' and
'ext' are passed thru, appended to the message sent.  For local clients who
subscribed from another session, the message is immediately posted to their
callback state.  For HTTP clients, messages are put into queue and flushed if
they have an open /meta/connect.

=back

=cut

sub publish {
    my ($kernel, $heap, $sender, $args) = @_[KERNEL, HEAP, SENDER, ARG0];

    my @args = %$args;
    my %args;
    eval {
        %args = validate(@args, {
            channel => 1,
            client_id => 0,
            data => 1,
            id => 0,
            ext => 0,
        });
    };
    if ($@) {
        $heap->{logger}->error("publish() invalid call: $@");
        return;
    }

    # Check each subscription, getting list of who to send this to

    my %send_to_clients;
    CLIENT:
    foreach my $client_id (keys %{ $heap->{clients} }) {
        my $client_heap = $heap->{clients}{$client_id};
        next unless $client_heap->{subscriptions};
        foreach my $subscribed (keys %{ $client_heap->{subscriptions} }) {
            next unless channel_match($args{channel}, $subscribed);
            my $subscription_args = $client_heap->{subscriptions}{$subscribed};
            $send_to_clients{ $client_id } = $subscription_args;
            next CLIENT;
        }
    }

    my @send_to_clients = keys %send_to_clients;
    return unless @send_to_clients;

    # Construct deliver packet

    my %deliver = (
        map { $_ => $args{$_} }
        grep { defined $args{$_} }
        qw(channel data id ext)
    );
    $deliver{clientId} = $args{client_id} if defined $args{client_id};

    foreach my $client_id (@send_to_clients) {
        my $client = POE::Component::Server::Bayeux::Client->new(
            id => $client_id,
            server_heap => $heap,
        );
        next if ! $client || $client->is_error;
        $client->send_message(\%deliver, $send_to_clients{$client_id});
    }
}

=head1 TODO

Lots of stuff.

The code currently implements only the long-polling transport and doesn't yet
strictly follow all the directives in the protocol document http://svn.xantus.org/shortbus/trunk/bayeux/bayeux.html

=head1 KNOWN BUGS

No known bugs, but I'm sure you can find some.

=head1 SEE ALSO

L<POE>, L<POE::Component::Server::HTTP>

=head1 COPYRIGHT

Copyright (c) 2008 Eric Waters and XMission LLC (http://www.xmission.com/).
All rights reserved.  This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included with
this module.

=head1 AUTHOR

Eric Waters <ewaters@uarc.com>

=cut

1;
