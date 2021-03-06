package Net::DNS::Packet;

#
# $Id: Packet.pm 1282 2014-10-27 09:45:19Z willem $
#
use vars qw($VERSION);
$VERSION = (qw$LastChangedRevision: 1282 $)[1];


=head1 NAME

Net::DNS::Packet - DNS protocol packet

=head1 SYNOPSIS

    use Net::DNS::Packet;

    $query = new Net::DNS::Packet( 'example.com', 'MX', 'IN' );

    $reply = $resolver->send( $query );


=head1 DESCRIPTION

A Net::DNS::Packet object represents a DNS protocol packet.

=cut


use strict;
use integer;
use Carp;

use constant UDPSZ => 512;

BEGIN {
	require Net::DNS::Header;
	require Net::DNS::Question;
	require Net::DNS::RR;
}

use constant OLDDNSSEC => Net::DNS::RR->COMPATIBLE;
my @dummy_header = OLDDNSSEC ? ( header => {} ) : ();


=head1 METHODS

=head2 new

    $packet = new Net::DNS::Packet( 'example.com' );
    $packet = new Net::DNS::Packet( 'example.com', 'MX', 'IN' );

    $packet = new Net::DNS::Packet();

If passed a domain, type, and class, new() creates a Net::DNS::Packet
object which is suitable for making a DNS query for the specified
information.  The type and class may be omitted; they default to A
and IN.

If called with an empty argument list, new() creates an empty packet.

=cut

sub new {
	return &decode if ref $_[1];
	my $class = shift;

	my $self = bless {
		question   => [],
		answer	   => [],
		authority  => [],
		additional => [],
		@dummy_header		## Net::DNS::SEC 0.17 compatible
		}, $class;

	$self->{question} = [Net::DNS::Question->new(@_)] if scalar @_;

	$self->header->rd(1);
	return $self;
}


#=head2 decode

=pod

    $packet = new Net::DNS::Packet( \$data );
    $packet = new Net::DNS::Packet( \$data, 1 );	# debug

If passed a reference to a scalar containing DNS packet data, a new
packet object is created by decoding the data.
The optional second boolean argument enables debugging output.

Returns undef if unable to create a packet object.

Decoding errors, including data corruption and truncation, are
collected in the $@ ($EVAL_ERROR) variable.


    ( $packet, $length ) = new Net::DNS::Packet( \$data );

If called in array context, returns a packet object and the number
of octets successfully decoded.

Note that the number of RRs in each section of the packet may differ
from the corresponding header value if the data has been truncated
or corrupted during transmission.

=cut

use constant HEADER_LENGTH => length pack 'n6', (0) x 6;

sub decode {
	my $class = shift;
	my $data  = shift;
	my $debug = shift || 0;

	my $offset = 0;
	my $self;
	eval {
		local $SIG{__WARN__} = sub { die @_ };
		die 'corrupt wire-format data' if length($$data) < HEADER_LENGTH;

		# header section
		my ( $id, $status, @count ) = unpack 'n6', $$data;
		my ( $qd, $an, $ns, $ar ) = @count;
		$offset = HEADER_LENGTH;

		$self = bless {
			id	   => $id,
			status	   => $status,
			count	   => [@count],
			question   => [],
			answer	   => [],
			authority  => [],
			additional => [],
			answersize => length $$data,
			@dummy_header	## Net::DNS::SEC 0.17 compatible
			}, $class;

		# question/zone section
		my $hash = {};
		my $record;
		while ( $qd-- ) {
			( $record, $offset ) = decode Net::DNS::Question( $data, $offset, $hash );
			CORE::push( @{$self->{question}}, $record );
		}

		# RR sections
		while ( $an-- ) {
			( $record, $offset ) = decode Net::DNS::RR( $data, $offset, $hash );
			CORE::push( @{$self->{answer}}, $record );
		}

		while ( $ns-- ) {
			( $record, $offset ) = decode Net::DNS::RR( $data, $offset, $hash );
			CORE::push( @{$self->{authority}}, $record );
		}

		while ( $ar-- ) {
			( $record, $offset ) = decode Net::DNS::RR( $data, $offset, $hash );
			CORE::push( @{$self->{additional}}, $record );
		}

		return $self;
	};

	if ( $debug && $self ) {
		local $@;
		$self->print;
	}

	return wantarray ? ( $self, $offset ) : $self;
}


