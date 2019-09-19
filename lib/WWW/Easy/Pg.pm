package WWW::Easy::Pg;
use strict;
use base 'Exporter';
use DBI;
our @EXPORT=qw(api_txn);

sub connect {
	my $r = shift;
	return DBI->connect($r->dir_config('DSN'), $r->dir_config('DBUSER') || 'httpd', $r->dir_config('DBPASSWORD'), {
		RaiseError => 1, 
		PrintError => 1,
		AutoCommit => 1,
		pg_enable_ut8 => 1,
	}) ||  die $DBI::errstr;
}

sub api_txn {
	my ($list, $context) = @_;
	my (@res, $dbh);
	{ no strict 'refs';
	  $dbh = ${$context->{__package__}.'::DBH'} || die("api_txn cannot detrermine DBH from package $context->{__package__}");
	}
	$dbh->{RaiseError} = 1;
	eval { 
		$dbh->begin_work;
		foreach my $op (@$list) { 
			my $method = shift @$op;
			my $func = "api_$method";
	        if (my $code = $context->{__package__}->can($func)) { 
                push @res, &$code($op, $context);
	        } else { 
    			die("func $func not found");
	        }
		}
		$dbh->commit;
	};
	if($@) { 
		my $err = $@;
		local $dbh->{RaiseError} = 0;
		$dbh->rollback;
		warn $@;
		die $@; # sub api() will do:	return {error=>'API Transaction error'};	
	} else { 
		return {result=>\@res};
	}
}

1;
