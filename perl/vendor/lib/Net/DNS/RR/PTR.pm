package Net::DNS::RR::PTR;

#
# $Id: PTR.pm 1188 2014-04-03 18:54:34Z willem $
#
use vars qw($VERSION);
$VERSION = (qw$LastChangedRevision: 1188 $)[1];


use strict;
use base qw(Net::DNS::RR);

=head1 NAME

Net::DNS::RR::PTR - DNS PTR resource record

=cut


use integer;

use Net::DNS::DomainName;


sub decode_rdata {			## decode rdata from wire-format octet string
	my $self = shift;

	$self->{ptrdname} = decode Net::DNS::DomainName1035(@_);
}


sub encode_rdata {			## encode rdata as wire-format octet string
	my $self = shift;

	return '' unless $self->{ptrdname};
	$self->{ptrdname}->encode(@_);
}


sub format_rdata {			## format rdata portion of RR string.
	my $self = shift;

	return '' unless $self->{ptrdname};
	$self->{ptrdname}->string;
}


sub parse_rdata {			## populate RR from rdata in argument list
	my $self = shift;

	$self->ptrdname(shift);
}


sub ptrdname {
	my $self = shift;

	$self->{ptrdname} = new Net::DNS::DomainName1035(shift) if scalar @_;
	$self->{ptrdname}->name if defined wantarray;
}

1;
__END__


=head1 SYNOPSIS

    use Net::DNS;
    $rr = new Net::DNS::RR('name PTR ptrdname');

=head1 DESCRIPTION

Class for DNS Pointer (PTR) resource records.

=head1 METHODS

The available methods are those inherited from the base class augmented
by the type-specific methods defined in this package.

Use of undocumented package features or direct access to internal data
structures is discouraged and could result in program termination or
other unpredictable behaviour.


=head2 ptrdname

    $ptrdname = $rr->ptrdname;
    $rr->ptrdname( $ptrdname );

A domain name which points to some location in the
domain name space.


=head1 COPYRIGHT

Copyright (c)1997-2002 Michael Fuhr. 

All rights reserved.

This program is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

Package template (c)2009,2012 O.M.Kolkman and R.W.Franks.


=head1 SEE ALSO

L<perl>, L<Net::DNS>, L<Net::DNS::RR>, RFC1035 Section 3.3.12

=cut