=head2 data

    $data = $packet->data;
    $data = $packet->data( $size );

Returns the packet data in binary format, suitable for sending as a
query or update request to a nameserver.

Truncation may be specified using a non-zero optional size argument.

=cut

sub data {
	my ( $self, $size ) = @_;
	$self->truncate($size) if $size;			# temp fix for RT#91306
	&encode;
}

sub encode {
	my $self = shift;

	my $ident = $self->header->id;				# packet header

	for ( my $edns = $self->edns ) {			# EDNS support
		my @xopt = grep !$_->isa('Net::DNS::RR::OPT'), @{$self->{additional}};
		unshift( @xopt, $edns ) if $edns->defined;
		$self->{additional} = \@xopt;
	}

	my @part = qw(question answer authority additional);
	my @size = map scalar( @{$self->{$_}} ), @part;
	my $data = pack 'n6', $ident, $self->{status}, @size;
	$self->{count} = [];

	my $hash = {};						# packet body
	foreach my $component ( map @{$self->{$_}}, @part ) {
		$data .= $component->encode( length $data, $hash, $self );
	}

	return $data;
}


=head2 header

    $header = $packet->header;

Constructor method which returns a Net::DNS::Header object which
represents the header section of the packet.

=cut

sub header {
	my $self = shift;
	bless \$self, q(Net::DNS::Header);
}


=head2 EDNS extended header

    $edns    = $packet->edns;
    $version = $edns->version;
    $size    = $edns->size;

Auxiliary function edns() provides access to EDNS extensions.

=cut

sub edns {
	my $self = shift;
	my $link = \$self->{xedns};
	($$link) = grep $_->isa(qw(Net::DNS::RR::OPT)), @{$self->{additional}} unless $$link;
	$$link ||= new Net::DNS::RR( type => 'OPT' );
}


=head2 reply

    $reply = $query->reply( $UDPmax );

Constructor method which returns a new reply packet.

The optional UDPsize argument is the maximum UDP packet size which
can be reassembled by the local network stack, and is advertised in
response to an EDNS query.

=cut

sub reply {
	my $query  = shift;
	my $UDPmax = shift;
	my $qheadr = $query->header;
	die 'erroneous qr flag in query packet' if $qheadr->qr;

	my $reply  = new Net::DNS::Packet();
	my $header = $reply->header;
	$header->qr(1);						# reply with same id, opcode and question
	$header->id( $qheadr->id );
	$header->opcode( $qheadr->opcode );
	my @question = $query->question;
	$reply->{question} = [@question];

	$header->rcode('FORMERR');				# failure to provide RCODE is sinful!

	$header->rd( $qheadr->rd );				# copy these flags into reply
	$header->cd( $qheadr->cd );

	$reply->edns->size($UDPmax) if $query->edns->defined;
	return $reply;
}


=head2 question, zone

    @question = $packet->question;

Returns a list of Net::DNS::Question objects representing the
question section of the packet.

In dynamic update packets, this section is known as zone() and
specifies the DNS zone to be updated.

=cut

sub question {
	my @qr = @{shift->{question}};
}

sub zone {&question}


=head2 answer, pre, prerequisite

    @answer = $packet->answer;

Returns a list of Net::DNS::RR objects representing the answer
section of the packet.

In dynamic update packets, this section is known as pre() or
prerequisite() and specifies the RRs or RRsets which must or must
not preexist.

=cut

sub answer {
	my @rr = @{shift->{answer}};
}

sub pre		 {&answer}
sub prerequisite {&answer}


=head2 authority, update

    @authority = $packet->authority;

Returns a list of Net::DNS::RR objects representing the authority
section of the packet.

In dynamic update packets, this section is known as update() and
specifies the RRs or RRsets to be added or deleted.

=cut

sub authority {
	my @rr = @{shift->{authority}};
}

sub update {&authority}


=head2 additional

    @additional = $packet->additional;

Returns a list of Net::DNS::RR objects representing the additional
section of the packet.

=cut

sub additional {
	my @rr = @{shift->{additional}};
}


=head2 print

    $packet->print;

