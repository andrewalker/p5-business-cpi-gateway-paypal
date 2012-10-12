package CPI::Gateway::PayPal;
use Moose;
use DateTime;
use DateTime::Format::Strptime;
use Business::PayPal::IPN;
use Business::PayPal::NVP;
use Carp 'croak';
use namespace::autoclean;

extends 'CPI::Gateway::Base';

has '+checkout_url' => (
    default => 'https://www.paypal.com/cgi-bin/webscr'
);

has '+currency' => (
    default => 'USD',
);

# TODO: make it lazy, and croak if needed
has api_username => (
    isa => 'Str',
    is => 'ro',
    required => 0,
);

has api_password => (
    isa => 'Str',
    is => 'ro',
    required => 0,
);

has signature    => (
    isa => 'Str',
    is => 'ro',
    required => 0,
);

has nvp => (
    isa => 'Business::PayPal::NVP',
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;

        return Business::PayPal::NVP->new(
            live => {
                user => $self->api_username,
                pwd  => $self->api_password,
                sig  => $self->signature,
            },
            branch => 'live'
        );
    }
);

has date_format => (
    isa => 'DateTime::Format::Strptime',
    is => 'ro',
    lazy => 1,
    default => sub {
        DateTime::Format::Strptime->new(
            pattern   => '%Y-%m-%dT%H:%M:%SZ',
            time_zone => 'UTC',
        );
    },
);

sub notify {
    my ( $self, $req ) = @_;

    my $ipn = Business::PayPal::IPN->new( query => $req )
        or die Business::PayPal::IPN->error;

    my %vars = $ipn->vars;

    my $result = {
        payment_id => int($vars{invoice}),
        status     => undef,
        amount     => $vars{mc_gross},
        date       => $vars{payment_date},
    };

    if ($ipn->completed) {
        $result->{status} = 'completed';
    }
    elsif (my $reason = $ipn->pending) {
        $result->{status} = 'processing';
    }
    elsif ($ipn->failed || $ipn->denied) {
        $result->{status} = 'failed';
    }
    else {
        return {}; # unknown status
    }

    return $result;
}

sub query_transactions {
    my ($self, $info) = @_;

    my $final_date   = $info->{final_date}   || DateTime->now(time_zone => 'UTC');
    my $initial_date = $info->{initial_date} || $final_date->clone->subtract(days => 30);

    my %search = $self->nvp->send(
        METHOD    => 'TransactionSearch',
        STARTDATE => $initial_date->strftime('%Y-%m-%dT%H:%M:%SZ'),
        ENDDATE   => $final_date->strftime('%Y-%m-%dT%H:%M:%SZ'),
    );

    if ($search{ACK} ne 'Success') {
        require Data::Dumper;
        croak "Error in the query: " . Data::Dumper::Dumper(\%search);
    }

    while (my ($k, $v) = each %search) {
        if ($k =~ /^L_TYPE(.*)$/) {
            my $deleted_key = "L_TRANSACTIONID$1";
            if (lc($v) ne 'payment') {
                delete $search{$deleted_key};
            }
        }
    }

    my @transaction_ids = map { $search{$_} } grep { /^L_TRANSACTIONID/ } keys %search;

    my @transactions    = map { $self->get_transaction_details($_) } @transaction_ids;

    return {
        current_page         => 1,
        results_in_this_page => scalar @transaction_ids,
        total_pages          => 1,
        transactions         => \@transactions,
    };
}

sub get_transaction_details {
    my ( $self, $id ) = @_;

    my %details = $self->nvp->send(
        METHOD        => 'GetTransactionDetails',
        TRANSACTIONID => $id,
    );

    if ($details{ACK} ne 'Success') {
        require Data::Dumper;
        croak "Error in the details fetching: " . Data::Dumper::Dumper(\%details);
    }

    return {
        payment_id  => $details{INVNUM},
        status      => lc $details{PAYMENTSTATUS},
        amount      => $details{AMT},
        date        => $self->date_format->parse_datetime($details{ORDERTIME}),
        buyer_email => $details{EMAIL},
    };
}

sub get_hidden_inputs {
    my ($self, $info) = @_;

    my @hidden_inputs = (
        # -- make paypal accept multiple items (cart)
        cmd           => '_ext-enter',
        redirect_cmd  => '_cart',
        upload        => 1,
        # --

        business      => $self->receiver_email,
        currency_code => $self->currency,
        charset       => $self->form_encoding,
        invoice       => $info->{payment_id},
        email         => $info->{buyer}->email,

        # TODO: shipping / handling
        no_shipping   => 1,
    );

    my $i = 1;

    foreach my $item (@{ $info->{items} }) {
        push @hidden_inputs,
          (
            "item_number_$i" => $item->id,
            "item_name_$i"   => $item->description,
            "amount_$i"      => $item->price,
            "quantity_$i"    => $item->quantity,
          );
        $i++;
    }

    return @hidden_inputs;
}

__PACKAGE__->meta->make_immutable;

1;

# TODO: POD!
