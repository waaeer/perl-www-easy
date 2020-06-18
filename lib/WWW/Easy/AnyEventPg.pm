package WWW::Easy::AnyEventPg;
use strict;
use AnyEvent::Pg::Pool; 
use WWW::Easy::Daemon;  # for easy_try
use base 'Exporter';
# Postgres stuff for anyevent daemons
our @EXPORT = qw(db_connect db_query db_query_rows db_query_json db_query_scalar db_query_row_hashes
    db_transaction from_json to_json from_intarray to_intarray to_textarray process_json_result is_true
);

sub db_connect { 
	my ($dbhp, $connect_opts, $pool_opts) = @_;
	$pool_opts ||= {};
	$$dbhp = AnyEvent::Pg::Pool->new({
			connect_timeout => 2, 
			%$connect_opts,
		},
		size               =>10,
		connection_retries => 2,
		connection_delay   => 2,
		%$pool_opts,
		on_connect_error   => sub { 
			my ($pool, $pg) = @_; 
			warn "Connection error $connect_opts->{user}\@$connect_opts->{host}:$connect_opts->{port}/$connect_opts->{dbname}\n";
			if($pool->is_dead) { 
				warn "Pool is dead\n";
				db_connect(\$dbhp, $connect_opts, $pool_opts); # vivat the pool!
			}
   		},
	);	
}

sub db_query { 
	my ($db, $query, $cb, $err_cb) = @_;
	my $q;
#warn "WAO DB_QUERY (".(ref($query)? '['.join(', ', @$query).']' :$query).", $cb, $err_cb)\n";
	$q = $db->push_query(
		query     => $query,
		on_result => sub  {
			my $pg = shift;
			my $conn = $pg->isa('AnyEvent::Pg::Pool') ? shift : $pg;
			### почему это сделано? Если мы работаем с пулом, то параментры (pg,con,res); если с коннектом - внутри транзакции - то (pg,res);
			my $res = shift;
			my $status = $res->status;
			undef $q;

			if($status eq 'PGRES_TUPLES_OK') {
				return $cb->($res);
			} elsif ($status eq 'PGRES_COMMAND_OK') {
				return $cb->($res, $pg, $conn );  # needed in transaction
			} else { 
				warn "RES STATUS=".$res->status." in ".(ref($query) eq 'ARRAY' ? join(', ', @$query) : $query )."\n";
				my $errmsg = $res->errorMessage;
				warn "ERROR '$errmsg' cb=$err_cb\n";
				my $user_error = 'Internal error';
				if($errmsg =~ /^ERROR:\s+ORM:\s*(.*)$/s) {
					my $err = $1;
					if($err =~ /^\{/) { # если начинается на { - это JSON
						$user_error = WWW::Easy::Daemon::easy_try { _extract_json_prefix($err) } || 'Incorrect JSON error message';
					}
				} elsif ($errmsg =~ /^ERROR:\s+update or delete on table "([^"]+)" violates foreign key constraint "([^"]+)" on table "([^"]+)"/) { 
					$user_error = { error => 'integrity', table => $3 };
				}
				return $err_cb->($user_error);
			}
		},
		on_error => sub { 
			warn "Error in db_query ".Data::Printer::np(@_);
			return $err_cb->('Database connection pool error');
        } 
	);
	return $q;
}

sub db_query_rows { 
	my ($db, $query, $cb, $err_cb) = @_;
	return db_query($db, $query, sub { $cb->([shift->rows]) }, $err_cb);
}

sub db_query_row_hashes { 
	my ($db, $query, $cb, $err_cb) = @_;
	return db_query ($db, $query, sub { $cb->([shift->rowsAsHashes]) }, $err_cb);
}
sub db_query_json { 
	my ($db, $query, $cb, $err_cb) = @_;
	return db_query ($db, $query, sub { $cb->(process_json_result($_[0])) }, $err_cb);
}

sub db_query_scalar { 
	my ($db, $query, $cb, $err_cb) = @_;
	return db_query ($db, $query, sub { $cb->((shift->rows)[0]->[0]) }, $err_cb);
}

sub _extract_json_prefix { 
	my $res = shift;
	return $res ? (JSON::XS->new->decode_prefix(Encode::encode_utf8($res)))[0] : undef;
}

sub to_json { 
	my $res = shift;
	return $res ? Encode::decode_utf8( JSON::XS::encode_json( $res )) : undef;
}
sub from_json { 
	my $res = shift;
       if($res) {
                my $ret = WWW::Easy::Daemon::easy_try { JSON::XS::decode_json(Encode::encode_utf8($res)) };
                if($@) { 
                        warn "bad json $res: $@\n";
                        return undef;
                }
                return $ret;
        }
        return undef;   
}
sub to_intarray {
	my $ids = shift;
	return '{'.join(',',@{$ids||[]}).'}';
}
sub to_textarray {
	my $ids = shift;
	return '{'.join(',' , map { $_=~ s/"/\\"/g; "\"$_\"" } @{$ids||[]}).'}';
}

sub from_intarray { 
	my $txt = shift;
	$txt =~ s/^\{|\}//g;
	return [ split(',', $txt) ];
}

sub is_true { 
	my $x = shift;
	return ($x && $x ne 'f');
}

sub process_json_result { 
	my $res = shift;
	return wantarray 
		? ( map { from_json($_) || {null=>1} } @{($res->rows)[0]} )
		: (       from_json(                     ($res->rows)[0]->[0]) || {null=>1} );
}

sub db_transaction {
	my ($dbh, $actions, $context, $do_op, $cb, $error_cb) = @_;
	my @queries;
	$context->{_queries} = \@queries;
	$context->{_db} = {};
	my $conn_to_rollback;

	my $in_error_cb = $context->{error_cb} =  sub {		
		my $err = shift;
		@$actions = (); ## опустошаем список команд, чтобы больше ничего делать 
		warn "ROLL BACK ($err)\n";
		#  Мы можем попасть сюда при попытке сделать BEGIN, тогда $conn_to_rollback ещё не определён.
		if($conn_to_rollback) {
 			push @queries, $conn_to_rollback->push_query(query=>'ROLLBACK', on_result=> sub {
					$error_cb->($err);
				}, on_error=>sub {
					$error_cb->($err);
				}
			);
		} else {
			$error_cb->($err);
			#if($db->is_dead) { $db->{dead} = 0; } # revive
		}
	};

	my $run_one;
	$run_one = sub {  # выполнить очередную команду из транзакции
		my ($conn) = @_;
		$context->{_pg} = $conn;
		if(!(@$actions)) {  # Commit in nothing more to execute
#			warn "committing txn\n"; 
			push @queries, $conn->push_query(query=>'COMMIT', on_result=> $cb, on_error=>$in_error_cb);
			return;
		}
#warn "CMD in TX=".Data::Printer::np($tx);
		my $op = shift @$actions;
		if(ref($op) ne 'ARRAY') { $in_error_cb->("Bad tx structure"); } 
		$do_op->($op, $conn, sub { $run_one->($conn); } # если все ок, выполняем следующую команду
		, $in_error_cb);
	};
#warn "begin txn\n";
	my $q = db_query( $dbh, 'BEGIN TRANSACTION', sub {
		my ($res, $pg, $conn) = @_;
		$conn_to_rollback = $conn;
		$run_one->($conn);		
	}, $in_error_cb );
	push @queries, $q;
	return $q;

}



1;