Prints the packet data on the standard output in an ASCII format
similar to that used in DNS zone files.

=cut

sub print { print &string; }


=head2 string

    print $packet->string;

Returns a string representation of the packet.

=cut

sub string {
	my $self = shift;

	my $header = $self->header;
	my $update = $header->opcode eq 'UPDATE';

	my $server = $self->{answerfrom};
	my $string = $server ? ";; Answer received from $server ($self->{answersize} bytes)\n" : "";

	$string .= ";; HEADER SECTION\n" . $header->string;

	my $question = $update ? 'ZONE' : 'QUESTION';
	my @question = map $_->string, $self->question;
	my $qdcount  = scalar @question;
	my $qds	     = $qdcount != 1 ? 's' : '';
	$string .= join "\n;; ", "\n;; $question SECTION ($qdcount record$qds)", @question;

	my $answer = $update ? 'PREREQUISITE' : 'ANSWER';
	my @answer  = map $_->string, $self->answer;
	my $ancount = scalar @answer;
	my $ans	    = $ancount != 1 ? 's' : '';
	$string .= join "\n", "\n\n;; $answer SECTION ($ancount record$ans)", @answer;

	my $authority = $update ? 'UPDATE' : 'AUTHORITY';
	my @authority = map $_->string, $self->authority;
	my $nscount   = scalar @authority;
	my $nss	      = $nscount != 1 ? 's' : '';
	$string .= join "\n", "\n\n;; $authority SECTION ($nscount record$nss)", @authority;

	my @additional = map $_->string, $self->additional;
	my $arcount    = scalar @additional;
	my $ars	       = $arcount != 1 ? 's' : '';
	$string .= join "\n", "\n\n;; ADDITIONAL SECTION ($arcount record$ars)", @additional;

	return "$string\n\n";
}


=head2 answerfrom

    print "packet received from ", $packet->answerfrom, "\n";

Returns the IP address from which this packet was received.
User-created packets will return undef for this method.

=cut

sub answerfrom {
	my $self = shift;

	return $self->{answerfrom} = shift if scalar @_;

	return $self->{answerfrom};
}


=head2 answersize

    print "packet size: ", $packet->answersize, " bytes\n";

Returns the size of the packet in bytes as it was received from a
nameserver.  User-created packets will return undef for this method
(use length($packet->data) instead).

=cut

sub answersize {
	return shift->{answersize};
}


=head2 push

    $ancount = $packet->push( prereq => $rr );
    $nscount = $packet->push( update => $rr );
    $arcount = $packet->push( additional => $rr );

    $nscount = $packet->push( update => $rr1, $rr2, $rr3 );
    $nscount = $packet->push( update => @rr );

Adds RRs to the specified section of the packet.

Returns the number of resource records in the specified section.

=cut

sub push {
	my $self = shift;
	my $list = $self->_section(shift);
	my @rr	 = grep ref($_), @_;

	if ( $self->header->opcode eq 'UPDATE' ) {
		my $zclass = ( $self->zone )[0]->zclass;
		foreach (@rr) {
			$_->class($zclass) unless $_->class =~ /ANY|NONE/;
		}
	}

	return CORE::push( @$list, @rr );
}


=head2 unique_push

    $ancount = $packet->unique_push( prereq => $rr );
    $nscount = $packet->unique_push( update => $rr );
    $arcount = $packet->unique_push( additional => $rr );

    $nscount = $packet->unique_push( update => $rr1, $rr2, $rr3 );
    $nscount = $packet->unique_push( update => @rr );

Adds RRs to the specified section of the packet provided that the
RRs are not already present in the same section.

Returns the number of resource records in the specified section.

=cut

sub unique_push {
	my $self = shift;
	my $list = $self->_section(shift);
	my @rr	 = grep ref($_), @_;

	if ( $self->header->opcode eq 'UPDATE' ) {
		my $zclass = ( $self->zone )[0]->zclass;
		foreach (@rr) {
			$_->class($zclass) unless $_->class =~ /ANY|NONE/;
		}
	}

	my %unique = map { ( bless( {%$_, ttl => 0}, ref($_) )->canonical, $_ ) } @$list, @rr;

	@$list = ();
	return CORE::push( @$list, values %unique );
}

