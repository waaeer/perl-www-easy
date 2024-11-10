package WWW::Easy::AnyEventORMAPI;
use WWW::Easy::AnyEventPg;

## Basic API for ORM::Easy through WWW::Easy::AnyEvent and WWW::Easy::AnyEventPg;
use strict;
sub init { 
	my ($db) = @_;
	my ($target_pkg, $file, $line) = caller();
	no strict 'refs';
	*{$target_pkg.'::api_txn'}      = sub { return api_txn     (@_[0,1,2,3,4], $target_pkg, $db); };
	*{$target_pkg.'::api_save'}     = sub { return api_save    (@_[0,1,2,3,4], $db); };
	*{$target_pkg.'::api_delete'}   = sub { return api_delete  (@_[0,1,2,3,4], $db); };
	*{$target_pkg.'::api_setOrder'} = sub { return api_setOrder(@_[0,1,2,3,4], $db); };
	*{$target_pkg.'::api_get'}      = sub { return api_get     (@_[0,1,2,3,4], $db); };
	*{$target_pkg.'::api_mget'}     = sub { return api_mget    (@_[0,1,2,3,4], $db); };
	*{$target_pkg.'::api_msave'}    = sub { return api_msave   (@_[0,1,2,3,4], $db); };
}

sub api_txn { 
	my ($args, $user, $cb, $err_cb, $context, $package, $db) = @_;
	my $actions = $args;
	my @result_accum;   ## prepare result accumulation	

	db_transaction($db, $actions, $context, sub {  # do_op
		my ($op, $conn, $ok_cb, $error_cb) = @_;
		if(ref($op) ne 'ARRAY') { return $error_cb->("Bad tx structure"); } 
		my ($method, @method_args) = @$op;
		my $check = $package->can("can_api_$method");
		my $func  = $package->can("api_$method");
		if(!$func) { 
			warn "No method api_$method\n";
			return $error_cb->("No method $method");
		}
		my $op_ok_cb = sub {
			push @result_accum, $_[0];
			$ok_cb->();
		};
		if($check) { 
			WWW::Easy::Daemon::easy_try {
            	$check->(\@method_args, $user, sub { 
					WWW::Easy::Daemon::easy_try {
            	   		$func->(\@method_args, $user, $op_ok_cb, $error_cb, $context);
					};
					if($@) { warn $@; $error_cb->('Internal error'); }
            	}, $error_cb, $context); 
			};
			if($@) { warn $@; $error_cb->('Internal error'); }
        } else { 
			WWW::Easy::Daemon::easy_try {
	            $func->(\@method_args, $user, $op_ok_cb, $error_cb, $context);
			};
			if($@) { warn $@; $error_cb->('Internal error'); }
        } 	
	},
	sub { # ok_cb
		return $cb->({ result => \@result_accum }); #ok
	}, $err_cb
	);
}

sub api_save { 
	my ($args, $user, $cb, $err_cb, $context, $db) = @_;
	my ($xtbl, $id, $data) = @$args;
	my ($nsp, $tbl) = ($xtbl =~ /\./) ? split(/\./,$xtbl) : ('public', $xtbl);
	delete $data->{__return}; # ui.js передает этот параметр, но тут мы всегда возвращаем объект
	return db_query_json( $context->{_pg} || $db, 
		['SELECT * FROM orm_interface.save($1::text, $2::text, $3::text, auth_interface.add_or_check_internal_user ($4::text), $5::jsonb, $6::jsonb)', $nsp, $tbl, $id, $user, to_json($data), to_json($context->{_db}) ],
		sub { 
#			warn "orm save returned ". Data::Printer::np($res);
			my ($obj, $misc) = @_;
			if($misc->{_ids}) {  # запомним временные id, возникшие внутри
				foreach my $tmp_id (keys %{$misc->{_ids}}) { 
					$context->{_db}->{_ids}->{ $tmp_id } = $misc->{_ids}->{$tmp_id};
				}
			}
			if($misc->{_created_ids}) { 
				foreach my $tmp_id (keys %{$misc->{_created_ids}}) { 
					$context->{_db}->{_created_ids}->{ $tmp_id } = $misc->{_created_ids}->{$tmp_id};
				}
			}
			$cb->({obj=>$obj});
		}, 
		$err_cb,
	);
}

