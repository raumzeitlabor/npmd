# vim:ts=4:sw=4:expandtab
package AnyEvent::NPM;
use Moose;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use v5.10;

has 'ip' => (is => 'ro', isa => 'Str', required => 1);
has '_handle' => (is => 'rw', isa => 'AnyEvent::Handle', default => undef);

sub _when_connected {
    my ($self, $cb) = @_;

    if (defined($self->_handle)) {
        $cb->();
        return;
    }

    tcp_connect $self->ip, 4001, sub {
        my ($fh) = @_ or die "connect failed: $!";
        say "Connected!";
        my $handle;
        $handle = new AnyEvent::Handle
            fh => $fh,
            on_error => sub {
                warn "handle error: error $_[2]\n";
                $_[0]->destroy;
            },
            on_eof => sub {
                say "eof";
                $handle->destroy; # destroy handle
                warn "done.\n";
            };
        $self->_handle($handle);
        $cb->();
    };
}

sub _command {
    my ($self, $cmd, $replylen, $cb) = @_;

    $self->_when_connected(sub {
        my $handle = $self->_handle;
        my $auth = "5507FFFF" . "12345678" . "5A";
        $handle->push_write($auth);
        $handle->push_read(chunk => 10, sub {
            my ($handle, $chunk) = @_;

            if ($chunk ne 'AA03FFFFA9') {
                say "Could not authenticate at NPM";
                # TODO: error handling
                return;
            }

            say "DEBUG: authenticated, writing $cmd";
            $handle->push_write($cmd);
            $handle->push_read(chunk => $replylen, sub {
                my ($handle, $chunk) = @_;

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

        my ($status) = ($reply =~ /D104FFFF([0-9A-F]{2})/);
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