sub safe_push {
	carp 'safe_push() deprecated: replaced by unique_push()';
	&unique_push;
}


=head2 pop

    my $rr = $packet->pop( 'pre' );
    my $rr = $packet->pop( 'update' );
    my $rr = $packet->pop( 'additional' );

Removes a single RR from the specified section of the packet.

=cut

sub pop {
	my $self = shift;
	my $list = $self->_section(shift);

	return CORE::pop(@$list);
}


my %_section = (			## section name abbreviation table
	'ans' => 'answer',
	'pre' => 'answer',
	'aut' => 'authority',
	'upd' => 'authority',
	'add' => 'additional'
	);

sub _section {				## returns array reference for section
	my $self = shift;
	my $name = shift;
	my $list = $_section{unpack 'a3', $name} || $name;
	return $self->{$list} || [];
}


# =head2 dn_comp

#     $compname = $packet->dn_comp("foo.example.com", $offset);

# Returns a domain name compressed for a particular packet object, to
# be stored beginning at the given offset within the packet data.  The
# name will be added to a running list of compressed domain names for
# future use.

# =cut

sub dn_comp {
	my ($self, $fqdn, $offset) = @_;

	my @labels = Net::DNS::name2labels($fqdn);
	my $hash   = $self->{compnames};
	my $data   = '';
	while (@labels) {
		my $name = join( '.', @labels );

		return $data . pack( 'n', 0xC000 | $hash->{$name} ) if defined $hash->{$name};

		my $label = shift @labels;
		my $length = length($label) || next;		   # skip if null
		if ( $length > 63 ) {
			$length = 63;
			$label = substr( $label, 0, $length );
			carp "\n$label...\ntruncated to $length octets (RFC1035 2.3.1)";
		}
		$data .= pack( 'C a*', $length, $label );

		next unless $offset < 0x4000;
		$hash->{$name} = $offset;
		$offset += 1 + $length;
	}
	$data .= chr(0);
}


# =head2 dn_expand

#     use Net::DNS::Packet qw(dn_expand);
#     ($name, $nextoffset) = dn_expand(\$data, $offset);

#     ($name, $nextoffset) = Net::DNS::Packet::dn_expand(\$data, $offset);

# Expands the domain name stored at a particular location in a DNS
# packet.  The first argument is a reference to a scalar containing
# the packet data.  The second argument is the offset within the
# packet where the (possibly compressed) domain name is stored.

# Returns the domain name and the offset of the next location in the
# packet.

# Returns undef if the domain name could not be expanded.

# =cut


# This is very hot code, so we try to keep things fast.  This makes for
# odd style sometimes.

sub dn_expand {
#FYI	my ($packet, $offset) = @_;
	return dn_expand_XS(@_) if $Net::DNS::HAVE_XS;
#	warn "USING PURE PERL dn_expand()\n";
	return dn_expand_PP(@_, {} );	# $packet, $offset, anonymous hash
}

sub dn_expand_PP {
	my ($packet, $offset, $visited) = @_;
	my $packetlen = length $$packet;
	my $name = '';

	while ( $offset < $packetlen ) {
		unless ( my $length = unpack("\@$offset C", $$packet) ) {
			$name =~ s/\.$//o;
			return ($name, ++$offset);

		} elsif ( ($length & 0xc0) == 0xc0 ) {		# pointer
			my $point = 0x3fff & unpack("\@$offset n", $$packet);
			die 'Exception: unbounded name expansion' if $visited->{$point}++;

			my ($suffix) = dn_expand_PP($packet, $point, $visited);

			return ($name.$suffix, $offset+2) if defined $suffix;

		} else {
			my $element = substr($$packet, ++$offset, $length);
			$name .= Net::DNS::wire2presentation($element).'.';
			$offset += $length;
		}
	}
	return undef;
}


=head2 sign_tsig

    $query = Net::DNS::Packet->new( 'www.example.com', 'A' );

    $query->sign_tsig(
		'Khmac-sha512.example.+165+01018.private',
		fudge => 60
		);

    $reply = $res->send( $query );

    $reply->verify( $query ) || die $reply->verifyerr;

Attaches a TSIG resource record object, which will be used to sign
the packet (see RFC 2845).

