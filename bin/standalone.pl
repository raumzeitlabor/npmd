#!/usr/bin/env perl
# vim:ts=4:sw=4:expandtab
# © 2011 Michael Stapelberg
# quick and dirty HTTP-like server which serializes requests to the NPM

use strict;
use warnings;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Data::Dumper;
use Try::Tiny;
use npmd;
use v5.10;

my %conns;
my %state;
my @queue = qw();
my $process_queue = undef;
my $npm = AnyEvent::NPM->new(ip => '192.168.0.178');

sub handle_request {
    my ($req) = @_;

    my $reply = undef;
    say "serving request " . Dumper($req);
    my $fh = $conns{$req->{id}};

    if ($req->{url} =~ /^status/) {
        $npm->status->cb(sub {
            my $cv = shift;
            try {
                my $reply = $cv->recv;
                send_reply($fh, $reply);
            } catch {
                syswrite $fh, "HTTP/1.0 500 Internal Server Error\r\n";
                syswrite $fh, "Content-Length: " . length($_) . "\r\n";
                syswrite $fh, "\r\n";
                syswrite $fh, $_;
            };
        });
        return;
    }

    if ($req->{url} =~ /^port/) {
        my ($port) = ($req->{url} =~ m,port/([0-9]),);
        say "should change port $port";

        my $state = ($req->{content} eq '1');

        $npm->_set_port($port, $state)->cb(sub {
            my $reply = $_[0]->recv;

            send_reply($fh, 'Changed port ' . $port . ' to ' . ($state ? 'on' : 'off'));
        });
    }
}

sub send_reply {
    my ($fh, $reply) = @_;

    syswrite $fh, "HTTP/1.0 200 OK\r\n";
    syswrite $fh, "Connection: close\r\n";
    syswrite $fh, "Content-Type: text/plain\r\n";
    syswrite $fh, "Content-Length: " . length($reply) . "\r\n";
    syswrite $fh, "\r\n";
    syswrite $fh, $reply;
}

tcp_server undef, 5000, sub {
    my ($fh, $host, $port) = @_;

    my $id = "$host:$port";
    $conns{$id} = $fh;
    $state{$id} = { id => $id, step => 0, length => 0 };

    my $timeout;
    my $hdl = AnyEvent::Handle->new(
        fh => $fh,
        on_error => sub {
            say "on_error for $id: " . $_[2];
            $_[0]->destroy;
            delete $conns{$id};
            delete $state{$id};
            undef $timeout;
            my @k = keys %conns;
            say "still " . @k . " clients connected";
            if (@k == 0) {
                $process_queue = undef;
            }
        }
    );
    $timeout = AnyEvent->timer(
        after => 10,
        cb => sub {
            say "Disconnecting $id due to timeout (10 seconds)";
            undef $timeout;
            $hdl->push_shutdown();
            undef $hdl;
            delete $conns{$id};
            delete $state{$id};
        }
    );
    my $reader;
    $reader = sub {
        my $line = $_[1];
        my $s = $state{$id};
        print "read line $line in state " . $s->{step} . " from $id\n";

        # Store method/URL
        my ($method, $url) = ($line =~ m,([A-Z]+) /([^ ]+),);
        if (defined($method) && defined($url)) {
            print "http method $method, url $url\n";
            if ($method eq 'GET') {
                push @queue, { method => $method, url => $url, id => $id };
            } else {
                $s->{method} = $method;
                $s->{url} = $url;
            }
        }

        # Store the Content-Length, if it exists
        if ($line =~ /^Content-Length: /) {
            ($s->{length}) = ($line =~ m,^Content-Length: ([0-9]+),);
        }

        # After an empty line (separates header/body), we go to the next step
        if (length($line) == 0) {
            $s->{step} = 1;
        }

        # If header is done and Content-Length > 0, we read the body data and
        # queue the request
        if ($s->{step} == 0 || $s->{length} == 0) {
            $hdl->push_read(line => $reader);
        } else {
            $hdl->push_read(chunk => $s->{length}, sub {
                say "content: " . $_[1];
                $s->{content} = $_[1];
                push @queue, $s;
            });
        }
    };
    $hdl->push_read(line => $reader);
    $process_queue = AnyEvent->timer(
        after => 0.1,
        interval => 0.1,
        cb => sub {
            while (@queue > 0) {
                my $q = shift @queue;
                # Skip if the client is no longer connected
                next unless exists $conns{$q->{id}};
                handle_request($q);
            }

    });
};

AnyEvent->condvar->recv
