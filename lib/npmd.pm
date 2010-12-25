package npmd;
# vim:ts=4:sw=4:expandtab

use Dancer ':syntax';
use AnyEvent;
use Data::Dumper;
use AnyEvent::NPM;
use IO::All;

our $VERSION = '0.1';

my $npmd_active = 1;
my $npm_status = undef;

# create NPM object
my $npm = AnyEvent::NPM->new(ip => '192.168.0.178');

# schedule status updates every 60 seconds (kind of as a keep-alive)
our $refresh_status;
$refresh_status = AnyEvent->timer(after => 60, interval => 60, cb => sub {
    debug "inside npmd";
});

# trigger initial status update:
$npm->status->cb(sub {
    $npm_status = $_[0]->recv;
});

get '/' => sub {
    my $status = $npm_status;

    # if we did not get the initial status yet, display loading page
    if (!defined($status)) {
        template 'connecting';
    } else {
        template 'status', { status => $status };
    }
};

post '/enable' => sub {
    $npmd_active = 1;
    redirect '/';
};

post '/disable' => sub {
    $npmd_active = 0;
    redirect '/';
};

get '/status' => sub {
    my $status = $npm->status->recv;
    $npm_status = $status;
    content_type 'text/plain';
    return $status;
};

any [ 'put', 'post' ] => '/port/:port' => sub {
    if (!$npmd_active) {
        status 'forbidden';
        return 'npmd manually disabled';
    }

    my $state = (request->body eq '1');
    my $port = params->{port};

    $npm->_set_port($port, $state)->recv;

    content_type 'text/plain';
    return 'Changed port ' . $port . ' to ' . ($state ? 'on' : 'off');
};

true;
