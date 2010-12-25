#!/usr/bin/env perl
# vim:ts=4:sw=4:expandtab

use strict;
use warnings;
use EV;
use Twiggy::Server;
use Dancer;
use npmd;

my $server = Twiggy::Server->new(
    host => '0.0.0.0',
    port => 5000
);

my $app = sub {
    my $env = shift;
    my $request = Dancer::Request->new( $env );
    Dancer->dance( $request );
};

$server->register_service($app);

EV->loop
#AE::cv->recv