The TSIG record can be customised by optional additional arguments to
sign_tsig() or by calling the appropriate Net::DNS::RR::TSIG methods.

If you wish to create a TSIG record using a non-standard algorithm,
you will have to create it yourself.  In all cases, the TSIG name
must uniquely identify the key shared between the parties, and the
algorithm name must identify the signing function to be used with the
specified key.

    $tsig = Net::DNS::RR->new(
		name		=> 'tsig.example',
		type		=> 'TSIG',
		algorithm	=> 'custom-algorithm',
		key		=> '<base64 key text>',
		sig_function	=> sub {
					  my ($key, $data) = @_;
						...
					}
		);

    $query->sign_tsig( $tsig );


The historical simplified syntax is still available, but additional
options can not be specified.

    $packet->sign_tsig( $key_name, $key );


The response to an inbound request is signed by presenting the request
in place of the key parameter.

    $response = $request->reply;
    $response->sign_tsig( $request, @options );


Multi-packet transactions are signed by chaining the sign_tsig()
calls together as follows:

    $opaque  =	$packet1->sign_tsig( 'Kexample.+165+13281.private' );
    $opaque  =	$packet2->sign_tsig( $opaque );
		$packet3->sign_tsig( $opaque );

The opaque intermediate object references returned during multi-packet
signing are not intended to be accessed by the end-user application.
Any such access is expressly forbidden.

Note that a TSIG record is added to every packet; this implementation
does not support the suppressed signature scheme described in RFC2845.

=cut

sub sign_tsig {
	my $self = shift;

	my $tsig = eval {
		require Net::DNS::RR::TSIG;
		Net::DNS::RR::TSIG->create(@_);
	} || croak "$@\nTSIG: unable to sign packet";

	$self->push( 'additional', $tsig );
	return $tsig;
}


=head2 verify and verifyerr

    $packet->verify()		|| die $packet->verifyerr;
    $reply->verify( $query )	|| die $reply->verifyerr;

Verify TSIG signature of packet or reply to the corresponding query.


    $opaque  =	$packet1->verify( $query ) || die $packet1->verifyerr;
    $opaque  =	$packet2->verify( $opaque );
    $verifed =	$packet3->verify( $opaque ) || die $packet3->verifyerr;

The opaque intermediate object references returned during multi-packet
verify() will be undefined (Boolean false) if verification fails.
Access to the object itself, if it exists, is expressly forbidden.
Testing at every stage may be omitted, which results in a BADSIG error
on the final packet in the absence of more specific information.

=cut

sub verify {
	my $self = shift;

	my $sig = $self->sigrr || return undef;
	return $sig->verify( $self, @_ );
}

sub verifyerr {
	my $self = shift;

	my $sig = $self->sigrr || return 'not signed';
	return $sig->vrfyerrstr;
}


=head2 sign_sig0

SIG0 support is provided through the Net::DNS::RR::SIG class.
This class is not integrated into Net::DNS but resides in the
Net::DNS::SEC distribution available from CPAN.

    $update = new Net::DNS::Update('example.com');
    $update->push( update => rr_add('foo.example.com A 10.1.2.3'));
    $update->sign_sig0('Kexample.com+003+25317.private');

Execution will be terminated if Net::DNS::RR::SIG is not available.


=head2 verify SIG0

    $packet->verify( $keyrr )		|| die $packet->verifyerr;
    $packet->verify( [$keyrr, ...] )	|| die $packet->verifyerr;

Verify SIG0 packet signature against one or more specified KEY RRs.

=cut

sub sign_sig0 {
	my $self = shift;
	my $karg = shift || return undef;

	my $sig0 = eval {
		unless ( my $kref = ref($karg) ) {
			return Net::DNS::RR::SIG->create( '', $karg );

		} elsif ( $kref eq 'Net::DNS::RR::SIG' ) {
			return $karg;

		} elsif ( $kref eq 'Net::DNS::SEC::Private' ) {
			return Net::DNS::RR::SIG->create( '', $karg );
		} else {
			die "unexpected $kref argument passed to sign_sig0";
		}
	} || croak "$@\nSIG0: Net::DNS::SEC not available";

	$self->push( 'additional', $sig0 );
	return $sig0;
}