sub api_msave { 
	my ($args, $user, $cb, $err_cb, $context, $db) = @_;
	my ($xtbl, $query, $page, $pagesize, $data) = @$args;
	my ($nsp, $tbl) = ($xtbl =~ /\./) ? split(/\./,$xtbl) : ('public', $xtbl);
	delete $data->{__return}; # ui.js передает этот параметр, но тут мы всегда возвращаем объект
	return db_query_json( $context->{_pg} || $db, 
		['SELECT * FROM orm_interface.msave($1::text, $2::text, auth_interface.add_or_check_internal_user ($3::text), $4::int, $5::int, $6::jsonb, $7::jsonb, $8::jsonb)', $nsp, $tbl, $user, $page, $pagesize, to_json($query), to_json($data), to_json($context->{_db}) ],
		sub { 
#			warn "orm msave returned ". Data::Printer::np($_[0]);
			$cb->({ok=>1});
		}, 
		$err_cb,
	);
}


sub api_delete { 
	my ($args, $user, $cb, $err_cb, $context, $db) = @_;
	my ($xtbl, $id) = @$args;
	my ($nsp, $tbl) = ($xtbl =~ /\./) ? split(/\./,$xtbl) : ('public', $xtbl);
	return db_query( $context->{_pg} || $db, 
		['SELECT * FROM orm_interface.delete($1::text, $2::text, $3::text, auth_interface.add_or_check_internal_user ($4::text), $5::jsonb)', $nsp, $tbl, $id, $user, to_json($context->{_db}) ], 
		sub { 
			my $res = shift;
	#		warn "orm delete returned ". Data::Printer::np($res);
			$cb->({ok=>1});
		}, 
		$err_cb
	);
}

sub api_setOrder { 
	my ($args, $user, $cb, $err_cb, $context, $db) = @_;
	my ($xtbl, $ids) = @$args;
	my ($nsp, $tbl) = ($xtbl =~ /\./) ? split(/\./,$xtbl) : ('public', $xtbl);
	return db_query_json( $context->{_pg} || $db, 
		['SELECT * FROM orm_interface.set_order($1::text, $2::text, $3::jsonb, auth_interface.add_or_check_internal_user ($4::text), $5::jsonb)',
				$nsp, $tbl,to_json($ids), $user , to_json($context->{_db}) 
		], sub { 
			my $misc = shift;
			if($misc->{_ids}) {  # запомним временные id, возникшие внутри
				foreach my $tmp_id (keys %{$misc->{_ids}}) { 
					$context->{_db}->{_ids}->{ $tmp_id } = $misc->{_ids}->{$tmp_id};
				}
			}
			$cb->({ok=>1});
		}, 
		$err_cb 
	);
}


sub api_mget { 
	my ($args, $user, $cb, $err_cb, $context, $db) = @_;
	my ($xtbl, $opt, $page, $page_size) = @$args;	
	my ($nsp, $tbl) = ($xtbl =~ /\./) ? split(/\./,$xtbl) : ('public', $xtbl);
	if($page && !Scalar::Util::looks_like_number($page)) { 
		die("mget: page must be integer, not '$page'");
	}
	if($page_size && !Scalar::Util::looks_like_number($page_size)) { 
		die("mget: page size must be integer, not '$page_size'");
	}

	my $sql = ['select orm_interface.mget($1, $2, auth_interface.check_internal_user ($3), $4, $5, $6)', $nsp, $tbl, $user, $page, $page_size, to_json( $opt ) ]; 

	my $w =  db_query_json( $context->{_pg} || $db, $sql, $cb, $err_cb, $context);
	$context->{'q'} = $w;  # чтоб раньше времени не померло
}

sub api_get { 
	my ($args, $user, $cb, $err_cb, $context, $db) = @_;
	my ($xtbl, $id, $opt) = @$args;	
	my ($nsp, $tbl) = ($xtbl =~ /\./) ? split(/\./,$xtbl) : ('public', $xtbl);
	if($context && $context->{_db} && $context->{_db}->{_ids}) { 
		if(my $new_id = $context->{_db}->{_ids}->{$id}) {
			$id = $new_id;
		}
	}
	$opt = { ($opt ? %$opt : ()), id=>$id, without_count => 1 };
	my $sql = ['select orm_interface.mget($1, $2, auth_interface.check_internal_user ($3), $4, $5, $6)', $nsp, $tbl, $user, 1, 1, to_json( $opt ) ]; 
	my $w =  db_query_json( $context->{_pg} || $db, $sql, sub { 
		my $res = shift;
		$cb->({obj=>$res->{list}->[0]})
	}, $err_cb, $context);
	$context->{'q'} = $w;  # чтоб раньше времени не померло
}





1;
