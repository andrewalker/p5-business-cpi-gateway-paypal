package Business::CPI::Gateway::PayPal::IPN;
# ABSTRACT: Instant Payment Notifications
use Moo;
use LWP::UserAgent ();

# VERSION

has is_valid => (
    is      => 'lazy',
    default => sub {
        my $self = shift;

        for ($self->response->decoded_content) {
            return 0 if /^INVALID$/;
            return 1 if /^VERIFIED$/;

            die "Vague response: " . $_;
        }
    }
);

has vars => (
    is      => 'lazy',
    default => sub {
        my $self = shift;

        my $query = $self->query;
        my %vars;

        map { $vars{$_} = $query->param($_) } $query->param;

        return \%vars;
    },
);

has gateway_url => (
    is => 'ro',
    default => sub { 'https://www.paypal.com/cgi-bin/webscr' },
);

has query => (
    is      => 'ro',
    default => sub { require CGI; CGI->new() },
);

has user_agent_name => (
    is => 'ro',
    default => sub {
        my $base    = 'Business::CPI::Gateway::PayPal';
        my $version = __PACKAGE__->VERSION;

        return $version ? "$base/$version" : $base;
    }
);

has user_agent => (
    is      => 'lazy',
    default => sub {
        my $self = shift;

        my $ua = LWP::UserAgent->new();
        $ua->agent( $self->user_agent_name );

        return $ua;
    },
);

has response => (
    is      => 'lazy',
    default => sub {
        my $self = shift;

        my $ua   = $self->user_agent;
        my %vars = %{ $self->vars };
        my $gtw  = $self->gateway_url;

        $vars{cmd} = "_notify-validate";

        my $r = $ua->post( $gtw, \%vars );

        die "Couldn't connect to '$gtw': " . $r->status_line
            if $r->is_error;

        return $r;
    },
);

1;
