use strict;
package WWW::Easy::ORMAPI;
use strict;
use base 'Exporter';
use DBI::Ext;
our @EXPORT=qw(api_mget api_get api_save api_delete api_setOrder);

sub _get_dbh_and_user {
	my $context = shift;
	no strict 'refs';
	my $dbh  = $context->{DBH}  || ${$context->{__package__}.'::DBH' } || die("api_* cannot determine DBH  from package $context->{__package__}");
	my $user = $context->{USER} || ${$context->{__package__}.'::USER'} || die("api_* cannot determine USER from package $context->{__package__}");
	return ($dbh, $user);
}

sub api_mget { 
	my ($args, $context) = @_;
	my ($tbl, $query, $page, $pagesize) = @$args;
	my ($dbh, $user) = _get_dbh_and_user($context);
	my ($nsp, $tbl) = ($tbl =~ /\./) ? split(/\./,$tbl) : ('public', $tbl);
	my $r = $dbh->selectrow_arrayref('SELECT * FROM orm_interface.mget($1::text, $2::text, $3::idtype, $4::int, $5::int, $6::jsonb)',
		{}, $nsp, $tbl, $user->{id}, $page, $pagesize, WWW::Easy::to_json($query || {} ) );
	return WWW::Easy::from_json($r->[0]);
}

sub api_get { 
	my ($args, $context) = @_;
	my ($tbl, $id, $opt) = @$args;
	my ($dbh, $user) = _get_dbh_and_user($context);
	my ($nsp, $tbl) = ($tbl =~ /\./) ? split(/\./,$tbl) : ('public', $tbl);
	if (my $real_id = $context->{_db}->{_ids}->{ $id }) { $id = $real_id; } 
	my $r = $dbh->selectrow_arrayref('SELECT * FROM orm_interface.mget($1::text, $2::text, $3::idtype, $4::int, $5::int, $6::jsonb)',
		{}, $nsp, $tbl, $user->{id}, 1,1, WWW::Easy::to_json({%{$opt||{}}, id=>$id, without_count=>1})); 
	return { obj=>WWW::Easy::from_json($r->[0])->{list}->[0]};
}

sub api_save { 
	my ($args, $context) = @_;
	my ($tbl, $id, $data) = @$args;
	delete $data->{__return};	
	my ($dbh, $user) = _get_dbh_and_user($context);
	my ($nsp, $tbl) = ($tbl =~ /\./) ? split(/\./,$tbl) : ('public', $tbl);
	my $r = $dbh->selectrow_arrayref('SELECT * FROM orm_interface.save($1::text, $2::text, $3::text, $4, $5::jsonb, $6::jsonb)', 
		{}, $nsp, $tbl, $id, $user->{id}, WWW::Easy::to_json($data), WWW::Easy::to_json($context->{_db} ||+{}));
	my ($obj, $misc) = map { WWW::Easy::from_json($_) } @$r;
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
	return { obj=>$obj };
}

sub api_delete { 
	my ($args, $context) = @_;
	my ($tbl, $id) = @$args;
	my ($dbh, $user) = _get_dbh_and_user($context);
	my ($nsp, $tbl) = ($tbl =~ /\./) ? split(/\./,$tbl) : ('public', $tbl);
	my $r = $dbh->selectrow_arrayref('SELECT * FROM orm_interface.delete($1::text, $2::text, $3::text, $4::idtype, $5::jsonb)',
		{}, $nsp, $tbl, $id, $user->{id}, WWW::Easy::to_json($context->{_db} ||= {}) );
	return  {ok=>1};
}

sub api_setOrder { 
	my ($args, $context) = @_;
	my ($tbl, $ids, $fld) = @$args;
	my ($dbh, $user) = _get_dbh_and_user($context);	
	my ($nsp, $tbl) = ($tbl =~ /\./) ? split(/\./,$tbl) : ('public', $tbl);
	my $r = $dbh->selectrow_arrayref('SELECT * FROM orm_interface.set_order($1::text, $2::text, $3::jsonb, $4::text, $5::idtype, $6::jsonb)',
		{}, $nsp, $tbl, WWW::Easy::to_json($ids), $fld || 'pos', $user->{id}, WWW::Easy::to_json($context->{_db} ||= {}) );
	return  {ok=>1};
}

1;
