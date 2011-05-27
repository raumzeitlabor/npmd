# vim:ts=4:sw=4:expandtab
package AnyEvent::NPM;
use Moose;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Dancer::Logger;
use v5.10;

has 'ip' => (is => 'ro', isa => 'Str', required => 1);
has '_handle' => (is => 'rw', isa => 'AnyEvent::Handle', predicate => 'has_handle', clearer => 'clear_handle');

sub _when_connected {
    my ($self, $cb) = @_;

    Dancer::Logger::debug '_when_connected';

    if ($self->has_handle) {
        $cb->(undef);
        return;
    }

    tcp_connect $self->ip, 4001, sub {
	    Dancer::Logger::debug 'connect cb';
        my ($fh) = @_;
        if (!$fh) {
            $cb->($!);
            return;
        }
	    Dancer::Logger::debug 'connected';
        my $handle;
        $handle = new AnyEvent::Handle
            fh => $fh,
            on_eof => sub {
                say "eof";
	    Dancer::Logger::debug 'eof';
                $handle->destroy; # destroy handle
                $self->clear_handle;
                #warn "done.\n";
            };
	    #on_timeout => sub {
	    #        Dancer::Logger::debug 'on_timeout';
	    #    $handle->destroy;
	    #    $self->_handle(undef);
	    #};
        Dancer::Logger::debug 'setting handle';
        $self->_handle($handle);
        Dancer::Logger::debug 'triggering cb';
        $cb->(undef);
    }, sub {
        my ($fh) = @_;

        # timeout: 15 seconds
        15
    };
}

sub _command {
    my ($self, $cmd, $replylen, $cb) = @_;

    $self->_when_connected(sub {
        my ($err) = @_;
        if (defined($err)) {
        Dancer::Logger::debug 'triggering error. ' . $err;
            $cb->();
            return;
        }

        Dancer::Logger::debug 'continuing';
        my $handle = $self->_handle;

	$handle->on_error(sub {
	    Dancer::Logger::debug 'handle error: ' . $_[2];
                #warn "handle error: error $_[2]\n";
	    Dancer::Logger::debug 'destroying';
                $_[0]->destroy;
	    Dancer::Logger::debug 'destroyed';
                $self->clear_handle;
	    Dancer::Logger::debug 'error triggering cb';
		$cb->();
	    Dancer::Logger::debug 'error triggering cb, done';
		#die 'handle error: ' . $_[2];
            });
	# trigger timeout upon 5 seconds without read/write
        my $auth = "5507FFFF" . "12345678" . "5A";
        $handle->push_write($auth);
	$handle->timeout(5);
        $handle->push_read(chunk => 10, sub {
            my ($handle, $chunk) = @_;
        Dancer::Logger::debug 'read chunk: ' . $chunk;

            if ($chunk ne 'AA03FFFFA9') {
                say "Could not authenticate at NPM";
                $cb->();
                return;
            }

            say "DEBUG: authenticated, writing $cmd";
            $handle->push_write($cmd);
            $handle->push_read(chunk => $replylen, sub {
                my ($handle, $chunk) = @_;
        Dancer::Logger::debug 'read reply: ' . $chunk;

		# Disable timeout
		$handle->timeout(0);
                $cb->($chunk);
            });
        });
    });
}

sub _set_port {
    my ($self, $port, $state) = @_;

    my $cv = AE::cv;

    my %portmagic = (
        1 => '7',
        2 => '4',
        3 => '5',
        4 => '2',
        5 => '3',
        6 => '0',
        7 => '1',
        8 => 'E',
    );

    my $onoff = ($state ? 'B' : 'C');
    my $cmd = $onoff . '204FFFF0' . $port . $onoff . $portmagic{$port};

    $self->_command($cmd, 12, sub {
        my ($reply) = @_;
        if (!defined($reply)) {
            $cv->croak('Could not communicate with NPM');
            return;
        }

        say "DEBUG: reply to $cmd is $reply";
        $cv->send(1);
    });

    return $cv
}

sub on {
    my ($self, $port) = @_;
    return $self->_set_port($port, 1);
}

sub off {
    my ($self, $port) = @_;
    return $self->_set_port($port, 0);
}

sub status {
    my ($self, $port) = @_;

    my $cv = AE::cv;

    $self->_command('D103FFFFD2', 12, sub {
        my ($reply) = @_;

        Dancer::Logger::debug 'status cb called';

        if (!defined($reply)) {
            $cv->croak('Could not communicate with NPM');
            return;
        }

        my ($status) = ($reply =~ /D104FFFF([0-9A-F]{2})/);
        if (!defined($status)) {
            $cv->croak('Invalid port status');
            return;
        }
        say "DEBUG: port status = $status";
        my $is = hex $status;

        # User asked for a specific port
        if (defined($port)) {
            $cv->send(($is & (1 << ($port-1))) > 0 ? 1 : 0);
        } else {
            my $status = '00000000';
            for (my $c = 0; $c < 8; $c++) {
                substr($status, $c, 1) = ($is & (1 << $c)) > 0 ? '1' : '0';
            }

            $cv->send($status);
        }
    });

    $cv
}

1