=head2 truncate

The truncate method takes a maximum length as argument and then tries
to truncate the packet and set the TC bit according to the rules of
RFC2181 Section 9.

The minimum maximum length that is honoured is 512 octets.

=cut

# From RFC2181:
#9. The TC (truncated) header bit
#
#   The TC bit should be set in responses only when an RRSet is required
#   as a part of the response, but could not be included in its entirety.
#   The TC bit should not be set merely because some extra information
#   could have been included, for which there was insufficient room. This
#   includes the results of additional section processing.  In such cases
#   the entire RRSet that will not fit in the response should be omitted,
#   and the reply sent as is, with the TC bit clear.  If the recipient of
#   the reply needs the omitted data, it can construct a query for that
#   data and send that separately.
#
#   Where TC is set, the partial RRSet that would not completely fit may
#   be left in the response.  When a DNS client receives a reply with TC
#   set, it should ignore that response, and query again, using a
#   mechanism, such as a TCP connection, that will permit larger replies.

# Code inspired on a contribution from Aaron Crane via rt.cpan.org 33547

sub truncate {
	my $self=shift;
	my $max_len=shift;
	my $debug=0;
	$max_len=$max_len>UDPSZ?$max_len:UDPSZ;

	print "Truncating to $max_len\n" if $debug;

	if (length $self->encode() > $max_len) {
		# first remove data from the additional section
		while (length $self->encode() > $max_len){
			# first remove _complete_ RRstes from the additonal section.
			my $popped= CORE::pop(@{$self->{'additional'}});
			last unless defined($popped);
			print "Removed ".$popped->string." from additional \n" if $debug;
			my $i=0;
			my @stripped_additonal;

			while ( $i < scalar @{$self->{'additional'}} ) {
				#remove all of these same RRtypes
				if  (
				    ${$self->{'additional'}}[$i]->type eq $popped->type &&
				    ${$self->{'additional'}}[$i]->name eq $popped->name &&
				    ${$self->{'additional'}}[$i]->class eq $popped->class ){
					print "       Also removed ". ${$self->{'additional'}}[$i]->string." from additonal \n" if $debug;				}else{
					CORE::push @stripped_additonal,  ${$self->{'additional'}}[$i];
				}
				$i++;
			}
			$self->{'additional'}=\@stripped_additonal;
		}

		return $self if length $self->encode <= $max_len;

      		my @sections = qw<authority answer question>;
		while (@sections) {
			while (my $popped=$self->pop($sections[0])) {
				last unless defined($popped);
				print "Popped ".$popped->string." from the $sections[0] section\n" if $debug;
				$self->header->tc(1);
				return $self if length $self->encode <= $max_len;
				next;
			}
			shift @sections;
		}
	}
	return $self;
}


########################################

sub dump {				## print internal data structure
	require Data::Dumper;
	local $Data::Dumper::Maxdepth = 6;
	local $Data::Dumper::Sortkeys = 1;
	print Data::Dumper::Dumper(@_);
}


sub sigrr {				## obtain packet signature RR
	my $self = shift;

	my ($sig) = reverse $self->additional;
	return undef unless $sig;
	return $sig if $sig->type eq 'TSIG';
	return $sig if $sig->type eq 'SIG';
	return undef;
}


sub DESTROY { }				## Avoid tickling AUTOLOAD (in cleanup)

use vars qw($AUTOLOAD);

sub AUTOLOAD {				## Default method
	no strict;
	@_ = ("method $AUTOLOAD undefined");
	goto &{'Carp::confess'};
}


1;
__END__


=head1 COPYRIGHT

Copyright (c)1997-2002 Michael Fuhr.

Portions Copyright (c)2002-2004 Chris Reinhardt.

Portions Copyright (c)2002-2009 Olaf Kolkman

Portions Copyright (c)2007-2013 Dick Franks

All rights reserved.

This program is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.


=head1 SEE ALSO

L<perl>, L<Net::DNS>, L<Net::DNS::Update>, L<Net::DNS::Header>,
L<Net::DNS::Question>, L<Net::DNS::RR>, L<Net::DNS::RR::TSIG>,
RFC1035 Section 4.1, RFC2136 Section 2, RFC2845

=cut

