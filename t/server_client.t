#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Test::More qw(no_plan);
use POE;

BEGIN {
    use_ok('POE::Component::Server::Bayeux');
    use_ok('POE::Component::Client::Bayeux');
}

my $test_port = 60601;

my $server = POE::Component::Server::Bayeux->spawn(
    Port => $test_port,
    Alias => 'server',
);
isa_ok($server, 'POE::Component::Server::Bayeux');

my $client = POE::Component::Client::Bayeux->spawn(
    Host => '127.0.0.1',
    Port => $test_port,
    Alias => 'client',
);
isa_ok($client, 'POE::Component::Client::Bayeux');

POE::Session->create(
    inline_states => {
        _start => \&start,
        new_message => \&new_message,
    },
);

$poe_kernel->run();

sub start {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    $kernel->alias_set('test_session');

    $kernel->post('client', 'init');
    $kernel->post('client', 'subscribe', '/test/*', 'new_message');
    $kernel->post('client', 'publish', '/test/channel', {
        message => "I am a walrus",
    });
}

sub new_message {
    my ($kernel, $heap, $message) = @_[KERNEL, HEAP, ARG0];

    is( $message->{data}{message}, 'I am a walrus', "Test message received" );

    $kernel->call('client', 'shutdown');
    $kernel->call('server', 'shutdown');
    exit;
}
