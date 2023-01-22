package WWW::Easy::DateUtil;
use strict;
use Date::Calc;

sub iso2date { 
	my $x = shift;
	if($x) { 
		if($x =~ /^\s*(\d+)-(\d+)-(\d+)(?:[\sT](\d\d?):(\d\d)(?:-(\d\d))?)?/) {
			return [$1,$2,$3,$4,$5,$6];
		} else {
			die "Bad date format: $x";
		}
	} else {
		return undef;
	}
}
sub date2iso { 
	my $t_iso = shift;
	return $t_iso ? sprintf("%04d-%02d-%02d", @$t_iso) : undef;
}
sub datetime2iso { 
	my $t_iso = shift;
	return $t_iso ? sprintf("%04d-%02d-%02dT%02d:%02d:%02d", @$t_iso) : undef;
}
sub add_days {
	my ($t_iso, $n) = @_;
	return $t_iso ? date2iso( [ Date::Calc::Add_Delta_Days( (@{ iso2date($t_iso) })[0,1,2] , $n) ]) : undef ;
}
sub truncate_to_date {
	return date2iso(iso2date(shift));
}
1;
