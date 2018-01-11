package WWW::Easy::SPI;
use strict;
use Encode;
use JSON::XS;
use Data::Dumper;
use Time::HiRes;
use Hash::Merge;
use Clone;
use WWW::Easy::Auth;
use locale;
require "utf8_heavy.pl";


sub from_json { 
	return JSON::XS::decode_json(Encode::encode_utf8($_[0]));
}
sub to_json {
	return Encode::decode_utf8( JSON::XS::encode_json($_[0]));
}
sub unbless_arrays_in_rows { 
	my $rows = shift;
	foreach my $r (@$rows) {
		foreach my $k ( keys %$r) { 
			if (UNIVERSAL::isa($r->{$k} , 'PostgreSQL::InServer::ARRAY')) { 
				$r->{$k} = $r->{$k}->{array};
			}
		}
	}
}

sub parse_daterange { 
	my $range = shift;
	$range =~ s/^\(|\)$//gs;
	return [ map { $_ || undef } split(/,/, $range) ];
}

sub spi_run_query {  # toDo: cache
	my ($sql, $types, $values) = @_;
	my $h   = ::spi_prepare($sql, @$types);
	my $ret = ::spi_exec_prepared($h, @$values);
	## todo: check and log errors
	if($ret) { 
		unbless_arrays_in_rows( $ret->{rows} );
	}
	::spi_freeplan($h);
	return $ret;
}
1;
