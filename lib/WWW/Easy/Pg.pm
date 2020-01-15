package WWW::Easy::Pg;
use strict;
use base 'Exporter';
use DBI::Ext;
our @EXPORT=qw(api_txn);

sub connect {
	my $r = shift;
	return DBI::Ext->new(
		dsn      => $r->dir_config('DSN'), 
		user     => $r->dir_config('DBUSER') || 'httpd',
		password => $r->dir_config('DBPASSWORD'),
		attr     => { 
			pg_enable_utf8 => 1,
			pg_bool_tf => 0,   
		}
	);

}

sub api_txn {
	my ($list, $context) = @_;
	my (@res, $dbh);
	{ no strict 'refs';
	  $dbh = ${$context->{__package__}.'::DBH'} || die("api_txn cannot determine DBH from package $context->{__package__}");
	}
	$context->{in_transaction} = 1;

	$dbh->transaction( sub { 
		foreach my $op (@$list) { 
			my $method = shift @$op;
			my $func = "api_$method";
	        if (my $code = $context->{__package__}->can($func)) { 
                push @res, &$code($op, $context);
	        } else { 
    			die("func $func not found");
	        }
		}
		return 1;
	});
	if($@) { 
		die $@; # sub api() will do:	return {error=>'API Transaction error'};	
	} else { 
		return {result=>\@res};
	}
}

1;
